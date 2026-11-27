# DFM

DFM 是 Debian 13 及以上版本的 Debian + FrankenPHP + MySQL 安装与管理脚本集。
它从同目录的 LNMP 版本改写而来：用 FrankenPHP 同时替代 Nginx 与 PHP-FPM，
MySQL 的安装、数据目录迁移和选版逻辑保持不变。

## 主要变化

  - Web 层只有一个 frankenphp 服务，不再安装 nginx 和 php-fpm。
  - 站点配置从 /etc/nginx/conf.d/*.conf 改为 /etc/frankenphp/Caddyfile.d/*.caddyfile。
  - TLS 由 Caddy 的自动 HTTPS 处理，不再安装 acme.sh。
  - PHP 扩展来自 FrankenPHP deb 仓库的 php-zts-* 包，不再使用 sury 的 php8.x-* 包。
  - 管理命令从 lnmp 改名为 dfm。

## 目录内容

  install.sh        安装器（官方 deb 源 + Oracle MySQL 官方源，交互选版）
  dfm.conf          安装前编辑的配置，安装时覆盖 /etc/dfm.conf
  dfm               安装后的管理命令：服务、虚拟主机、扩展入口（内置 addons）
  dfm-common.sh     共享常量与函数，随 dfm 安装和同步
  uninstall.sh      按 mysql / frankenphp / all 卸载，保留数据
  upgrade.sh        按 frankenphp / php / mysql 手动升级
  sync-dfm.sh       把 dfm 同步到系统命令路径
  conf/             Caddyfile、默认站点、静态缓存片段模板
  docs/             安装、配置、命令、路径、卸载、升级与备份文档

## 从零开始的完整流程

  1. 在源码目录的 dfm.conf 中设置网站根目录、MySQL 数据目录、PHP 分支、ACME 邮箱；安装会覆盖 /etc/dfm.conf。
  2. 以 root 运行 ./install.sh，按提示选择 PHP 分支与 MySQL 版本。
  3. 用 dfm status 检查 frankenphp 与 mysql 均为 active。
  4. 用 dfm vhost add 创建站点，默认启用 HTTPS，询问时选 n 可创建仅 HTTP 站点；也可直接用 dfm vhost add-http。域名解析到本机后 Caddy 自动签发证书。后期要为某个域名申请证书时，手工去掉该地址的 http:// 前缀，再用 dfm vhost cert 触发签发并列出已签发证书。站点按 <域名>.caddyfile 管理；多个域名共用网站目录时手工写进同一文件，list 列文件名，del 删整个文件。
  5. 按需用 dfm addons install <扩展> 安装 php-zts 扩展。
  6. 修改配置后 dfm reload 会先校验 Caddyfile 再重载服务。
  7. 需要拆除时用 ./uninstall.sh --component=... 按组件卸载。

## 文档索引

  安装流程与来源        docs/installation.md
  配置变量与行为        docs/configuration.md
  管理命令与站点流程    docs/commands.md
  路径说明与完整目录树  docs/paths.md
  卸载与数据保留        docs/uninstall.md
  手动升级              docs/upgrade.md
  手动备份配置与证书    docs/backup.md
  安装器备份文件        docs/installer-backups.md

文档使用纯文本排版，便于在编辑器中直接阅读和搜索。

## 安装器对系统的修改

  install.sh 以 root 运行，除安装软件包外还会改动下列系统状态。卸载时按
  docs/uninstall.md 处理；两类 APT 源文件若留有 .dfm.orig，会先还原原内容
  再删除备份。

  APT 源与密钥

  - /etc/apt/sources.list.d/mysql.list：写入 Oracle MySQL 源，组件按所选版本固定，签名密钥指向 /usr/share/keyrings/mysql-apt.gpg；已有非 Oracle 源会先备份为 mysql.list.dfm.orig 再覆盖。
  - /usr/share/keyrings/mysql-apt.gpg：下载 Oracle MySQL 2025 公钥，校验指纹 BCA43417C3B485DD128EC6D4B7B3B788A8D3785C 后 dearmor 写入。upgrade.sh mysql 每次升级前也会重新下载并校验后覆盖，以应对密钥到期；指纹不符则终止升级。
  - /etc/apt/sources.list.d/static-php<code>.list：写入 FrankenPHP 仓库的 php-zts 源；已有非 DFM 源备份为 .dfm.orig。切换 PHP 分支时删除旧分支与其他残留的 DFM 源及对应密钥。
  - /etc/apt/keyrings/static-php<code>.asc：写入 FrankenPHP 仓库签名密钥。
  - 多次运行 apt-get update；安装 ca-certificates、curl、gnupg，以及 frankenphp、php-zts-*（cli/curl/gd/intl/zip/pdo-mysql/mysqli/bcmath/fileinfo）与指定版本的 mysql-server。

  MySQL 数据目录与配置

  - /etc/mysql/mysql.conf.d/zz-dfm.cnf：写入 [mysqld] datadir=<MYSQL_DATA_DIR>。
  - MYSQL_DATA_DIR 不是默认 /var/lib/mysql 时：先停 mysql，把包初始化的数据复制过去，删除原 /var/lib/mysql 并建立指向新目录的软链；数据目录设为 mysql:mysql、0750。已有数据须手工输入 clear 确认后才会清空。
  - /etc/apparmor.d/local/usr.sbin.mysqld：为数据目录及其每一级父目录追加 r、x 与 ** rwk 规则，随后重载 AppArmor；仅在系统提供 mysqld 的 AppArmor 配置时执行。

  用户、组与目录权限

  - 创建系统组 www 与系统用户 www（home /home/wwwroot、shell /usr/sbin/nologin），并把 frankenphp 加入 www 组。
  - WEB_ROOT 与 DEFAULT_WEB_ROOT：缺失时创建，设为 www:www、0775；已存在则只提示，不改动。
  - /var/lib/frankenphp/caddy：设为 frankenphp:frankenphp、0750，存放 Caddy 自动证书。
  - /var/log/frankenphp：已存在时改属主为 frankenphp:frankenphp，缺失时按 frankenphp:frankenphp、0755 创建。

  systemd 与服务

  - /etc/systemd/system/frankenphp.service.d/10-dfm.conf：写入 [Service] ProtectHome=false。deb 单元默认 ProtectHome=true 会屏蔽 /home 下的网站根目录。
  - 执行 systemctl daemon-reload，enable 并启动 frankenphp 与 mysql；启动前先停 frankenphp 服务，再通过 Caddy admin API（FRANKENPHP_ADMIN_URL，默认 localhost:2019）探测并优雅停止可能遗留的实例，轮询次数与间隔由 FRANKENPHP_STOP_POLL_ATTEMPTS / FRANKENPHP_STOP_POLL_INTERVAL 控制，探测失败时明确报错，不按进程名杀进程。

  FrankenPHP 与 Caddy 配置

  - /etc/frankenphp 与 Caddyfile.d 目录按 0755 创建。
  - /etc/frankenphp/Caddyfile：仅首次安装按 conf/Caddyfile 生成并写入 ACME_EMAIL，同时创建标记 /etc/dfm/caddyfile.installed；之后重装一律保留。
  - /etc/frankenphp/logging.caddyfile：与主配置同时首次部署，之后重装保留；主配置 import 引入。
  - /etc/frankenphp/Caddyfile.d/default.caddyfile：缺失时按 conf/default-site.caddyfile 生成 HTTP 默认站点。
  - /etc/frankenphp/cache-static.caddyfile：缺失时按模板复制。
  - 主配置通过 import Caddyfile.d/*.caddyfile 加载站点块。

  DFM 自身文件

  - /etc/dfm.conf：由源码 dfm.conf 覆盖写入。
  - /etc/dfm/php-version、frankenphp-version：记录已装版本。
  - /etc/dfm/caddyfile.installed：主配置首次生成标记。
  - /usr/local/bin/dfm-common.sh 与 /usr/local/bin/dfm：安装命令实体（0755）；/usr/bin/dfm 为指向后者的软链。

  不安装 nginx、php-fpm 或 acme.sh，也不修改 /etc/php-zts/php.ini；TLS 由 Caddy 自动 HTTPS 处理。

