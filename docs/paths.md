# DFM 目录结构速查

标注说明

  [DFM]      由本项目 install.sh / dfm / uninstall.sh 创建或修改。
  [包]       由软件包提供：FrankenPHP 与 php-zts 来自其 deb 仓库，
              MySQL 来自 Oracle 官方仓库；另有修改时同时带 [DFM]。
  [运行时]   服务启动后生成，重启可重建。
  [自定义]   默认不存在或由管理员决定，文中仅示例。
  [Caddy]    Caddy 自动 HTTPS 生成与维护的数据。

文中 PHP 8.5 仅为示例，实际分支由安装时选择的仓库决定。
网站根目录、日志目录与 MySQL 数据目录可由 /etc/dfm.conf 覆盖。

关键路径速查

  用户配置入口        /etc/dfm.conf                              [DFM]
  内部状态            /etc/dfm/                                  [DFM]
  Caddy 主配置        /etc/frankenphp/Caddyfile                  [包] [DFM]
  默认站点            /etc/frankenphp/Caddyfile.d/default.caddyfile  [DFM]
  站点配置            /etc/frankenphp/Caddyfile.d/<域名>.caddyfile  [DFM]
  静态缓存片段        /etc/frankenphp/cache-static.caddyfile     [DFM]
  伪静态片段          /etc/frankenphp/rewrite/<名称>.caddyfile    [DFM]
  PHP 配置            /etc/php-zts/php.ini                       [包]
  PHP 扩展 ini        /etc/php-zts/conf.d/*.ini                  [包]
  Caddy 证书数据      /var/lib/frankenphp/caddy                  [Caddy]
  服务覆盖配置        /etc/systemd/system/frankenphp.service.d/10-dfm.conf  [DFM]
  MySQL 配置          /etc/mysql/                                [包] [DFM]
  MySQL 数据          /var/lib/mysql 或 MYSQL_DATA_DIR           [包] [DFM]
  管理命令            /usr/local/bin/dfm、/usr/local/bin/addons.sh  [DFM]
  网站根目录          /home/wwwroot/                             [自定义]

完整目录树

/
│
├── etc/                                  # 系统配置文件
│   │
│   ├── frankenphp/                       # FrankenPHP 与 Caddy 配置目录
│   │   ├── Caddyfile                     # [包] [DFM] 主配置（首次安装备份为 .dfm.orig）
│   │   ├── Caddyfile.d/                  # [DFM] 站点目录，由主配置 import
│   │   │   ├── default.caddyfile         # [DFM] HTTP 默认站点
│   │   │   ├── example.com.caddyfile     # [DFM] 域名站点（自动 HTTPS）
│   │   │   └── <domain>.caddyfile        # [DFM] 其他站点
│   │   │
│   │   ├── cache-static.caddyfile        # [DFM] 静态资源缓存头片段
│   │   │
│   │   └── rewrite/                      # [DFM] 伪静态片段
│   │       ├── none.caddyfile            # 空规则
│   │       ├── other.caddyfile           # 自定义占位
│   │       ├── wordpress.caddyfile       # WordPress
│   │       ├── laravel.caddyfile         # Laravel
│   │       ├── joomla.caddyfile          # Joomla
│   │       ├── drupal.caddyfile          # Drupal
│   │       └── <name>.caddyfile          # 自定义规则
│   │
│   ├── php-zts/                          # [包] FrankenPHP 使用的 ZTS PHP
│   │   ├── php.ini                       # 生产预设
│   │   └── conf.d/                       # php-zts-* 扩展 ini
│   │       ├── 30-redis.ini              # 示例：扩展包生成
│   │       └── <ext>.ini                 # 其他扩展
│   │
│   ├── mysql/                            # MySQL 配置目录
│   │   ├── my.cnf                        # 主配置入口
│   │   ├── conf.d/                       # [自定义] 通用配置片段
│   │   │
│   │   └── mysql.conf.d/                 # MySQL 服务端配置
│   │       ├── mysqld.cnf                # [包]
│   │       ├── custom.cnf                # [自定义]
│   │       └── zz-lnmp-debian.cnf        # [DFM] 仅自定义数据目录时写入
│   │
│   ├── apt/                              # APT 源与密钥
│   │   ├── sources.list.d/
│   │   │   ├── mysql.list                # [DFM] Oracle MySQL 官方源
│   │   │   └── static-php85.list         # [DFM] FrankenPHP 源（85 为 PHP 8.5 示例）
│   │   │
│   │   └── keyrings/
│   │       └── static-php85.asc          # [DFM] FrankenPHP 仓库签名密钥
│   │
│   ├── systemd/
│   │   └── system/
│   │       └── frankenphp.service.d/
│   │           └── 10-dfm.conf           # [DFM] ProtectHome / ReadWritePaths
│   │
│   ├── lnmp-debian.conf                  # 仅旧 LNMP 安装残留；DFM 不读取
│   ├── dfm.conf                          # [DFM] 用户配置入口
│   │
│   ├── dfm/                              # [DFM] 内部状态目录
│   │   ├── php-version                   # 安装时选择的 PHP 分支
│   │   └── frankenphp-version            # 已安装 FrankenPHP 的 apt 版本
│   │
│   └── logrotate.d/                      # 软件包自带日志轮转
│       └── mysql                         # MySQL 日志轮转（如有）
│
│
├── usr/                                  # 系统软件及程序文件
│   │
│   ├── bin/
│   │   ├── frankenphp                    # [包] 服务与 CLI 主程序
│   │   ├── php                           # [包] php-zts-cli 提供的命令行 PHP
│   │   ├── mysql                         # [包] MySQL 客户端
│   │   └── dfm                           # [DFM] 指向 /usr/local/bin/dfm 的软链
│   │
│   ├── lib/
│   │   └── php-zts/
│   │       └── modules/                  # [包] php-zts-* 扩展模块
│   │           └── redis-zts-85.so       # 示例扩展
│   │
│   └── local/
│       └── bin/                          # [DFM] 管理脚本
│           ├── dfm                       # 服务、站点与扩展入口
│           └── addons.sh                 # 扩展管理
│
│
├── var/                                  # 可变数据
│   │
│   ├── lib/
│   │   ├── frankenphp/                   # [包] 服务用户家目录
│   │   │   └── caddy/                    # [Caddy] 自动 HTTPS 证书与 ACME 状态
│   │   │
│   │   └── mysql/                        # MySQL 数据（自定义目录时此路径为软链）
│   │
│   └── log/
│       ├── frankenphp/                   # [DFM] 站点访问日志目录
│       │   ├── example.com.log           # [DFM] 按站点开启时生成
│       │   └── <domain>.log              # [DFM]
│       │
│       └── mysql/                        # MySQL 日志（视配置而定）
│
│
├── run/                                  # 运行时文件（重启后可重建）
│   └── mysqld/
│       └── mysqld.sock                   # MySQL Socket
│
│
├── home/                                 # 用户业务数据
│   │
│   └── wwwroot/                          # [自定义] 网站根目录，属主 www:www
│       ├── default/                      # [DFM] 默认站点
│       ├── example.com/                  # 站点 A
│       └── example.net/                  # 站点 B
│
│
└── usr/local/etc/                        # 管理员自行安装的软件配置（示例）
