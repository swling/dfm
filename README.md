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
  rewrite/          常见程序的 Caddyfile 伪静态片段
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
