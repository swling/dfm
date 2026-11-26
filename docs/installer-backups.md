# 安装器备份文件（.dfm.orig）

安装器改动系统已有文件前，会在原路径旁留一份 .dfm.orig 备份，便于人工
比对和恢复。备份只在安装时产生，路径就是原路径加 .dfm.orig；使用 cp -p，
目标已存在时不覆盖，所以重复安装不会改写首次快照。安装器不读取、不回滚、
也不自动删除这些备份。

## APT 源文件

  - /etc/apt/sources.list.d/static-php<code>.list.dfm.orig
    源文件存在且不含 `# Managed by DFM` 标记时产生。安装器用当前 PHP 分支
    对应的 FrankenPHP deb 源覆盖原文件。<code> 是仓库使用的分支代码。

  - /etc/apt/sources.list.d/mysql.list.dfm.orig
    mysql.list 已存在且不是 Oracle MySQL Debian 源时产生。安装器用
    repo.mysql.com/apt/debian 对应的源覆盖原文件。

## 不产生备份

  - /usr/local/bin/dfm、/usr/bin/dfm：安装时直接覆盖实体并重建软链，不产生备份。
  - /etc/frankenphp/Caddyfile：已有文件（含软链）重装时原样保留，不产生备份。
  - /etc/frankenphp/Caddyfile.d/default.caddyfile：已有文件同样保留，也不产生备份。
  - /usr/local/bin/dfm-common.sh：安装与同步时直接覆盖。
  - /etc/apt/keyrings/static-php<code>.asc：安装时直接重建。
