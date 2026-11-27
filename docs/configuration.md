# 配置文件与路径

安装前编辑当前目录的 dfm.conf；安装时会用它覆盖 /etc/dfm.conf：

    WEB_ROOT="/home/wwwroot"
    DEFAULT_WEB_ROOT="/home/wwwroot/default"
    FRANKENPHP_LOG_DIR="/var/log/frankenphp"
    MYSQL_DATA_DIR="/var/lib/mysql"
    PHP_VERSION=""
    MYSQL_VERSION=""
    ACME_EMAIL=""
    PHP_BRANCH_CANDIDATES="8.2 8.3 8.4 8.5"
    PHP_BRANCH_PROBE_TIMEOUT=20
    MYSQL_MIN_MAJOR_VERSION=8
    MIN_DEBIAN_MAJOR=13
    MYSQL_ARCHITECTURES="amd64"
    FRANKENPHP_ARCHITECTURES="amd64 arm64"
    MYSQL_GPG_KEY_URL="https://repo.mysql.com/RPM-GPG-KEY-mysql-2025"
    MYSQL_GPG_FINGERPRINT="BCA43417C3B485DD128EC6D4B7B3B788A8D3785C"
    FRANKENPHP_ADMIN_URL="http://localhost:2019"
    FRANKENPHP_STOP_POLL_ATTEMPTS=25
    FRANKENPHP_STOP_POLL_INTERVAL=0.2

重装同样以源码目录的 dfm.conf 为准，系统会用新配置覆盖 /etc/dfm.conf；
需要保留旧值时先备份 /etc/dfm.conf。

/etc/dfm.conf 的使用场景：

  - install.sh    只读取源码目录的 dfm.conf，不读取 /etc/dfm.conf；安装时把源码配置写到 /etc/dfm.conf。
  - dfm 管理命令  每次运行先读取 /etc/dfm.conf，缺失时回退脚本同目录的 dfm.conf（源码目录直接运行时即源码 dfm.conf）；用于 WEB_ROOT、FRANKENPHP_LOG_DIR、CADDY_DATA_DIR。
  - uninstall.sh  读取 /etc/dfm.conf，缺失时回退脚本同目录的 dfm.conf；用于 WEB_ROOT、MYSQL_DATA_DIR、FRANKENPHP_LOG_DIR，决定卸载提示与 AppArmor 规则清理。
  - upgrade.sh 读取 /etc/dfm.conf，缺失时回退脚本同目录的 dfm.conf；用于探测与平台参数。
  - sync-dfm.sh 不读取 /etc/dfm.conf。

MYSQL_DATA_DIR 只在安装阶段生效：仅当源码 dfm.conf 中该值不是 /var/lib/mysql、
且 /var/lib/mysql 与目标目录指向不同时，安装器才会迁移数据、建软链并写入
/etc/mysql/mysql.conf.d/zz-dfm.cnf。默认配置下安装器完全不碰 MySQL 自身配置。

/etc/dfm.conf 里的 MYSQL_DATA_DIR 只被卸载脚本用于提示和 AppArmor 规则清理，
重装时又会被源码 dfm.conf 覆盖。安装后直接修改 /etc/mysql/ 下 MySQL 配置的
做法不会被安装器覆盖或迁移，卸载脚本也不会删除这些手工配置；但卸载提示中的
数据目录仍取自 /etc/dfm.conf，可能与实际配置不一致，需要自行核对。

## 变量说明

  WEB_ROOT            新建站点的默认父目录。
  DEFAULT_WEB_ROOT    未匹配域名时默认站点的根目录。
  FRANKENPHP_LOG_DIR  访问日志、caddy.log 与 php-error.log 的输出目录。
  MYSQL_DATA_DIR      MySQL 数据目录，可用于独立磁盘；逻辑与 LNMP 版本一致。
  PHP_VERSION         留空则交互选择；填写时必须是 PHP_BRANCH_CANDIDATES 中的分支。
  MYSQL_VERSION       留空则交互选择；填写时必须是菜单中的确切版本字符串。
  ACME_EMAIL          可选，写进 Caddyfile 全局 email 指令，用于 ACME 通知。

  PHP_BRANCH_CANDIDATES  探测的 PHP 分支候选，空格分隔；最后一个可用分支为默认。
  PHP_BRANCH_PROBE_TIMEOUT  单个分支仓库探测的超时秒数。
  MYSQL_MIN_MAJOR_VERSION   仓库中接受的最低 MySQL 主版本号。
  MIN_DEBIAN_MAJOR      允许安装的最低 Debian 主版本号。
  MYSQL_ARCHITECTURES   MySQL 仓库支持的 CPU 架构，空格分隔。
  FRANKENPHP_ARCHITECTURES  FrankenPHP 仓库支持的 CPU 架构，空格分隔。
  MYSQL_GPG_KEY_URL     Oracle MySQL 仓库签名密钥的下载地址；安装与每次 mysql 升级都会重新下载。
  MYSQL_GPG_FINGERPRINT 预期的 MySQL 密钥指纹；不匹配即报错退出。Oracle 续期时不换指纹，只改有效期。
  FRANKENPHP_ADMIN_URL  Caddy admin 端点；单实例清理时用它探测与关闭遗留实例。
  FRANKENPHP_STOP_POLL_ATTEMPTS  关闭遗留实例后的轮询次数。
  FRANKENPHP_STOP_POLL_INTERVAL  每轮轮询的间隔秒数。

所有路径必须是绝对路径，且只包含字母、数字、点、下划线、斜杠和连字符，
不能包含 .. 段。ACME_EMAIL 必须是合法邮箱格式，否则安装器报错退出。

## 探测与平台参数

  install.sh、upgrade.sh 与 dfm 都从配置读取这些值，函数内部不再写死：
  PHP 分支候选与探测超时、MySQL 最低主版本、最低 Debian 版本、
  两个仓库的架构白名单、Oracle MySQL 签名密钥地址与指纹，
  以及 Caddy admin 端点与遗留实例清理的轮询参数。

  dfm-common.sh 保留同名默认值，配置缺失时脚本仍能运行。
  修改源码 dfm.conf 后需要重新安装才会写入 /etc/dfm.conf；
  upgrade.sh 优先读 /etc/dfm.conf，缺失时回退源码目录的 dfm.conf。

## 版本变量规则

  - PHP：分支来自 FrankenPHP deb 仓库。配置值不在菜单中时警告并回退，
    避免旧版本导致无法重装。安装器把分支记录在 /etc/dfm/php-version。
  - MySQL：版本来自 Oracle 仓库，涉及数据兼容性；配置值不在菜单中时报错退出。
  - FrankenPHP：不配置版本号，跟随所选分支仓库的 apt 候选版本；实际版本写入
    /etc/dfm/frankenphp-version，可用 apt upgrade frankenphp 升级。

## MySQL 数据目录迁移

  触发条件       首次安装前设置非默认 MYSQL_DATA_DIR。
  安装器动作     把包初始化的数据迁移到目标目录。
  默认目录       复制 /var/lib/mysql 的数据到目标目录后删除该目录，再建软链。
  卸载后重装     mysql-community-server 未安装且目标目录已有数据时，
                 提示输入 clear 全新安装或终止；自定义目录在装包成功后清空，
                 默认 /var/lib/mysql 在确认后立即清空；不做复用判断。
  已安装后更换   未安装 MySQL 包且目标目录已有数据时会提示，处理同上。

## Caddyfile 配置行为

  主配置         仅在首次安装时按 conf/Caddyfile 覆盖 /etc/frankenphp/Caddyfile，
                 并创建标记 /etc/dfm/caddyfile.installed。之后重装一律保留已有主配置，
                 不更新模板也不更新 ACME_EMAIL，你在文件里的修改不会被覆盖。
                 标记存在但主配置缺失时会重新生成。要恢复模板，
                 删除主配置和标记后再安装；只删标记、保留主配置则同样会按模板覆盖。
                 全局块包含 frankenphp、可选 email 与固定证书存储路径，
                 并附带注释掉的线程、并发、php_ini 与 worker 调优示例，按需取消注释即可。
  调优示例       conf/Caddyfile 的 frankenphp 块内注释了 num_threads、max_threads、
                 max_wait_time、max_idle_time、max_requests、php_ini 与 worker。
                 默认值：每 CPU 2 线程，max_idle_time 5s，其余未设置。
                 示例仅供参考，需按内存与业务调整后再启用。
  ACME 测试      模板 conf/Caddyfile 注释了 acme_ca 行，指向 Let's Encrypt staging：
                 https://letsencrypt.org/docs/staging-environment/
                 每次安装都会用该模板覆盖 /etc/frankenphp/Caddyfile，
                 需调整全局块时请改源码模板后重新安装。开发调试时取消注释 acme_ca 行；
                 staging 证书不被浏览器信任、
                 ACME 账户独立、限流宽松（同组域名每周 30000 张）。
                 正式签发前必须重新注释，否则拿到的是不受信任的证书。
  日志片段       主配置 import logging.caddyfile，来自 conf/logging.caddyfile；
                 与主配置同时首次部署，之后重装保留。仅 caddy.log / php-error.log
                 两个文件 logger，路径由 FRANKENPHP_LOG_DIR 渲染，不进 journald。
  journald        只剩 systemd 自身信息（启停、unit 失败、OOM、崩溃）。
  站点加载       主配置末尾 import Caddyfile.d/*.caddyfile。
                 默认站点是 default.caddyfile；dfm 新建站点按主域名命名，
                 手工配置可让多个域名共用一个文件或写多个站点块。
  站点识别       dfm vhost list / del 按文件名处理，不解析地址行：
                 list 列出 *.caddyfile（不含 default.caddyfile），del 删除 <域名>.caddyfile。
                 手工合并的多域名文件由用户自行维护，dfm 不做域名级拆分或重复检查。
  证书存储       storage file_system /var/lib/frankenphp/caddy。
                 备份服务器时需要包含该目录，否则恢复后证书要重新签发。
  自动 HTTPS     dfm vhost add 默认创建域名站点并自动签发、续期证书；
                 选择仅 HTTP（或 dfm vhost add-http）时地址加 http:// 前缀，
                 不签发证书，也不做 HTTP 到 HTTPS 跳转。
  站点方案标记   仅 HTTP 的站点配置写入 # Scheme: http，作为人工阅读的备注；
                 是否申请证书以地址行中该域名的 http:// 前缀为准。
                 要让域名申请证书，手工去掉该地址的前缀，再用 dfm vhost cert
                 触发 reload 并列出已签发证书。该命令不改写任何配置。
  默认站点       只有 default.caddyfile 不存在时才按 conf/default-site.caddyfile 渲染；
                 已有文件（含软链）重装时一律保留，DEFAULT_WEB_ROOT 的变化
                 不会应用到已有默认站点。默认模板只提供 HTTP。
  静态缓存       conf/cache-static.caddyfile 部署到 /etc/frankenphp/cache-static.caddyfile，
                 由每个站点自行 import；已有文件不覆盖。
  隐藏文件       站点块用 @dotfiles path_regexp 匹配并 respond 404。
  PATHINFO       php_server 默认 split_path .php，不需要单独的 FastCGI 片段。
  重定向         默认不生成；需要时编辑站点块或使用 Caddyfile 的 redir 指令。
  Worker 模式    向导使用经典模式。要启用 worker，在站点的 php_server 块中
                 添加 worker index.php，并确认应用能在内存中重复运行。

## PHP 配置

  php.ini            /etc/php-zts/php.ini（包提供生产预设）。
  扩展 ini           /etc/php-zts/conf.d/*.ini，由 php-zts-* 包安装。
  全局覆盖           可在 Caddyfile 的 frankenphp 块中用 php_ini 指令设置。

## 服务用户与权限

  - FrankenPHP 包以 frankenphp:frankenphp 运行 systemd 服务。
  - 安装器创建 www 用户/组，新建的网站目录属主为 www:www、权限 0775，
    并把 frankenphp 加入 www 组，使其可读取和写入网站文件；已有目录不改动属主。
  - 包自带单元设置 ProtectHome=true，会让 /home 下的站点目录不可访问；
    DFM 写入 /etc/systemd/system/frankenphp.service.d/10-dfm.conf 改为
    ProtectHome=false。

## 路径速查

  用户配置入口        /etc/dfm.conf
  内部状态            /etc/dfm/
  Caddy 主配置        /etc/frankenphp/Caddyfile
  日志片段            /etc/frankenphp/logging.caddyfile
  默认站点            /etc/frankenphp/Caddyfile.d/default.caddyfile
  站点配置            /etc/frankenphp/Caddyfile.d/*.caddyfile（dfm 新建时以主域名命名，可手工合并多域名）
  静态缓存片段        /etc/frankenphp/cache-static.caddyfile
  PHP 配置            /etc/php-zts/php.ini、/etc/php-zts/conf.d/
  Caddy 证书数据      /var/lib/frankenphp/caddy
  MySQL 配置          /etc/mysql/（自定义数据目录时写入 zz-dfm.cnf）
  MySQL 数据          /var/lib/mysql 或 MYSQL_DATA_DIR
  管理命令            /usr/local/bin/dfm（addons 已内置）

更完整的目录树见 paths.md。
