#!/usr/bin/env bash
# ============================================================
#  wp_restore.sh -- full restore from a wp_backup.sh archive
#
#  Prerequisite: the target host runs the same OS release (Ubuntu 20.04 focal)
#  Restores: database, web root, nginx/php/mysql/ssh configuration, TLS material and xray
#
#  Usage (root):
#    bash wp_restore.sh /root/wpbackups/wpbackup-<domain>-<timestamp>.tar.gz
#    _SKIP_APT_=1 bash wp_restore.sh <archive>   # dependencies already installed
#
#  Design notes:
#   - stop services before overwriting configuration so no process keeps old state
#   - the dump uses --all-databases, so the mysql schema (users/grants) comes back
#   - the web root is replaced wholesale; wp-config.php becomes 640 root:www-data
#   - xray config, key, node URL and binary are restored; the node URL is rewritten
#     when the public IP changed, and a verification checklist runs at the end
# ============================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ARCHIVE="${1:-}"
SKIP_APT="${_SKIP_APT_:-0}"
red='\e[91m'; green='\e[92m'; yellow='\e[93m'; cyan='\e[96m'; none='\e[0m'
info(){ echo -e "${green}>>>${none} $*"; }
warn(){ echo -e "${yellow}>>>${none} $*"; }
die(){ echo -e "${red}>>> 错误：$*${none}" >&2; exit 1; }
LINE="----------------------------------------------------------------"

[ "$(id -u)" -eq 0 ] || die "请以 root 运行"
[ -n "$ARCHIVE" ] || die "用法: bash wp_restore.sh <归档.tar.gz>"
[ -f "$ARCHIVE" ] || die "找不到归档：$ARCHIVE"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==== §1 校验归档 ===="
if [ -f "${ARCHIVE}.sha256" ]; then
  # Compare the digest itself (independent of the archive file name)
  EXPECT=$(awk '{print $1}' "${ARCHIVE}.sha256" | head -1)
  ACTUAL=$(sha256sum "$ARCHIVE" | awk '{print $1}')
  if [ -n "$EXPECT" ] && [ "$EXPECT" = "$ACTUAL" ]; then
    info "sha256 校验通过"
  else
    die "sha256 校验失败（期望 ${EXPECT:0:16}… 实际 ${ACTUAL:0:16}…）"
  fi
else
  warn "未找到 .sha256 文件，跳过哈希校验"
fi
tar tzf "$ARCHIVE" > "$WORK/list" || die "归档损坏（tar 无法读取）"
for f in db.sql www.tar.gz etc.tar.gz manifest.txt; do
  grep -qx "./$f" "$WORK/list" || die "归档缺少 $f"
done
tar xzf "$ARCHIVE" -C "$WORK"
info "归档解包完成"
echo "  --- 备份来源信息 ---"
grep -E 'domain|backup_time|PRETTY|wp_version' "$WORK/manifest.txt" 2>/dev/null | sed 's/^/    /' || true

echo "==== §2 安装同套件（focal 默认版本） ===="
if [ "$SKIP_APT" = "1" ]; then
  warn "已跳过 apt（_SKIP_APT_=1）"
else
  apt-get update -qq || warn "apt update 失败，继续"
  # Same package set as wordpress-deploy-kit; libnginx-mod-stream is required
  apt-get install -y nginx mariadb-server php-fpm php-mysql php-gd php-mbstring \
    php-xml php-curl php-zip php-intl libnginx-mod-stream certbot python3-certbot-nginx \
    qrencode unzip curl >/dev/null 2>&1 || die "依赖安装失败"
  info "依赖安装完成：$(nginx -v 2>&1 | sed 's/nginx version: //') / PHP $(php -r 'echo PHP_VERSION;')"
fi

echo "==== §3 停止服务 + 还原系统配置 ===="
systemctl stop xray 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
systemctl stop php7.4-fpm 2>/dev/null || true
systemctl stop mariadb 2>/dev/null || true
tar xzf "$WORK/etc.tar.gz" -C / --numeric-owner
info "配置已还原（nginx / php / mysql / ssh / cron / xray unit）"

echo "==== §4 还原证书 ===="
if [ -f "$WORK/le.tar.gz" ]; then
  tar xzf "$WORK/le.tar.gz" -C / --numeric-owner
  info "证书已还原：$(ls -1 /etc/letsencrypt/live/ 2>/dev/null | grep -v README | tr '\n' ' ')"
else
  warn "归档里没有证书，将走 HTTP-only"
fi

echo "==== §5 还原站点文件 ===="
rm -rf /var/www/html
tar xzf "$WORK/www.tar.gz" -C / --numeric-owner
chown -R www-data:www-data /var/www/html
if [ -f /var/www/html/wp-config.php ]; then
  chown root:www-data /var/www/html/wp-config.php
  chmod 640 /var/www/html/wp-config.php
fi
[ -f /var/www/html/.maintenance ] && rm -f /var/www/html/.maintenance
info "站点文件已还原：$(du -sh /var/www/html | cut -f1)"

echo "==== §6 还原数据库（含 mysql 库 → 用户/授权一并恢复） ===="
systemctl start mariadb || die "MariaDB 启动失败"
for i in $(seq 1 30); do
  mysqladmin --socket=/run/mysqld/mysqld.sock ping >/dev/null 2>&1 && break
  sleep 1
done
# Two possible target states:
#   A) fresh host -- root has no password (unix_socket), use mysql -uroot
#   B) re-run -- root already carries the archived password, use debian.cnf
if mysql -uroot -e 'SELECT 1' > /dev/null 2>&1; then
  MYSQL_IMPORT="mysql -uroot"
  info "导入方式：root 无密码（全新目标）"
elif mysql --defaults-file=/etc/mysql/debian.cnf -e 'SELECT 1' > /dev/null 2>&1; then
  MYSQL_IMPORT="mysql --defaults-file=/etc/mysql/debian.cnf"
  info "导入方式：debian.cnf 凭据（重跑目标）"
else
  die "无法获得 MariaDB root 权限（既无密码登录，debian.cnf 也不可用）"
fi
$MYSQL_IMPORT < "$WORK/db.sql" || die "数据库导入失败"
# Important: after writing the mysql schema directly, reload the grant tables,
# otherwise the in-memory table does not know the imported wordpress user
$MYSQL_IMPORT -e "FLUSH PRIVILEGES;" || die "FLUSH PRIVILEGES 失败"
# After the import root carries the archived password; debian.cnf was restored
mysqladmin --defaults-file=/etc/mysql/debian.cnf --local status >/dev/null 2>&1 \
  || die "导入后 debian.cnf 无法登录（root 密码与 debian.cnf 不一致）"
info "数据库导入完成，debian.cnf 可登录"
WC=$(mysql --defaults-file=/etc/mysql/debian.cnf -N -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='wordpress';" 2>/dev/null)
echo "  wordpress 表数: ${WC}"

echo "==== §7 还原 xray ===="
if [ -f "$WORK/xray.tar.gz" ]; then
  tar xzf "$WORK/xray.tar.gz" -C / --numeric-owner
  systemctl daemon-reload
  # Align the config owner with the current service user (newer installers use xray)
  if [ -f /usr/local/etc/xray/config.json ]; then
    svc_u=$(systemctl show -p User --value xray 2>/dev/null); svc_u=${svc_u:-root}
    svc_g=$(systemctl show -p Group --value xray 2>/dev/null); [ -n "$svc_g" ] || svc_g=$(id -gn "$svc_u" 2>/dev/null || echo root)
    chown "root:${svc_g}" /usr/local/etc/xray/config.json
    chmod 640 /usr/local/etc/xray/config.json
    [ -f /root/xray_reality_url ] && chmod 600 /root/xray_reality_url
    [ -f /root/xray_manage.sh ] && chmod 700 /root/xray_manage.sh
    info "xray 已还原（$(/usr/local/bin/xray version 2>/dev/null | head -1)）配置权限 640 root:${svc_g}"
    # Rewrite the node URL when its address differs from the current public IP
    CUR_IP=$(curl -s --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)
    if [ -n "$CUR_IP" ] && [ -f /root/xray_reality_url ]; then
      OLD_IP=$(grep -oE 'vless://[^@]+@[0-9.]+:[0-9]+' /root/xray_reality_url | head -1 | sed -E 's|.*@([0-9.]+):.*|\1|')
      if [ -n "$OLD_IP" ] && [ "$OLD_IP" != "$CUR_IP" ]; then
        cp -a /root/xray_reality_url /root/xray_reality_url.orig
        sed -i "s|@${OLD_IP}:443|@${CUR_IP}:443|g" /root/xray_reality_url
        if command -v qrencode >/dev/null 2>&1; then
          URL_LINE=$(head -1 /root/xray_reality_url)
          { echo "$URL_LINE"; echo; qrencode -t ANSI "$URL_LINE"; } > /root/.url.new 2>/dev/null && mv /root/.url.new /root/xray_reality_url
          chmod 600 /root/xray_reality_url
        fi
        info "节点地址已改写：${OLD_IP} → ${CUR_IP}（密钥/UUID 不变）"
      fi
    fi
  fi
else
  warn "归档里没有 xray"
fi

echo "==== §8 启动服务 ===="
nginx -t 2>&1 | tail -1 | sed 's/^/  /'
systemctl start php7.4-fpm || die "php-fpm 启动失败"
systemctl start nginx || die "nginx 启动失败"
if [ -f /usr/local/etc/xray/config.json ]; then
  systemctl start xray || warn "xray 启动失败"
fi
systemctl enable nginx php7.4-fpm mariadb >/dev/null 2>&1 || true
[ -f /usr/local/etc/xray/config.json ] && systemctl enable xray >/dev/null 2>&1 || true
# Apply the restored SSH hardening
sshd -t && systemctl reload ssh 2>/dev/null && info "SSH 配置已重载（仅密钥登录）" || warn "SSH 重载失败"

echo "==== §9 验证 ===="
D=$(ls -1 /etc/letsencrypt/live/ 2>/dev/null | grep -v README | head -1 || true)
for u in nginx php7.4-fpm mariadb; do printf "  %-12s = %s\n" "$u" "$(systemctl is-active $u)"; done
[ -f /usr/local/etc/xray/config.json ] && printf "  %-12s = %s\n" xray "$(systemctl is-active xray)"
if [ -n "$D" ]; then
  echo -n "  站点(HTTPS)="; curl -sk -o /dev/null -m 10 --resolve "$D:443:127.0.0.1" -w "%{http_code}" "https://$D/"
  echo -n "  login="; curl -sk -o /dev/null -m 10 --resolve "$D:443:127.0.0.1" -w "%{http_code}" "https://$D/wp-login.php"
  echo -n "  xmlrpc="; curl -sk -o /dev/null -m 10 --resolve "$D:443:127.0.0.1" -w "%{http_code}" "https://$D/xmlrpc.php"
  echo -n "  readme="; curl -sk -o /dev/null -m 10 --resolve "$D:443:127.0.0.1" -w "%{http_code}\n" "https://$D/readme.html"
  echo -n "  SNI($D)="; timeout 8 openssl s_client -connect 127.0.0.1:443 \
    -servername "$D" </dev/null 2>/dev/null | openssl x509 -noout -subject 2>/dev/null \
    | sed 's/subject=//'
  echo -n "  SNI(learn.microsoft.com)="; timeout 8 openssl s_client -connect 127.0.0.1:443 \
    -servername learn.microsoft.com </dev/null 2>/dev/null | openssl x509 -noout -subject 2>/dev/null \
    | sed 's/subject=//'
fi
echo "  stream块=$(grep -c 'stream {' /etc/nginx/nginx.conf 2>/dev/null)  \
  站点8006=$(grep -c '127.0.0.1:8006' /etc/nginx/sites-available/default 2>/dev/null)"
echo "  wp-config 权限=$(stat -c '%a %U:%G' /var/www/html/wp-config.php 2>/dev/null)"
echo "  xray 配置=$(stat -c '%a %U:%G' /usr/local/etc/xray/config.json 2>/dev/null)  URL=$(stat -c '%a' /root/xray_reality_url 2>/dev/null)"
echo "$LINE"
info "恢复完成。域名解析指向本机后即可对外服务：https://${D:-<域名>}/"
