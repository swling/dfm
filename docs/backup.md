# 安装器备份文件（.dfm.orig）

安装器改动系统已有文件前，会在原路径旁留一份 .dfm.orig 备份，便于人工
比对和恢复。备份只在安装时产生，路径就是原路径加 .dfm.orig；使用 cp -p，
目标已存在时不覆盖，所以重复安装不会改写首次快照。安装器不读取、不回滚、
也不自动删除这些备份。

## 已有配置文件

  - /etc/apt/sources.list.d/static-php<code>.list.dfm.orig
    源文件存在且不含 `# Managed by DFM` 标记时产生。安装器用当前 PHP 分支
    对应的 FrankenPHP deb 源覆盖原文件。<code> 是仓库使用的分支代码。

  - /etc/frankenphp/Caddyfile.dfm.orig
    Caddyfile 是普通文件、不含 `# Managed by DFM` 标记且备份不存在时产生。
    安装器会重新生成全局块与站点 import。

## 管理命令文件

  - /usr/local/bin/dfm.dfm.orig
  - /usr/bin/dfm.dfm.orig
    对应路径是普通文件（非软链）、备份不存在且内容与本目录的 dfm 不同时
    产生。若已经是正确软链，安装器直接重建，不产生备份。安装后
    /usr/local/bin/dfm 是脚本实体，/usr/bin/dfm 指向它。

## 不产生备份

  - addons.sh：不安装到系统路径，只保留在源码目录。
  - /etc/apt/keyrings/static-php<code>.asc：安装时直接重建。
