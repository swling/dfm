# 管理命令

安装后使用 dfm（/usr/local/bin/dfm，/usr/bin/dfm 为软链）：

    dfm {start|stop|restart|reload|kill|status}
    dfm {frankenphp|fp|mysql|db|mariadb} {start|stop|restart|reload|kill|status}
    dfm vhost {add|add-http|list|del [domain]|cert}
    dfm addons {install|uninstall} <addon>

证书由 Caddy 自动管理；`dfm vhost cert` 只 reload 并列出已签发证书，不改写站点配置。
fp 是 frankenphp 的别名，db 是 mysql 的别名；mariadb 也作为 mysql 的别名保留。

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
后期要为已有域名申请证书时不用重建站点：手工去掉该地址的 http:// 前缀，再用 `dfm vhost cert` 触发。

依次询问：

  1. 主域名（通配符域名需自行配置 DNS 挑战，向导不接受）。
  2. 附加域名，多个名称用空格分隔，写入同一个站点地址行。
  3. 网站根目录，默认 WEB_ROOT/<域名>；不存在时创建并设为 www:www、0775。
  4. 是否启用 HTTPS 并自动申请证书？[Y/n]：回车或 Y 为 HTTPS，n 为仅 HTTP。
  5. 是否开启访问日志；开启时写入 /var/log/frankenphp/<域名>.log。

生成的站点配置类似：

    # Managed by DFM. Site: example.com
    example.com, www.example.com {
        root /home/wwwroot/example.com
        encode zstd br gzip

        import /etc/frankenphp/cache-static.caddyfile

        @dotfiles path_regexp (^|/)\.
        handle @dotfiles {
            respond 404
        }

        handle {
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
        root /home/wwwroot/example.com
        ...
    }

写入后会执行 frankenphp validate；验证失败时删除新文件并报错。
reload 前记录时间点，随后轮询证书存储：默认每 2 秒检查一次，最多 60 秒，
证书一出现就立即结束，只输出路径与有效期；超时只报“等待期内未签发”，不判定签发失败。
未签发时才摘出这段时间内 journalctl -u frankenphp 中与 TLS/ACME 相关的行
（acme、certificate、tls、challenge、letsencrypt、http-01、dns-01 等关键词），
不按域名过滤，并给出查看完整日志的命令。
站点文件直接放在 Caddyfile.d/ 下，不使用 sites-available/sites-enabled。

## 多域名共用一个站点文件

  - dfm 按 <域名>.caddyfile 管理站点：list 列出文件名，del 按域名删除整个文件，add 只检查同名文件是否存在。
  - 一个文件也可以写多个站点块；多个域名指向同一网站目录时，手工把它们写进同一地址行或同一文件。
  - dfm 不解析地址行，不按域名拆分或删除配置；手工合并后的文件由你自行维护。
  - default.caddyfile 不参与 list / del；重装 install.sh 时一律保留，不会恢复成纯 catch-all 模板，DEFAULT_WEB_ROOT 变化也不会写回。
  - 要让其中某个域名申请证书，手工改该域名的地址前缀；dfm 不会改动同一地址行的其他域名。

例如把两个域名写进同一个站点块，共用同一套 root 与 php_server：

    # Managed by DFM. Site: ceshi.fenbu.net
    # Scheme: http
    http://ceshi.fenbu.net, http://sim.yisuan.net {
        root /home/wwwroot/wordpress
        encode zstd br gzip
        import /etc/frankenphp/cache-static.caddyfile
        php_server
    }

带 http:// 的地址不申请证书；要让某个域名走 HTTPS，手工去掉它的前缀即可，
dfm 不会替你改写配置，也不会动同一地址行的其他域名。

## 触发证书签发

    dfm vhost cert

这是 DFM 唯一的证书触发动作：先校验 Caddyfile 并 reload FrankenPHP，
让 Caddy 按当前配置尝试签发，然后列出证书目录里的全部证书（域名、路径、有效期）。
命令不接受域名参数：签发对象完全由 Caddyfile 的地址行决定，dfm 不做域名筛选，
也不修改任何站点配置。

证书由 Caddy 后台异步签发，reload 后立即列出的是当时已存在的证书；
刚触发的签发可能还没完成，需稍后再执行本命令查看，或直接查看证书目录。
签发失败时查看 journalctl -u frankenphp 中的 ACME/TLS 日志。

开发调试时直接编辑 /etc/frankenphp/Caddyfile 的全局块启用 staging CA
（见 docs/configuration.md）。重装不会覆盖已有主配置，所以改动会保留；
想恢复模板时删除主配置与标记后重装。
这样可避开生产 CA 每周 5 张证书的限制。

## 列出与删除站点

    dfm vhost list
    dfm vhost del
    dfm vhost del <域名>

list 列出 Caddyfile.d/ 下的站点文件名，不含 default.caddyfile。
del 可直接带域名，也可交互输入；按 <域名>.caddyfile 删除整个配置文件。
删除时先把文件移到临时副本，先 validate 再 reload，校验失败会还原。
网站文件、证书和日志均不删除。

## 自定义路由规则

  php_server 已内置 try_files 与 PATH_INFO 处理：请求的文件存在时直接输出，
  不存在时回退到 index.php，并把剩余路径作为 PATH_INFO 传入。
  WordPress、Joomla、Laravel、Drupal 等前控制器式应用不需要额外规则。

需要 matcher、redir、respond 等自定义指令时，直接编辑
Caddyfile.d/<域名>.caddyfile，在 handle 块内的 php_server 前后添加，
改完用 dfm reload 生效。

## 扩展管理

    dfm addons install redis
    dfm addons uninstall redis
    dfm addons            # 进入菜单

扩展管理已内置于 dfm，不安装独立的全局命令。也可以在本目录直接运行
./dfm addons，用法相同。

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
通过 dfm addons 安装的独立服务包不在 dfm uninstall 的清理范围内。

## HTTPS 与证书

  - 站点地址使用域名时，Caddy 自动申请和续期证书，不需要任何 dfm ssl 命令。
  - 添加站点时选择仅 HTTP，站点地址写成 http://<域名>，Caddy 不申请证书，
    也不跳转 HTTPS；适合内网域名、证书尚未就绪或暂时只用 80 端口的场景。
  - 首次签发需要域名解析到本机且 80/443 端口可访问。
  - 同一个 HTTPS 站点块中的多个域名由 Caddy 各自申请证书；dfm vhost cert 只做全局 reload 并列出证书，不读取站点文件。
  - 证书与密钥存放在 /var/lib/frankenphp/caddy，不放在 /etc/frankenphp/ssl。
  - 查看证书相关数据请直接查看该目录；不要手工编辑 Caddy 的证书存储。
  - 需要自定义 CA、DNS 挑战或 ACME 账号时，编辑 /etc/frankenphp/Caddyfile 的全局块。

## 同步脚本

  sudo ./sync-dfm.sh

  修改当前目录的 dfm 后，用同步脚本更新系统中的命令。
  默认同步本目录的 dfm 与 dfm-common.sh 到 /usr/local/bin/；同步前会检查 Bash 语法，
  并确认 /usr/bin/dfm 仍是指向 /usr/local/bin/dfm 的软链。
  也可重新运行 install.sh 直接覆盖命令文件，不会生成 *.dfm.orig 备份。
  扩展管理已内置于 dfm，随 dfm 同步，无需单独处理。

## 常用检查

    dfm status
    /usr/bin/frankenphp validate --config /etc/frankenphp/Caddyfile
    journalctl -u frankenphp -n 100 --no-pager
    ls /var/lib/frankenphp/caddy
