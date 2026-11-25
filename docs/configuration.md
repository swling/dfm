# 配置文件与路径

安装前编辑当前目录的 dfm.conf，或安装后编辑 /etc/dfm.conf：

    WEB_ROOT="/home/wwwroot"
    DEFAULT_WEB_ROOT="/home/wwwroot/default"
    FRANKENPHP_LOG_DIR="/var/log/frankenphp"
    MYSQL_DATA_DIR="/var/lib/mysql"
    PHP_VERSION=""
    MYSQL_VERSION=""
    ACME_EMAIL=""

变量说明

  WEB_ROOT            新建站点的默认父目录。
  DEFAULT_WEB_ROOT    未匹配域名时默认站点的根目录。
  FRANKENPHP_LOG_DIR  按站点开启访问日志时的输出目录。
  MYSQL_DATA_DIR      MySQL 数据目录，可用于独立磁盘；逻辑与 LNMP 版本一致。
  PHP_VERSION         留空则交互选择；可填 8.2 / 8.3 / 8.4 / 8.5。
  MYSQL_VERSION       留空则交互选择；填写时必须是菜单中的确切版本字符串。
  ACME_EMAIL          可选，写进 Caddyfile 全局 email 指令，用于 ACME 通知。

所有路径必须是绝对路径，且只包含字母、数字、点、下划线、斜杠和连字符，
不能包含 .. 段。ACME_EMAIL 必须是合法邮箱格式，否则安装器报错退出。

版本变量规则

  PHP       分支来自 FrankenPHP deb 仓库。配置值不在菜单中时警告并回退，
            避免旧版本导致无法重装。安装器把分支记录在 /etc/dfm/php-version。
  MySQL     版本来自 Oracle 仓库，涉及数据兼容性：配置值不在菜单中时报错退出。
  FrankenPHP  不配置版本号，跟随所选分支仓库的 apt 候选版本；实际版本写入
            /etc/dfm/frankenphp-version，可用 apt upgrade frankenphp 升级。

MySQL 数据目录迁移

  触发条件       首次安装前设置非默认 MYSQL_DATA_DIR。
  安装器动作     把包初始化的数据迁移到目标目录。
  默认目录       复制 /var/lib/mysql 的数据到目标目录后删除该目录，再建软链。
  卸载后重装     mysql-community-server 未安装且目标目录已有数据时，
                 提示输入 clear 全新安装或终止；自定义目录在装包成功后清空，
                 默认 /var/lib/mysql 在确认后立即清空；不做复用判断。
  已安装后更换   未安装 MySQL 包且目标目录已有数据时会提示，处理同上。

Caddyfile 配置行为

  主配置         由 conf/Caddyfile 渲染到 /etc/frankenphp/Caddyfile。
                 原包自带文件首次安装时备份为 /etc/frankenphp/Caddyfile.dfm.orig。
                 全局块包含 frankenphp、可选 email 与固定证书存储路径。
  站点加载       主配置末尾 import Caddyfile.d/*.caddyfile。
                 默认站点是 default.caddyfile，其他站点按域名命名。
  证书存储       storage file_system /var/lib/frankenphp/caddy。
                 备份服务器时需要包含该目录，否则恢复后证书要重新签发。
  自动 HTTPS     域名站点自动签发和续期证书；http:// 站点不签发证书。
  默认站点       从 conf/default-site.caddyfile 渲染，按 DEFAULT_WEB_ROOT 设置根目录，
                 只提供 HTTP，安装时直接覆盖 default.caddyfile。
  静态缓存       conf/cache-static.caddyfile 部署到 /etc/frankenphp/cache-static.caddyfile，
                 由每个站点自行 import；已有文件不覆盖。
  隐藏文件       站点块用 @dotfiles path_regexp 匹配并 respond 404。
  PATHINFO       php_server 默认 split_path .php，不需要单独的 FastCGI 片段。
  重定向         默认不生成；需要时编辑站点块或使用 Caddyfile 的 redir 指令。
  Worker 模式    向导使用经典模式。要启用 worker，在站点的 php_server 块中
                 添加 worker index.php，并确认应用能在内存中重复运行。

PHP 配置

  php.ini            /etc/php-zts/php.ini（包提供生产预设）。
  扩展 ini           /etc/php-zts/conf.d/*.ini，由 php-zts-* 包安装。
  全局覆盖           可在 Caddyfile 的 frankenphp 块中用 php_ini 指令设置。

服务用户与权限

  - FrankenPHP 包以 frankenphp:frankenphp 运行 systemd 服务。
  - 安装器创建 www 用户/组，新建的网站目录属主为 www:www、权限 0775，
    并把 frankenphp 加入 www 组，使其可读取和写入网站文件；已有目录不改动属主。
  - 包自带单元设置 ProtectHome=true；DFM 写入
    /etc/systemd/system/frankenphp.service.d/10-dfm.conf 改为 ProtectHome=false，
    并通过 ReadWritePaths 允许写入 WEB_ROOT。

路径速查

  用户配置入口        /etc/dfm.conf
  内部状态            /etc/dfm/
  Caddy 主配置        /etc/frankenphp/Caddyfile
  默认站点            /etc/frankenphp/Caddyfile.d/default.caddyfile
  站点配置            /etc/frankenphp/Caddyfile.d/<域名>.caddyfile
  静态缓存片段        /etc/frankenphp/cache-static.caddyfile
  伪静态片段          /etc/frankenphp/rewrite/<名称>.caddyfile
  PHP 配置            /etc/php-zts/php.ini、/etc/php-zts/conf.d/
  Caddy 证书数据      /var/lib/frankenphp/caddy
  MySQL 配置          /etc/mysql/（自定义数据目录时写入 zz-lnmp-debian.cnf）
  MySQL 数据          /var/lib/mysql 或 MYSQL_DATA_DIR
  管理命令            /usr/local/bin/dfm、/usr/local/bin/addons.sh

更完整的目录树见 paths.md。
