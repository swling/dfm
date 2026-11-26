# 安装

以 root 身份执行：

    cd lnmp-debian/dfm
    ./install.sh

安装器只接受无参数运行；--help 用于查看说明。

## 前置条件

  - Debian 13 或更高版本，root 权限，可用的 APT 网络。
  - 计划使用 HTTPS 的域名已解析到本机，80 与 443（含 UDP/443）端口可达。
  - 先备份数据库和网站数据。
  - 安装 MySQL 时软件包可能要求在终端完成配置，建议使用交互终端。

## 组件来源

  FrankenPHP   FrankenPHP 官方文档列出的 deb 仓库：
               https://pkg.henderkes.com/api/packages/<代码>/debian
               仓库套件为 php-zts，组件为 main，使用仓库自带的签名密钥。
               代码 82/83/84/85 分别对应 PHP 8.2/8.3/8.4/8.5，
               同一时刻只启用一个分支的仓库。

  MySQL        Oracle MySQL 官方 APT 仓库 https://repo.mysql.com/apt/debian。
               从 Release 文件动态发现 Server 组件，不做版本写死。

  PHP 扩展     php-zts-* 包来自当前启用的 FrankenPHP 仓库；
               memcached / redis-server 等服务包来自 Debian APT。

  HTTPS        Caddy 内置的自动 HTTPS，不安装 acme.sh，也不创建续期定时器。

  Debian       ca-certificates、curl、gnupg 等基础依赖来自 Debian APT。

组件来源中没有 sury、nginx.org，也没有 acme.sh。Oracle MySQL 的 Debian 13
仓库目前只提供 amd64 构建；FrankenPHP 仓库提供 amd64 与 arm64 构建。

## 版本选择流程

  1. 安装器探测 8.2 至 8.5 中哪些分支的仓库可访问，列出菜单。
  2. dfm.conf 中的 PHP_VERSION 作为菜单默认值；值不可用时警告并回退到最新可用分支。
  3. MySQL 列出仓库中全部 8.x 版本并标注 LTS / 创新版，默认选版本最高的 LTS。
  4. MYSQL_VERSION 若已设置，必须是菜单中的确切值，否则报错退出。
  5. 无交互终端时按各自默认值安装。
  6. 确认后先把 MySQL 源收敛到所选版本对应的单个组件，再写入 FrankenPHP 源。

  FrankenPHP 不按 apt 版本号做菜单：仓库按 PHP 分支隔离，apt 安装该仓库的
  当前候选版本。安装后实际版本记录在 /etc/dfm/frankenphp-version。

## 安装过程依次完成

  1. 校验平台与已有数据，必要时确认清空 MYSQL_DATA_DIR。
  2. 安装基础依赖，写入 Oracle MySQL 源并发现组件。
  3. 选择 PHP 分支与 MySQL 版本，确认后写入两个最终 APT 源。
  4. 安装 frankenphp、php-zts 基础扩展与指定版本的 mysql-server。
  5. 迁移 MySQL 数据目录（若使用自定义目录），处理 AppArmor 规则与软链。
  6. 创建 www 用户/组，并把 frankenphp 服务用户加入 www 组。
  7. 创建 /etc/frankenphp 布局，渲染 Caddyfile 与默认站点，部署伪静态片段。
  8. 写入 systemd 覆盖配置，安装 dfm 命令与共享函数库（addons 已内置）。
  9. 校验 Caddyfile，启动并重启 frankenphp，检查 frankenphp 与 mysql 状态。

## 安装后检查

  dfm status
  systemctl status frankenphp --no-pager
  /usr/bin/frankenphp validate --config /etc/frankenphp/Caddyfile
  curl -I http://127.0.0.1/

  新站点的证书在浏览器首次访问 https 域名时由 Caddy 自动签发；
  可用 journalctl -u frankenphp 查看 ACME 过程。

  upgrade.sh 与 sync-dfm.sh 都依赖本目录；
  请保留源码目录，不要在安装后删除。

## 与 LNMP 版本的行为差异

  - 站点文件写在 /etc/frankenphp/Caddyfile.d/，dfm 新建时按主域名命名，可手工把多个域名写进同一文件；list / del 按文件名管理，cert 只做全局 reload 并列出证书，不使用 sites-enabled。
  - 重装时 /etc/frankenphp/Caddyfile 一律保留，只有文件不存在时才按 conf/Caddyfile 生成。
  - 重装时 default.caddyfile 一律保留，只有文件不存在时才按 conf/default-site.caddyfile 生成。
  - 默认站点只监听 HTTP；域名站点默认启用 HTTPS 与 HTTP 到 HTTPS 跳转，
    添加站点时选择仅 HTTP 或运行 dfm vhost add-http 时只监听 80 端口。
  - 伪静态片段是 Caddyfile 语法，php_server 已内置 try_files 与 PATH_INFO 处理。
  - 不需要为证书开放单独的 .well-known 目录，Caddy 自己处理 ACME 校验请求。
  - 隐藏文件访问由站点块中的 @dotfiles 匹配器返回 404。
  - access log 默认不生成；在 dfm vhost add 中选择开启后写入 /var/log/frankenphp/。
  - 切换 PHP 分支需重新运行 install.sh：旧仓库会被移除，安装后重启服务。
