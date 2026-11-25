#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage:
  addons.sh
  addons.sh {install|uninstall} {memcached|opcache|redis|apcu|imagemagick|exif|fileinfo|ldap|bz2|sodium|imap|swoole}

PHP extensions are installed as php-zts-* packages from the configured APT
repositories. Extensions compiled into the FrankenPHP binary need no package.
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
    command -v frankenphp >/dev/null 2>&1 ||
        fail "FrankenPHP is not installed. Install DFM first."
}

package_available() {
    local candidate
    candidate="$(apt-cache policy "$1" | awk '/Candidate:/ {print $2; exit}')"
    [[ -n "$candidate" && "$candidate" != '(none)' ]]
}

prepare_addon() {
    local addon=$1
    ADDON_PACKAGES=()
    ADDON_SERVICES=()
    case "$addon" in
        memcached)
            ADDON_PACKAGES=(php-zts-memcached)
            ADDON_SERVICES=(memcached)
            ;;
        opcache)
            if package_available php-zts-opcache; then
                ADDON_PACKAGES=(php-zts-opcache)
            else
                printf 'OPcache is compiled into the PHP binary; no package is needed.\n'
            fi
            ;;
        redis)
            ADDON_PACKAGES=(php-zts-redis)
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
            if package_available php-zts-fileinfo; then
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

show_menu() {
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

restart_frankenphp() {
    if systemctl is-active --quiet frankenphp; then
        systemctl restart frankenphp
    fi
}

addon_action() {
    local action=$1 addon=$2 package
    local -a available_packages
    available_packages=()
    require_root
    require_frankenphp
    prepare_addon "$addon"
    ((${#ADDON_PACKAGES[@]} > 0)) || {
        printf '%s: nothing to install.\n' "$addon"
        return 0
    }

    for package in "${ADDON_PACKAGES[@]}"; do
        if ! package_available "$package"; then
            fail "APT package ${package} is unavailable. This extension is not provided by the configured repositories."
        fi
        available_packages+=("$package")
    done

    if [[ "$action" == install ]]; then
        apt-get install -y "${available_packages[@]}"
        for package in "${ADDON_SERVICES[@]}"; do
            systemctl enable --now "$package"
        done
        restart_frankenphp
        printf '%s installed.\n' "$addon"
    else
        apt-get remove -y "${available_packages[@]}"
        restart_frankenphp
        printf '%s removed.\n' "$addon"
    fi
}

action="${1:-}"
addon="${2:-}"
if [[ -z "$action" ]]; then
    show_menu
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
        13|exit) exit 0 ;;
        *) fail "Invalid addon selection: ${choice}" ;;
    esac
    action=install
fi

case "$action" in
    install|uninstall)
        [[ -n "$addon" ]] || { usage >&2; exit 2; }
        addon="${addon,,}"
        addon_action "$action" "$addon"
        ;;
    --help|-h)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
