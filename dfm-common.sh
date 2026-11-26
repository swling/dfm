#!/usr/bin/env bash
# DFM 共享常量与函数。由 install.sh 安装，dfm / upgrade.sh / sync-dfm.sh 引用。

MYSQL_KEYRING=/usr/share/keyrings/mysql-apt.gpg
MYSQL_SOURCE=/etc/apt/sources.list.d/mysql.list
MYSQL_REPO_URL=https://repo.mysql.com/apt/debian
FRANKENPHP_REPO_BASE=https://pkg.henderkes.com/api/packages
FRANKENPHP_MARKER='# Managed by DFM'
FRANKENPHP_CONFIG_DIR=/etc/frankenphp
STATE_DIR=/etc/dfm

# Defaults for the parameters exposed in dfm.conf. Every script sources this
# file before the config file, so values in dfm.conf override these defaults.
PHP_BRANCH_CANDIDATES="${PHP_BRANCH_CANDIDATES:-8.2 8.3 8.4 8.5}"
PHP_BRANCH_PROBE_TIMEOUT="${PHP_BRANCH_PROBE_TIMEOUT:-20}"
MYSQL_MIN_MAJOR_VERSION="${MYSQL_MIN_MAJOR_VERSION:-8}"
MIN_DEBIAN_MAJOR="${MIN_DEBIAN_MAJOR:-13}"
MYSQL_ARCHITECTURES="${MYSQL_ARCHITECTURES:-amd64}"
FRANKENPHP_ARCHITECTURES="${FRANKENPHP_ARCHITECTURES:-amd64 arm64}"
MYSQL_GPG_KEY_URL="${MYSQL_GPG_KEY_URL:-https://repo.mysql.com/RPM-GPG-KEY-mysql-2025}"
MYSQL_GPG_FINGERPRINT="${MYSQL_GPG_FINGERPRINT:-BCA43417C3B485DD128EC6D4B7B3B788A8D3785C}"
FRANKENPHP_ADMIN_URL="${FRANKENPHP_ADMIN_URL:-http://localhost:2019}"
FRANKENPHP_STOP_POLL_ATTEMPTS="${FRANKENPHP_STOP_POLL_ATTEMPTS:-25}"
FRANKENPHP_STOP_POLL_INTERVAL="${FRANKENPHP_STOP_POLL_INTERVAL:-0.2}"

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
    for branch in $PHP_BRANCH_CANDIDATES; do
        code="${branch//./}"
        if curl --fail --silent --show-error --location --head \
            --max-time "$PHP_BRANCH_PROBE_TIMEOUT" \
            "${FRANKENPHP_REPO_BASE}/${code}/debian/dists/php-zts/Release" \
            -o /dev/null 2>/dev/null; then
            PHP_BRANCHES+=("$branch")
        fi
    done
    ((${#PHP_BRANCHES[@]} > 0)) ||
        fail "No PHP branches are available from the FrankenPHP deb repository. Check PHP_BRANCH_CANDIDATES in dfm.conf."
}

stop_other_frankenphp() {
    local admin_url="$FRANKENPHP_ADMIN_URL"
    local i

    systemctl stop frankenphp >/dev/null 2>&1 || true

    # Caddy's admin endpoint is bound by one process at a time. A successful
    # probe means a leftover instance is still listening there (and usually on
    # :80/:443); no response means there is nothing to clean up.
    curl --fail --silent --max-time 2 "${admin_url}/config/" >/dev/null 2>&1 || return 0

    printf 'Stopping the leftover FrankenPHP instance via the admin API...\n'
    curl --silent --max-time 5 -X POST "${admin_url}/stop" >/dev/null 2>&1 || true

    for ((i = 1; i <= FRANKENPHP_STOP_POLL_ATTEMPTS; i++)); do
        curl --fail --silent --max-time 1 "${admin_url}/config/" >/dev/null 2>&1 || {
            printf 'Leftover FrankenPHP instance stopped.\n'
            return 0
        }
        sleep "$FRANKENPHP_STOP_POLL_INTERVAL"
    done

    fail "The FrankenPHP admin endpoint (${admin_url}) is still responding after POST /stop. Check which process holds the endpoint or ports 80/443 (for example with ss -ltnp) and stop it before continuing."
}
