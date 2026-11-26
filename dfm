#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/dfm-common.sh"

if [[ -r /etc/dfm.conf ]]; then
    # shellcheck disable=SC1091
    . /etc/dfm.conf
elif [[ -r "${SCRIPT_DIR}/dfm.conf" ]]; then
    # shellcheck disable=SC1091
    . "${SCRIPT_DIR}/dfm.conf"
fi

SITE_DIR="${FRANKENPHP_CONFIG_DIR}/Caddyfile.d"
CADDYFILE="${FRANKENPHP_CONFIG_DIR}/Caddyfile"
WEB_ROOT="${WEB_ROOT:-/home/wwwroot}"
DEFAULT_WEB_ROOT="${DEFAULT_WEB_ROOT:-${WEB_ROOT}/default}"
FRANKENPHP_LOG_DIR="${FRANKENPHP_LOG_DIR:-/var/log/frankenphp}"
CADDY_DATA_DIR="${CADDY_DATA_DIR:-/var/lib/frankenphp/caddy}"
CERT_WAIT_TIMEOUT=60
CERT_POLL_INTERVAL=2

usage() {
    cat <<'EOF'
Usage:
  dfm {start|stop|restart|reload|kill|status}
  dfm {frankenphp|fp|mysql|db|mariadb} {start|stop|restart|reload|kill|status}
  dfm vhost {add|add-http|list|del [domain]|cert}
  dfm addons {install|uninstall} <addon>

HTTPS certificates are handled automatically by Caddy for domain site blocks.
"dfm vhost add" enables HTTPS by default and can choose HTTP-only when asked.
"dfm vhost add-http" creates an HTTP-only site without asking again.
"dfm vhost cert" reloads FrankenPHP and lists all issued certificates;
it never edits site configs.
Enable HTTPS by removing the http:// prefix from the site address manually.
Sites are one file per domain; bind extra domains by editing the file directly.
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || fail "Run this command as root."
}

require_frankenphp() {
    [[ -x /usr/bin/frankenphp && -d "$SITE_DIR" ]] ||
        fail "DFM is not installed. Run dfm/install.sh first."
}

check_certificate() {
    local domain=$1 since=$2 cert= elapsed=0 lines expiry

    printf 'Waiting up to %ss for certificate (polling every %ss)...\n' \
        "$CERT_WAIT_TIMEOUT" "$CERT_POLL_INTERVAL"
    while :; do
        cert="$(find "$CADDY_DATA_DIR/certificates" -type f -name "${domain}.crt" -print -quit 2>/dev/null || true)"
        [[ -n "$cert" ]] && break
        ((elapsed >= CERT_WAIT_TIMEOUT)) && break
        sleep "$CERT_POLL_INTERVAL"
        elapsed=$((elapsed + CERT_POLL_INTERVAL))
    done

    printf 'HTTPS certificate:\n'
    printf '  Domain: %s\n' "$domain"
    if [[ -n "$cert" ]]; then
        printf '  Status: issued\n'
        printf '  File:   %s\n' "$cert"
        if command -v openssl >/dev/null 2>&1; then
            expiry="$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2 || true)"
            [[ -n "$expiry" ]] && printf '  Expiry: %s\n' "$expiry"
        fi
        return 0
    fi

    printf '  Status: pending after %ss (Caddy keeps retrying in the background)\n' "$elapsed"
    if command -v journalctl >/dev/null 2>&1; then
        sleep 1
        lines="$(journalctl -u frankenphp --since "$since" --no-pager 2>/dev/null |
            awk 'tolower($0) ~ /acme|certificate|tls|challenge|letsencrypt|http-01|dns-01/' |
            tail -n 20 || true)"
        if [[ -n "$lines" ]]; then
            printf 'Caddy TLS/ACME log:\n'
            printf '%s\n' "$lines" | sed 's/^/  /'
        fi
    fi

    printf '  Log:    journalctl -u frankenphp -n 100 --no-pager\n'
    printf '          journalctl -u frankenphp --since "-1h" --no-pager | grep -i "%s"\n' "$domain"
}

valid_domain() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

validate_config() {
    printf 'Validating Caddyfile...\n'
    /usr/bin/frankenphp validate --config "$CADDYFILE"
}

reload_frankenphp() {
    validate_config
    printf 'Reloading FrankenPHP...\n'
    systemctl reload frankenphp
    printf 'FrankenPHP reloaded.\n'
}

service_action() {
    local action=$1 service=$2
    [[ "$action" != kill ]] || action=stop
    local unit label state verb completed
    case "$service" in
        frankenphp) unit=frankenphp; label=FrankenPHP ;;
        mysql|mariadb) unit=mysql; label=MySQL ;;
        *) fail "Unknown service: $service" ;;
    esac
    if [[ "$action" == status ]]; then
        state="$(systemctl is-active "$unit" 2>/dev/null || true)"
        printf '%-12s %s\n' "${label}:" "${state:-unknown}"
    else
        case "$action" in
            start) verb=Starting; completed=started ;;
            stop) verb=Stopping; completed=stopped ;;
            restart) verb=Restarting; completed=restarted ;;
            reload) verb=Reloading; completed=reloaded ;;
            *) fail "Unsupported service action: $action" ;;
        esac
        printf '%s %s...\n' "$verb" "$label"
        systemctl daemon-reload
        if [[ "$service" == frankenphp && ( "$action" == start || "$action" == restart ) ]]; then
            stop_other_frankenphp
        fi
        if [[ "$action" == reload && "$service" == frankenphp ]]; then
            validate_config
        fi
        systemctl "$action" "$unit"
        printf '%s %s.\n' "$label" "$completed"
    fi
}

service_bundle() {
    local action=$1 service
    printf 'DFM: %s services\n' "$action"
    for service in frankenphp mysql; do
        service_action "$action" "$service"
    done
    printf 'DFM service group %s complete.\n' "$action"
}

create_vhost_config() {
    local domain=$1 names=$2 webroot=$3 log_block=$4 scheme=$5
    local config="${SITE_DIR}/${domain}.caddyfile" addresses name prefix cert_log_since
    local -A seen=()

    [[ ! -e "$config" && ! -L "$config" ]] ||
        fail "Virtual host already exists: $domain"
    [[ "$scheme" == https || "$scheme" == http ]] || fail "Invalid scheme: $scheme"
    [[ "$webroot" == /* && "$webroot" =~ ^/[A-Za-z0-9_./-]+$ ]] ||
        fail "Web root must be an absolute path using only letters, digits, dot, underscore, slash, or hyphen."

    for name in $names; do
        valid_domain "$name" || fail "Invalid domain name in site addresses: $name"
        [[ -z "${seen[$name]:-}" ]] || fail "Duplicate domain in site addresses: $name"
        seen[$name]=1
    done
    # An explicit http:// scheme disables Caddy's automatic HTTPS for this site.
    if [[ "$scheme" == http ]]; then
        addresses="http://${domain}"
        prefix="http://"
    else
        addresses="$domain"
        prefix=""
    fi
    for name in $names; do
        [[ "$name" == "$domain" ]] && continue
        addresses+=", ${prefix}${name}"
    done

    if [[ ! -d "$webroot" ]]; then
        mkdir -p "$webroot"
        chown www:www "$webroot"
        chmod 0775 "$webroot"
    fi

    cat > "$config" <<EOF
# Managed by DFM. Site: ${domain}
# Scheme: ${scheme}
${addresses} {
    root * ${webroot}
    encode zstd br gzip

    import /etc/frankenphp/cache-static.caddyfile

    @dotfiles path_regexp dotfiles (^|/)\\.
    handle @dotfiles {
        respond 404
    }

    handle {
        php_server
    }
${log_block}
}
EOF
    cert_log_since="$(date '+%Y-%m-%d %H:%M:%S')"
    if ! reload_frankenphp; then
        rm -f "$config"
        fail "FrankenPHP rejected the new virtual host; its config was removed."
    fi
    printf 'Virtual host created: %s\nWeb root: %s\n' "$domain" "$webroot"
    if [[ "$scheme" == http ]]; then
        printf 'Scheme: http (no certificate requested).\n'
    else
        check_certificate "$domain" "$cert_log_since"
    fi
}

add_vhost() {
    local forced_scheme=${1:-} scheme https_choice
    local domain more_names webroot
    local access_choice log_file log_block name
    local -a additional_names
    [[ -z "$forced_scheme" || "$forced_scheme" == https || "$forced_scheme" == http ]] ||
        fail "Invalid scheme: $forced_scheme"
    require_root
    require_frankenphp
    read -r -p "Please enter domain (example: www.example.com): " domain
    valid_domain "$domain" || fail "Invalid domain name."
    [[ "$domain" != \*.* ]] ||
        fail "Wildcard names need a DNS challenge; configure them manually in the site block."

    read -r -p "Enter additional domain names (optional): " more_names
    read -r -a additional_names <<< "$more_names"
    for name in "${additional_names[@]}"; do
        valid_domain "$name" || fail "Invalid additional domain name: $name"
    done

    read -r -p "Web root [${WEB_ROOT}/${domain}]: " webroot
    webroot="${webroot:-${WEB_ROOT}/${domain}}"

    if [[ -n "$forced_scheme" ]]; then
        scheme="$forced_scheme"
    else
        read -r -p "Enable HTTPS with an automatic certificate? [Y/n]: " https_choice
        if [[ "$https_choice" =~ ^[Nn]$ ]]; then
            scheme=http
        else
            scheme=https
        fi
    fi
    printf 'Using scheme: %s\n' "$scheme"

    read -r -p "Enable access log? [Y/n]: " access_choice
    log_block=
    if [[ ! "$access_choice" =~ ^[Nn]$ ]]; then
        log_file="${FRANKENPHP_LOG_DIR}/${domain}.log"
        install -d -o frankenphp -g frankenphp -m 0755 "$FRANKENPHP_LOG_DIR"
        log_block="    log {
        output file ${log_file}
    }"
    fi

    create_vhost_config "$domain" "$domain $more_names" "$webroot" "$log_block" "$scheme"
}

list_vhosts() {
    require_frankenphp
    printf 'FrankenPHP site list:\n'
    find "$SITE_DIR" -maxdepth 1 -type f -name '*.caddyfile' ! -name default.caddyfile -print |
        sed 's#^.*/##; s/\.caddyfile$//' | sort
}

delete_vhost() {
    local domain=${1:-} backup config

    require_root
    require_frankenphp
    if [[ -z "$domain" ]]; then
        list_vhosts
        read -r -p "Please enter domain you want to delete: " domain
    fi
    valid_domain "$domain" || fail "Invalid domain name."
    config="${SITE_DIR}/${domain}.caddyfile"
    [[ -f "$config" && ! -L "$config" ]] || fail "Virtual host does not exist: $domain"

    backup="$(mktemp)"
    mv -- "$config" "$backup"
    if ! reload_frankenphp; then
        mv "$backup" "$config"
        fail "FrankenPHP rejected the change; the site config was restored."
    fi
    rm -f "$backup"
    printf 'Site config deleted. Website files were not removed: %s\n' "$domain"
}

request_certificate() {
    local cert domain expiry found=0

    require_root
    require_frankenphp
    reload_frankenphp || fail "FrankenPHP reload failed."
    printf 'Certificate request triggered.\n'

    printf 'HTTPS certificates:\n'
    while IFS= read -r cert; do
        domain=${cert##*/}
        domain=${domain%.crt}
        printf '  Domain: %s\n  File:   %s\n' "$domain" "$cert"
        if command -v openssl >/dev/null 2>&1; then
            expiry="$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2 || true)"
            [[ -n "$expiry" ]] && printf '  Expiry: %s\n' "$expiry"
        fi
        found=1
    done < <(find "$CADDY_DATA_DIR/certificates" -type f -name '*.crt' -print 2>/dev/null | sort)
    (( found )) || printf '  none found in %s\n' "$CADDY_DATA_DIR/certificates"
}

addons_usage() {
    cat <<'EOF'
Usage:
  dfm addons
  dfm addons {install|uninstall} {memcached|opcache|redis|apcu|imagemagick|exif|fileinfo|ldap|bz2|sodium|imap|swoole}

PHP extensions are installed as php-zts-* packages from the configured APT
repositories. Extensions compiled into the FrankenPHP binary need no package.
EOF
}

addons_require_frankenphp() {
    command -v frankenphp >/dev/null 2>&1 ||
        fail "FrankenPHP is not installed. Install DFM first."
}

addons_package_available() {
    local candidate
    candidate="$(apt-cache policy "$1" | awk '/Candidate:/ {print $2; exit}')"
    [[ -n "$candidate" && "$candidate" != '(none)' ]]
}

addons_prepare() {
    local addon=$1
    ADDON_PACKAGES=()
    ADDON_SERVICES=()
    case "$addon" in
        memcached)
            ADDON_PACKAGES=(memcached php-zts-memcached)
            ADDON_SERVICES=(memcached)
            ;;
        opcache)
            if addons_package_available php-zts-opcache; then
                ADDON_PACKAGES=(php-zts-opcache)
            else
                printf 'OPcache is compiled into the PHP binary; no package is needed.\n'
            fi
            ;;
        redis)
            ADDON_PACKAGES=(redis-server php-zts-redis)
            ADDON_SERVICES=(redis-server)
            ;;
        apcu) ADDON_PACKAGES=(php-zts-apcu) ;;
        imagemagick)
            ADDON_PACKAGES=(php-zts-imagick)
            ADDON_SERVICES=()
            ;;
        exif)
            printf 'Exif is compiled into the PHP binary; no package is needed.\n'
            ;;
        fileinfo)
            if addons_package_available php-zts-fileinfo; then
                ADDON_PACKAGES=(php-zts-fileinfo)
            else
                printf 'Fileinfo is already provided by the PHP binary.\n'
            fi
            ;;
        ldap) ADDON_PACKAGES=(php-zts-ldap) ;;
        bz2) ADDON_PACKAGES=(php-zts-bz2) ;;
        sodium)
            printf 'Sodium is provided by the PHP binary and its bundled libraries; no package is needed.\n'
            ;;
        imap)
            fail "php-zts-imap is not published by the FrankenPHP deb repository; build it with PIE if you need it."
            ;;
        swoole) ADDON_PACKAGES=(php-zts-swoole) ;;
        *) fail "Unsupported addon: ${addon}" ;;
    esac
}

addons_show_menu() {
    cat <<'EOF'
PHP extensions and services (FrankenPHP / ZTS packages):
  1: Memcached server + PHP extension
  2: OPcache
  3: Redis server + PHP extension
  4: APCu
  5: ImageMagick PHP extension
  6: Exif (compiled in)
  7: Fileinfo
  8: LDAP
  9: Bz2
 10: Sodium (compiled in)
 11: Imap (not published; use PIE)
 12: Swoole
 13: Exit
EOF
}

addons_restart_frankenphp() {
    local was_active=0
    systemctl is-active --quiet frankenphp && was_active=1
    stop_other_frankenphp
    ((was_active)) || return 0
    systemctl start frankenphp
}

addons_action() {
    local action=$1 addon=$2 package
    local -a available_packages=()
    require_root
    addons_require_frankenphp
    addons_prepare "$addon"
    ((${#ADDON_PACKAGES[@]} > 0)) || {
        printf '%s: nothing to install.\n' "$addon"
        return 0
    }

    for package in "${ADDON_PACKAGES[@]}"; do
        if ! addons_package_available "$package"; then
            fail "APT package ${package} is unavailable. This extension is not provided by the configured repositories."
        fi
        available_packages+=("$package")
    done

    if [[ "$action" == install ]]; then
        apt-get install -y "${available_packages[@]}"
        for package in "${ADDON_SERVICES[@]}"; do
            if systemctl cat "$package" >/dev/null 2>&1; then
                systemctl enable --now "$package"
            else
                printf 'Warning: systemd unit %s not found; skipping enable.\n' "$package" >&2
            fi
        done
        addons_restart_frankenphp
        printf '%s installed.\n' "$addon"
    else
        apt-get remove -y "${available_packages[@]}"
        addons_restart_frankenphp
        printf '%s removed.\n' "$addon"
    fi
}

addons_run() {
    local action=${1:-} addon=${2:-} choice
    if [[ -z "$action" ]]; then
        addons_show_menu
        read -r -p "Select addon number: " choice
        case "$choice" in
            1) addon=memcached ;;
            2) addon=opcache ;;
            3) addon=redis ;;
            4) addon=apcu ;;
            5) addon=imagemagick ;;
            6) addon=exif ;;
            7) addon=fileinfo ;;
            8) addon=ldap ;;
            9) addon=bz2 ;;
            10) addon=sodium ;;
            11) addon=imap ;;
            12) addon=swoole ;;
            13|exit) return 0 ;;
            *) fail "Invalid addon selection: ${choice}" ;;
        esac
        action=install
    fi
    case "$action" in
        install|uninstall)
            [[ -n "$addon" ]] || { addons_usage >&2; exit 2; }
            addons_action "$action" "${addon,,}"
            ;;
        --help|-h) addons_usage ;;
        *) addons_usage >&2; exit 2 ;;
    esac
}

case "${1:-}" in
    --help|-h)
        usage
        exit 0
        ;;
    start|stop|restart|reload)
        require_root
        service_bundle "$1"
        ;;
    kill)
        require_root
        service_bundle stop
        ;;
    status)
        service_action status frankenphp
        service_action status mysql
        ;;
    fp|frankenphp|db|mysql|mariadb)
        [[ $# -eq 2 ]] || { usage >&2; exit 2; }
        require_root
        case "$2" in
            start|stop|restart|reload|kill|status) ;;
            *) usage >&2; exit 2 ;;
        esac
        case "$1" in
            fp) service=frankenphp ;;
            db|mariadb) service=mysql ;;
            *) service=$1 ;;
        esac
        service_action "$2" "$service"
        ;;
    vhost)
        case "${2:-}" in
            add) add_vhost ;;
            add-http) add_vhost http ;;
            list) list_vhosts ;;
            del)
                [[ $# -le 3 ]] || { usage >&2; exit 2; }
                delete_vhost "${3:-}"
                ;;
            cert)
                [[ $# -eq 2 ]] || { usage >&2; exit 2; }
                request_certificate
                ;;
            *) usage >&2; exit 2 ;;
        esac
        ;;
    addons)
        shift
        addons_run "$@"
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
