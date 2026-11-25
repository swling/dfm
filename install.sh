#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MYSQL_KEYRING=/usr/share/keyrings/mysql-apt.gpg
MYSQL_SOURCE=/etc/apt/sources.list.d/mysql.list
MYSQL_REPO_URL=https://repo.mysql.com/apt/debian
MYSQL_COMPONENTS=
MYSQL_COMPONENT=
MYSQL_CODENAME=
MYSQL_ARCHITECTURE=
FRANKENPHP_REPO_BASE=https://pkg.henderkes.com/api/packages
FRANKENPHP_MARKER='# Managed by DFM'
SYSTEM_CONFIG=/etc/dfm.conf
STATE_DIR=/etc/dfm

if [[ -r "$SYSTEM_CONFIG" ]]; then
    # shellcheck disable=SC1090
    . "$SYSTEM_CONFIG"
else
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/dfm.conf"
fi

WEB_ROOT="${WEB_ROOT:-/home/wwwroot}"
DEFAULT_WEB_ROOT="${DEFAULT_WEB_ROOT:-${WEB_ROOT}/default}"
FRANKENPHP_LOG_DIR="${FRANKENPHP_LOG_DIR:-/var/log/frankenphp}"
MYSQL_DATA_DIR="${MYSQL_DATA_DIR:-/var/lib/mysql}"
PHP_VERSION="${PHP_VERSION:-}"
MYSQL_VERSION="${MYSQL_VERSION:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
FRANKENPHP_CONFIG_DIR=/etc/frankenphp
FRANKENPHP_SITE_DIR="${FRANKENPHP_CONFIG_DIR}/Caddyfile.d"
FRANKENPHP_REWRITE_DIR="${FRANKENPHP_CONFIG_DIR}/rewrite"
FRANKENPHP_CACHE_CONF="${FRANKENPHP_CONFIG_DIR}/cache-static.caddyfile"
FRANKENPHP_CADDY_DATA=/var/lib/frankenphp/caddy
FRANKENPHP_DROPIN=/etc/systemd/system/frankenphp.service.d/10-dfm.conf
PHP_REPO_CODE=
CLEAR_MYSQL_DATA=0

usage() {
    cat <<'EOF'
Usage: install.sh

Install the DFM Debian profile on Debian 13 or later:
  FrankenPHP: deb packages from the repository linked by the official docs
              (PHP 8.2, 8.3, 8.4 or 8.5, selected by repository branch)
  MySQL:      Oracle MySQL APT repository (server components discovered dynamically)

There is no nginx, PHP-FPM or acme.sh. Caddy's automatic HTTPS obtains and
renews certificates for domain site blocks, so no separate TLS client is used.
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

select_mysql_version() {
    local choice index candidate marker kind version source major
    local -a raw_lines versions sources is_lts

    # madison's third column carries the originating component, which is how
    # LTS and innovation releases are told apart and how the source is pinned.
    mapfile -t raw_lines < <(
        apt-cache madison mysql-server |
            awk -F'|' '{
                v = $2; s = $3;
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v);
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", s);
                if (v != "") print v "\t" s
            }' |
            sort -t $'\t' -k1,1V -u
    )

    versions=()
    sources=()
    is_lts=()
    for candidate in "${raw_lines[@]}"; do
        version="${candidate%%$'\t'*}"
        source="${candidate#*$'\t'}"
        major="${version#*:}"
        major="${major%%.*}"
        [[ "$major" =~ ^[0-9]+$ ]] || continue
        (( major >= 8 )) || continue
        versions+=("$version")
        sources+=("$source")
        if [[ "$source" == *-lts* ]]; then
            is_lts+=(1)
        else
            is_lts+=(0)
        fi
    done
    ((${#versions[@]} > 0)) ||
        fail "No MySQL 8+ versions are available from the Oracle APT repository."

    # Versions are sorted ascending, so the last LTS entry is the newest LTS.
    # Fall back to the newest version when no LTS component is available.
    default_index=-1
    for index in "${!versions[@]}"; do
        (( is_lts[index] )) && default_index=$index
    done
    (( default_index >= 0 )) || default_index=$((${#versions[@]} - 1))

    if [[ -n "$MYSQL_VERSION" ]]; then
        for index in "${!versions[@]}"; do
            if [[ "${versions[index]}" == "$MYSQL_VERSION" ]]; then
                default_index=$index
                break
            fi
        done
        [[ "${versions[default_index]}" == "$MYSQL_VERSION" ]] ||
            fail "MySQL version ${MYSQL_VERSION} is not available from the Oracle APT repository."
    fi

    printf '\nAvailable MySQL versions:\n'
    for index in "${!versions[@]}"; do
        marker=
        [[ "$index" -eq "$default_index" ]] && marker=' [default]'
        kind=innovation
        (( is_lts[index] )) && kind=LTS
        printf '  %d) %s (%s)%s\n' "$((index + 1))" "${versions[index]}" "$kind" "$marker"
    done

    if [[ -t 0 ]]; then
        read -r -p "Select version [${versions[default_index]}]: " choice
    else
        choice=
    fi
    if [[ -z "$choice" ]]; then
        index=$default_index
    elif [[ "$choice" =~ ^[0-9]+$ ]] &&
         (( choice >= 1 && choice <= ${#versions[@]} )); then
        index=$((choice - 1))
    elif [[ " ${versions[*]} " == *" ${choice} "* ]]; then
        index=-1
        for candidate in "${!versions[@]}"; do
            if [[ "${versions[candidate]}" == "$choice" ]]; then
                index=$candidate
                break
            fi
        done
    else
        fail "Invalid MySQL version selection: ${choice}"
    fi

    MYSQL_VERSION="${versions[index]}"
    source="${sources[index]}"
    if [[ "$source" =~ (mysql-[a-zA-Z0-9][a-zA-Z0-9.-]*) ]]; then
        MYSQL_COMPONENT="${BASH_REMATCH[1]}"
    else
        fail "Could not determine the APT component for MySQL ${MYSQL_VERSION}."
    fi
}

select_php_version() {
    local branch code choice index default_index marker
    local -a available_branches=()

    # One deb repository per PHP branch; the suite/component layout is the
    # same for every branch, so only the repository code changes.
    for branch in 8.2 8.3 8.4 8.5; do
        code="${branch//./}"
        if curl --fail --silent --show-error --location --head --max-time 20 \
            "${FRANKENPHP_REPO_BASE}/${code}/debian/dists/php-zts/Release" \
            -o /dev/null 2>/dev/null; then
            available_branches+=("$branch")
        fi
    done
    ((${#available_branches[@]} > 0)) ||
        fail "No PHP branches are available from the FrankenPHP deb repository."

    default_index=$((${#available_branches[@]} - 1))
    if [[ -n "$PHP_VERSION" ]]; then
        for index in "${!available_branches[@]}"; do
            if [[ "${available_branches[index]}" == "$PHP_VERSION" ]]; then
                default_index=$index
                break
            fi
        done
        [[ "${available_branches[default_index]}" == "$PHP_VERSION" ]] ||
            warn "Configured PHP ${PHP_VERSION} is not available; using ${available_branches[default_index]}."
    fi

    printf '\nAvailable PHP branches (FrankenPHP deb repository):\n'
    for index in "${!available_branches[@]}"; do
        marker=
        [[ "$index" -eq "$default_index" ]] && marker=' [default]'
        printf '  %d) PHP %s%s\n' "$((index + 1))" "${available_branches[index]}" "$marker"
    done
    if [[ -t 0 ]]; then
        read -r -p "Select branch [${available_branches[default_index]}]: " choice
    else
        choice=
    fi
    if [[ -z "$choice" ]]; then
        PHP_VERSION="${available_branches[default_index]}"
    elif [[ "$choice" =~ ^[0-9]+$ ]] &&
         (( choice >= 1 && choice <= ${#available_branches[@]} )); then
        PHP_VERSION="${available_branches[choice - 1]}"
    elif [[ " ${available_branches[*]} " == *" ${choice} "* ]]; then
        PHP_VERSION=$choice
    else
        fail "Invalid PHP branch selection: ${choice}"
    fi
    PHP_REPO_CODE="${PHP_VERSION//./}"
}

discover_mysql_components() {
    local components
    components="$(
        curl --fail --silent --show-error --location \
            "${MYSQL_REPO_URL}/dists/${MYSQL_CODENAME}/Release" |
            awk -F': *' '$1 == "Components" { print $2; exit }' |
            tr ' ' '\n' |
            awk '
                /^mysql-/ &&
                !/^mysql-apt-config$/ &&
                !/^mysql-cluster-/ &&
                !/^mysql-tools/ &&
                !/-dbg$/ { print }
            ' |
            paste -sd' ' -
    )"
    [[ -n "$components" ]] ||
        fail "Could not discover MySQL server components from ${MYSQL_REPO_URL} for ${MYSQL_CODENAME}."
    printf '%s' "$components"
}

write_mysql_source() {
    local components=$1 source_tmp
    install -d -m 0755 "$(dirname "$MYSQL_SOURCE")"
    source_tmp="$(mktemp "${MYSQL_SOURCE}.XXXXXX")"
    printf 'deb [arch=%s signed-by=%s] %s/ %s %s\n' \
        "$MYSQL_ARCHITECTURE" "$MYSQL_KEYRING" "$MYSQL_REPO_URL" \
        "$MYSQL_CODENAME" "$components" > "$source_tmp"
    chmod 0644 "$source_tmp"
    mv "$source_tmp" "$MYSQL_SOURCE"
}

install_mysql_repository() {
    local key_tmp key_fingerprint
    MYSQL_CODENAME="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    MYSQL_ARCHITECTURE="$(dpkg --print-architecture)"
    [[ "$MYSQL_ARCHITECTURE" == amd64 ]] ||
        fail "Oracle MySQL's Debian 13 APT repository currently supports amd64 only (found: $MYSQL_ARCHITECTURE)."
    [[ -n "$MYSQL_CODENAME" ]] || fail "Could not determine Debian release codename."

    # Keep every server component enabled during discovery so the version menu
    # can offer all MySQL series the repository currently publishes.
    MYSQL_COMPONENTS="$(discover_mysql_components)"

    install -d -m 0755 /usr/share/keyrings
    key_tmp="$(mktemp)"
    trap 'rm -f "$key_tmp"' RETURN
    curl --fail --silent --show-error --location \
        https://repo.mysql.com/RPM-GPG-KEY-mysql-2025 -o "$key_tmp"
    key_fingerprint="$(gpg --show-keys --with-colons "$key_tmp" |
        awk -F: '$1 == "fpr" { print $10; exit }')"
    [[ "$key_fingerprint" == BCA43417C3B485DD128EC6D4B7B3B788A8D3785C ]] ||
        fail "Unexpected Oracle MySQL repository signing key fingerprint: ${key_fingerprint:-unreadable}"
    gpg --dearmor --yes --output "$MYSQL_KEYRING" "$key_tmp"
    chmod 0644 "$MYSQL_KEYRING"
    write_mysql_source "$MYSQL_COMPONENTS"
    printf 'Discovered MySQL components: %s\n' "$MYSQL_COMPONENTS"
    rm -f "$key_tmp"
    trap - RETURN
}

finalize_mysql_repository() {
    [[ -n "$MYSQL_COMPONENT" ]] ||
        fail "No MySQL component was selected; refusing to configure the APT source."
    # A single component avoids mixing mysql-common / libmysqlclient versions
    # from different series while resolving the pinned mysql-server version.
    write_mysql_source "$MYSQL_COMPONENT"
    apt-get update
}

frankenphp_source_path() {
    printf '/etc/apt/sources.list.d/static-php%s.list' "$1"
}

frankenphp_keyring_path() {
    printf '/etc/apt/keyrings/static-php%s.asc' "$1"
}

install_frankenphp_repository() {
    local architecture key_tmp source_tmp source_target keyring_target fingerprint repo_url stale_source stale_key previous_branch previous_code

    architecture="$(dpkg --print-architecture)"
    [[ "$architecture" == amd64 || "$architecture" == arm64 ]] ||
        fail "The FrankenPHP deb repository does not support this architecture: ${architecture}"
    [[ "$PHP_REPO_CODE" =~ ^[0-9]+$ ]] || fail "No PHP repository code was selected."

    source_target="$(frankenphp_source_path "$PHP_REPO_CODE")"
    keyring_target="$(frankenphp_keyring_path "$PHP_REPO_CODE")"
    repo_url="${FRANKENPHP_REPO_BASE}/${PHP_REPO_CODE}/debian"

    if [[ -e "$source_target" ]] &&
       ! grep -Fq "$FRANKENPHP_MARKER" "$source_target"; then
        cp -p -- "$source_target" "${source_target}.dfm.orig" 2>/dev/null || true
        warn "Existing APT source ${source_target} is unrelated to DFM; backed up and overwritten."
    fi

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

    # Only one PHP branch can be active: older DFM-managed repositories would
    # otherwise offer conflicting FrankenPHP and php-zts-* candidates.
    previous_branch=
    if [[ -r "${STATE_DIR}/php-version" ]]; then
        IFS= read -r previous_branch < "${STATE_DIR}/php-version" || true
    fi
    previous_code="${previous_branch//./}"
    if [[ -n "$previous_code" && "$previous_code" != "$PHP_REPO_CODE" ]]; then
        stale_source="$(frankenphp_source_path "$previous_code")"
        stale_key="$(frankenphp_keyring_path "$previous_code")"
        if [[ -f "$stale_source" ]] && grep -Fq "$FRANKENPHP_MARKER" "$stale_source"; then
            rm -f "$stale_source" "$stale_key"
            info "Removed the previous FrankenPHP repository for PHP ${previous_branch}."
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
    printf '%s\n' "$PHP_VERSION" > "${STATE_DIR}/php-version"

    rm -f "$key_tmp" "$source_tmp"
    trap - RETURN
    printf 'FrankenPHP APT source configured: %s php-zts main (PHP %s, key %s)\n' \
        "$repo_url" "$PHP_VERSION" "$fingerprint"
    apt-get update || warn "apt-get update failed after configuring sources; version list may be incomplete."
}

parse_arguments() {
    [[ "${1:-}" != --help && "${1:-}" != -h ]] || {
        usage
        exit 0
    }
    [[ $# -eq 0 ]] || {
        usage >&2
        exit 2
    }
}

validate_platform() {
    [[ "$(id -u)" -eq 0 ]] || fail "Run this installer as root."
    [[ -r /etc/os-release ]] || fail "This script requires Debian 13 or later."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == debian ]] || fail "Only Debian 13 or later is supported."
    DEBIAN_MAJOR="${VERSION_ID%%.*}"
    [[ "$DEBIAN_MAJOR" =~ ^[0-9]+$ ]] &&
        (( DEBIAN_MAJOR >= 13 )) || fail "Only Debian 13 or later is supported."
    command -v apt-get >/dev/null || fail "apt-get is required."
}

directory_has_entries() {
    [[ -n "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

clear_mysql_data() {
    find "$MYSQL_DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + ||
        fail "Could not clear MYSQL_DATA_DIR (${MYSQL_DATA_DIR})."
    info "Cleared MYSQL_DATA_DIR: ${MYSQL_DATA_DIR}"
}

confirm_clear_mysql_data() {
    local answer
    warn "MYSQL_DATA_DIR (${MYSQL_DATA_DIR}) already contains data."
    warn "Continuing will DELETE all existing data in that directory and install a fresh MySQL instance."
    read -r -p "Type 'clear' to delete the data and continue, or press Enter to abort: " answer || true
    [[ "$answer" == clear ]] || fail "Installation aborted; MYSQL_DATA_DIR was left unchanged."
    if [[ "$MYSQL_DATA_DIR" == /var/lib/mysql ]]; then
        # The package initializes the default directory, so it must be empty
        # before packages are installed.
        clear_mysql_data
    else
        # Delay the deletion until packages are installed, so a failed install
        # does not leave the machine with neither data nor a working stack.
        CLEAR_MYSQL_DATA=1
        info "Confirmed: MYSQL_DATA_DIR will be cleared after package installation."
    fi
}

clear_mysql_data_if_confirmed() {
    (( CLEAR_MYSQL_DATA )) || return 0
    clear_mysql_data
}

validate_configuration_and_existing_data() {
    local configured_path
    for configured_path in "$WEB_ROOT" "$DEFAULT_WEB_ROOT" "$FRANKENPHP_LOG_DIR" "$MYSQL_DATA_DIR"; do
        [[ "$configured_path" == /* && "$configured_path" =~ ^/[A-Za-z0-9_./-]+$ ]] ||
            fail "Configured paths must be absolute and contain only letters, digits, dot, underscore, slash, or hyphen: ${configured_path}"
        [[ "$configured_path" != *"/../"* && "$configured_path" != */.. ]] ||
            fail "Configured paths must not contain parent-directory segments: ${configured_path}"
    done
    [[ "$MYSQL_DATA_DIR" != / ]] || fail "MYSQL_DATA_DIR must not be the filesystem root."
    [[ "$MYSQL_DATA_DIR" != /var/lib/mysql/* && /var/lib/mysql != "$MYSQL_DATA_DIR"/* ]] ||
        fail "MYSQL_DATA_DIR must not be nested inside or above /var/lib/mysql."
    if [[ -n "$ACME_EMAIL" ]]; then
        [[ "$ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ||
            fail "ACME_EMAIL must be a valid email address."
    fi

    local mariadb_status mysql_community_status
    mariadb_status="$(dpkg-query -W -f='${db:Status-Status}' mariadb-server 2>/dev/null || true)"
    mysql_community_status="$(dpkg-query -W -f='${db:Status-Status}' mysql-community-server 2>/dev/null || true)"
    if [[ "$mariadb_status" == installed ]]; then
        fail "MariaDB is already installed. Back it up and remove or migrate it before installing MySQL."
    fi
    if [[ "$mysql_community_status" != installed ]] &&
       [[ -d "$MYSQL_DATA_DIR" ]] && directory_has_entries "$MYSQL_DATA_DIR"; then
        confirm_clear_mysql_data
    fi
}

prepare_package_sources() {
    if [[ ! -e "$SYSTEM_CONFIG" ]]; then
        install -m 0644 "$SCRIPT_DIR/dfm.conf" "$SYSTEM_CONFIG"
    fi

    # Leftover package sources no longer abort installation: install dependencies
    # first, then rebuild the sources and refresh indexes.
    apt-get update || warn "apt-get update failed; continuing to install source dependencies."
    apt-get install -y ca-certificates curl gnupg ||
        fail "Could not install ca-certificates / curl / gnupg; check APT sources and network."
    install_mysql_repository
    apt-get update || warn "apt-get update failed after configuring MySQL sources; version list may be incomplete."
}

select_install_versions() {
    select_php_version
    select_mysql_version
}

confirm_install_versions() {
    printf '\nSelected versions:\n'
    printf 'PHP branch:    %s\nMySQL version: %s\n' "$PHP_VERSION" "$MYSQL_VERSION"
    # Non-interactive runs cannot confirm; the version selectors already fell back to defaults.
    [[ -t 0 ]] || return 0
    if ! read -r -p "Press Enter to start installation, or Ctrl+C to abort: " answer; then
        fail "Installation aborted; no packages were installed."
    fi
    printf '\n'
}

finalize_package_sources() {
    finalize_mysql_repository
    install_frankenphp_repository
}

install_packages() {
    local -a php_packages=(
        php-zts-cli
        php-zts-curl
        php-zts-gd
        php-zts-intl
        php-zts-zip
        php-zts-pdo-mysql
        php-zts-mysqli
        php-zts-bcmath
        php-zts-fileinfo
    )
    apt-get install -y frankenphp "${php_packages[@]}" \
        "mysql-server=${MYSQL_VERSION}"

    [[ -x /usr/bin/frankenphp ]] || fail "FrankenPHP was not installed."
    install -d -m 0755 "$STATE_DIR"
    printf '%s\n' "$PHP_VERSION" > "${STATE_DIR}/php-version"
    printf '%s\n' "$(dpkg-query -W -f='${Version}' frankenphp)" \
        > "${STATE_DIR}/frankenphp-version"
}

configure_mysql_data_directory() {
    local apparmor_local apparmor_parent
    local mysql_current_real mysql_target_real
    mysql_current_real="$(readlink -f /var/lib/mysql 2>/dev/null || true)"
    mysql_target_real="$(readlink -f "$MYSQL_DATA_DIR" 2>/dev/null || true)"

    if [[ "$MYSQL_DATA_DIR" != /var/lib/mysql ]] &&
       [[ "$mysql_current_real" != "$mysql_target_real" ]]; then
        # Stop the server before changing what /var/lib/mysql points to.
        systemctl stop mysql || true
        mkdir -p "$MYSQL_DATA_DIR"
        if [[ -d /var/lib/mysql ]] && [[ ! -L /var/lib/mysql ]]; then
            cp -a /var/lib/mysql/. "$MYSQL_DATA_DIR"/
            chown -R mysql:mysql "$MYSQL_DATA_DIR"
            # The directory only holds data initialized by the package install.
            rm -rf -- /var/lib/mysql
        elif [[ -L /var/lib/mysql ]]; then
            fail "/var/lib/mysql already points to another directory; refusing to move database files."
        fi
        ln -s "$MYSQL_DATA_DIR" /var/lib/mysql
        mkdir -p /etc/mysql/mysql.conf.d
        cat > /etc/mysql/mysql.conf.d/zz-lnmp-debian.cnf <<EOF
[mysqld]
datadir = ${MYSQL_DATA_DIR}
EOF
        if [[ -f /etc/apparmor.d/usr.sbin.mysqld ]]; then
            apparmor_local=/etc/apparmor.d/local/usr.sbin.mysqld
            apparmor_parent="$(dirname "$MYSQL_DATA_DIR")"
            install -d -m 0755 /etc/apparmor.d/local
            if ! grep -Fq "${MYSQL_DATA_DIR}/** rwk," "$apparmor_local" 2>/dev/null; then
                while [[ "$apparmor_parent" != / ]]; do
                    printf '%s/ r,\n%s/ x,\n' "$apparmor_parent" "$apparmor_parent" \
                        >> "$apparmor_local"
                    apparmor_parent="$(dirname "$apparmor_parent")"
                done
                cat >> "$apparmor_local" <<EOF
${MYSQL_DATA_DIR}/ r,
${MYSQL_DATA_DIR}/** rwk,
EOF
            fi
            if command -v apparmor_parser >/dev/null; then
                apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld ||
                    warn "Failed to reload AppArmor; run manually: apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld"
            elif systemctl is-active --quiet apparmor; then
                fail "AppArmor is active but apparmor_parser is unavailable; cannot authorize MYSQL_DATA_DIR."
            fi
        fi
        chown mysql:mysql "$MYSQL_DATA_DIR"
        chmod 0750 "$MYSQL_DATA_DIR"
        systemctl start mysql
    fi
}

ensure_web_user() {
    if ! getent group www >/dev/null; then
        groupadd --system www
    fi
    if ! getent passwd www >/dev/null; then
        useradd --system --gid www --home-dir /home/wwwroot --no-create-home \
            --shell /usr/sbin/nologin www
    fi
    # The package service user reads site files owned by www:www.
    if getent passwd frankenphp >/dev/null &&
       ! id -nG frankenphp | grep -qw www; then
        usermod -aG www frankenphp
        info "Added frankenphp to the www group."
    fi
}

prepare_web_layout() {
    local webroot
    for webroot in "$WEB_ROOT" "$DEFAULT_WEB_ROOT"; do
        if [[ ! -d "$webroot" ]]; then
            mkdir -p "$webroot"
            chown www:www "$webroot"
            chmod 0775 "$webroot"
        else
            info "Using existing web root: ${webroot}"
        fi
    done
}

configure_frankenphp() {
    local caddyfile caddyfile_tmp default_site default_site_tmp email_line template
    local rewrite_template rewrite_name rewrite_file

    install -d -m 0755 "$FRANKENPHP_CONFIG_DIR" "$FRANKENPHP_SITE_DIR" \
        "$FRANKENPHP_REWRITE_DIR"
    install -d -o frankenphp -g frankenphp -m 0750 "$FRANKENPHP_CADDY_DATA"
    if [[ -d "$FRANKENPHP_LOG_DIR" ]]; then
        chown frankenphp:frankenphp "$FRANKENPHP_LOG_DIR"
    else
        install -d -o frankenphp -g frankenphp -m 0755 "$FRANKENPHP_LOG_DIR"
    fi
    prepare_web_layout

    # The deb package runs as frankenphp:frankenphp and ships ProtectHome=true;
    # sites under /home/wwwroot need the relaxed drop-in below.
    install -d -m 0755 "$(dirname "$FRANKENPHP_DROPIN")"
    cat > "$FRANKENPHP_DROPIN" <<EOF
[Service]
ProtectHome=false
ReadWritePaths=${WEB_ROOT}
EOF
    chmod 0644 "$FRANKENPHP_DROPIN"

    caddyfile="${FRANKENPHP_CONFIG_DIR}/Caddyfile"
    if [[ -f "$caddyfile" && ! -L "$caddyfile" ]] &&
       ! grep -Fq '# Managed by DFM' "$caddyfile" &&
       [[ ! -e "${caddyfile}.dfm.orig" ]]; then
        cp -p -- "$caddyfile" "${caddyfile}.dfm.orig"
    fi
    email_line=
    if [[ -n "$ACME_EMAIL" ]]; then
        email_line="    email ${ACME_EMAIL}"
    fi
    caddyfile_tmp="$(mktemp "${caddyfile}.XXXXXX")"
    sed "s#@EMAIL_LINE@#${email_line}#" "$SCRIPT_DIR/conf/Caddyfile" > "$caddyfile_tmp"
    chmod 0644 "$caddyfile_tmp"
    mv "$caddyfile_tmp" "$caddyfile"

    default_site="${FRANKENPHP_SITE_DIR}/default.caddyfile"
    default_site_tmp="$(mktemp "${default_site}.XXXXXX")"
    sed "s#@DEFAULT_WEB_ROOT@#${DEFAULT_WEB_ROOT}#g" \
        "$SCRIPT_DIR/conf/default-site.caddyfile" > "$default_site_tmp"
    chmod 0644 "$default_site_tmp"
    mv "$default_site_tmp" "$default_site"

    if [[ ! -e "$FRANKENPHP_CACHE_CONF" && ! -L "$FRANKENPHP_CACHE_CONF" ]]; then
        install -m 0644 "$SCRIPT_DIR/conf/cache-static.caddyfile" "$FRANKENPHP_CACHE_CONF"
    fi

    [[ -d "$SCRIPT_DIR/rewrite" ]] ||
        fail "Bundled Caddyfile rewrite templates are missing: ${SCRIPT_DIR}/rewrite"
    for rewrite_template in "$SCRIPT_DIR"/rewrite/*.caddyfile; do
        [[ -f "$rewrite_template" ]] || continue
        rewrite_name="${rewrite_template##*/}"
        if [[ ! -e "${FRANKENPHP_REWRITE_DIR}/${rewrite_name}" &&
              ! -L "${FRANKENPHP_REWRITE_DIR}/${rewrite_name}" ]]; then
            install -m 0644 "$rewrite_template" "${FRANKENPHP_REWRITE_DIR}/${rewrite_name}"
        fi
    done
    for rewrite_file in none other; do
        if [[ ! -e "${FRANKENPHP_REWRITE_DIR}/${rewrite_file}.caddyfile" &&
              ! -L "${FRANKENPHP_REWRITE_DIR}/${rewrite_file}.caddyfile" ]]; then
            : > "${FRANKENPHP_REWRITE_DIR}/${rewrite_file}.caddyfile"
        fi
    done
}

install_management_commands() {
    local cmd orig
    for cmd in /usr/local/bin/dfm /usr/bin/dfm; do
        orig="${cmd}.dfm.orig"
        if [[ -e "$cmd" && ! -L "$cmd" && ! -e "$orig" ]] &&
           ! cmp -s "$cmd" "$SCRIPT_DIR/dfm"; then
            cp -p -- "$cmd" "$orig"
        fi
    done
    install -m 0755 "$SCRIPT_DIR/dfm" /usr/local/bin/dfm
    install -m 0755 "$SCRIPT_DIR/addons.sh" /usr/local/bin/addons.sh
    ln -sfn /usr/local/bin/dfm /usr/bin/dfm
}

start_and_verify_services() {
    /usr/bin/frankenphp validate --config "${FRANKENPHP_CONFIG_DIR}/Caddyfile" ||
        fail "FrankenPHP rejected the generated Caddyfile."
    systemctl daemon-reload
    systemctl enable --now frankenphp mysql
    # The package post-install starts the service with its own Caddyfile;
    # restart once so the DFM config and the systemd drop-in are both applied.
    systemctl restart frankenphp ||
        fail "Could not restart FrankenPHP with the DFM configuration."
    systemctl is-active --quiet frankenphp || fail "FrankenPHP did not start."
    systemctl is-active --quiet mysql || fail "MySQL did not start."
}

print_summary() {
    local frankenphp_version
    frankenphp_version="$(dpkg-query -W -f='${Version}' frankenphp 2>/dev/null || printf 'unknown')"
    printf '\nDFM Debian installation completed.\n'
    printf 'FrankenPHP config: /etc/frankenphp/Caddyfile\n'
    printf 'Site configs:      %s/*.caddyfile\n' "$FRANKENPHP_SITE_DIR"
    printf 'PHP ini:           /etc/php-zts/php.ini\n'
    printf 'FrankenPHP:        %s (PHP %s)\n' "$frankenphp_version" "$PHP_VERSION"
    printf 'MySQL version:     %s\n' "$MYSQL_VERSION"
    printf 'Default web:       %s\nMySQL data:        %s\n' "$DEFAULT_WEB_ROOT" "$MYSQL_DATA_DIR"
    printf 'Caddy certificate data: %s\n' "$FRANKENPHP_CADDY_DATA"
    printf 'HTTPS: automatic for domain site blocks; no acme.sh is installed.\n'
    printf 'Management:        dfm {start|stop|reload|restart|status|vhost|addons}\n'
}

main() {
    parse_arguments "$@"
    validate_platform
    validate_configuration_and_existing_data
    prepare_package_sources
    select_install_versions
    confirm_install_versions
    finalize_package_sources
    install_packages
    clear_mysql_data_if_confirmed
    configure_mysql_data_directory
    ensure_web_user
    configure_frankenphp
    install_management_commands
    start_and_verify_services
    print_summary
}

main "$@"
