#!/bin/bash
#===============================================================
# wp_deploy.sh —— WordPress 一键部署脚本（Nginx + MariaDB + PHP-FPM + HTTPS）
#
# 适用：Ubuntu 20.04（推荐）/ 22.04 / 24.04 全新系统，root 权限运行
# 说明：低配 VPS 建议使用 20.04——更高版本的系统组件更重、内存占用更高，
#       小内存机器上安装与运行容易卡顿甚至卡死
#
# 流程：
#   §2  安装 Nginx                §6  配置 Nginx（FastCGI）
#   §3  安装并加固 MariaDB        §7  自动探针验证
#   §4  创建 WordPress 数据库     §8  下载并配置 WordPress
#   §5  安装 PHP-FPM              §9  部署上线
#                                 §10 Let's Encrypt 证书与自动续期（有域名时）
#                                 §11 安全基线与体检（logrotate 凭据 / 上传目录禁执行 / mu-plugin 加固 /
#                                     无人值守更新 / 可选 SSH 仅密钥加固）
#
# 交互集中在开头共 5 项：域名（回车=用公网 IP）、MariaDB root 密码、
# 数据库密码（两者回车=自动生成）、HTTPS 通知邮箱（回车=不填）、参数确认。
# 支持管道应答无人值守运行。
#
# 环境变量开关（默认值即推荐值，均不改变既有部署流程）：
#   WPDK_ALLOW_XMLRPC=1     保留 XML-RPC 端点（默认屏蔽；使用 WP 手机 App / Jetpack 时必须设 1）
#   WPDK_SKIP_SSH_HARDEN=1  跳过「仅密钥登录」加固（默认在检测到公钥时自动加固）
#
# 容错设计：set -e + ERR trap 失败即停；MariaDB 数据目录损坏自动重建；
# WordPress 多源下载（本地包优先）；密码留空自动生成；已部署机器可安全重跑。
#===============================================================
set -e
trap 'echo ">>> 部署在第 ${LINENO} 行失败，请检查上方错误信息"; exit 1' ERR

#---- 工具函数 ----
# 生成 8 位随机密码（数字+大小写字母；循环抽取直到同时含三类字符）
gen_password() {
    local pw
    while :; do
        pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8)
        [ ${#pw} -eq 8 ] || continue
        if [[ "$pw" =~ [0-9] && "$pw" =~ [A-Z] && "$pw" =~ [a-z] ]]; then
            printf '%s' "$pw"; return
        fi
    done
}

# 判断 nginx.conf 里是否已有占用 443 的 stream 块（即 443 已被独立的 TCP 网关接管，
# 站点只能挂在内部端口）。只看配置内容，不依赖任何外部写入的标记，保持脚本自包含。
nginx_443_taken() {
    [ -f /etc/nginx/nginx.conf ] || return 1
    awk '
        /^[[:space:]]*stream[[:space:]]*\{/ { in_stream = 1 }
        in_stream {
            nopen  = gsub(/\{/, "{")
            nclose = gsub(/\}/, "}")
            depth += nopen - nclose
            if ($0 ~ /listen[[:space:]]+(\[::\]:)?443([^0-9]|$)/) hit = 1
            if (depth <= 0) {
                if (hit) exit 0
                in_stream = 0; depth = 0; hit = 0
            }
        }
        END { exit (hit ? 0 : 1) }
    ' /etc/nginx/nginx.conf 2> /dev/null
}

# 重跑兼容：新装机 MariaDB root 无密码；重跑时 root 已有密码（§3 设置过）。
# 两种情况都兼容：先试无密码登录，失败则带 ROOTPW 登录
mysql_run() {
    if mysql -uroot -e 'SELECT 1;' > /dev/null 2>&1; then
        mysql -uroot "$@"
    else
        mysql -uroot -p"${ROOTPW}" "$@"
    fi
}


# 幂等设置 PHP-FPM 池参数（命中已存在行则改写，注释行同样命中；否则追加）
# 用法：fpm_set <键> <值> <池配置文件>
fpm_set() {
    local key="$1" val="$2" conf="$3"
    if grep -qE "^[;[:space:]]*${key}[[:space:]]*=" "$conf"; then
        sed -i -E "s|^[;[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "$conf"
    else
        printf '\n%s = %s\n' "$key" "$val" >> "$conf"
    fi
}

# 幂等写入 wp-config.php 常量（已存在同名 define 则跳过，避免重跑叠加）
# 用法：wp_config_define <常量名> <PHP 字面量> <wp-config.php 路径>
wp_config_define() {
    local name="$1" value="$2" conf="$3"
    if grep -q "define( *'${name}'" "$conf"; then
        echo ">>> wp-config.php 已包含 ${name}，跳过"
        return 0
    fi
    local line="define( '${name}', ${value} );"
    if grep -q "stop editing" "$conf"; then
        awk -v line="$line" 'index($0,"stop editing") && !done { print line; done=1 } { print }' "$conf" > "${conf}.wpdk.tmp"
    elif grep -q "require_once ABSPATH" "$conf"; then
        awk -v line="$line" 'index($0,"require_once ABSPATH") && !done { print line; done=1 } { print }' "$conf" > "${conf}.wpdk.tmp"
    else
        cp "$conf" "${conf}.wpdk.tmp"
        printf '\n%s\n' "$line" >> "${conf}.wpdk.tmp"
    fi
    if [ -s "${conf}.wpdk.tmp" ]; then
        cat "${conf}.wpdk.tmp" > "$conf"
        rm -f "${conf}.wpdk.tmp"
        echo ">>> wp-config.php 已写入 ${line}"
    else
        rm -f "${conf}.wpdk.tmp"
        echo ">>> 警告：${name} 写入失败（临时文件为空），未改动 wp-config.php"
    fi
}
#---- 部署参数（全部交互点集中在此）----
read -rp "请输入域名（如 example.com；直接回车 = 用公网 IP 作为 server_name）: " DOMAIN

# 公网 IP 自动检测，无需手工输入：ifconfig.me → ipify → 本机网卡兜底
SERVER_IP=$(curl -s --max-time 5 https://ifconfig.me)
[ -n "$SERVER_IP" ] || SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi
if [ -z "$SERVER_IP" ]; then
    read -rp "自动检测公网 IP 失败，请手工输入服务器公网 IP: " SERVER_IP
fi
echo ">>> 服务器公网 IP：${SERVER_IP}"
if [ -z "$DOMAIN" ]; then
    DOMAIN="$SERVER_IP"
    echo ">>> 未输入域名，server_name 将使用公网 IP：${DOMAIN}"
fi

# MariaDB root 密码（回车=自动生成）——替代 mysql_secure_installation 交互
read -rsp "设置 MariaDB root 密码（直接回车 = 自动生成 8 位随机密码）: " ROOTPW
echo ""
[ -n "$ROOTPW" ] || ROOTPW=$(gen_password)

# 数据库用户 wordpress 的密码（回车=自动生成）
read -rsp "为数据库用户 wordpress 设置密码（直接回车 = 自动生成 8 位随机密码）: " DBPASS
echo ""
[ -n "$DBPASS" ] || DBPASS=$(gen_password)

# HTTPS 证书通知邮箱（回车=不注册邮箱；不影响自动续期，仅缺到期提醒邮件）
read -rp "Let's Encrypt 通知邮箱（证书到期提醒用；直接回车 = 不填写）: " EMAIL

echo ""
echo "---------------- 部署参数确认 ----------------"
echo "  域名/访问地址 : ${DOMAIN}"
echo "  公网 IP       : ${SERVER_IP}"
echo "  数据库        : MariaDB（库名/用户名均为 wordpress）"
echo "  HTTPS 通知邮箱: ${EMAIL:-(未填写)}"
echo "------------------------------------------------"
read -rp "确认以上参数并开始部署？(y=继续 / 其他=退出): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "已取消部署。"
    exit 1
fi
echo ">>> MariaDB root 密码：${ROOTPW}（请记录，结尾汇总还会打印）"

# 前置拦截：nginx 已用 stream 接管 443（站点挂在内部端口）时不能重跑本脚本——
# §6 会把站点配置重写成仅 80 端口，§10 又会让 certbot 重新占用 443，
# 两者都会破坏正在工作的接管配置与站点。此时应先回滚接管配置，重跑完再重新部署。
if nginx_443_taken; then
    echo ""
    echo ">>> 检测到 nginx 已用 stream 接管 443，本脚本会破坏该配置，已中止。"
    echo "    §6 会把站点监听从内部端口改回仅 80 端口；§10 会让 certbot 重新占用 443。"
    echo "    请先移除该接管配置、把站点恢复为直连 443，之后再重跑本脚本。"
    exit 1
fi

echo "==== §2 安装 Nginx ===="
export DEBIAN_FRONTEND=noninteractive
apt update || { sleep 5; apt update; }
apt install nginx -y

# 启动并设置开机自启
systemctl start nginx
systemctl enable nginx > /dev/null
echo ">>> 验证：浏览器访问 http://${DOMAIN} 应看到 'Welcome to nginx!'"

echo ""
echo "==== §3 安装 MariaDB ===="
apt install mariadb-server -y

# 启动失败时自动重建数据目录（apt 安装中断可能导致系统表残缺而无法启动）
if ! systemctl start mariadb; then
    echo ">>> MariaDB 启动失败，尝试重建数据目录后重试……"
    systemctl stop mariadb 2> /dev/null || true
    rm -rf /var/lib/mysql/*
    mysql_install_db --user=mysql --datadir=/var/lib/mysql
    systemctl start mariadb
fi
systemctl enable mariadb > /dev/null

# 等待 socket 就绪（最多 30 秒），避免 SQL 阶段连接失败
for i in $(seq 1 30); do
    if mysqladmin --socket=/run/mysqld/mysqld.sock ping > /dev/null 2>&1; then
        break
    fi
    sleep 1
    if [ "$i" -eq 30 ]; then
        echo ">>> MariaDB 30 秒内未就绪"
        exit 1
    fi
done
# 这里的 ping 只判断服务可达性：重跑时 root 已有密码，认证失败会打 Access denied 噪音（退出码仍为 0）
mysqladmin --socket=/run/mysqld/mysqld.sock ping 2> /dev/null || true

# 安全加固：等价于 mysql_secure_installation，但无交互依赖，各版本通用
# （设置 root 密码 / 删除匿名用户 / 删除 test 库；root 仅限本机登录）
mysql_run <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOTPW}';
DROP USER IF EXISTS ''@'localhost';
DROP USER IF EXISTS ''@'%';
DROP USER IF EXISTS ''@'$(hostname)' ;
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db LIKE 'test%';
FLUSH PRIVILEGES;
SQL
# 验证 root 密码生效
mysql -uroot -p"${ROOTPW}" -e "SELECT 'MARIADB_SECURE_OK' AS status;"
echo ">>> §3 完成：root 密码已设置，匿名用户/test 库已移除，root 仅限本机"

# Debian 维护脚本（logrotate 的 mysql 片段、init 脚本等）通过 /etc/mysql/debian.cnf 连接数据库。
# 系统默认内容是「root + 空密码」，而上面已把 root 改为密码登录 → 不修正的话每天 logrotate 都会失败。
# 这里按实际口令回填（600 root:root），并立即验证一次；内容相同则不做任何改动。
if [ -f /etc/mysql/debian.cnf ]; then
    DEBIAN_SOCK=$(grep -m1 '^socket' /etc/mysql/debian.cnf | sed 's/.*=[[:space:]]*//')
    [ -n "${DEBIAN_SOCK:-}" ] || DEBIAN_SOCK=/run/mysqld/mysqld.sock
    DEBIAN_CNF_TMP=$(mktemp)
    cat > "$DEBIAN_CNF_TMP" <<EOF
# Automatically generated for Debian scripts. DO NOT TOUCH!
[client]
host     = localhost
user     = root
password = ${ROOTPW}
socket   = ${DEBIAN_SOCK}
[mysql_upgrade]
host     = localhost
user     = root
password = ${ROOTPW}
socket   = ${DEBIAN_SOCK}
EOF
    chmod 600 "$DEBIAN_CNF_TMP"
    if cmp -s "$DEBIAN_CNF_TMP" /etc/mysql/debian.cnf; then
        rm -f "$DEBIAN_CNF_TMP"
        echo ">>> /etc/mysql/debian.cnf 内容已正确，无需修改"
    else
        cp -a /etc/mysql/debian.cnf "/root/debian.cnf.bak.$(date +%s)"
        chown root:root "$DEBIAN_CNF_TMP"
        chmod 600 "$DEBIAN_CNF_TMP"
        mv -f "$DEBIAN_CNF_TMP" /etc/mysql/debian.cnf
        echo ">>> 已回填 /etc/mysql/debian.cnf（供 logrotate 等 Debian 脚本使用）"
    fi
    if mysqladmin --defaults-file=/etc/mysql/debian.cnf --local status > /dev/null 2>&1; then
        echo ">>> 验证通过：debian.cnf 可登录 MariaDB（logrotate 的 mysql 片段不会再报错）"
    else
        echo ">>> 警告：debian.cnf 仍无法登录 MariaDB，logrotate 可能继续报错，请手工检查"
    fi
fi
echo ""
echo "==== §4 创建 WordPress 数据库 ===="
# utf8mb4 完整支持 emoji 等 4 字节字符
# CREATE USER 与 GRANT 分开写（GRANT ... IDENTIFIED BY 在新版本已废弃）
mysql_run -e "CREATE DATABASE IF NOT EXISTS wordpress CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
mysql -uroot -p"${ROOTPW}" -e "CREATE USER IF NOT EXISTS 'wordpress'@'localhost' IDENTIFIED BY '${DBPASS}';"
mysql -uroot -p"${ROOTPW}" -e "GRANT ALL ON wordpress.* TO 'wordpress'@'localhost';"
mysql -uroot -p"${ROOTPW}" -e "FLUSH PRIVILEGES;"
# 用新用户实际登录验证
mysql -uwordpress -p"${DBPASS}" wordpress -e "SELECT 'WP_DB_OK' AS status;"
echo ">>> 已创建：库 wordpress / 用户 wordpress / utf8mb4_general_ci"

echo ""
echo "==== §5 安装 PHP（不指定版本号，发行版最新稳定版） ===="
# gd/imagick：媒体库图片上传与缩略图；其余为 WP 常用扩展（REST/更新/翻译/备份 zip）
apt install php-fpm php-mysql php-gd php-imagick php-mbstring php-xml php-curl php-zip php-intl python3 -y

# 放宽 PHP 上传限制（默认 upload 2M / post 8M，备份插件与大媒体上传会 413 失败）
PHP_INI=$(ls /etc/php/*/fpm/php.ini | head -n1)
sed -i "s/^upload_max_filesize.*/upload_max_filesize = 512M/" "$PHP_INI"
sed -i "s/^post_max_size.*/post_max_size = 512M/" "$PHP_INI"
PHP_VER=$(ls /etc/php | head -n1)

# PHP-FPM 池调优（幂等）：低内存 VPS 默认 pm=dynamic / max_children=5，遇到并发高峰或
# wp-cron 占满池时会返回 503；这里按物理内存给一组保守参数，并用 ondemand 让空闲子进程退出
FPM_POOL=$(ls /etc/php/*/fpm/pool.d/www.conf 2> /dev/null | head -n1)
MEM_MB_FPM=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2> /dev/null || echo 0)
if [ -n "${FPM_POOL:-}" ]; then
    if [ "${MEM_MB_FPM:-0}" -gt 0 ] && [ "${MEM_MB_FPM}" -lt 1024 ]; then
        FPM_CHILDREN=$(( MEM_MB_FPM / 64 ))
        if [ "$FPM_CHILDREN" -lt 4 ]; then FPM_CHILDREN=4; fi
        if [ "$FPM_CHILDREN" -gt 8 ]; then FPM_CHILDREN=8; fi
        fpm_set pm ondemand "$FPM_POOL"
        fpm_set pm.max_children "$FPM_CHILDREN" "$FPM_POOL"
        fpm_set pm.process_idle_timeout 10s "$FPM_POOL"
        fpm_set pm.max_requests 500 "$FPM_POOL"
        echo ">>> PHP-FPM 池已按 ${MEM_MB_FPM}MB 内存调优：pm=ondemand / max_children=${FPM_CHILDREN} / max_requests=500"
    else
        fpm_set pm.max_requests 500 "$FPM_POOL"
        echo ">>> PHP-FPM 池已设置 pm.max_requests=500（内存 ${MEM_MB_FPM}MB，保持发行版默认 pm 模式）"
    fi
fi

# 低内存机器专属优化（仅物理内存 < 1G 生效；大内存机器完全不动，保持发行版默认）：
#   (1) 没有 swap 就建 1G swapfile —— 0.4G 机器遇到一次内存尖峰就是 OOM 杀进程
#   (2) PHP-FPM 的 memory_limit 若是 -1/0 或高于 128M，收窄到 128M ——
#       单个请求吃光全部内存是这类机器最典型的死法（已经是 128M 时为空操作）
if [ "${MEM_MB_FPM:-0}" -gt 0 ] && [ "${MEM_MB_FPM}" -lt 1024 ] && [ "${WPDK_SKIP_LOWMEM_TUNE:-0}" != "1" ]; then
    if [ -z "$(awk 'NR > 1' /proc/swaps 2> /dev/null)" ]; then
        if [ ! -f /swapfile ]; then
            fallocate -l 1G /swapfile 2> /dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none 2> /dev/null
        fi
        chmod 600 /swapfile 2> /dev/null
        mkswap /swapfile > /dev/null 2>&1
        if swapon /swapfile 2> /dev/null; then
            grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            echo ">>> 低内存优化：已创建并启用 1G swapfile（OOM 前最后一道缓冲）"
        else
            echo ">>> 警告：swapfile 启用失败（磁盘空间不足？），建议手动添加 swap"
        fi
    else
        echo ">>> 低内存优化：已有 swap（$(awk 'NR > 1 {print $1}' /proc/swaps | tr '\n' ' ')），跳过"
    fi

    for ini in /etc/php/*/fpm/php.ini; do
        [ -f "$ini" ] || continue
        cur=$(grep -E '^[[:space:]]*memory_limit[[:space:]]*=' "$ini" | head -n1 | sed 's/.*=[[:space:]]*//' | tr -d '\r ')
        case "$cur" in
            -1 | 0 | "")
                sed -i 's/^[[:space:]]*memory_limit[[:space:]]*=.*/memory_limit = 128M/' "$ini"
                echo ">>> 低内存优化：PHP-FPM memory_limit ${cur:-未设置} -> 128M（$ini）" ;;
            *[MmGg])
                lim=${cur%[MmGg]}
                case "$cur" in *[Gg]) lim=$(( lim * 1024 )) ;; esac
                if [ "$lim" -gt 128 ] 2> /dev/null; then
                    sed -i 's/^[[:space:]]*memory_limit[[:space:]]*=.*/memory_limit = 128M/' "$ini"
                    echo ">>> 低内存优化：PHP-FPM memory_limit ${cur} -> 128M（$ini）"
                fi ;;
        esac
    done
fi

systemctl restart php$PHP_VER-fpm
echo ">>> PHP 上传限制已放宽：upload_max_filesize = post_max_size = 512M"
# 缺 gd/imagick 时媒体库上传图片会静默失败（WordPress 要求至少一种图像扩展）
if ! php -m | grep -qiE '^(gd|imagick)$'; then
    echo ">>> 警告：未检测到 php-gd / php-imagick，媒体库图片上传将不可用"
fi

# 自动探测实际的 PHP-FPM socket 路径（不同 Ubuntu 版本 sock 名不同）
ls /run/php/
if [ -e /run/php/php-fpm.sock ]; then
    PHP_SOCK="/run/php/php-fpm.sock"                      # 通用名优先
else
    PHP_SOCK=$(ls -t /run/php/php*-fpm.sock 2> /dev/null | head -n1)
fi
if [ -z "${PHP_SOCK:-}" ]; then
    echo ">>> 未找到 php-fpm.sock，PHP-FPM 安装异常"
    exit 1
fi
echo ">>> fastcgi_pass 将使用：${PHP_SOCK}"

echo ""
echo "==== §6 配置 Nginx 使用 PHP ===="
# 改写 sites-available/default：index 加 index.php / server_name 用域名 /
# php location 的 fastcgi_pass 指向实际 sock
cp /etc/nginx/sites-available/default "/etc/nginx/sites-available/default.bak.$(date +%s)"
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    index index.php index.html index.htm index.nginx-debian.html;

    # 允许大文件上传（备份包/媒体），nginx 默认 1m 会导致 413
    client_max_body_size 512m;

    # 禁止把内部端口拼进目录补斜杠的重定向地址
    # （避免重定向到访客无法访问的端口）
    port_in_redirect off;
    absolute_redirect off;

    server_name ${DOMAIN};

    # 隐藏 nginx 版本号，减少版本探测
    server_tokens off;

    # 上传目录只允许静态资源：即使有 .php 文件被写进去也不会执行（最常见的拿 shell 路径）
    location ^~ /wp-content/uploads/ {
        location ~* \.(php|phtml|php[0-9]|phar)$ { deny all; }
    }

    # 屏蔽版本探测文件与敏感文件直访
    location = /readme.html { deny all; }
    location = /wp-config.php { deny all; }

    location / {
        # WordPress 固定链接 / REST API（/wp-json）需要回退到 index.php
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# 验证配置语法
nginx -t
# 使新配置生效
systemctl reload nginx

echo ""
echo "==== §7 测试 PHP 与 Nginx 集成（自动探针） ===="
# 本机 curl 自动探针，验证 Nginx ↔ PHP-FPM 链路
cat > /var/www/html/info.php <<EOF
<?php
phpinfo();
EOF
sleep 1
if curl -s "http://127.0.0.1/info.php" | grep -q "PHP Version"; then
    echo ">>> 探针通过：Nginx + PHP-FPM 已打通"
else
    echo ">>> 探针失败：http://${DOMAIN}/info.php 未返回 PHP 信息"
    exit 1
fi
rm -f /var/www/html/info.php

echo ""
echo "==== §8 安装与配置 WordPress ===="
cd /root
rm -rf /root/wordpress /root/latest-zh_CN.tar.gz
# 下载顺序：本地已上传包优先 → 官方 downloads 端点 → 华为云镜像 → cn.wordpress.org → wordpress.org
# （镜像路径经常变动或因限流返回 429/HTML 错误页：wget 退出码 0 不代表内容正确，
#   因此下面必须用 tar -tzf 校验内容确实是 gzip 包，否则换下一个源）
WP_TGZ="/root/wp_latest_zh.tar.gz"
if [ ! -f "$WP_TGZ" ]; then
    for URL in https://downloads.wordpress.org/release/zh_CN/wordpress-latest.tar.gz \
               https://mirrors.huaweicloud.com/wordpress/latest-zh_CN.tar.gz \
               https://cn.wordpress.org/latest-zh_CN.tar.gz \
               https://wordpress.org/latest-zh_CN.tar.gz; do
        echo ">>> 尝试下载：${URL}"
        # -O 固定输出路径：各源 URL 的文件名不同，统一落到 $WP_TGZ 便于校验与复用
        if wget --timeout=60 --tries=2 --waitretry=5 -O "$WP_TGZ" "${URL}"; then
            if tar -tzf "$WP_TGZ" > /dev/null 2>&1; then
                echo ">>> 下载成功并通过 gzip 校验"
                break
            fi
            echo ">>> 该源返回的不是有效的 WordPress 包（镜像错误页/限流页？），换下一个源"
            rm -f "$WP_TGZ"
        else
            rm -f "$WP_TGZ"
        fi
    done
fi
# 兼容：手工 scp 到原始文件名 latest-zh_CN.tar.gz 的情形
if [ ! -f "$WP_TGZ" ] && [ -f /root/latest-zh_CN.tar.gz ]; then
    WP_TGZ=/root/latest-zh_CN.tar.gz
fi
if [ ! -f "$WP_TGZ" ]; then
    echo ">>> 所有源均下载失败。请在本机下载 latest-zh_CN.tar.gz 后执行："
    echo "    scp latest-zh_CN.tar.gz root@${SERVER_IP}:/root/wp_latest_zh.tar.gz"
    echo "    然后重新运行本脚本"
    exit 1
fi
ls -la "$WP_TGZ"
tar -xzf "$WP_TGZ"

# 准备配置文件
mv /root/wordpress/wp-config-sample.php /root/wordpress/wp-config.php

# wp-config.php 需修改 5 处：DB_NAME / DB_USER / DB_PASSWORD / DB_CHARSET / Salts
# 密码经环境变量传入 python，避免多层转义问题
curl -s --max-time 15 https://api.wordpress.org/secret-key/1.1/salt/ > /root/salts.txt
# 兜底：官方 API 不可达时本地随机生成 8 条 salts（格式与 API 返回一致，安全等价）
if [ ! -s /root/salts.txt ]; then
    : > /root/salts.txt
    for K in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY \
             AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
        echo "define( '${K}', '$(head -c 32 /dev/urandom | base64 | tr -d '=+/\n')' );" >> /root/salts.txt
    done
    echo ">>> （api.wordpress.org 不可达，salts 已改为本地随机生成）"
fi
export DBPASS
python3 - <<'PY'
import os, re
p = '/root/wordpress/wp-config.php'
s = open(p).read()
s = re.sub(r"define\(\s*'DB_NAME'.*?;",     "define( 'DB_NAME', 'wordpress' );",     s, count=1)
s = re.sub(r"define\(\s*'DB_USER'.*?;",     "define( 'DB_USER', 'wordpress' );",     s, count=1)
s = re.sub(r"define\(\s*'DB_PASSWORD'.*?;", "define( 'DB_PASSWORD', '" + os.environ['DBPASS'] + "' );", s, count=1)
s = re.sub(r"define\(\s*'DB_CHARSET'.*?;",  "define( 'DB_CHARSET', 'utf8mb4' );",    s, count=1)
salts = open('/root/salts.txt').read()
if salts.strip():
    if not salts.endswith('\n'):
        salts += '\n'
    # 整段替换 AUTH_KEY ~ NONCE_SALT 共 8 个 define 行
    s = re.sub(r"define\(\s*'AUTH_KEY'.*?NONCE_SALT.*?;\n", salts, s, count=1, flags=re.S)
open(p, 'w').write(s)
print('>>> wp-config.php 已完成 5 处修改')
PY
rm -f /root/salts.txt

echo ""
echo "==== §9 部署 WordPress ===="
# 重跑保护：已安装站点的 wp-config.php 先备份，部署后原样恢复
# （否则会被新生成的配置覆盖，重跑时输入的密码与原库不一致会导致站点断库）
WP_CFG_BAK=""
if [ -f /var/www/html/wp-config.php ]; then
    WP_CFG_BAK="/root/wp-config.php.bak.$(date +%s)"
    cp /var/www/html/wp-config.php "$WP_CFG_BAK"
    echo ">>> 检测到已有 wp-config.php，已备份至 ${WP_CFG_BAK}"
fi
# 拷贝到站点根目录
cp -r /root/wordpress/* /var/www/html
if [ -n "$WP_CFG_BAK" ]; then
    cp "$WP_CFG_BAK" /var/www/html/wp-config.php
    echo ">>> 已恢复原 wp-config.php（站点配置与数据库对接保持不变）"
fi

# 修改属主（Nginx/PHP-FPM 以 www-data 运行，主题安装、上传、更新都需要写）
chown -R www-data:www-data /var/www/html

# 按机器内存自动选择图像引擎：小内存优先 GD（省内存更快），大内存保持 Imagick 优先
mkdir -p /var/www/html/wp-content/mu-plugins
cat > /var/www/html/wp-content/mu-plugins/wp-image-perf.php <<'PHP'
<?php
/**
 * Plugin Name: WP Image Perf (auto GD/Imagick by RAM)
 * Description: 按服务器 MemTotal 自动选择图像引擎；低内存时跳过超大中间尺寸。
 * Author: wordpress-deploy-kit
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * @return int 物理内存 MB；读不到时返回 0。
 */
function wpdk_memtotal_mb() {
	static $mb = null;
	if ( null !== $mb ) {
		return $mb;
	}
	$mb = 0;
	$info = @file_get_contents( '/proc/meminfo' );
	if ( is_string( $info ) && preg_match( '/^MemTotal:\s+(\d+)\s*kB/mi', $info, $m ) ) {
		$mb = (int) round( (int) $m[1] / 1024 );
	}
	return $mb;
}

/**
 * <2G：优先 GD；≥2G：保持 WP 默认（Imagick 优先）。
 */
add_filter(
	'wp_image_editors',
	static function ( $editors ) {
		$mem = wpdk_memtotal_mb();
		if ( $mem > 0 && $mem < 2048 ) {
			return array( 'WP_Image_Editor_GD', 'WP_Image_Editor_Imagick' );
		}
		return $editors;
	}
);

/**
 * 低内存机器跳过 1536/2048 中间图，减少上传后同步缩放耗时。
 */
add_filter(
	'intermediate_image_sizes_advanced',
	static function ( $sizes ) {
		$mem = wpdk_memtotal_mb();
		if ( $mem > 0 && $mem < 2048 ) {
			unset( $sizes['1536x1536'], $sizes['2048x2048'] );
		}
		return $sizes;
	}
);

/**
 * 保留并直接使用原分辨率全图（关闭 WP 默认的大图自动缩放 / -scaled）。
 */
add_filter( 'big_image_size_threshold', '__return_false' );
PHP
chown www-data:www-data /var/www/html/wp-content/mu-plugins/wp-image-perf.php
# 屏蔽用户枚举（REST /wp/v2/users 与 ?author=N 探测）——不影响正常功能，可删除文件回滚
cat > /var/www/html/wp-content/mu-plugins/block-user-enumeration.php <<'PHP'
<?php
/**
 * Plugin Name: Block User Enumeration
 * Description: Hides user listing/enumeration from unauthenticated visitors (REST /wp/v2/users routes and ?author=N probing). Delete this file to revert.
 * Version: 1.0
 */
defined( 'ABSPATH' ) || exit;

/* 1) REST API: remove the users routes for guests. */
add_filter( 'rest_endpoints', function ( $endpoints ) {
	if ( is_user_logged_in() ) {
		return $endpoints;
	}
	foreach ( array_keys( $endpoints ) as $route ) {
		if ( 0 === strpos( $route, '/wp/v2/users' ) ) {
			unset( $endpoints[ $route ] );
		}
	}
	return $endpoints;
} );

/* 2) ?author=N probing: never reveal an author slug to a guest. */
add_action( 'template_redirect', function () {
	if ( is_user_logged_in() || is_admin() ) {
		return;
	}
	if ( isset( $_GET['author'] ) ) {
		wp_safe_redirect( home_url( '/' ), 301 );
		exit;
	}
}, 1 );
PHP
chown www-data:www-data /var/www/html/wp-content/mu-plugins/block-user-enumeration.php

# 屏蔽 XML-RPC（system.multicall 密码放大器 / pingback 滥用）。
# 若使用 WordPress 手机 App 或 Jetpack（依赖 XML-RPC），部署前 export WPDK_ALLOW_XMLRPC=1
if [ "${WPDK_ALLOW_XMLRPC:-0}" = "1" ]; then
    echo ">>> 已按 WPDK_ALLOW_XMLRPC=1 保留 XML-RPC 端点"
else
    cat > /var/www/html/wp-content/mu-plugins/disable-xmlrpc.php <<'PHP'
<?php
/**
 * Plugin Name: Disable XML-RPC
 * Description: Fully disables the XML-RPC endpoint (blocks system.multicall password amplification and pingback abuse). Delete this file to revert.
 * Version: 1.0
 */
defined( 'ABSPATH' ) || exit;

/* 1) Hard block at request level: xmlrpc.php defines XMLRPC_REQUEST before loading wp-load.php. */
if ( defined( 'XMLRPC_REQUEST' ) && XMLRPC_REQUEST ) {
	http_response_code( 403 );
	header( 'Content-Type: text/plain; charset=utf-8' );
	exit( 'XML-RPC is disabled on this site.' );
}

/* 2) Defense in depth for internal callers. */
add_filter( 'xmlrpc_enabled', '__return_false' );
add_filter( 'xmlrpc_methods', function ( $methods ) {
	$kill = array( 'system.multicall', 'system.listMethods', 'pingback.ping', 'pingback.extensions.getPingbacks', 'wp.getUsersBlogs' );
	foreach ( $kill as $m ) {
		unset( $methods[ $m ] );
	}
	return $methods;
} );
PHP
    chown www-data:www-data /var/www/html/wp-content/mu-plugins/disable-xmlrpc.php
    echo ">>> 已写入 mu-plugin：屏蔽 XML-RPC（如需手机 App 管理，删除该文件即可恢复）"
fi

MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${MEM_MB}" -gt 0 ] && [ "${MEM_MB}" -lt 2048 ]; then
    echo ">>> 检测到内存约 ${MEM_MB}MB（<2G）：媒体处理优先 GD，跳过 1536/2048 大缩略图；原图不缩放"
else
    echo ">>> 检测到内存约 ${MEM_MB}MB：媒体处理保持 Imagick 优先；原图不缩放（mu-plugin 已就位）"
fi

# wp-config.php 含数据库密码，收紧为 root:www-data 640（拒绝其他用户读取）
if [ -f /var/www/html/wp-config.php ]; then
    if ! grep -q "define( *'DISALLOW_FILE_EDIT'" /var/www/html/wp-config.php; then
        cp -a /var/www/html/wp-config.php "/root/wp-config.php.pre-hardening.$(date +%s)"
    fi
    # 禁用后台「插件/主题文件编辑器」：后台被登入后也无法直接改代码，少一条 RCE 路径
    wp_config_define DISALLOW_FILE_EDIT true /var/www/html/wp-config.php
    chown root:www-data /var/www/html/wp-config.php
    chmod 640 /var/www/html/wp-config.php
fi
# 去掉 Nginx 默认主页，避免覆盖 WordPress
if [ -f /var/www/html/index.nginx-debian.html ]; then
    mv /var/www/html/index.nginx-debian.html /var/www/html/index.html
fi

# 重启 Nginx
/etc/init.d/nginx restart

# 部署后自动验证：302 = 未安装（跳转安装向导）；200/301 = 站点已安装并在运行（重跑场景）；
# 其余（404/500/000）视为异常。注意：重跑已安装的站点时首页会返回 200，不能只认 302——
# 否则脚本会在 §9 中途退出，而此时 §6 刚把站点配置重写成仅 80 端口、§10 还没给回 443，
# 结果是站点被留在"没有 HTTPS"的半途状态
sleep 1
WP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1/")
case "$WP_CODE" in
    302) echo ">>> 本机访问首页返回：302（未安装，将跳转 install.php 安装向导）" ;;
    200 | 301) echo ">>> 本机访问首页返回：${WP_CODE}（站点已安装并在运行，重跑正常）" ;;
    *) echo ">>> 首页返回码异常：${WP_CODE}，请检查 /var/www/html 与 nginx 配置"
       exit 1 ;;
esac

echo ""
echo "==== §10 HTTPS 证书申请与自动续期（Let's Encrypt / certbot） ===="
# 前提：域名已解析到本机且 80 端口公网可达；server_name 为裸 IP 时自动跳过
# 证书申请失败只告警不终止，不影响已部署的 HTTP 站点
if [ "$DOMAIN" = "$SERVER_IP" ]; then
    echo ">>> 未使用域名（server_name 为 IP），跳过 HTTPS；"
    echo ">>> 解析域名后运行：bash /root/cert_manage.sh reissue 即可补装"
else
    apt install certbot python3-certbot-nginx -y

    # 通知邮箱：留空则不注册邮箱（--register-unsafely-without-email）
    if [ -n "${EMAIL:-}" ]; then
        EMAIL_ARG="-m ${EMAIL} --no-eff-email"
    else
        EMAIL_ARG="--register-unsafely-without-email"
    fi

    if certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos ${EMAIL_ARG} --redirect; then
        echo ">>> 证书申请并安装成功（nginx 已自动改为 80→443 强制跳转）"

        # 自动定时续期：systemd certbot.timer 每天两次检查，到期前 30 天自动续
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        if systemctl list-timers --all 2>/dev/null | grep -q certbot; then
            echo ">>> 自动续期已就绪（systemd timer：certbot.timer）"
        else
            # 兜底：个别精简系统无 timer 时补 cron（每天 03:17 检查续期）
            cat > /etc/cron.d/certbot-renew <<'CRON'
17 3 * * * root certbot renew --quiet --deploy-hook "systemctl reload nginx"
CRON
            echo ">>> certbot.timer 不存在，已补 /etc/cron.d/certbot-renew 定时任务"
        fi

        # 续期成功后自动 reload nginx（certbot renew 触发 deploy 钩子）
        cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/bin/bash
systemctl reload nginx
HOOK
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
        echo ">>> 已配置续期钩子：renewal-hooks/deploy/reload-nginx.sh"

        # 续期演练（--dry-run 走 Let's Encrypt 测试环境，不消耗正式配额）
        if certbot renew --dry-run > /dev/null 2>&1; then
            echo ">>> 续期演练通过（certbot renew --dry-run OK）"
        else
            echo ">>> 续期演练失败（不影响证书使用），可运行 cert_manage.sh dryrun 查看详情"
        fi

        # HTTPS 实测
        sleep 1
        HTTPS_CODE=$(curl -s -o /dev/null -w '%{http_code}' "https://${DOMAIN}/" || echo 000)
        echo ">>> https://${DOMAIN}/ 返回：${HTTPS_CODE}（预期 200 或 302）"
    else
        echo ">>> 证书申请失败（常见原因：DNS 未生效/未指向本机、80 端口被运营商拦截）"
        echo ">>> HTTP 站点不受影响；DNS 生效后运行：bash /root/cert_manage.sh reissue"
    fi

    # 证书手动管理脚本：status=查看 / renew=续期 / force=强制重签 /
    # dryrun=续期演练 / reissue=重新申请安装（renew 临近到期才真正续）
    cat > /root/cert_manage.sh <<CEOF
#!/bin/bash
# HTTPS 证书手动管理（Let's Encrypt / certbot）—— 由 wp_deploy.sh 自动生成
# 用法：bash /root/cert_manage.sh {status|renew|force|dryrun|reissue}
set -e
DOMAIN="${DOMAIN}"
# 443 已被独立的 TCP 网关（nginx stream）接管时，certbot --nginx 安装器会往站点块里补
# listen 443 ssl 而抢占 443；这种情况改用 certonly：只取证书、不改 nginx 配置。
nginx_443_taken() {
    [ -f /etc/nginx/nginx.conf ] || return 1
    awk '
        /^[[:space:]]*stream[[:space:]]*\{/ { in_stream = 1 }
        in_stream {
            nopen  = gsub(/\{/, "{")
            nclose = gsub(/\}/, "}")
            depth += nopen - nclose
            if (\$0 ~ /listen[[:space:]]+(\[::\]:)?443([^0-9]|\$)/) hit = 1
            if (depth <= 0) {
                if (hit) exit 0
                in_stream = 0; depth = 0; hit = 0
            }
        }
        END { exit (hit ? 0 : 1) }
    ' /etc/nginx/nginx.conf 2> /dev/null
}
case "\$1" in
    status)  certbot certificates ;;
    renew)   certbot renew && systemctl reload nginx ;;
    force)   certbot renew --force-renewal && systemctl reload nginx ;;
    dryrun)  certbot renew --dry-run ;;
    reissue)
        if nginx_443_taken; then
            certbot certonly --nginx -d "\${DOMAIN}" --non-interactive --agree-tos ${EMAIL_ARG} && systemctl reload nginx
        else
            certbot --nginx -d "\${DOMAIN}" --non-interactive --agree-tos ${EMAIL_ARG} --redirect && systemctl reload nginx
        fi
        ;;
    *)       echo "用法: \$0 {status|renew|force|dryrun|reissue}"; exit 1 ;;
esac
CEOF
    chmod 700 /root/cert_manage.sh   # 含域名与证书通知邮箱，收紧为仅 root
    echo ">>> 证书手动管理脚本已生成：/root/cert_manage.sh"
fi

echo ""
echo "==== §11 安全基线与体检（幂等；失败只告警，不影响站点） ===="

# 11.1 无人值守安全更新（只装安全更新、不自动重启；低配机器同样建议开启）
if ! dpkg -s unattended-upgrades > /dev/null 2>&1; then
    apt install unattended-upgrades -y || echo ">>> 警告：unattended-upgrades 安装失败，请稍后手动开启"
fi
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AUTOUP'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
AUTOUP
systemctl enable --now unattended-upgrades > /dev/null 2>&1 || true
echo ">>> 已开启无人值守安全更新（/etc/apt/apt.conf.d/20auto-upgrades）"
if [ "$(lsb_release -rs 2> /dev/null)" = "20.04" ]; then
    echo ">>> 提示：Ubuntu 20.04 标准支持已于 2025-05 结束；如需继续获取安全补丁，"
    echo "          可免费启用 Ubuntu Pro / ESM：pro attach <你的 token>（≤5 台免费）"
fi

# 11.2 logrotate 体检（MySQL 片段的 postrotate 依赖 /etc/mysql/debian.cnf，§3 已回填口令）
if logrotate -d /etc/logrotate.d/mysql-server > /dev/null 2>&1; then
    echo ">>> logrotate MySQL 片段可正常解析"
fi
if systemctl is-failed logrotate.service > /dev/null 2>&1; then
    echo ">>> 检测到 logrotate.service 为 failed，强制执行一次以确认修复效果……"
    if logrotate -f /etc/logrotate.d/mysql-server 2> /tmp/wpdk.logrotate.err; then
        systemctl start logrotate.service > /dev/null 2>&1 || true
        echo ">>> logrotate MySQL 片段执行成功（此前每天午夜都会失败）"
    else
        echo ">>> 警告：logrotate MySQL 片段仍失败，原因："
        sed 's/^/      /' /tmp/wpdk.logrotate.err || true
    fi
    rm -f /tmp/wpdk.logrotate.err
else
    echo ">>> logrotate.service 状态正常"
fi

# 11.3 SSH 加固：仅当 authorized_keys 中已有公钥时才启用（避免把自己锁在门外）
SSH_STATE="未改动（未检测到公钥）"
if [ "${WPDK_SKIP_SSH_HARDEN:-0}" = "1" ]; then
    SSH_STATE="已按 WPDK_SKIP_SSH_HARDEN=1 跳过"
elif [ -s /root/.ssh/authorized_keys ] && grep -qE '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys; then
    SSH_DROPIN=/etc/ssh/sshd_config.d/99-hardening.conf
    mkdir -p /etc/ssh/sshd_config.d
    cat > "$SSH_DROPIN" <<'SSHD'
# 仅密钥登录 + 抗爆破（由 wp_deploy.sh 写入）
# 回滚：rm -f /etc/ssh/sshd_config.d/99-hardening.conf && sshd -t && systemctl reload ssh
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 20
MaxStartups 10:30:60
SSHD
    chmod 644 "$SSH_DROPIN"
    if sshd -t > /dev/null 2>&1; then
        SSH_DEADMAN=""
        if [ -t 0 ] && command -v at > /dev/null 2>&1; then
            SSH_ROLLBACK=/root/ssh-hardening-rollback.sh
            printf '#!/bin/bash\nrm -f %s\nsshd -t && systemctl reload ssh\n' "$SSH_DROPIN" > "$SSH_ROLLBACK"
            chmod 700 "$SSH_ROLLBACK"
            if echo "$SSH_ROLLBACK" | at now + 15 minutes > /dev/null 2>&1; then
                SSH_DEADMAN=$(atq 2> /dev/null | tail -n1 | awk '{print $1}')
            fi
        fi
        if systemctl reload ssh > /dev/null 2>&1 || systemctl reload sshd > /dev/null 2>&1; then
            if sshd -T 2> /dev/null | grep -qi '^passwordauthentication no'; then
                SSH_STATE="已启用（仅密钥登录，密码登录已关闭）"
            else
                SSH_STATE="配置已写入但未生效，请检查 sshd -T"
            fi
        else
            SSH_STATE="已写入但 reload 失败，请手动执行 systemctl reload ssh"
        fi
        if [ -n "${SSH_DEADMAN:-}" ]; then
            echo ">>> SSH 加固已应用。保险：15 分钟后自动回滚（at 任务 ${SSH_DEADMAN}）"
            echo "    请立刻用密钥另开一个连接验证；确认可用后执行：atrm ${SSH_DEADMAN}"
            echo "    若暂时无法用密钥登录，等 15 分钟会自动恢复密码登录。"
        fi
    else
        rm -f "$SSH_DROPIN"
        SSH_STATE="跳过（sshd 配置检查未通过，未改动任何 SSH 配置）"
    fi
fi

# 11.4 凭据落盘（root 600，便于运维取用）
CRED_FILE="/root/wp-credentials-${DOMAIN}.txt"
umask 077
cat > "$CRED_FILE" <<CRED
# 由 wp_deploy.sh 于 $(date '+%F %T') 生成（权限 600，仅 root 可读）
域名/访问地址 : ${DOMAIN}
服务器公网 IP : ${SERVER_IP}
数据库名/用户 : wordpress / wordpress
数据库密码    : ${DBPASS}
MariaDB root  : ${ROOTPW}
站点根目录    : /var/www/html
证书管理      : bash /root/cert_manage.sh {status|renew|force|dryrun|reissue}
CRED
chmod 600 "$CRED_FILE"
echo ">>> 凭据已写入 ${CRED_FILE}（600）；请勿把含明文口令的部署过程日志长期留在服务器上"

# 11.5 部署后体检（只报告，不因失败中断）
echo "---------------- 体检结果 ----------------"
if nginx -t > /dev/null 2>&1; then echo "  [OK] nginx 配置语法"; else echo "  [!!] nginx 配置语法异常"; fi
# 注意：装好证书后 80 端口的 default_server 对 IP 主机名返回 404，所以这里按域名走 443 探测；
# --resolve 指到 127.0.0.1，既不依赖 DNS 也不依赖 hairpin
WP_CODE_FINAL=$(curl -sk --resolve "${DOMAIN}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${DOMAIN}/" 2>/dev/null || echo 000)
case "$WP_CODE_FINAL" in
    200 | 301 | 302) echo "  [OK] https://${DOMAIN}/ → ${WP_CODE_FINAL}" ;;
    000) echo "  [--] 未能探测站点（HTTP 模式或证书未就绪）" ;;
    *) echo "  [!!] https://${DOMAIN}/ → ${WP_CODE_FINAL}" ;;
esac
if mysqladmin --defaults-file=/etc/mysql/debian.cnf --local status > /dev/null 2>&1; then
    echo "  [OK] /etc/mysql/debian.cnf 可用（logrotate 不会再报错）"
else
    echo "  [!!] /etc/mysql/debian.cnf 不可用（logrotate 会报错）"
fi
if systemctl is-failed mariadb > /dev/null 2>&1; then echo "  [!!] mariadb 处于 failed"; else echo "  [OK] mariadb 运行正常"; fi
if systemctl is-failed logrotate.service > /dev/null 2>&1; then echo "  [!!] logrotate.service 仍为 failed"; else echo "  [OK] logrotate.service 正常"; fi
if [ -f /var/www/html/wp-content/mu-plugins/disable-xmlrpc.php ]; then echo "  [OK] XML-RPC 已屏蔽"; else echo "  [--] XML-RPC 保留（WPDK_ALLOW_XMLRPC=1）"; fi
echo "  [--] SSH：${SSH_STATE}"
echo "-----------------------------------------"
echo ""
echo "============================================================"
echo "  §2~§11 全部执行完毕 —— 关键配置信息（请记录备份）"
echo "============================================================"
echo "  域名/访问地址   : ${DOMAIN}"
echo "  服务器公网 IP   : ${SERVER_IP}"
echo "  WordPress 站点  : http://${DOMAIN}/  （浏览器打开进入安装向导）"
echo "  WordPress 后台  : http://${DOMAIN}/wp-admin"
echo "  站点根目录      : /var/www/html  （属主 www-data:www-data）"
echo "  Nginx 配置文件  : /etc/nginx/sites-available/default"
echo "  PHP-FPM sock    : ${PHP_SOCK}"
echo "  数据库类型      : MariaDB（默认仅本机监听，未开放 3306 公网）"
echo "  数据库名        : wordpress"
echo "  数据库用户      : wordpress"
echo "  数据库密码      : ${DBPASS}"
echo "  数据库主机      : localhost"
echo "  表字符集/排序   : utf8mb4 / utf8mb4_general_ci"
echo "  wp-config.php   : /var/www/html/wp-config.php（含随机 Salts）"
echo "  MariaDB root    : ${ROOTPW}"
echo "  HTTPS 证书      : /etc/letsencrypt/live/${DOMAIN}/（§10 成功时；HTTP 已强制跳 HTTPS）"
echo "  自动续期        : certbot.timer 每天检查两次 + deploy 钩子自动 reload nginx"
echo "  证书手动管理    : bash /root/cert_manage.sh {status|renew|force|dryrun|reissue}"
echo "  凭据文件        : ${CRED_FILE}（600，含数据库与 MariaDB root 口令）"
echo "  凭据/日志提醒   : 部署过程日志含明文口令，请勿长期留存（建议 chmod 600 或删除）"
echo "  SSH 登录        : ${SSH_STATE}"
echo "  回滚 SSH 加固   : rm -f /etc/ssh/sshd_config.d/99-hardening.conf && sshd -t && systemctl reload ssh"
echo "  XML-RPC         : 默认已屏蔽（WP 手机 App 需使用时删除 mu-plugins/disable-xmlrpc.php）"
echo "------------------------------------------------------------"
echo "  下一步：浏览器打开站点地址，按 WordPress 安装向导完成初始化"
echo "============================================================"
