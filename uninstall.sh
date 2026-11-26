#!/usr/bin/env bash
# DFM 卸载脚本（Debian + FrankenPHP + MySQL）
# 支持按 mysql / frankenphp 单独卸载，或整体卸载（all）。
# 只卸载软件与安装器生成的配置；数据库、网站、站点配置和证书数据只警告、不处理。
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/dfm-common.sh"

SYSTEM_CONFIG=/etc/dfm.conf
FRANKENPHP_DIR="${FRANKENPHP_CONFIG_DIR}"
SITE_DIR="${FRANKENPHP_DIR}/Caddyfile.d"
REWRITE_DIR="${FRANKENPHP_DIR}/rewrite"
FRANKENPHP_DROPIN_DIR=/etc/systemd/system/frankenphp.service.d
CADDY_DATA=/var/lib/frankenphp/caddy
MYSQL_DFM_CNF=/etc/mysql/mysql.conf.d/zz-dfm.cnf
AUTO_CONFIRM=0
COMPONENT=""

declare -a PURGE_PKGS=()
declare -a REMOVE_ITEMS=()

usage() {
    cat <<'EOF'
Usage:
  ./uninstall.sh [--component=mysql|frankenphp|all] [--yes]

卸载 DFM 的指定组件：
  mysql       仅卸载 MySQL 软件包、APT 仓库与安装器生成的配置；数据目录保留
  frankenphp  仅卸载 FrankenPHP 与 php-zts 扩展包、APT 仓库与 DFM 配置；站点配置保留
  all         卸载全部组件与管理命令（交互选择时默认）

不会处理（仅打印警告，需你手动决定）：
  - MySQL 数据目录（可能在独立磁盘）与其备份
  - 网站文件、站点配置、访问日志与 Caddy 自动证书数据
  - Caddyfile.d/ 下全部站点配置（含 default.caddyfile）

选项：
  -c, --component NAME  指定卸载目标：mysql / frankenphp / all
  -y, --yes             跳过确认；未指定 --component 时按 all 处理
  -h, --help            显示帮助

不带 --component 且交互运行时，会先询问卸载目标。
EOF
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
info() { printf '  - %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

select_component() {
    local answer=""
    [[ -n "$COMPONENT" ]] && return 0
    if (( AUTO_CONFIRM )); then
        COMPONENT=all
        info "--yes 未指定组件，按 all 处理"
        return 0
    fi

    cat <<'EOF'
请选择卸载目标：
  1) mysql       仅卸载 MySQL
  2) frankenphp  仅卸载 FrankenPHP 与 PHP 扩展
  3) all         卸载全部（默认）
EOF
    read -r -p "输入选项 [3]: " answer || true
    case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
        1|mysql) COMPONENT=mysql ;;
        2|frankenphp|php) COMPONENT=frankenphp ;;
        3|all|"") COMPONENT=all ;;
        *) fail "无效选择: $answer" ;;
    esac
}

confirm() {
    if (( AUTO_CONFIRM )); then
        printf '  (--yes: 自动确认)\n'
        return 0
    fi
    local answer=""
    read -r -p "确认卸载 ${COMPONENT} ? 输入 yes 继续: " answer || true
    [[ "$answer" == yes ]] || fail "已取消。"
}

remove_files() {
    local f
    for f in "$@"; do
        [[ -e "$f" || -L "$f" ]] && { rm -f -- "$f"; info "已删除: $f"; }
    done
}

# ---- 参数 ----
while (( $# )); do
    case "$1" in
        -y|--yes) AUTO_CONFIRM=1; shift ;;
        -c|--component)
            (( $# >= 2 )) || fail "--component 需要一个目标：mysql / frankenphp / all"
            COMPONENT=$2
            shift 2
            ;;
        --component=*) COMPONENT="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "未知参数: $1（用 --help 查看用法）" ;;
    esac
done
case "$COMPONENT" in
    ""|mysql|frankenphp|all) ;;
    *) fail "无效的卸载目标: ${COMPONENT} (可选: mysql / frankenphp / all)" ;;
esac

(( EUID == 0 )) || fail "请以 root 身份运行。"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == debian ]] || warn "当前系统不是 Debian，继续卸载但请自行核对路径。"
fi
select_component

# ---- 读取安装时的配置 ----
if [[ -r "$SYSTEM_CONFIG" ]]; then
    # shellcheck disable=SC1090
    . "$SYSTEM_CONFIG"
elif [[ -r "${SCRIPT_DIR}/dfm.conf" ]]; then
    # shellcheck disable=SC1091
    . "${SCRIPT_DIR}/dfm.conf"
fi
WEB_ROOT="${WEB_ROOT:-/home/wwwroot}"
MYSQL_DATA_DIR="${MYSQL_DATA_DIR:-/var/lib/mysql}"
FRANKENPHP_LOG_DIR="${FRANKENPHP_LOG_DIR:-/var/log/frankenphp}"

# ---- 组件：收集待 purge 的软件包 ----
collect_prefix() {
    local prefix=$1 pkg
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] || continue
        PURGE_PKGS+=("$pkg")
    done < <(dpkg-query -W -f='${Package}\n' 2>/dev/null | awk -v p="$prefix" 'index($0,p)==1')
}

collect_mysql_packages() {
    collect_prefix mysql-server
    collect_prefix mysql-client
    # mysql-server 只是元包，Oracle 实际安装的是 mysql-community-* 包，必须一并清除。
    collect_prefix mysql-community-server
    collect_prefix mysql-community-client
}

collect_frankenphp_packages() {
    collect_prefix frankenphp
    # 所有 php-zts-* 扩展与共享运行时都来自同一个 FrankenPHP deb 仓库。
    collect_prefix php-zts
}

dedup_packages() {
    local p
    declare -A seen=()
    declare -a uniq=()
    for p in "${PURGE_PKGS[@]}"; do
        [[ -n "$p" ]] || continue
        if [[ -z "${seen[$p]:-}" ]]; then
            seen[$p]=1
            uniq+=("$p")
        fi
    done
    PURGE_PKGS=("${uniq[@]}")
}

collect_packages() {
    case "$COMPONENT" in
        mysql) collect_mysql_packages ;;
        frankenphp) collect_frankenphp_packages ;;
        all)
            collect_mysql_packages
            collect_frankenphp_packages
            ;;
    esac
    dedup_packages
}

# ---- 组件：生成卸载计划 ----
plan_mysql() {
    REMOVE_ITEMS+=(
        "MySQL 安装器生成的配置: ${MYSQL_DFM_CNF}"
        "AppArmor 中为 ${MYSQL_DATA_DIR} 追加的规则"
        "软链 /var/lib/mysql（不触碰其指向的数据）"
        "APT 仓库与密钥: ${MYSQL_SOURCE}, ${MYSQL_KEYRING}（源文件有 .dfm.orig 时还原原内容）"
    )
}

plan_frankenphp() {
    REMOVE_ITEMS+=(
        "systemd 覆盖配置: ${FRANKENPHP_DROPIN_DIR}/10-dfm.conf"
        "内置伪静态规则（自定义规则保留）、cache-static.caddyfile"
        "APT 仓库与密钥: /etc/apt/sources.list.d/static-php*.list、/etc/apt/keyrings/static-php*.asc（源文件有 .dfm.orig 时还原原内容）"
        "状态文件: ${STATE_DIR}/php-version、${STATE_DIR}/frankenphp-version"
    )
}

plan_all_extra() {
    REMOVE_ITEMS+=(
        "管理命令: /usr/local/bin/dfm, /usr/bin/dfm"
        "共享函数库: /usr/local/bin/dfm-common.sh"
        "用户配置与状态: ${SYSTEM_CONFIG}, ${STATE_DIR}"
        "www 用户/组"
    )
}

build_plan() {
    REMOVE_ITEMS=("APT 包: ${PURGE_PKGS[*]:-（未检测到）}")
    case "$COMPONENT" in
        mysql) plan_mysql ;;
        frankenphp) plan_frankenphp ;;
        all)
            plan_mysql
            plan_frankenphp
            plan_all_extra
            ;;
    esac
}

print_plan() {
    local c kept_list=""
    cat <<EOF
================================================================
DFM 卸载计划 (目标: ${COMPONENT})
----------------------------------------------------------------
将删除（软件与 DFM 自身的配置）：
EOF
    for c in "${REMOVE_ITEMS[@]}"; do
        printf '  - %s\n' "$c"
    done
    cat <<EOF

将保留（只警告，不处理，请自行决定）：
  - MySQL 数据目录: ${MYSQL_DATA_DIR}
  - 网站文件: ${WEB_ROOT}
  - 站点配置: ${SITE_DIR}/（含 default.caddyfile）
  - Caddy 自动证书数据: ${CADDY_DATA}
  - 访问日志: ${FRANKENPHP_LOG_DIR}
  - 扩展服务包（如 memcached、redis-server）不会被单独移除
EOF
    case "$COMPONENT" in
        mysql) kept_list="FrankenPHP" ;;
        frankenphp) kept_list="MySQL" ;;
    esac
    [[ -z "$kept_list" ]] ||
        printf '  - 未选择的组件: %s（管理命令与共享配置保留）\n' "$kept_list"
    cat <<'EOF'
================================================================
EOF
    warn "不会备份数据库，也不会删除任何数据库文件/目录。"
    confirm
}

# ---- 组件：MySQL ----
remove_apparmor_rules() {
    local apparmor_local=/etc/apparmor.d/local/usr.sbin.mysqld
    [[ "$MYSQL_DATA_DIR" != /var/lib/mysql && -f "$apparmor_local" ]] || return 0

    local rules_tmp filtered_tmp apparmor_parent
    rules_tmp="$(mktemp)"
    printf '%s\n' "${MYSQL_DATA_DIR}/ r," "${MYSQL_DATA_DIR}/** rwk," > "$rules_tmp"
    apparmor_parent="$(dirname "$MYSQL_DATA_DIR")"
    while [[ "$apparmor_parent" != / ]]; do
        printf '%s\n' "${apparmor_parent}/ r," "${apparmor_parent}/ x," >> "$rules_tmp"
        apparmor_parent="$(dirname "$apparmor_parent")"
    done
    filtered_tmp="$(mktemp)"
    awk 'NR==FNR { drop[$0]=1; next } !($0 in drop)' \
        "$rules_tmp" "$apparmor_local" > "$filtered_tmp"
    if ! cmp -s "$apparmor_local" "$filtered_tmp"; then
        chmod --reference="$apparmor_local" "$filtered_tmp"
        mv -- "$filtered_tmp" "$apparmor_local"
        [[ -s "$apparmor_local" ]] || rm -f -- "$apparmor_local"
        if command -v apparmor_parser >/dev/null 2>&1; then
            apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld >/dev/null 2>&1 ||
                warn "AppArmor 重新加载失败，请手动执行: apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld"
        fi
        info "已移除 AppArmor 中为 ${MYSQL_DATA_DIR} 追加的规则"
    fi
    rm -f -- "$rules_tmp" "$filtered_tmp"
}

run_mysql() {
    local orig
    step "卸载 MySQL"
    systemctl stop mysql >/dev/null 2>&1 || true

    if [[ -f "$MYSQL_DFM_CNF" ]]; then
        rm -f -- "$MYSQL_DFM_CNF"
        info "已删除: $MYSQL_DFM_CNF"
    fi
    remove_apparmor_rules

    step "数据库安全处理（仅移除软链，不动数据）"
    if [[ -L /var/lib/mysql ]]; then
        info "移除软链 /var/lib/mysql -> $(readlink /var/lib/mysql)"
        rm -f -- /var/lib/mysql
        info "数据目录 ${MYSQL_DATA_DIR} 未做任何改动"
    else
        info "/var/lib/mysql 不是软链，未做改动"
    fi
    warn "MySQL 数据目录 ${MYSQL_DATA_DIR} 保留，请自行处理。"

    step "处理 MySQL APT 仓库与密钥"
    orig="${MYSQL_SOURCE}.dfm.orig"
    if [[ -f "$orig" ]]; then
        mv -f -- "$orig" "$MYSQL_SOURCE" && info "已还原 APT 源: $MYSQL_SOURCE"
    else
        remove_files "$MYSQL_SOURCE"
    fi
    remove_files "$MYSQL_KEYRING"
}

# ---- 组件：FrankenPHP ----
remove_frankenphp_repository() {
    local source key orig
    for source in /etc/apt/sources.list.d/static-php*.list; do
        [[ -f "$source" ]] || continue
        grep -Fq "$FRANKENPHP_MARKER" "$source" || continue
        key="/etc/apt/keyrings/$(basename "${source%.list}").asc"
        orig="${source}.dfm.orig"
        if [[ -f "$orig" ]]; then
            mv -f -- "$orig" "$source" && info "已还原 APT 源: $source"
        else
            remove_files "$source"
        fi
        remove_files "$key"
    done
    for orig in /etc/apt/sources.list.d/static-php*.list.dfm.orig; do
        [[ -f "$orig" ]] || continue
        source="${orig%.dfm.orig}"
        mv -f -- "$orig" "$source" && info "已还原 APT 源: $source"
    done
}

run_frankenphp() {
    local tpl leftover dropin

    step "卸载 FrankenPHP"
    systemctl stop frankenphp >/dev/null 2>&1 || true

    dropin="${FRANKENPHP_DROPIN_DIR}/10-dfm.conf"
    remove_files "$dropin"
    if [[ -d "$FRANKENPHP_DROPIN_DIR" ]] &&
       [[ -z "$(find "$FRANKENPHP_DROPIN_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        rmdir -- "$FRANKENPHP_DROPIN_DIR" 2>/dev/null || true
    fi

    for tpl in none other wordpress laravel joomla drupal; do
        [[ -e "${REWRITE_DIR}/${tpl}.caddyfile" || -L "${REWRITE_DIR}/${tpl}.caddyfile" ]] && {
            rm -f -- "${REWRITE_DIR}/${tpl}.caddyfile"
            info "已删除内置规则: ${tpl}.caddyfile"
        }
    done
    if [[ -d "$REWRITE_DIR" ]]; then
        leftover="$(find "$REWRITE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"
        [[ -z "$leftover" ]] || warn "${REWRITE_DIR} 中仍有自定义规则，已保留整个目录。"
    fi
    remove_files "${FRANKENPHP_DIR}/cache-static.caddyfile"

    step "删除状态文件与 FrankenPHP APT 仓库"
    remove_files "${STATE_DIR}/php-version" "${STATE_DIR}/frankenphp-version"
    remove_frankenphp_repository

    warn "站点配置、证书数据 ${CADDY_DATA} 与日志 ${FRANKENPHP_LOG_DIR} 均未处理。"
    warn "通过 dfm addons 安装的 memcached / redis-server 等独立服务包未移除。"
}

# ---- all：管理组件 ----
run_all_extra() {
    step "处理管理命令"
    remove_files /usr/local/bin/dfm /usr/bin/dfm /usr/local/bin/dfm-common.sh

    step "删除 DFM 配置与状态"
    remove_files "$SYSTEM_CONFIG"
    if [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]]; then
        rm -rf -- "$STATE_DIR" && info "已删除: $STATE_DIR"
    fi

    step "处理 www 用户/组"
    if getent passwd www >/dev/null 2>&1; then
        if userdel www >/dev/null 2>&1; then
            info "已删除用户 www（网站文件 ${WEB_ROOT} 保留，其属主将显示为原 UID）"
        else
            warn "删除用户 www 失败（可能被占用），已保留。"
        fi
    fi
    if getent group www >/dev/null 2>&1; then
        groupdel www >/dev/null 2>&1 || warn "删除组 www 失败，已保留。"
    fi
}

# ---- 统一处理软件包 ----
purge_selected_packages() {
    step "清理软件包与 APT 缓存"
    if (( ${#PURGE_PKGS[@]} )); then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${PURGE_PKGS[@]}" ||
            warn "apt-get purge 返回错误，请检查输出。"
        # 清理随 MySQL 服务器自动安装的依赖（如 mysql-community-libs/common）。
        DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y ||
            warn "apt-get autoremove 返回错误，请检查输出。"
    else
        info "未检测到需要 purge 的软件包"
    fi
    apt-get update >/dev/null 2>&1 || warn "apt-get update 失败，请手动执行。"
}

print_summary() {
    cat <<EOF

================================================================
卸载完成 (目标: ${COMPONENT})
----------------------------------------------------------------
EOF
    if [[ "$COMPONENT" == all ]]; then
        cat <<'EOF'
已移除 DFM 软件、管理命令、安装器生成的配置与 APT 仓库，并清理或还原了安装器
生成的 .dfm.orig 备份。Caddyfile.d/ 下所有站点配置（含 default.caddyfile）均未处理；
下次安装时已有 default.caddyfile 会原样保留，只有缺失时才按模板生成。
EOF
    else
        printf '已移除 %s 相关软件、配置与 APT 仓库；未选择的组件、管理命令和共享配置保持原样。\n' "$COMPONENT"
    fi
    cat <<EOF

以下数据未被处理，请自行确认：
  数据库数据:       ${MYSQL_DATA_DIR}
  网站文件:         ${WEB_ROOT}
  站点配置:         ${SITE_DIR}/（含 default.caddyfile）
  Caddy 证书数据:   ${CADDY_DATA}
  访问日志:         ${FRANKENPHP_LOG_DIR}
================================================================
EOF
}

# ---- 主流程 ----
collect_packages
build_plan
print_plan

case "$COMPONENT" in
    mysql) run_mysql ;;
    frankenphp) run_frankenphp ;;
    all)
        run_mysql
        run_frankenphp
        run_all_extra
        ;;
esac

purge_selected_packages
systemctl daemon-reload >/dev/null 2>&1 || true
print_summary
