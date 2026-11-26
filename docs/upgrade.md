# 手动升级

`upgrade.sh` 按组件从各自的 APT 仓库升级。脚本不自动备份数据或配置，
升级前请自行备份；交互运行时必须输入 `yes` 才继续。

## 用法

    cd lnmp-debian/dfm
    sudo ./upgrade.sh                        # 交互菜单
    sudo ./upgrade.sh frankenphp [版本]
    sudo ./upgrade.sh php <分支>
    sudo ./upgrade.sh mysql [版本]

省略组件时显示交互菜单。FrankenPHP 与 MySQL 的版本可以是上游版本（如
`8.4.0`）或完整 APT 版本；PHP 只接受 `8.2` / `8.3` / `8.4` / `8.5`
这样的分支号。

`--yes` 必须放在组件之前，并显式指定版本：

    sudo ./upgrade.sh --yes frankenphp <版本>
    sudo ./upgrade.sh --yes php 8.5
    sudo ./upgrade.sh --yes mysql <版本>

## 组件说明

  frankenphp  升级当前 PHP 分支内的 frankenphp 与 php-zts-* 包。
              仓库与状态文件里的分支不变，只更新包版本。
              同一分支内的补丁升级都用这个组件。

  php         切换到另一个 PHP 分支。脚本把 APT 源切到目标分支，
              重新安装 frankenphp 与 php-zts-* 包，并更新状态文件。
              这是跨分支升级，属于高风险操作。

  mysql       从 install.sh 配置的 Oracle APT 仓库升级 mysql-server。
              数据目录不受影响，配置变更使用 `--force-confold`
              保留现有配置文件。

## 版本来源与状态

  FrankenPHP   https://pkg.henderkes.com/api/packages/<代码>/debian
               套件 php-zts、组件 main，代码为分支号去掉小数点（8.4 → 84）。
               同一时刻只启用一个分支的仓库，切换分支会移除旧的 DFM 仓库。

  MySQL        https://repo.mysql.com/apt/debian
               组件由 install.sh 发现并收敛到单个 server 系列。

相关文件路径：

  FrankenPHP apt 源     /etc/apt/sources.list.d/static-php<code>.list
  FrankenPHP 密钥       /etc/apt/keyrings/static-php<code>.asc
  当前 PHP 分支         /etc/dfm/php-version
  已装 FrankenPHP 版本  /etc/dfm/frankenphp-version
  MySQL apt 源          /etc/apt/sources.list.d/mysql.list
  MySQL 密钥            /usr/share/keyrings/mysql-apt.gpg

FrankenPHP 与 php-zts-* 来自同一个仓库，必须一起升级，不能只更新其中一个。
Oracle MySQL 的 Debian 13 仓库目前只提供 amd64 构建；FrankenPHP 仓库提供
amd64 与 arm64 构建。

## 升级流程

脚本对每个组件都先确认风险、打印 APT 演练计划，再执行安装。

  - 检查 root 权限、Debian 13 及以上版本、组件已安装且服务处于 active 状态。
  - 解析版本：从 apt-cache madison 中只取目标仓库的候选版本，并要求严格高于当前版本。
  - 打印 apt-get -s install 的结果，确认后再执行安装。
  - 安装后校验 Caddyfile（FrankenPHP / PHP）或重启服务（MySQL），确认服务 active。
  - 回写 /etc/dfm 下的状态文件，并调用 sync-dfm.sh 同步管理命令。

PHP 跨分支升级时会备份旧的 APT 源与状态文件。如果包安装失败，脚本会恢复
源文件与状态，避免下次运行时指向错误仓库。已安装的包无法由 apt 自动回滚，
恢复后请先检查 FrankenPHP 服务再重试。

## 风险与注意事项

升级会改动正在运行的服务，请在维护窗口执行，并确认已完成备份。

  - 跨分支升级 PHP 后，通过 dfm addons 安装的第三方扩展（如 php-zts-redis）
    需要针对新分支重新安装。php-zts-* 包名在各分支间相同，apt 会就地替换；
    只有当新分支不再提供某个包时才需要手动检查残留。
  - 切换 PHP 分支会改变 PHP ABI，站点行为可能变化，升级后应检查站点与日志。
  - MySQL 的 apt 源已收敛到单个 server 系列，本脚本只能在该系列内升级；
    跨系列升级需要重新运行 install.sh 并选择新版本。
  - FrankenPHP 升级前会执行 frankenphp validate 校验 Caddyfile；
    校验失败时脚本直接退出，不会重启服务。
  - --yes 会跳过风险确认，但必须显式指定版本，否则脚本在修改任何 APT 源之前
    就报错退出。

## 升级后清理

跨分支升级 PHP 后，确认新运行时正常，再用 apt 清理不再需要的依赖：

    apt autoremove --purge
    apt clean

MySQL 升级后同样只需清理无用依赖，数据目录不受影响。

文档使用纯文本排版，便于在编辑器中直接阅读和搜索。
