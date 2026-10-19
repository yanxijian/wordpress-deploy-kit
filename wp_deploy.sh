#!/bin/bash
#===============================================================
# wp_deploy.sh - one-command WordPress deployment (Nginx + MariaDB + PHP-FPM + HTTPS)
#
# Target: a fresh Ubuntu 20.04 (recommended) / 22.04 / 24.04, run as root
# Note: on a low-spec VPS prefer 20.04 - newer releases ship heavier components and use more memory,
#             so installation or normal operation can stall or hang on a small machine
#
# Flow:
#     §2  install Nginx               §6  configure Nginx (FastCGI)
#     §3  install and harden MariaDB  §7  automated probe
#     §4  create the WordPress DB    §8  download and configure WordPress
#     §5  install PHP-FPM            §9  deploy and go live
#                                                                  §10 Let's Encrypt certificate and auto-renewal (with a domain)
#                                                                  §11 security baseline and health check (logrotate credentials / no PHP in uploads /
#                                                                          mu-plugin hardening / unattended updates / optional SSH key-only hardening)
#
# Five prompts up front: domain (Enter = public IP), MariaDB root password,
# database password (Enter for either = generate), HTTPS notification email (Enter = none), confirmation.
# Piped answers are supported for unattended runs.
#
# Environment switches (defaults are the recommended values; none changes the deployment flow):
#     WPDK_ALLOW_XMLRPC=1     keep the XML-RPC endpoint (blocked by default; required for the WP mobile app / Jetpack)
#     WPDK_SKIP_SSH_HARDEN=1  skip the "key-only login" hardening (on by default when a public key exists)
#
# Fault tolerance: set -e + ERR trap stop at the first failure; a corrupt MariaDB data directory is rebuilt;
# WordPress is downloaded from several sources (local archive first); empty passwords are generated; an already deployed machine can rerun safely.
#===============================================================
set -e
trap 'echo ">>> 部署在第 ${LINENO} 行失败，请检查上方错误信息"; exit 1' ERR

#---- helper functions ----
# Generate an 8-character random password (digits + upper/lower case; redraw until all three classes appear)
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

# Whether nginx.conf already has a stream block on 443 (443 is taken over by a TCP gateway and the site
# can only listen on an internal port). This reads the config only, no external marker, so the script stays self-contained.
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

# Rerun compatibility: a fresh install has no MariaDB root password; on a rerun root already has one (§3 set it).
# Both cases work: try a password-less login first, then retry with ROOTPW
mysql_run() {
    if mysql -uroot -e 'SELECT 1;' > /dev/null 2>&1; then
        mysql -uroot "$@"
    else
        mysql -uroot -p"${ROOTPW}" "$@"
    fi
}


# Idempotently set a PHP-FPM pool parameter (rewrite an existing line, commented lines included; otherwise append)
# Usage: fpm_set <key> <value> <pool config file>
fpm_set() {
    local key="$1" val="$2" conf="$3"
    if grep -qE "^[;[:space:]]*${key}[[:space:]]*=" "$conf"; then
        sed -i -E "s|^[;[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "$conf"
    else
        printf '\n%s = %s\n' "$key" "$val" >> "$conf"
    fi
}

# Idempotently write a wp-config.php constant (skip when the same define already exists, so reruns do not stack)
# Usage: wp_config_define <constant> <PHP literal> <wp-config.php path>
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
#---- deployment parameters (every interactive point lives here) ----
read -rp "请输入域名（如 example.com；直接回车 = 用公网 IP 作为 server_name）: " DOMAIN

# Public IP auto-detection, no manual input: ifconfig.me -> ipify -> local NIC
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

# MariaDB root password (Enter = generate) - replaces the interactive mysql_secure_installation
read -rsp "设置 MariaDB root 密码（直接回车 = 自动生成 8 位随机密码）: " ROOTPW
echo ""
[ -n "$ROOTPW" ] || ROOTPW=$(gen_password)

# Password for the wordpress database user (Enter = generate)
read -rsp "为数据库用户 wordpress 设置密码（直接回车 = 自动生成 8 位随机密码）: " DBPASS
echo ""
[ -n "$DBPASS" ] || DBPASS=$(gen_password)

# HTTPS notification email (Enter = register no email; renewal still works, you just get no expiry mail)
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

# Preflight block: when nginx already uses stream on 443 (the site listens on an internal port) this script must not rerun -
# §6 would rewrite the site config back to port 80 only, and §10 would let certbot take 443 again,
# breaking both the working takeover config and the site. Roll the takeover back first, rerun, then redeploy.
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

# Start the service and enable it at boot
systemctl start nginx
systemctl enable nginx > /dev/null
echo ">>> 验证：浏览器访问 http://${DOMAIN} 应看到 'Welcome to nginx!'"

echo ""
echo "==== §3 安装 MariaDB ===="
apt install mariadb-server -y

# Rebuild the data directory when startup fails (an interrupted apt install can leave the system tables broken)
if ! systemctl start mariadb; then
    echo ">>> MariaDB 启动失败，尝试重建数据目录后重试……"
    systemctl stop mariadb 2> /dev/null || true
    rm -rf /var/lib/mysql/*
    mysql_install_db --user=mysql --datadir=/var/lib/mysql
    systemctl start mariadb
fi
systemctl enable mariadb > /dev/null

# Wait for the socket (up to 30 s) so the SQL stage does not fail to connect
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
# This ping only checks reachability: on a rerun root already has a password, so a failed auth logs an Access denied noise line (exit code is still 0)
mysqladmin --socket=/run/mysqld/mysqld.sock ping 2> /dev/null || true

# Hardening: equivalent to mysql_secure_installation, but non-interactive and portable across versions
# (set the root password / drop anonymous users / drop the test database; root may only log in locally)
mysql_run <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOTPW}';
DROP USER IF EXISTS ''@'localhost';
DROP USER IF EXISTS ''@'%';
DROP USER IF EXISTS ''@'$(hostname)' ;
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db LIKE 'test%';
FLUSH PRIVILEGES;
SQL
# Verify the root password works
mysql -uroot -p"${ROOTPW}" -e "SELECT 'MARIADB_SECURE_OK' AS status;"
echo ">>> §3 完成：root 密码已设置，匿名用户/test 库已移除，root 仅限本机"

# Debian maintenance scripts (the logrotate mysql snippet, init scripts) connect through /etc/mysql/debian.cnf.
# The default content is "root + empty password", but root was just switched to password auth -> logrotate would fail every day.
# Backfill the real password here (600 root:root) and verify it once; when the content already matches, nothing changes.
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
# utf8mb4 fully supports 4-byte characters such as emoji
# Keep CREATE USER and GRANT separate (GRANT ... IDENTIFIED BY is deprecated in recent versions)
mysql_run -e "CREATE DATABASE IF NOT EXISTS wordpress CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
mysql -uroot -p"${ROOTPW}" -e "CREATE USER IF NOT EXISTS 'wordpress'@'localhost' IDENTIFIED BY '${DBPASS}';"
mysql -uroot -p"${ROOTPW}" -e "GRANT ALL ON wordpress.* TO 'wordpress'@'localhost';"
mysql -uroot -p"${ROOTPW}" -e "FLUSH PRIVILEGES;"
# Log in as the new user to verify it works
mysql -uwordpress -p"${DBPASS}" wordpress -e "SELECT 'WP_DB_OK' AS status;"
echo ">>> 已创建：库 wordpress / 用户 wordpress / utf8mb4_general_ci"

echo ""
echo "==== §5 安装 PHP（不指定版本号，发行版最新稳定版） ===="
# gd/imagick: media-library uploads and thumbnails; the rest are common WordPress extensions (REST / updates / translations / backup zips)
apt install php-fpm php-mysql php-gd php-imagick php-mbstring php-xml php-curl php-zip php-intl python3 -y

# Raise the PHP upload limits (defaults are upload 2M / post 8M; backup plugins and large media fail with 413)
PHP_INI=$(ls /etc/php/*/fpm/php.ini | head -n1)
sed -i "s/^upload_max_filesize.*/upload_max_filesize = 512M/" "$PHP_INI"
sed -i "s/^post_max_size.*/post_max_size = 512M/" "$PHP_INI"
PHP_VER=$(ls /etc/php | head -n1)

# PHP-FPM pool tuning (idempotent): a low-memory VPS defaults to pm=dynamic / max_children=5, which returns 503 when
# concurrency peaks or wp-cron saturates the pool; these are conservative values derived from physical RAM, with ondemand so idle children exit
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

# Low-memory optimisation (only when physical RAM < 1G; larger machines keep the distribution defaults):
#     (1) create a 1G swapfile when there is none - a single memory spike on a 0.4G box is an OOM kill
#     (2) narrow the PHP-FPM memory_limit to 128M when it is -1/0 or above 128M -
#             one request eating all the RAM is the classic way these machines die (already 128M: no-op)
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
# Without gd/imagick, media-library uploads fail silently (WordPress requires at least one image extension)
if ! php -m | grep -qiE '^(gd|imagick)$'; then
    echo ">>> 警告：未检测到 php-gd / php-imagick，媒体库图片上传将不可用"
fi

# Detect the actual PHP-FPM socket path (the socket name differs between Ubuntu releases)
ls /run/php/
if [ -e /run/php/php-fpm.sock ]; then
    PHP_SOCK="/run/php/php-fpm.sock"                      # prefer the default socket
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
# Rewrite sites-available/default: add index.php to index / use the domain in server_name /
# point the php location's fastcgi_pass at the real socket
cp /etc/nginx/sites-available/default "/etc/nginx/sites-available/default.bak.$(date +%s)"
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    index index.php index.html index.htm index.nginx-debian.html;

    #     Allow large uploads (backup packages, media); the nginx default of 1m causes 413
    client_max_body_size 512m;

    #     Do not append the internal port to the directory-slash redirect
    #     (visitors cannot reach that port)
    port_in_redirect off;
    absolute_redirect off;

    server_name ${DOMAIN};

    #     Hide the nginx version to reduce version probing
    server_tokens off;

    #     The upload directory serves static files only: a .php file written there never executes (the most common shell path)
    location ^~ /wp-content/uploads/ {
        location ~* \.(php|phtml|php[0-9]|phar)$ { deny all; }
    }

    #     Block version-probing and sensitive files from direct access
    location = /readme.html { deny all; }
    location = /wp-config.php { deny all; }

    location / {
        #         WordPress permalinks and the REST API (/wp-json) need the index.php fallback
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

# Validate the configuration syntax
nginx -t
# Apply the new configuration
systemctl reload nginx

echo ""
echo "==== §7 测试 PHP 与 Nginx 集成（自动探针） ===="
# Local curl probe verifying the Nginx <-> PHP-FPM path
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
# Download order: an already uploaded local archive -> the official downloads endpoint -> the Huawei Cloud mirror -> cn.wordpress.org -> wordpress.org
# (mirror paths change often and rate limiting returns 429 or an HTML error page: a wget exit code of 0 does not mean the
#    content is right, so the gzip archive must be validated with tar -tzf, otherwise try the next source)
WP_TGZ="/root/wp_latest_zh.tar.gz"
if [ ! -f "$WP_TGZ" ]; then
    for URL in https://downloads.wordpress.org/release/zh_CN/wordpress-latest.tar.gz \
               https://mirrors.huaweicloud.com/wordpress/latest-zh_CN.tar.gz \
               https://cn.wordpress.org/latest-zh_CN.tar.gz \
               https://wordpress.org/latest-zh_CN.tar.gz; do
        echo ">>> 尝试下载：${URL}"
        #         -O pins the output path: each source uses a different file name, so everything lands in $WP_TGZ for validation and reuse
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
# Compatibility: a manual scp that kept the original name latest-zh_CN.tar.gz
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

# Prepare the config file
mv /root/wordpress/wp-config-sample.php /root/wordpress/wp-config.php

# wp-config.php needs five edits: DB_NAME / DB_USER / DB_PASSWORD / DB_CHARSET / Salts
# Passwords travel to python through environment variables to avoid several layers of escaping
curl -s --max-time 15 https://api.wordpress.org/secret-key/1.1/salt/ > /root/salts.txt
# Fallback: when the official API is unreachable, generate eight random salts locally (same format as the API, equally safe)
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
    #     Replace the whole AUTH_KEY .. NONCE_SALT block of eight define lines
    s = re.sub(r"define\(\s*'AUTH_KEY'.*?NONCE_SALT.*?;\n", salts, s, count=1, flags=re.S)
open(p, 'w').write(s)
print('>>> wp-config.php 已完成 5 处修改')
PY
rm -f /root/salts.txt

echo ""
echo "==== §9 部署 WordPress ===="
# Rerun protection: back up wp-config.php of an installed site and restore it verbatim afterwards
# (otherwise the freshly generated config overwrites it and a different password disconnects the site from its database)
WP_CFG_BAK=""
if [ -f /var/www/html/wp-config.php ]; then
    WP_CFG_BAK="/root/wp-config.php.bak.$(date +%s)"
    cp /var/www/html/wp-config.php "$WP_CFG_BAK"
    echo ">>> 检测到已有 wp-config.php，已备份至 ${WP_CFG_BAK}"
fi
# Copy to the site root
cp -r /root/wordpress/* /var/www/html
if [ -n "$WP_CFG_BAK" ]; then
    cp "$WP_CFG_BAK" /var/www/html/wp-config.php
    echo ">>> 已恢复原 wp-config.php（站点配置与数据库对接保持不变）"
fi

# Set the owner (Nginx/PHP-FPM run as www-data and need write access for theme installs, uploads and updates)
chown -R www-data:www-data /var/www/html

# Pick the image engine from installed memory: small machines prefer GD (cheaper and faster), large ones keep Imagick first
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
# Block user enumeration (REST /wp/v2/users and ?author=N probing) - normal features keep working; delete the file to roll back
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

# Block XML-RPC (system.multicall password amplification / pingback abuse).
# For the WordPress mobile app or Jetpack (both need XML-RPC), export WPDK_ALLOW_XMLRPC=1 before deploying
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

# wp-config.php holds the database password: restrict it to root:www-data 640 (other users cannot read it)
if [ -f /var/www/html/wp-config.php ]; then
    if ! grep -q "define( *'DISALLOW_FILE_EDIT'" /var/www/html/wp-config.php; then
        cp -a /var/www/html/wp-config.php "/root/wp-config.php.pre-hardening.$(date +%s)"
    fi
    #     Disable the dashboard plugin/theme file editor: even a compromised admin cannot edit code, removing one RCE path
    wp_config_define DISALLOW_FILE_EDIT true /var/www/html/wp-config.php
    chown root:www-data /var/www/html/wp-config.php
    chmod 640 /var/www/html/wp-config.php
fi
# Remove the default nginx page so it does not shadow WordPress
if [ -f /var/www/html/index.nginx-debian.html ]; then
    mv /var/www/html/index.nginx-debian.html /var/www/html/index.html
fi

# Restart nginx
/etc/init.d/nginx restart

# Post-deploy verification: 302 = not installed (redirect to the wizard); 200/301 = installed and running (rerun case);
# anything else (404/500/000) is a failure. Note: a rerun against an installed site returns 200 on the home page, so
# accepting only 302 would abort in the middle of §9 - §6 has just rewritten the config to port 80 only and §10 has
# not restored 443 yet, leaving the site without HTTPS
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
# Preconditions: the domain resolves here and port 80 is reachable; skipped automatically when server_name is a bare IP
# A failed certificate request only warns and does not stop: the HTTP site keeps working
if [ "$DOMAIN" = "$SERVER_IP" ]; then
    echo ">>> 未使用域名（server_name 为 IP），跳过 HTTPS；"
    echo ">>> 解析域名后运行：bash /root/cert_manage.sh reissue 即可补装"
else
    apt install certbot python3-certbot-nginx -y

    #     Notification email: empty means register without an email (--register-unsafely-without-email)
    if [ -n "${EMAIL:-}" ]; then
        EMAIL_ARG="-m ${EMAIL} --no-eff-email"
    else
        EMAIL_ARG="--register-unsafely-without-email"
    fi

    if certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos ${EMAIL_ARG} --redirect; then
        echo ">>> 证书申请并安装成功（nginx 已自动改为 80→443 强制跳转）"

        #         Automatic renewal: the systemd certbot.timer checks twice a day and renews 30 days before expiry
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        if systemctl list-timers --all 2>/dev/null | grep -q certbot; then
            echo ">>> 自动续期已就绪（systemd timer：certbot.timer）"
        else
            #             Fallback: add a cron entry when a minimal system has no timer (check daily at 03:17)
            cat > /etc/cron.d/certbot-renew <<'CRON'
17 3 * * * root certbot renew --quiet --deploy-hook "systemctl reload nginx"
CRON
            echo ">>> certbot.timer 不存在，已补 /etc/cron.d/certbot-renew 定时任务"
        fi

        #         Reload nginx after a successful renewal (certbot renew fires the deploy hook)
        cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/bin/bash
systemctl reload nginx
HOOK
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
        echo ">>> 已配置续期钩子：renewal-hooks/deploy/reload-nginx.sh"

        #         Renewal rehearsal (--dry-run uses the Let's Encrypt staging environment and spends no quota)
        if certbot renew --dry-run > /dev/null 2>&1; then
            echo ">>> 续期演练通过（certbot renew --dry-run OK）"
        else
            echo ">>> 续期演练失败（不影响证书使用），可运行 cert_manage.sh dryrun 查看详情"
        fi

        #         HTTPS smoke test
        sleep 1
        HTTPS_CODE=$(curl -s -o /dev/null -w '%{http_code}' "https://${DOMAIN}/" || echo 000)
        echo ">>> https://${DOMAIN}/ 返回：${HTTPS_CODE}（预期 200 或 302）"
    else
        echo ">>> 证书申请失败（常见原因：DNS 未生效/未指向本机、80 端口被运营商拦截）"
        echo ">>> HTTP 站点不受影响；DNS 生效后运行：bash /root/cert_manage.sh reissue"
    fi

    #     Certificate management helper: status=show / renew=renew / force=force reissue /
    #     dryrun=rehearsal / reissue=reissue and install (renew only acts near expiry)
    cat > /root/cert_manage.sh <<CEOF
#!/bin/bash
# HTTPS certificate management (Let's Encrypt / certbot) - generated by wp_deploy.sh
# Usage: bash /root/cert_manage.sh {status|renew|force|dryrun|reissue}
set -e
DOMAIN="${DOMAIN}"
# When 443 is taken over by a TCP gateway (nginx stream), the certbot --nginx installer would add
# listen 443 ssl to the site block and grab 443; in that case use certonly: fetch the certificate only, leave nginx alone.
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
    chmod 700 /root/cert_manage.sh   # holds the domain and the certificate notification email: restrict to root
    echo ">>> 证书手动管理脚本已生成：/root/cert_manage.sh"
fi

echo ""
echo "==== §11 安全基线与体检（幂等；失败只告警，不影响站点） ===="

# 11.1 Unattended security updates (security updates only, no automatic reboot; recommended on small boxes too)
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

# 11.2 logrotate check (the MySQL snippet's postrotate depends on /etc/mysql/debian.cnf, which §3 backfilled)
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

# 11.3 SSH hardening: only when authorized_keys already holds a public key (avoids locking yourself out)
SSH_STATE="未改动（未检测到公钥）"
if [ "${WPDK_SKIP_SSH_HARDEN:-0}" = "1" ]; then
    SSH_STATE="已按 WPDK_SKIP_SSH_HARDEN=1 跳过"
elif [ -s /root/.ssh/authorized_keys ] && grep -qE '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys; then
    SSH_DROPIN=/etc/ssh/sshd_config.d/99-hardening.conf
    mkdir -p /etc/ssh/sshd_config.d
    cat > "$SSH_DROPIN" <<'SSHD'
# Key-only login + brute-force resistance (written by wp_deploy.sh)
# Rollback: rm -f /etc/ssh/sshd_config.d/99-hardening.conf && sshd -t && systemctl reload ssh
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

# 11.4 Write credentials to disk (root 600, handy for operations)
CRED_FILE="/root/wp-credentials-${DOMAIN}.txt"
umask 077
cat > "$CRED_FILE" <<CRED
# Generated by wp_deploy.sh at $(date '+%F %T') (mode 600, root only)
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

# 11.5 Post-deploy health check (reports only, never aborts)
echo "---------------- 体检结果 ----------------"
if nginx -t > /dev/null 2>&1; then echo "  [OK] nginx 配置语法"; else echo "  [!!] nginx 配置语法异常"; fi
# Note: with a certificate installed, the default_server on port 80 answers 404 for IP hostnames, so probe 443 by domain;
# --resolve points at 127.0.0.1, depending on neither DNS nor hairpin
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
