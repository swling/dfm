# 卸载

以 root 运行 uninstall.sh，按组件卸载：

    ./uninstall.sh                          # 交互选择，默认 all
    ./uninstall.sh --component=mysql --yes
    ./uninstall.sh --component=frankenphp --yes
    ./uninstall.sh --component=all --yes
    ./uninstall.sh --help

## 卸载目标

  mysql       卸载 MySQL 软件包、Oracle 源与安装器生成的配置；数据目录保留。
  frankenphp  卸载 frankenphp 与 php-zts-* 包、FrankenPHP 源与 DFM 配置片段；
              站点配置保留。
  all         卸载全部组件与管理命令（交互时默认选此项）。

  --yes 跳过确认；未指定组件时按 all 处理。卸载前会先打印计划并再次确认。

## 将删除

  MySQL
    /etc/mysql/mysql.conf.d/zz-dfm.cnf（仅安装器写入时存在）
    AppArmor 中为 MYSQL_DATA_DIR 追加的规则
    /var/lib/mysql 软链（不触碰其指向的数据）
    /etc/apt/sources.list.d/mysql.list（无备份时删除）与 MySQL 签名密钥
    MySQL 源文件的 *.dfm.orig 备份（还原后删除）

  FrankenPHP
    /etc/systemd/system/frankenphp.service.d/10-dfm.conf
    内置伪静态片段与 cache-static.caddyfile
    DFM 管理的 /etc/apt/sources.list.d/static-php*.list 与对应密钥
    static-php 源文件的 *.dfm.orig 备份（还原后删除）
    /etc/dfm/php-version、/etc/dfm/frankenphp-version

  all 额外删除
    /usr/local/bin/dfm、/usr/bin/dfm、/usr/local/bin/dfm-common.sh
    /etc/dfm.conf 与 /etc/dfm/
    www 用户/组

注：APT 源文件若存在 .dfm.orig，卸载时先还原原文件再删除备份；
没有备份时才直接删除当前源文件。

## 将保留（仅警告，不处理）

  - MySQL 数据目录及其备份，包括独立磁盘上的数据。
  - 网站文件。
  - /etc/frankenphp/Caddyfile.d/ 下全部站点配置（含 default.caddyfile）。
  - /var/lib/frankenphp/caddy 中的 Caddy 自动证书数据。
  - /var/log/frankenphp/ 中的访问日志。
  - 通过 dfm addons 安装的 memcached、redis-server 等独立服务包。
  - 自定义伪静态片段保留。

## 执行流程

  1. 解析参数、确认 root 与目标组件。
  2. 读取 /etc/dfm.conf（缺失时回退源码 dfm.conf）确定路径，再从 dpkg 收集待 purge 的软件包。
  3. 打印删除与保留清单，等待输入 yes 确认（或使用 --yes）。
  4. 停止相关服务，删除配置与 APT 源。
  5. 以 apt-get purge 与 autoremove --purge 清理软件包。
  6. 执行 systemctl daemon-reload 并打印未处理的数据清单。

## 卸载后重装

  - MySQL 包未安装且 MYSQL_DATA_DIR 已有数据时，install.sh 会提示
    输入 clear 全新安装或终止，不做旧数据复用判断。
  - Caddy 证书数据仍在 /var/lib/frankenphp/caddy：重装并恢复相同域名后，
    证书可继续使用；若要彻底清除证书，需自行处理该目录。
  - default.caddyfile 与自定义站点配置重装时都不会被覆盖；
    只有默认站点文件缺失时才按模板生成。
