# wordpress-deploy-kit

在 Ubuntu 云服务器上**一键部署 WordPress 生产站点**的单文件脚本。
一条命令完成 Nginx + MariaDB + PHP-FPM + WordPress 中文版 + Let's Encrypt HTTPS
的安装、配置、验证与自动续期，全程约 5~8 分钟。

## 功能特性

- **一键全自动**：9 个部署阶段顺序执行，`set -e` + ERR trap 保证任何一步失败立即终止并报告行号，绝不静默带病运行
- **交互前置**：仅开头 5 项输入（域名、数据库密码×2、通知邮箱、参数确认），之后全程无人值守，支持管道应答
- **密码可选自动生成**：密码留空回车即由 `/dev/urandom` 生成 8 位随机密码（数字 + 大小写）
- **公网 IP 自动探测**：ifconfig.me → ipify → 本机网卡三级兜底，无需手工输入
- **WordPress 多源下载**：本地包优先 → 官方 downloads 端点 → 镜像源，全部带超时；**下载后用 `tar -tzf` 校验内容**（镜像改版/限流会返回 HTML 错误页，wget 退出码仍为 0），无效则自动换下一个源；全部失败时给出明确的手动补救指引
- **HTTPS 全托管**：certbot 自动签发并改写 Nginx 为 SSL、80 强制 301 跳转 443；systemd timer 自动续期 + deploy 钩子自动 reload；证书环节失败只告警，不影响 HTTP 站点
- **自愈能力**：MariaDB 数据目录损坏自动重建、PHP-FPM socket 自动探测、官方 Salts API 不可达时本地生成
- **上传限制已放宽**：nginx `client_max_body_size 512m` + PHP `upload_max_filesize/post_max_size 512M`，备份插件与大媒体上传不会 413
- **媒体库可用**：默认安装 `php-gd` / `php-imagick` 及 mbstring/xml/curl/zip/intl；Nginx `try_files` 回退到 `index.php`，固定链接与 `/wp-json` REST 上传正常
- **小内存自动优化**：写入 mu-plugin，按 `/proc/meminfo` 自动选择图像引擎（<2G 优先 GD，≥2G 优先 Imagick），低内存时跳过 1536/2048 大缩略图；关闭大图自动缩放，网站直接使用原分辨率全图
- **低内存机器专属优化**（仅物理内存 < 1G 生效，大内存机器完全不动）：无 swap 时自动创建并启用 1G swapfile；PHP-FPM `memory_limit` 若为 `-1` 或高于 128M 则收窄到 128M（防单个请求吃爆内存）；FPM 池改 `ondemand` 并按内存算 `max_children`；可用 `WPDK_SKIP_LOWMEM_TUNE=1` 跳过
- **重跑安全**：已部署的机器重复执行不会因密码或数据库已存在而中断；已有站点的 `wp-config.php` 自动备份并原样恢复
- **开箱即加固**（全部幂等、可重复执行）：
  - `/etc/mysql/debian.cnf` 自动回填真实口令 → 修掉**每天午夜 `logrotate.service` 失败**（系统默认是「root + 空口令」，而 §3 又把 root 改成密码登录，不修必然报 `Access denied`）
  - `uploads/` 目录禁止执行 PHP（上传目录只放静态资源，堵住最常见的 getshell 路径；图片等静态文件照常访问）
  - `wp-config.php` 写入 `DISALLOW_FILE_EDIT`：后台无法直接编辑插件/主题代码
  - mu-plugin 屏蔽 **XML-RPC**（`system.multicall` 密码放大器、pingback 滥用）与**用户枚举**（REST `/wp/v2/users`、`?author=N`）
  - Nginx `server_tokens off`；屏蔽 `readme.html`、`wp-config.php` 直访
  - 开启无人值守安全更新；Ubuntu 20.04 会提示启用免费 Ubuntu Pro/ESM
  - **检测到 `/root/.ssh/authorized_keys` 中有公钥时**，自动切换「仅密钥登录 + 抗爆破」（`MaxAuthTries 3` / `MaxStartups`）；交互运行时挂 15 分钟自动回滚保险
- **小内存 PHP-FPM 调优**：按物理内存设置 `pm=ondemand` / `max_children` / `max_requests`，减少并发或 wp-cron 占满进程池导致的 503
- **凭据落盘**：关键凭据写入 `/root/wp-credentials-<域名>.txt`（600，仅 root 可读），并提示不要长期留存含明文口令的部署日志
- **收尾输出全部关键凭据**：数据库密码、证书路径、管理脚本用法一次打印，并附部署后体检结果

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统 | **Ubuntu 20.04（推荐）**，22.04 / 24.04 亦可（Debian 系） |
| 权限 | root |
| 网络 | 80 / 443 端口入方向放行（云服务器需在安全组放行） |
| HTTPS（可选） | 一个已解析到本机 IP 的域名；没有域名也能部署，脚本自动跳过证书环节 |
| 本地 | ssh / scp（上传脚本） |

> **系统版本建议**：低配置 VPS（1 核 1G/2G 内存）请优先选择 Ubuntu 20.04 镜像。
> 更高版本的系统自带组件更重、内存占用更高，在 1~2G 内存的机器上安装与运行
> 都容易出现卡顿甚至卡死；配置充足（2G 以上）可任选。若使用小内存机器，
> 建议部署前先添加 swap（如 `fallocate -l 1G /swapfile`）。

## 快速开始

### 部署步骤

```bash
# 1. 上传
scp wp_deploy.sh root@<服务器IP>:/root/

# 2. 运行
ssh root@<服务器IP>
bash /root/wp_deploy.sh

# 3. 部署完成后，浏览器打开 http://<域名或IP>/ 按 WordPress 安装向导完成初始化
```

开头 5 项交互（全部支持回车默认值）：

| # | 提示 | 回车默认行为 |
| --- | --- | --- |
| 1 | 域名 | 用公网 IP 作为 server_name（自动跳过 HTTPS） |
| 2 | MariaDB root 密码 | 自动生成 |
| 3 | WordPress 数据库密码 | 自动生成 |
| 4 | Let's Encrypt 通知邮箱 | 不填写（不影响自动续期，仅无到期提醒邮件） |
| 5 | 参数确认 | 开始部署 |

### 无人值守（管道应答）

```bash
printf 'example.com\n<root密码>\n<数据库密码>\nyou@example.com\ny\n' | bash /root/wp_deploy.sh
```

密码对应行留空即自动生成，例如两个密码都自动生成：

```bash
printf 'example.com\n\n\nyou@example.com\ny\n' | bash /root/wp_deploy.sh
```

### 可选环境变量（默认值即推荐值）

| 变量 | 作用 | 何时需要 |
| --- | --- | --- |
| `WPDK_ALLOW_XMLRPC=1` | 保留 XML-RPC 端点（默认屏蔽） | 使用 **WordPress 手机 App** 或 Jetpack 时 |
| `WPDK_SKIP_SSH_HARDEN=1` | 跳过「仅密钥登录」加固（默认在检测到公钥时自动加固） | 想先人工确认密钥可用，或机器上还有别的登录方式 |
| `WPDK_SKIP_LOWMEM_TUNE=1` | 跳过「低内存机器专属优化」（不建 swap、不改 `memory_limit`） | 内存 < 1G 但你有自己的内存/swap 方案 |

```bash
# 例：站点要用 WP 手机 App，且本次不动 SSH
WPDK_ALLOW_XMLRPC=1 WPDK_SKIP_SSH_HARDEN=1 bash /root/wp_deploy.sh
```
> 若服务器网络拉取 WordPress 安装包失败，可在本地下载
> [latest-zh_CN.tar.gz](https://cn.wordpress.org/latest-zh_CN.tar.gz) 后执行
> `scp latest-zh_CN.tar.gz root@<服务器IP>:/root/wp_latest_zh.tar.gz`，
> 重新运行脚本即可自动使用。

## 部署流程

| 阶段 | 内容 |
| --- | --- |
| §2 | 安装 Nginx 并设为开机自启 |
| §3 | 安装 MariaDB；执行无交互安全加固（设置 root 密码、删除匿名用户与 test 库）；等待 socket 就绪；**回填 `/etc/mysql/debian.cnf`**（修复 logrotate 每日失败） |
| §4 | 创建数据库 `wordpress`（utf8mb4）与专用用户，仅授予本机访问权限 |
| §5 | 安装 PHP-FPM 与 WordPress 常用扩展（mysql/gd/imagick/mbstring/xml/curl/zip/intl），自动探测实际 socket 路径；**按内存调优 FPM 池**（ondemand / max_children / max_requests）；**低内存（<1G）额外优化**：无 swap 则建 1G swapfile、`memory_limit` 收窄到 128M |
| §6 | 改写 Nginx 站点配置（PHP FastCGI、`try_files` → `index.php`、server_name），改前自动备份，`nginx -t` 验证后生效；**内置 uploads 禁执行 PHP、`server_tokens off`、敏感文件屏蔽** |
| §7 | 写入临时 `info.php` 探针，本机 curl 验证 Nginx ↔ PHP-FPM 链路后立即删除 |
| §8 | 按多源顺序下载 WordPress 中文版并校验；生成 `wp-config.php`（注入数据库配置与随机 Salts） |
| §9 | 部署到 `/var/www/html`，写入按内存自动选 GD/Imagick 的 mu-plugin，属主设为 `www-data`，本机 curl 验证首页；**加写枚举屏蔽 / XML-RPC 屏蔽 mu-plugin 与 `DISALLOW_FILE_EDIT`** |
| §10 | 安装 certbot 并签发 Let's Encrypt 证书，80 强制跳转 443，配置自动续期（无域名时自动跳过） |
| §11 | 安全基线与体检：无人值守更新、logrotate 复核、仅密钥登录加固（有公钥时）、凭据落盘、部署后体检 |

### HTTPS 自动续期机制

Let's Encrypt 证书有效期为 90 天。脚本完成 §10 后，服务器上具备完整的无人值守续期链路：

1. **certbot.timer**（systemd）：每天两次检查，到期前 30 天自动续期；缺失时脚本自动写入 `/etc/cron.d` 兜底任务
2. **deploy 钩子**：`/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh`，续期成功后自动 reload Nginx 加载新证书
3. **续期演练**：部署结束时通过 `certbot renew --dry-run` 在测试环境完整验证续期链路

### 证书手动管理

脚本会在服务器上生成管理工具 `/root/cert_manage.sh`：

```bash
bash /root/cert_manage.sh status    # 查看证书（域名 / 到期时间 / 路径）
bash /root/cert_manage.sh renew     # 手动续期（临近到期才真正续）
bash /root/cert_manage.sh force     # 立即强制重签（注意 Let's Encrypt 速率限制）
bash /root/cert_manage.sh dryrun    # 续期演练
bash /root/cert_manage.sh reissue   # 重新签发安装（证书环节曾失败时使用）
```

## 容错与自愈

| 场景 | 脚本行为 |
| --- | --- |
| 任意步骤执行失败 | `set -e` + ERR trap 立即终止，打印失败行号与上下文 |
| MariaDB 启动失败（数据目录残缺） | 自动重建数据目录后重试，随后轮询等待 socket 就绪（最长 30 秒） |
| MySQL root 已设置密码时重跑 | 自动在无密码/密码两种登录方式间切换 |
| 数据库已存在时重跑 | `CREATE DATABASE IF NOT EXISTS`，幂等执行 |
| 官方下载源 429 限流 / 不可达 | 依次尝试镜像源与官方源；全部失败时输出手动补救指引 |
| Salts API 不可达 | 本地以 `/dev/urandom` 生成等价随机 Salts |
| 备份/媒体上传报 413 | 已内置放宽：nginx `client_max_body_size 512m` + PHP `upload/post 512M` |
| 媒体库上传图片没反应 | 已内置 `php-gd`/`php-imagick`；Nginx 使用 WordPress 标准 `try_files`（支持 `/wp-json`） |
| 媒体上传很慢（小内存 VPS） | mu-plugin 按内存自动优先 GD，并跳过 1536/2048 大缩略图；仍慢时可先压缩原图 |
| 重跑覆盖站点配置 | 重跑前自动备份 `wp-config.php` 并在部署后原样恢复，站点与数据库对接不变 |
| 重跑**已安装**的站点 | §9 部署后校验接受 `200/301/302`（已安装站点首页返回 200），不会误判失败而中途退出 |
| 证书签发失败（DNS 未生效、80 端口不通等） | 仅告警不中断，HTTP 站点正常；事后 `reissue` 补装 |
| apt 安装触发交互对话框 | 全程 `DEBIAN_FRONTEND=noninteractive` |
| `logrotate.service` 每天 failed | §3 自动回填 `/etc/mysql/debian.cnf`，§11 再体检一次；修复后单元状态恢复 `inactive` |
| uploads 目录被写入 .php | §6 已内置 `location ^~ /wp-content/uploads/`：命中 `.php/.phtml/.phar` 返回 403，静态文件不受影响 |
| 用户枚举（`?author=1`、`/wp-json/wp/v2/users`） | §9 已内置 mu-plugin 屏蔽，正常前后台功能不受影响 |
| XML-RPC 被用于批量试密码 | §9 默认屏蔽；需要 WP 手机 App 时用 `WPDK_ALLOW_XMLRPC=1` 保留 |
| 加固后无法用密钥登录（SSH 自锁） | 仅在 `authorized_keys` 已有公钥时才加固；交互运行时挂 15 分钟自动回滚（`atrm <任务号>` 取消），无人值守不挂保险 |
| 低内存机器并发 503 | §5 按内存设置 `pm=ondemand` + `max_children` + `max_requests` |
| 重复执行加固步骤 | 全部幂等：`;pm.max_requests` 这类注释行也能识别改写，`define('DISALLOW_FILE_EDIT')` 已存在则跳过 |

## 常见问题

**Q：部署中途失败怎么办？**
根据报错修正问题（磁盘、网络、安全组等）后直接重跑，脚本各阶段幂等。

**Q：低配置 VPS（1 核 1G）能部署吗？**
能。推荐选择 Ubuntu 20.04 系统镜像，其组件更轻量；更高版本在小内存机器上
容易卡死。建议再添加 1G swap 降低 OOM 风险。

**Q：可以只重装某个组件吗？**
不支持单步运行。脚本按整机从零部署设计；如需重建，建议在云控制台重置系统盘后重跑。

**Q：`certbot renew --dry-run` 等待几分钟正常吗？**
正常。certbot 非交互续期会先随机延迟（最长 8 分钟）错峰请求 ACME 服务器。

**Q：没有域名能用吗？**
能。回车跳过域名输入后以公网 IP 作为站点地址，仅跳过 §10 证书环节；之后绑定了域名再运行 `bash /root/cert_manage.sh reissue` 即可补装 HTTPS。

**Q：脚本输出里打印了数据库密码，安全吗？**
凭据只输出到当前 SSH 会话，同时会落盘到 `/root/wp-credentials-<域名>.txt`（600，仅 root 可读）。
⚠️ 如果你用 `bash wp_deploy.sh | tee deploy.log` 之类方式留存了运行日志，**日志里就是明文口令**
（真实教训：服务器上 `/root/wp_deploy_run.log` 里躺着 MariaDB root 口令）。请给这类日志 `chmod 600` 或及时删除，并把口令存进密码管理器。

## 安全建议

### 脚本已自动完成

- 上传目录禁止执行 PHP、`server_tokens off`、屏蔽 `readme.html` / `wp-config.php` 直访
- 屏蔽 XML-RPC 与用户枚举；关闭后台文件编辑器（`DISALLOW_FILE_EDIT`）
- 回填 `/etc/mysql/debian.cnf`（修掉每天 `logrotate` 失败）；开启无人值守安全更新
- 检测到公钥时自动切换「仅密钥登录 + 抗爆破」
  （回滚：`rm -f /etc/ssh/sshd_config.d/99-hardening.conf && sshd -t && systemctl reload ssh`）
- MariaDB 仅监听本机，3306 不对外

### 仍需人工处理

- **WordPress 管理员密码**：安装向导里设置强密码，并启用**纯 TOTP 类**两步验证插件（先把恢复码存好）。
- **主机层兜底**：确认云控制台 VNC/远程连接可用（这是唯一不依赖密钥的入口）；有条件开启云快照
- **备份**：UpdraftPlus 等插件务必**配置定时任务**（很多站点装了却没设计划，等于没有备份）
- **系统补丁**：Ubuntu 20.04 标准支持已于 2025-05 结束，建议 `pro attach` 启用免费 ESM，或规划升级到 22.04/24.04

## License

[MIT](./LICENSE) © 2026 wordpress-deploy-kit contributors

