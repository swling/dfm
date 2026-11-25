#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/dfm-common.sh"
PHP_VERSION_STATE="${STATE_DIR}/php-version"
FRANKENPHP_VERSION_STATE="${STATE_DIR}/frankenphp-version"
AUTO_CONFIRM=0

usage() {
    cat <<'EOF'
Usage:
  upgrade.sh [--yes] [frankenphp [version]]
  upgrade.sh [--yes] php <branch>
  upgrade.sh [--yes] mysql [version]

Components:
  frankenphp  Upgrade FrankenPHP and php-zts-* packages inside the active
              PHP branch. Same-branch upgrades belong here.
  php         Switch to another PHP branch (8.2 / 8.3 / 8.4 / 8.5). The APT
              source is switched and the php-zts-* packages are reinstalled.
  mysql       Upgrade mysql-server from the Oracle APT repository configured
              by install.sh. The data directory is not touched.

With no component, an interactive menu is shown. FrankenPHP and MySQL versions
may be upstream versions (for example 1.2.3 or 8.4.0) or full APT versions.
The php component takes a major.minor branch such as 8.4.

This script does NOT back up data or configuration; back up before upgrading.
Interactive upgrades require typing "yes" to accept the risk. --yes skips that
confirmation but requires an explicit version; non-interactive upgrades require
both an explicit version and --yes.

After upgrading PHP across branches, third-party extensions installed by
addons.sh must be reinstalled for the new branch. php-zts-* packages keep the
same names across branches, so apt replaces them in place; check for leftovers
only if a package was dropped by the new branch.
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

info() {
    printf '  - %s\n' "$*"
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || fail "Run this command as root (for example: sudo ./upgrade.sh)."
}

require_debian() {
    local major
    [[ -r /etc/os-release ]] || fail "This script requires Debian."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == debian ]] || fail "Only Debian is supported."
    major="${VERSION_ID%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] && ((major >= 13)) ||
        fail "This script requires Debian 13 or later."
}

list_package_versions() {
    local package=$1 origin=${2:-}
    apt-cache madison "$package" |
        awk -F'|' -v origin="$origin" '
            {
                repository = tolower($3)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                if ($2 != "" && (origin == "" || index(repository, tolower(origin)))) {
                    print $2
                }
            }' |
        sort -Vu
}

version_matches() {
    local available=$1 requested=$2 normalized
    [[ "$available" == "$requested" ]] && return 0
    normalized="${available#*:}"
    [[ "$normalized" == "$requested"-* ||
       "$normalized" == "$requested"~* ||
       "$normalized" == "$requested"+* ]]
}

resolve_package_version() {
    local package=$1 requested=$2 minimum_major=${3:-0} origin=${4:-}
    local version normalized major selected=
    local -a versions matches

    mapfile -t versions < <(list_package_versions "$package" "$origin")
    matches=()
    for version in "${versions[@]}"; do
        normalized="${version#*:}"
        major="${normalized%%.*}"
        [[ "$major" =~ ^[0-9]+$ ]] || continue
        ((major >= minimum_major)) || continue
        if [[ -z "$requested" ]] || version_matches "$version" "$requested"; then
            matches+=("$version")
        fi
    done
    ((${#matches[@]} > 0)) ||
        fail "No matching APT version for ${package}${requested:+ (${requested})} from ${origin:-configured repositories}. Available versions: ${versions[*]:-none}"

    if [[ -z "$requested" ]]; then
        selected="${matches[${#matches[@]}-1]}"
        if [[ -t 0 ]]; then
            printf 'Available versions for %s:\n' "$package" >&2
            printf '  %s\n' "${matches[@]}" >&2
            read -r -p "Version to install [${selected}]: " requested
            if [[ -n "$requested" ]]; then
                resolve_package_version "$package" "$requested" "$minimum_major" "$origin"
                return
            fi
        fi
        printf '%s' "$selected"
        return
    fi

    ((${#matches[@]} == 1)) ||
        fail "Version ${requested} is ambiguous for ${package}; use one of: ${matches[*]}"
    printf '%s' "${matches[0]}"
}

confirm_risk() {
    local component=$1 answer
    if ((AUTO_CONFIRM)); then
        return
    fi
    [[ -t 0 ]] || fail "Refusing to upgrade without an interactive confirmation (or pass --yes)."
    printf '\n================================================================\n' >&2
    printf 'WARNING: %s upgrade will modify this system.\n' "$component" >&2
    printf 'This script does NOT create backups. Back up your data and\n' >&2
    printf 'configuration yourself before proceeding.\n' >&2
    printf '\nTo accept the risk, type exactly:\n' >&2
    printf '\n            >>>  yes  <<<\n\n' >&2
    printf '================================================================\n' >&2
    read -r -p "Type yes to continue (anything else cancels): " answer
    [[ "$answer" == yes ]] || fail "Upgrade cancelled."
}

print_apt_plan() {
    local component=$1
    shift
    printf '\nAPT plan for %s:\n' "$component"
    apt-get -s install "$@"
}

run_apt_install() {
    DEBIAN_FRONTEND=readline apt-get install -y \
        -o Dpkg::Options::=--force-confold "$@"
}

read_state() {
    local path=$1 value=
    [[ -r "$path" ]] || fail "State file is missing: ${path}"
    IFS= read -r value < "$path" || true
    printf '%s' "$value"
}

configure_frankenphp_repository() {
    local branch=$1 code source_target keyring_target repo_url
    local key_tmp source_tmp fingerprint previous_branch previous_code stale_source stale_key
    local architecture

    architecture="$(dpkg --print-architecture)"
    [[ "$architecture" == amd64 || "$architecture" == arm64 ]] ||
        fail "The FrankenPHP deb repository does not support this architecture: ${architecture}"

    code="${branch//./}"
    source_target="$(frankenphp_source_path "$branch")"
    keyring_target="$(frankenphp_keyring_path "$branch")"
    repo_url="${FRANKENPHP_REPO_BASE}/${code}/debian"

    install -d -m 0755 /etc/apt/keyrings "$(dirname "$source_target")"
    key_tmp="$(mktemp)"
    source_tmp="$(mktemp "${source_target}.XXXXXX")"
    trap 'rm -f "$key_tmp" "$source_tmp"' RETURN

    curl --fail --silent --show-error --location \
        "${repo_url}/repository.key" -o "$key_tmp"
    fingerprint="$(gpg --show-keys --with-colons "$key_tmp" |
        awk -F: '$1 == "fpr" { gsub(/ /, "", $10); print $10; exit }')"
    [[ -n "$fingerprint" ]] ||
        fail "Could not read the FrankenPHP repository signing key fingerprint."
    install -m 0644 "$key_tmp" "$keyring_target"

    # Only one PHP branch may be active; otherwise apt sees conflicting
    # frankenphp and php-zts-* candidates from several repositories.
    previous_branch="$(read_state "$PHP_VERSION_STATE")"
    previous_code="${previous_branch//./}"
    if [[ -n "$previous_code" && "$previous_code" != "$code" ]]; then
        stale_source="$(frankenphp_source_path "$previous_branch")"
        stale_key="$(frankenphp_keyring_path "$previous_branch")"
        if [[ -f "$stale_source" ]] && grep -Fq "$FRANKENPHP_MARKER" "$stale_source"; then
            rm -f "$stale_source" "$stale_key"
            info "Removed the previous repository for PHP ${previous_branch}."
        fi
    fi
    for stale_source in /etc/apt/sources.list.d/static-php*.list; do
        [[ -f "$stale_source" ]] || continue
        [[ "$stale_source" == "$source_target" ]] && continue
        grep -Fq "$FRANKENPHP_MARKER" "$stale_source" || continue
        stale_key="/etc/apt/keyrings/$(basename "${stale_source%.list}").asc"
        rm -f "$stale_source" "$stale_key"
        info "Removed stale DFM repository: ${stale_source}"
    done

    printf '%s\n' "$FRANKENPHP_MARKER" \
        "deb [signed-by=${keyring_target}] ${repo_url} php-zts main" > "$source_tmp"
    chmod 0644 "$source_tmp"
    mv "$source_tmp" "$source_target"

    install -d -m 0755 "$STATE_DIR"
    printf '%s\n' "$branch" > "$PHP_VERSION_STATE"

    rm -f "$key_tmp" "$source_tmp"
    trap - RETURN
    printf 'FrankenPHP repository: %s php-zts main (PHP %s, key %s)\n' \
        "$repo_url" "$branch" "$fingerprint"
    apt-get update || warn "apt-get update failed after configuring sources; version list may be incomplete."
}

sync_management_commands() {
    [[ -x "${SCRIPT_DIR}/sync-dfm.sh" ]] ||
        fail "Management sync script not found: ${SCRIPT_DIR}/sync-dfm.sh"
    "${SCRIPT_DIR}/sync-dfm.sh"
}

finish_frankenphp_upgrade() {
    local branch=$1 installed
    installed="$(dpkg-query -W -f='${Version}' frankenphp 2>/dev/null || true)"
    [[ -n "$installed" ]] || fail "Could not read the installed FrankenPHP version."
    printf '%s\n' "$installed" > "$FRANKENPHP_VERSION_STATE"
    printf '%s\n' "$branch" > "$PHP_VERSION_STATE"

    systemctl daemon-reload
    /usr/bin/frankenphp validate --config "${FRANKENPHP_CONFIG_DIR}/Caddyfile" ||
        fail "Caddyfile validation failed; check ${FRANKENPHP_CONFIG_DIR}/Caddyfile."
    stop_other_frankenphp
    systemctl start frankenphp || fail "FrankenPHP failed to start."
    systemctl is-active --quiet frankenphp || fail "FrankenPHP is not active after the upgrade."
    sync_management_commands
    printf 'FrankenPHP is active; installed APT version: %s\n' "$installed"
}

upgrade_frankenphp() {
    local requested=$1 branch version current_version target_release
    local -a packages

    [[ -x /usr/bin/frankenphp ]] || fail "FrankenPHP is not installed at /usr/bin/frankenphp."
    branch="$(read_state "$PHP_VERSION_STATE")"
    [[ "$branch" =~ ^[0-9]+\.[0-9]+$ ]] ||
        fail "Could not determine the active PHP branch from ${PHP_VERSION_STATE}."

    confirm_risk "FrankenPHP (PHP ${branch})"
    printf 'Current FrankenPHP APT version: %s\n' \
        "$(dpkg-query -W -f='${Version}' frankenphp 2>/dev/null || printf unknown)"

    configure_frankenphp_repository "$branch"
    version="$(resolve_package_version frankenphp "$requested" 0 pkg.henderkes.com)"

    current_version="$(dpkg-query -W -f='${Version}' frankenphp 2>/dev/null || true)"
    current_version="${current_version#*:}"
    current_version="${current_version%%[-+~]*}"
    target_release="${version#*:}"
    target_release="${target_release%%[-+~]*}"
    dpkg --compare-versions "$target_release" gt "$current_version" ||
        fail "Requested FrankenPHP ${target_release} is not newer than the installed ${current_version:-unknown}."

    packages=("frankenphp=${version}" "${PHP_ZTS_PACKAGES[@]}")
    print_apt_plan "FrankenPHP ${branch}" "${packages[@]}"
    run_apt_install "${packages[@]}"
    finish_frankenphp_upgrade "$branch"
    printf 'FrankenPHP upgraded to APT version %s (PHP %s).\n' "$version" "$branch"
}

upgrade_php() {
    local requested=$1 current_branch target_branch version target_release
    local -a packages
    local source_backup state_backup source_old

    current_branch="$(read_state "$PHP_VERSION_STATE")"
    [[ "$current_branch" =~ ^[0-9]+\.[0-9]+$ ]] ||
        fail "Could not determine the active PHP branch from ${PHP_VERSION_STATE}."
    detect_php_branches

    if [[ -z "$requested" ]]; then
        printf '\nAvailable PHP branches (FrankenPHP deb repository):\n' >&2
        printf '  Current: %s\n' "$current_branch" >&2
        for available in "${PHP_BRANCHES[@]}"; do
            printf '  - %s\n' "$available" >&2
        done
        [[ -t 0 ]] || fail "A target PHP branch is required without an interactive terminal."
        read -r -p "Target branch: " requested
    fi
    [[ "$requested" =~ ^[0-9]+\.[0-9]+$ ]] ||
        fail "The php component takes a branch such as 8.4; for patch upgrades use frankenphp."
    target_branch=$requested
    [[ " ${PHP_BRANCHES[*]} " == *" ${target_branch} "* ]] ||
        fail "PHP ${target_branch} is not available. Available branches: ${PHP_BRANCHES[*]}"
    [[ "$target_branch" != "$current_branch" ]] ||
        fail "PHP is already on branch ${current_branch}; use 'frankenphp' for same-branch upgrades."

    confirm_risk "PHP ${current_branch} -> ${target_branch}"

    source_old="$(frankenphp_source_path "$current_branch")"
    source_backup="$(mktemp)"
    state_backup="$(mktemp)"
    [[ ! -f "$source_old" ]] || cp -p "$source_old" "$source_backup"
    cp -p "$PHP_VERSION_STATE" "$state_backup"

    configure_frankenphp_repository "$target_branch"
    version="$(resolve_package_version frankenphp "" 0 pkg.henderkes.com)"
    target_release="${version#*:}"
    target_release="${target_release%%[-+~]*}"

    packages=("frankenphp=${version}" "${PHP_ZTS_PACKAGES[@]}")
    printf '\nPHP upgrade plan:\n  From branch: %s\n  To branch:   %s\n  FrankenPHP:  %s\n' \
        "$current_branch" "$target_branch" "$version"
    print_apt_plan "PHP ${target_branch}" "${packages[@]}"

    if ! run_apt_install "${packages[@]}"; then
        # apt may have partially installed packages; restore the repository
        # selection and state so a retry starts from a consistent source.
        if [[ -s "$source_backup" ]]; then
            install -m 0644 "$source_backup" "$source_old"
        fi
        install -m 0644 "$state_backup" "$PHP_VERSION_STATE"
        apt-get update || warn "apt-get update failed while restoring the previous repository."
        rm -f "$source_backup" "$state_backup"
        fail "Package installation failed; the previous APT source and state were restored. Check the FrankenPHP service before retrying."
    fi
    rm -f "$source_backup" "$state_backup"

    finish_frankenphp_upgrade "$target_branch"
    printf 'PHP switched from %s to %s (FrankenPHP APT version %s).\n' \
        "$current_branch" "$target_branch" "$version"
    warn "Reinstall addons extensions for PHP ${target_branch}, for example: cd ${SCRIPT_DIR} && ./addons.sh install redis"
    warn "php-zts-* package names are shared across branches; apt replaces them in place. Check for leftovers after verifying the new runtime."
}

upgrade_mysql() {
    local requested=$1 version current_version target_release

    [[ -x /usr/bin/mysql ]] || fail "MySQL client not found at /usr/bin/mysql."
    [[ -r "$MYSQL_SOURCE" ]] ||
        fail "MySQL APT source is missing: ${MYSQL_SOURCE}; run install.sh first."
    grep -Fq 'repo.mysql.com/apt/debian' "$MYSQL_SOURCE" ||
        fail "Oracle MySQL APT repository is not configured; run install.sh first."
    [[ -r "$MYSQL_KEYRING" ]] ||
        fail "Oracle MySQL APT keyring is missing; run install.sh first."
    systemctl is-active --quiet mysql || fail "MySQL must be active before upgrading."

    confirm_risk "MySQL"
    apt-get update
    version="$(resolve_package_version mysql-server "$requested" 8 repo.mysql.com)"

    current_version="$(dpkg-query -W -f='${Version}' mysql-server 2>/dev/null || true)"
    current_version="${current_version#*:}"
    current_version="${current_version%%[-+~]*}"
    target_release="${version#*:}"
    dpkg --compare-versions "$target_release" gt "$current_version" ||
        fail "Requested MySQL ${target_release} is not newer than the installed ${current_version:-unknown}."

    print_apt_plan MySQL "mysql-server=${version}"
    run_apt_install "mysql-server=${version}"
    systemctl daemon-reload
    systemctl restart mysql || fail "MySQL failed to restart."
    systemctl is-active --quiet mysql || fail "MySQL is not active after the upgrade."
    /usr/bin/mysql --version
    printf 'MySQL upgraded to APT version %s.\n' "$version"
}

show_menu() {
    cat <<'EOF'
Select a component to upgrade:
  1: FrankenPHP (same PHP branch)
  2: PHP (switch to another branch)
  3: MySQL (Oracle APT repository)
  4: Exit
EOF
    local choice
    read -r -p "Selection: " choice
    case "$choice" in
        1) COMPONENT=frankenphp ;;
        2) COMPONENT=php ;;
        3) COMPONENT=mysql ;;
        4) exit 0 ;;
        *) fail "Invalid selection: $choice" ;;
    esac
}

[[ "${1:-}" != --help && "${1:-}" != -h ]] || {
    usage
    exit 0
}

if [[ "${1:-}" == --yes ]]; then
    AUTO_CONFIRM=1
    shift
fi

requested=
if (($# == 0)); then
    [[ -t 0 ]] || fail "No component specified and no interactive terminal; pass a component and an explicit version."
    show_menu
else
    COMPONENT=$1
    shift
    case "$COMPONENT" in
        frankenphp)
            requested="${1:-}"
            if (($# > 0)); then
                shift
            fi
            (($# == 0)) || { usage >&2; exit 2; }
            ;;
        php)
            requested="${1:-}"
            if (($# > 0)); then
                shift
            fi
            (($# == 0)) || { usage >&2; exit 2; }
            ;;
        mysql)
            requested="${1:-}"
            if (($# > 0)); then
                shift
            fi
            (($# == 0)) || { usage >&2; exit 2; }
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
fi

if [[ -z "$requested" ]] && { ((AUTO_CONFIRM)) || [[ ! -t 0 ]]; }; then
    fail "A version must be specified explicitly when --yes is used or when there is no interactive terminal."
fi
if [[ ! -t 0 ]] && ! ((AUTO_CONFIRM)); then
    fail "Non-interactive upgrades require --yes; otherwise the script would change package sources before refusing to install."
fi

require_root
require_debian

case "$COMPONENT" in
    frankenphp) upgrade_frankenphp "$requested" ;;
    php) upgrade_php "$requested" ;;
    mysql) upgrade_mysql "$requested" ;;
    *) usage >&2; exit 2 ;;
esac
