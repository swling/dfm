#!/usr/bin/env bash
# DFM 共享常量与函数。由 install.sh 安装，dfm / upgrade.sh / sync-dfm.sh 引用。

MYSQL_KEYRING=/usr/share/keyrings/mysql-apt.gpg
MYSQL_SOURCE=/etc/apt/sources.list.d/mysql.list
MYSQL_REPO_URL=https://repo.mysql.com/apt/debian
FRANKENPHP_REPO_BASE=https://pkg.henderkes.com/api/packages
FRANKENPHP_MARKER='# Managed by DFM'
FRANKENPHP_CONFIG_DIR=/etc/frankenphp
STATE_DIR=/etc/dfm

PHP_ZTS_PACKAGES=(
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
declare -a PHP_BRANCHES=()

frankenphp_source_path() {
    printf '/etc/apt/sources.list.d/static-php%s.list' "${1//./}"
}

frankenphp_keyring_path() {
    printf '/etc/apt/keyrings/static-php%s.asc' "${1//./}"
}

detect_php_branches() {
    local branch code
    PHP_BRANCHES=()
    for branch in 8.2 8.3 8.4 8.5; do
        code="${branch//./}"
        if curl --fail --silent --show-error --location --head --max-time 20 \
            "${FRANKENPHP_REPO_BASE}/${code}/debian/dists/php-zts/Release" \
            -o /dev/null 2>/dev/null; then
            PHP_BRANCHES+=("$branch")
        fi
    done
    ((${#PHP_BRANCHES[@]} > 0)) ||
        fail "No PHP branches are available from the FrankenPHP deb repository."
}

stop_other_frankenphp() {
    local admin_url=http://localhost:2019
    local _

    systemctl stop frankenphp >/dev/null 2>&1 || true

    # Caddy's admin endpoint is bound by one process at a time. A successful
    # probe means a leftover instance is still listening on :2019 (and usually
    # :80/:443); no response means there is nothing to clean up.
    curl --fail --silent --max-time 2 "${admin_url}/config/" >/dev/null 2>&1 || return 0

    printf 'Stopping the leftover FrankenPHP instance via the admin API...\n'
    curl --silent --max-time 5 -X POST "${admin_url}/stop" >/dev/null 2>&1 || true

    for _ in {1..25}; do
        curl --fail --silent --max-time 1 "${admin_url}/config/" >/dev/null 2>&1 || {
            printf 'Leftover FrankenPHP instance stopped.\n'
            return 0
        }
        sleep 0.2
    done

    fail "The FrankenPHP admin endpoint is still responding after POST /stop. Check which process holds :2019, :80 and :443 (for example with ss -ltnp) and stop it before continuing."
}
