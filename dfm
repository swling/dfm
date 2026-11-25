#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r /etc/dfm.conf ]]; then
    # shellcheck disable=SC1091
    . /etc/dfm.conf
elif [[ -r "${SCRIPT_DIR}/dfm.conf" ]]; then
    # shellcheck disable=SC1091
    . "${SCRIPT_DIR}/dfm.conf"
fi

FRANKENPHP_CONFIG_DIR=/etc/frankenphp
SITE_DIR="${FRANKENPHP_CONFIG_DIR}/Caddyfile.d"
REWRITE_DIR="${FRANKENPHP_CONFIG_DIR}/rewrite"
CADDYFILE="${FRANKENPHP_CONFIG_DIR}/Caddyfile"
WEB_ROOT="${WEB_ROOT:-/home/wwwroot}"
DEFAULT_WEB_ROOT="${DEFAULT_WEB_ROOT:-${WEB_ROOT}/default}"
FRANKENPHP_LOG_DIR="${FRANKENPHP_LOG_DIR:-/var/log/frankenphp}"

usage() {
    cat <<'EOF'
Usage:
  dfm {start|stop|restart|reload|kill|status}
  dfm {frankenphp|mysql} {start|stop|restart|reload|kill|status}
  dfm vhost {add|list|del}
  dfm addons {install|uninstall} <addon>

HTTPS certificates are handled automatically by Caddy for domain site blocks.
There are no ssl / dnsssl commands in DFM.
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

stop_other_frankenphp() {
    local -a pids=()
    local _

    # Stop the managed unit first so systemd does not restart the process
    # while we are cleaning up leftover instances.
    systemctl stop frankenphp >/dev/null 2>&1 || true

    mapfile -t pids < <(pgrep -x frankenphp 2>/dev/null || true)
    ((${#pids[@]} > 0)) || return 0

    printf 'Stopping existing FrankenPHP processes...\n'
    kill -TERM "${pids[@]}" 2>/dev/null || true
    for _ in {1..25}; do
        mapfile -t pids < <(pgrep -x frankenphp 2>/dev/null || true)
        ((${#pids[@]} == 0)) && break
        sleep 0.2
    done
    if ((${#pids[@]} > 0)); then
        kill -KILL "${pids[@]}" 2>/dev/null || true
        sleep 0.2
    fi
    printf 'Existing FrankenPHP processes stopped.\n'
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
    local domain=$1 names=$2 webroot=$3 rewrite=$4 log_block=$5
    local config="${SITE_DIR}/${domain}.caddyfile" addresses name

    [[ ! -e "$config" && ! -L "$config" ]] ||
        fail "Virtual host already exists: $domain"
    [[ "$webroot" == /* && "$webroot" =~ ^/[A-Za-z0-9_./-]+$ ]] ||
        fail "Web root must be an absolute path using only letters, digits, dot, underscore, slash, or hyphen."
    [[ "$rewrite" =~ ^[A-Za-z0-9_-]+$ ]] || fail "Invalid rewrite profile name."
    [[ -e "${REWRITE_DIR}/${rewrite}.caddyfile" || -L "${REWRITE_DIR}/${rewrite}.caddyfile" ]] ||
        fail "Rewrite profile does not exist: ${rewrite}"

    addresses="$domain"
    for name in $names; do
        addresses+=", ${name}"
    done

    if [[ ! -d "$webroot" ]]; then
        mkdir -p "$webroot"
        chown www:www "$webroot"
        chmod 0775 "$webroot"
    fi

    cat > "$config" <<EOF
# Managed by DFM. Site: ${domain}
${addresses} {
    root * ${webroot}
    encode zstd br gzip

    import /etc/frankenphp/cache-static.caddyfile

    @dotfiles path_regexp dotfiles (^|/)\\.
    handle @dotfiles {
        respond 404
    }

    handle {
        import ${REWRITE_DIR}/${rewrite}.caddyfile
        php_server
    }
${log_block}
}
EOF
    if ! reload_frankenphp; then
        rm -f "$config"
        fail "FrankenPHP rejected the new virtual host; its config was removed."
    fi
    printf 'Virtual host created: %s\nWeb root: %s\n' "$domain" "$webroot"
    printf 'HTTPS: Caddy will obtain a certificate on the first request over HTTPS.\n'
}

add_vhost() {
    local domain more_names webroot rewrite allow_rewrite
    local access_choice log_file log_block name
    local -a additional_names rewrite_profiles
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

    read -r -p "Enable pseudo-static rewrite rules? [y/N]: " allow_rewrite
    if [[ "$allow_rewrite" =~ ^[Yy]$ ]]; then
        mapfile -t rewrite_profiles < <(
            find "$REWRITE_DIR" -maxdepth 1 -type f -name '*.caddyfile' -print |
                sed 's#^.*/##; s/\.caddyfile$//' | sort
        )
        printf 'Available rewrite profiles:\n'
        printf '  %s\n' "${rewrite_profiles[@]}"
        read -r -p "Rewrite profile [other]: " rewrite
        rewrite="${rewrite:-other}"
    else
        rewrite=none
    fi
    [[ "$rewrite" =~ ^[A-Za-z0-9_-]+$ ]] || fail "Invalid rewrite profile name."
    printf 'Using rewrite profile: %s\n' "$rewrite"

    # In classic mode php_server splits PATH_INFO by default, so there is no
    # separate Pathinfo prompt like the old FastCGI vhost flow.

    read -r -p "Enable access log? [Y/n]: " access_choice
    log_block=
    if [[ ! "$access_choice" =~ ^[Nn]$ ]]; then
        log_file="${FRANKENPHP_LOG_DIR}/${domain}.log"
        install -d -o frankenphp -g frankenphp -m 0755 "$FRANKENPHP_LOG_DIR"
        log_block="    log {
        output file ${log_file}
    }"
    fi

    create_vhost_config "$domain" "$domain $more_names" "$webroot" "$rewrite" "$log_block"
}

list_vhosts() {
    require_frankenphp
    printf 'FrankenPHP site list:\n'
    find "$SITE_DIR" -maxdepth 1 -type f -name '*.caddyfile' ! -name default.caddyfile -print |
        sed 's#^.*/##; s/\.caddyfile$//' | sort
}

delete_vhost() {
    local domain backup config
    require_root
    require_frankenphp
    list_vhosts
    read -r -p "Please enter domain you want to delete: " domain
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
    frankenphp|mysql|mariadb)
        [[ $# -eq 2 ]] || { usage >&2; exit 2; }
        require_root
        case "$2" in
            start|stop|restart|reload|kill|status) ;;
            *) usage >&2; exit 2 ;;
        esac
        if [[ "$1" == mariadb ]]; then
            service_action "$2" mysql
        else
            service_action "$2" "$1"
        fi
        ;;
    vhost)
        case "${2:-}" in
            add) add_vhost ;;
            list) list_vhosts ;;
            del) delete_vhost ;;
            *) usage >&2; exit 2 ;;
        esac
        ;;
    addons)
        shift
        exec /usr/local/bin/addons.sh "$@"
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
