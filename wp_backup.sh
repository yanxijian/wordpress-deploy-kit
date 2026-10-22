#!/usr/bin/env bash
# ============================================================
#  wp_backup.sh -- consistent backup of WordPress plus system configuration
#
#  Goal: one archive that restores completely onto a host with the same OS
#  release. It covers four layers: database, web root, system configuration
#  (nginx/php/mysql/ssh), certificates and the xray REALITY private key
#
#  Usage (root):
#    bash wp_backup.sh                          # write to /root/wp-backups
#    _OUT_DIR_=/data/backups bash wp_backup.sh  # custom output directory
#    _SKIP_MAINT_=1 bash wp_backup.sh           # skip maintenance mode (weaker consistency)
#    _KEEP_DAYS_=14 bash wp_backup.sh           # retention in days (default 7)
#
#  Output: wpbackup-<domain>-<timestamp>.tar.gz plus .sha256
#  Restore: bash wp_restore.sh <archive>   (see wp_restore.sh)
# ============================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

WEBROOT="${_WEBROOT_:-/var/www/html}"
OUT_DIR="${_OUT_DIR_:-/root/wp-backups}"
KEEP_DAYS="${_KEEP_DAYS_:-7}"
SKIP_MAINT="${_SKIP_MAINT_:-0}"

red='\e[91m'; green='\e[92m'; yellow='\e[93m'; cyan='\e[96m'; none='\e[0m'
info(){ echo -e "${green}>>>${none} $*"; }
warn(){ echo -e "${yellow}>>>${none} $*"; }
die(){ echo -e "${red}>>> 错误：$*${none}" >&2; exit 1; }
LINE="----------------------------------------------------------------"

[ "$(id -u)" -eq 0 ] || die "请以 root 运行"
[ -d "$WEBROOT" ] || die "找不到 $WEBROOT"
[ -f /etc/mysql/debian.cnf ] || die "缺少 /etc/mysql/debian.cnf（无法做一致性 dump）"

DOMAIN="${_DOMAIN_:-}"
if [ -z "$DOMAIN" ]; then
  DOMAIN=$(ls -1 /etc/letsencrypt/live/ 2>/dev/null | grep -v README | head -1 || true)
fi
[ -n "$DOMAIN" ] || DOMAIN="site"
TS=$(date +%Y%m%d-%H%M%S)
NAME="wpbackup-${DOMAIN}-${TS}"
WORK=$(mktemp -d)
mkdir -p "$OUT_DIR"

MAINT_CREATED=0
cleanup(){
  rm -rf "$WORK"
  if [ "$MAINT_CREATED" = "1" ]; then rm -f "$WEBROOT/.maintenance"; fi
}
trap cleanup EXIT

echo "==== §1 一致性：维护模式 ===="
if [ "$SKIP_MAINT" != "1" ] && [ ! -f "$WEBROOT/.maintenance" ]; then
  echo '<?php $upgrading = time();' > "$WEBROOT/.maintenance" && MAINT_CREATED=1
  info "已进入维护模式（备份结束后自动退出）"
else
  warn "跳过维护模式（数据库仍用 single-transaction 保证一致；uploads 可能有秒级偏差）"
fi

echo "==== §2 数据库（--single-transaction，不锁表） ===="
# MariaDB 10.3 only ships mysqldump; mariadb-dump exists from 10.4 on, so adapt
DUMP_BIN=$(command -v mariadb-dump 2>/dev/null || command -v mysqldump 2>/dev/null || true)
[ -n "$DUMP_BIN" ] || die "找不到 mysqldump / mariadb-dump"
info "dump 工具：${DUMP_BIN}"
"$DUMP_BIN" --defaults-file=/etc/mysql/debian.cnf \
  --single-transaction --quick --routines --triggers --events \
  --all-databases --skip-lock-tables > "$WORK/db.sql" 2>"$WORK/dump.err" \
  || { cat "$WORK/dump.err" >&2; die "数据库 dump 失败"; }
DBSIZE=$(du -h "$WORK/db.sql" | cut -f1)
grep -q 'CREATE TABLE' "$WORK/db.sql" || die "dump 内容异常（没有 CREATE TABLE）"
info "db.sql = ${DBSIZE}"

echo "==== §3 站点文件（保留属主，排除备份/缓存目录） ===="
tar czf "$WORK/www.tar.gz" -C / --numeric-owner \
  --exclude="var/www/html/wp-content/updraft" \
  --exclude="var/www/html/wp-content/cache" \
  --exclude="var/www/html/wp-content/ai1wm-backups" \
  --exclude="var/www/html/wp-content/uploads_bak" \
  var/www/html
info "www.tar.gz = $(du -h "$WORK/www.tar.gz" | cut -f1)"

echo "==== §4 系统配置（nginx/php/mysql/ssh/cron） ===="
CFG_FILES=(
  etc/nginx/nginx.conf
  etc/nginx/sites-available/default
  etc/nginx/modules-enabled
  etc/php/7.4/fpm/php.ini
  etc/php/7.4/fpm/pool.d/www.conf
  etc/mysql/debian.cnf
  etc/mysql/mariadb.conf.d
  etc/ssh/sshd_config.d/99-hardening.conf
  etc/cron.d/certbot
  etc/systemd/system/xray.service
  etc/systemd/system/xray@.service
  etc/systemd/system/xray.service.d
)
EXIST=()
for f in "${CFG_FILES[@]}"; do [ -e "/$f" ] && EXIST+=("$f"); done
tar czf "$WORK/etc.tar.gz" -C / --numeric-owner "${EXIST[@]}"
info "etc.tar.gz = $(du -h "$WORK/etc.tar.gz" | cut -f1)（${#EXIST[@]} 项）"

echo "==== §5 证书（含续期配置） ===="
if [ -d /etc/letsencrypt ]; then
  tar czf "$WORK/le.tar.gz" -C / --numeric-owner etc/letsencrypt
  info "le.tar.gz = $(du -h "$WORK/le.tar.gz" | cut -f1)"
else
  warn "没有 /etc/letsencrypt（HTTP-only 站点？）"
fi

echo "==== §6 xray（配置/私钥/节点链接/管理脚本/二进制） ===="
XRAY_FILES=()
for f in usr/local/etc/xray/config.json usr/local/bin/xray usr/local/share/xray root/xray_reality_url root/xray_manage.sh; do
  [ -e "/$f" ] && XRAY_FILES+=("$f")
done
if [ ${#XRAY_FILES[@]} -gt 0 ]; then
  tar czf "$WORK/xray.tar.gz" -C / --numeric-owner "${XRAY_FILES[@]}"
  info "xray.tar.gz = $(du -h "$WORK/xray.tar.gz" | cut -f1)（${#XRAY_FILES[@]} 项）"
else
  warn "未发现 xray 相关文件，跳过"
fi

echo "==== §7 manifest（版本清单） ===="
# Version probing is best effort: a failed probe must never abort the backup
set +e
{
  echo "# WordPress backup manifest"
  echo "backup_time: ${TS}"
  echo "domain: ${DOMAIN}"
  echo "hostname: $(hostname)"
  echo "## os"
  (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || true
  echo "kernel: $(uname -r)"
  echo "## packages"
  dpkg-query -W -f='${Package}=${Version}\n' \
    nginx nginx-common nginx-core libnginx-mod-stream php7.4-fpm php7.4-common \
    php7.4-cli mariadb-server mariadb-client openssl certbot python3-certbot-nginx \
    libssl1.1 qrencode unzip 2>/dev/null || true
  echo "## wordpress"
  grep -m1 "wp_version =" "$WEBROOT/wp-includes/version.php" 2>/dev/null || true
  echo "## plugins"
  for d in "$WEBROOT"/wp-content/plugins/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    v=$(grep -m1 -i '^[[:space:]]*\*[[:space:]]*Version:' "$d"*.php 2>/dev/null \
        | head -1 | sed 's/.*Version:[[:space:]]*//' | tr -d '\r' || true)
    printf '%s=%s\n' "$n" "${v:-?}"
  done
  echo "## theme"
  grep -m1 -i '^[[:space:]]*Version:' "$WEBROOT"/wp-content/themes/*/style.css 2>/dev/null || true
  echo "## xray"
  /usr/local/bin/xray version 2>/dev/null | head -1 || true
  echo "## db"
  mysql --defaults-file=/etc/mysql/debian.cnf -N -e \
    "SELECT CONCAT('wordpress_db_size_mb=', ROUND(SUM(data_length+index_length)/1024/1024,2)) FROM " \
    "information_schema.tables WHERE table_schema='wordpress';" 2>/dev/null || true
} > "$WORK/manifest.txt"
set -e
info "manifest.txt 已生成"

echo "==== §8 打包 + 校验 ===="
tar czf "$OUT_DIR/$NAME.tar.gz" -C "$WORK" .
( cd "$OUT_DIR" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
SIZE=$(du -h "$OUT_DIR/$NAME.tar.gz" | cut -f1)
# Do not write this as "tar tzf ... | grep -q": grep exits early, tar gets
# SIGPIPE and pipefail reports a failure. Write the listing first, then check.
ARCHIVE_LIST="$WORK/archive.list"
tar tzf "$OUT_DIR/$NAME.tar.gz" > "$ARCHIVE_LIST" || die "归档自检失败（tar 无法读取）"
for part in db.sql www.tar.gz etc.tar.gz manifest.txt; do
  grep -qx "./$part" "$ARCHIVE_LIST" || die "归档缺少 $part"
done
info "归档完整性校验通过"
info "备份完成：$OUT_DIR/$NAME.tar.gz（${SIZE}）"
info "校验文件：$OUT_DIR/$NAME.tar.gz.sha256"

echo "==== §9 保留策略（>${KEEP_DAYS} 天自动清理） ===="
find "$OUT_DIR" -maxdepth 1 -name 'wpbackup-*.tar.gz*' -mtime +"$KEEP_DAYS" -print -delete | sed 's/^/  清理: /' || true
echo "$LINE"
info "恢复命令：bash wp_restore.sh $OUT_DIR/$NAME.tar.gz"
