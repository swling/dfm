# 手动备份配置

建议直接备份 Debian 的配置与证书目录。MySQL 数据目录位于独立磁盘时，请按
/etc/dfm.conf 中的实际路径另行备份；若未安装 Redis，可跳过 Redis 命令。

## 备份

    sudo install -d -m 700 /home/bf

    sudo tar -czpf /home/bf/frankenphp-conf.tar.gz /etc/frankenphp /etc/dfm.conf
    sudo tar -czpf /home/bf/frankenphp-caddy.tar.gz /var/lib/frankenphp/caddy
    sudo tar -czpf /home/bf/frankenphp-systemd.tar.gz /etc/systemd/system/frankenphp.service.d
    sudo tar -czpf /home/bf/mysql-conf.tar.gz /etc/mysql
    sudo tar -czpf /home/bf/redis-conf.tar.gz /etc/redis/redis.conf

## 恢复

恢复前先备份目标服务器当前配置，再从备份中按需覆盖，不要先删除配置目录。

    sudo tar -xzpf /home/bf/frankenphp-conf.tar.gz -C /
    sudo tar -xzpf /home/bf/frankenphp-caddy.tar.gz -C /
    sudo tar -xzpf /home/bf/frankenphp-systemd.tar.gz -C /
    sudo tar -xzpf /home/bf/mysql-conf.tar.gz -C /
    sudo tar -xzpf /home/bf/redis-conf.tar.gz -C /

恢复 FrankenPHP 配置时，只取需要的公共配置；不同服务器的站点配置应单独核对，
不要盲目覆盖。恢复后至少运行

    sudo frankenphp validate --config /etc/frankenphp/Caddyfile

并检查 frankenphp 与 mysql 服务状态，再重载或重启服务。
