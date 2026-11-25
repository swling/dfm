# 管理命令

安装后使用 dfm（/usr/local/bin/dfm，/usr/bin/dfm 为软链）：

    dfm {start|stop|restart|reload|kill|status}
    dfm {frankenphp|mysql|mariadb} {start|stop|restart|reload|kill|status}
    dfm vhost {add|list|del}
    dfm addons {install|uninstall} <addon>

DFM 没有 ssl / dnsssl / onlyssl 命令：证书由 Caddy 自动管理。
mariadb 作为 mysql 的别名保留，便于沿用旧命令习惯。

## 服务操作

  - start / stop / restart / reload 作用于 frankenphp 与 mysql 两个服务。
  - kill 映射为 systemd 正常停止，不发送强制终止信号。
  - status 只显示两项服务的 active / inactive 状态。
  - 单项命令只对指定服务操作；reload frankenphp 前会先校验 Caddyfile。
  - 所有服务操作前执行 systemctl daemon-reload，避免单元文件升级后的警告。

## 创建站点

    dfm vhost add

依次询问：

  1. 主域名（通配符域名需自行配置 DNS 挑战，向导不接受）。
  2. 附加域名，多个名称用空格分隔，写入同一个站点地址行。
  3. 网站根目录，默认 WEB_ROOT/<域名>；不存在时创建并设为 www:www、0775。
  4. 是否启用伪静态，以及使用哪个 rewrite 片段。
  5. 是否开启访问日志；开启时写入 /var/log/frankenphp/<域名>.log。

生成的站点配置类似：

    # Managed by DFM. Site: example.com
    example.com, www.example.com {
        root * /home/wwwroot/example.com
        encode zstd br gzip

        import /etc/frankenphp/cache-static.caddyfile

        @dotfiles path_regexp dotfiles (^|/)\.
        handle @dotfiles {
            respond 404
        }

        handle {
            import /etc/frankenphp/rewrite/wordpress.caddyfile
            php_server
        }

        log {
            output file /var/log/frankenphp/example.com.log
        }
    }

写入后会执行 frankenphp validate；验证失败时删除新文件并报错。
站点文件直接放在 Caddyfile.d/ 下，不使用 sites-available/sites-enabled。

## 列出与删除站点

    dfm vhost list
    dfm vhost del

删除时先移走配置并校验，校验失败会还原文件。网站文件、证书和日志均不删除。

## 伪静态片段

  none       空规则；php_server 仍会提供静态文件与 index.php 回退。
  other      自定义占位文件，可自行填写 Caddyfile 指令。
  wordpress  front-controller 回退由 php_server 提供，片段保留 /wp-admin 尾斜杠重定向。
  laravel    php_server 的 try_files + PATH_INFO 已等价于常见入口回退。
  joomla     同上，无需额外规则。
  drupal     PATH_INFO 适配现代 Drupal；Drupal 7 的 ?q= 需自行补充。

片段由站点块在 php_server 之前 import，可使用 matcher 与 redir 等指令。
修改片段后需要 dfm reload 才会生效。

## 扩展管理

    dfm addons install redis
    dfm addons uninstall redis
    dfm addons            # 进入菜单

扩展管理已内置于 dfm，不安装独立的全局命令。也可以在本目录直接运行
./addons.sh，用法相同。

## 可用名称与来源

  memcached    php-zts-memcached + Debian memcached 服务
  opcache      PHP 二进制内置；仓库若提供 php-zts-opcache 则安装该包
  redis        php-zts-redis + Debian redis-server 服务
  apcu         php-zts-apcu
  imagemagick  php-zts-imagick
  exif         二进制内置，无需安装
  fileinfo     php-zts-fileinfo（若已内置则不安装）
  ldap         php-zts-ldap
  bz2          php-zts-bz2
  sodium       二进制与其内置库提供，无需安装
  imap         仓库不提供，需用 PIE 自行构建
  swoole       php-zts-swoole（若仓库提供）

安装或卸载扩展后会重启 frankenphp 服务；memcached 与 redis-server 会设为开机启动。
通过 addons.sh 安装的独立服务包不在 dfm uninstall 的清理范围内。

## HTTPS 与证书

  - 站点地址使用域名时，Caddy 自动申请和续期证书，不需要任何 dfm ssl 命令。
  - 首次签发需要域名解析到本机且 80/443 端口可访问。
  - 证书与密钥存放在 /var/lib/frankenphp/caddy，不放在 /etc/frankenphp/ssl。
  - 查看证书相关数据请直接查看该目录；不要手工编辑 Caddy 的证书存储。
  - 需要自定义 CA、DNS 挑战或 ACME 账号时，编辑 /etc/frankenphp/Caddyfile 的全局块。

## 同步脚本

  sudo ./sync-dfm.sh

  修改当前目录的 dfm 后，用同步脚本更新系统中的命令。
  默认只同步本目录的 dfm 到 /usr/local/bin/；同步前会检查 Bash 语法，
  并确认 /usr/bin/dfm 仍是指向 /usr/local/bin/dfm 的软链。
  也可重新运行 install.sh，安装器会备份被覆盖的命令为 *.dfm.orig。
  addons.sh 不安装到系统路径，无需同步。

## 常用检查

    dfm status
    /usr/bin/frankenphp validate --config /etc/frankenphp/Caddyfile
    journalctl -u frankenphp -n 100 --no-pager
    ls /var/lib/frankenphp/caddy
