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
    local -a pids=()
    local _

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
