# 管理命令

安装后使用 dfm（/usr/local/bin/dfm，/usr/bin/dfm 为软链）：

    dfm {start|stop|restart|reload|kill|status}
    dfm {frankenphp|mysql|mariadb} {start|stop|restart|reload|kill|status}
    dfm vhost {add|add-http|list|del|cert <domain>}
    dfm vhost {add-ssl|enable-https} <domain>
    dfm addons {install|uninstall} <addon>

DFM 没有手工签发证书的 ssl / dnsssl / onlyssl 命令：证书由 Caddy 自动管理。
把已有 HTTP 站点切到 HTTPS 用 add-ssl（别名 enable-https）。
mariadb 作为 mysql 的别名保留，便于沿用旧命令习惯。

## 服务操作

  - start / stop / restart / reload 作用于 frankenphp 与 mysql 两个服务。
  - 启动或重启 frankenphp 前，会先停止 systemd 单元并结束残留的 frankenphp 进程，避免旧实例占用 80/443 端口；一台机器只保留一个 frankenphp 实例。
  - kill 映射为 systemd 正常停止，不发送强制终止信号。
  - status 只显示两项服务的 active / inactive 状态。
  - 单项命令只对指定服务操作；reload frankenphp 前会先校验 Caddyfile。
  - 所有服务操作前执行 systemctl daemon-reload，避免单元文件升级后的警告。

## 创建站点

    dfm vhost add

`dfm vhost add` 默认启用 HTTPS；回答 HTTPS 询问为 n 即创建仅 HTTP 的站点。
也可直接用 `dfm vhost add-http` 进入 HTTP 模式，跳过该询问，其余步骤相同。
后期要补证书时不用重建站点，用 `dfm vhost add-ssl <域名>` 切换即可。

依次询问：

  1. 主域名（通配符域名需自行配置 DNS 挑战，向导不接受）。
  2. 附加域名，多个名称用空格分隔，写入同一个站点地址行。
  3. 网站根目录，默认 WEB_ROOT/<域名>；不存在时创建并设为 www:www、0775。
  4. 是否启用伪静态，以及使用哪个 rewrite 片段。
  5. 是否启用 HTTPS 并自动申请证书？[Y/n]：回车或 Y 为 HTTPS，n 为仅 HTTP。
  6. 是否开启访问日志；开启时写入 /var/log/frankenphp/<域名>.log。

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

选择仅 HTTP 时，站点地址会加上 http:// 前缀，Caddy 不再为该站点申请证书，
也不会做 HTTP 到 HTTPS 跳转；配置第二行记录 # Scheme: http：

    # Managed by DFM. Site: example.com
    # Scheme: http
    http://example.com, http://www.example.com {
        root * /home/wwwroot/example.com
        ...
    }

写入后会执行 frankenphp validate；验证失败时删除新文件并报错。
reload 前记录时间点，随后轮询证书存储：默认每 2 秒检查一次，最多 60 秒，
证书一出现就立即结束，只输出路径与有效期；超时只报“等待期内未签发”，不判定签发失败。
未签发时才摘出这段时间内 journalctl -u frankenphp 的 TLS/ACME 相关日志
（含域名、acme、certificate、tls、challenge 等关键词），并给出查看完整日志的命令。
站点文件直接放在 Caddyfile.d/ 下，不使用 sites-available/sites-enabled。

## 后期把 HTTP 站点切到 HTTPS

    dfm vhost add-ssl <域名>
    dfm vhost enable-https <域名>

用于“先建 HTTP、之后再补 SSL”的场景。命令只改站点地址行：去掉每个地址的
http:// 前缀，并把 # Scheme: http 改成 # Scheme: https；网站目录、伪静态、
访问日志与附加域名都保持不变。之后 `dfm vhost cert <域名>` 就能正常等待证书。

改动前保留原文件副本，先 frankenphp validate 再 reload；校验失败会还原配置。
切换成功后按常规流程轮询证书状态，超时只表示等待期内未签发，Caddy 仍会后台重试。
已经是 HTTPS 的站点会直接提示，不做改动。

## 查看证书状态

    dfm vhost cert <域名>

同样采用轮询：证书存在时显示 issued、文件路径与有效期，并立即返回，不输出日志；
等待期内未出现证书则显示 pending，并注明已等待秒数，Caddy 仍可能在后台重试，
此时才摘出最近 1 小时内该域名的 TLS/ACME 日志，并给出查看完整日志的命令。
等待可用 Ctrl+C 中止。
若站点是仅 HTTP 模式，该命令直接提示不申请证书，不进入等待。

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
  - 添加站点时选择仅 HTTP，站点地址写成 http://<域名>，Caddy 不申请证书，
    也不跳转 HTTPS；适合内网域名、证书尚未就绪或暂时只用 80 端口的场景。
  - 首次签发需要域名解析到本机且 80/443 端口可访问。
  - 证书与密钥存放在 /var/lib/frankenphp/caddy，不放在 /etc/frankenphp/ssl。
  - 查看证书相关数据请直接查看该目录；不要手工编辑 Caddy 的证书存储。
  - 需要自定义 CA、DNS 挑战或 ACME 账号时，编辑 /etc/frankenphp/Caddyfile 的全局块。

## 同步脚本

  sudo ./sync-dfm.sh

  修改当前目录的 dfm 后，用同步脚本更新系统中的命令。
  默认同步本目录的 dfm 与 dfm-common.sh 到 /usr/local/bin/；同步前会检查 Bash 语法，
  并确认 /usr/bin/dfm 仍是指向 /usr/local/bin/dfm 的软链。
  也可重新运行 install.sh，安装器会备份被覆盖的命令为 *.dfm.orig。
  addons.sh 不安装到系统路径，无需同步。

## 常用检查

    dfm status
    /usr/bin/frankenphp validate --config /etc/frankenphp/Caddyfile
    journalctl -u frankenphp -n 100 --no-pager
    ls /var/lib/frankenphp/caddy
