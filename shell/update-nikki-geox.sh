#!/bin/sh
#
# 一键更新 Nikki / Mihomo 的 GeoX 数据库
# 兼容 OpenWrt BusyBox ash，仅依赖 curl（Nikki 的标准依赖）。
#
# 可选环境变量：
#   GEOX_DIR=/etc/nikki/run
#   RESTART_NIKKI=1             # 设为 0 时更新后不重启
#   GEOSITE_URL=...
#   GEOIP_URL=...
#   MMDB_URL=...
#   ASN_URL=...
#

set -eu

GEOX_DIR="${GEOX_DIR:-/etc/nikki/run}"
RESTART_NIKKI="${RESTART_NIKKI:-1}"

GEOSITE_URL="${GEOSITE_URL:-https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat}"
GEOIP_URL="${GEOIP_URL:-https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat}"
MMDB_URL="${MMDB_URL:-https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb}"
ASN_URL="${ASN_URL:-https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb}"

GEOSITE_FILE="GeoSite.dat"
GEOIP_FILE="GeoIP.dat"
MMDB_FILE="Country.mmdb"
ASN_FILE="ASN.mmdb"

STAGE_DIR="${GEOX_DIR}/.geox-update.$$"
BACKUP_DIR="${GEOX_DIR}/.geox-backup.$$"
LOCK_DIR="${GEOX_DIR}/.geox-update.lock"
INSTALLED=0

log() {
	printf '%s\n' "[GeoX] $*"
}

die() {
	printf '%s\n' "[GeoX] 错误：$*" >&2
	exit 1
}

cleanup() {
	rm -rf "$STAGE_DIR" "$LOCK_DIR"
	if [ "$INSTALLED" -eq 0 ]; then
		rm -rf "$BACKUP_DIR"
	fi
}

rollback() {
	log "Nikki 重启失败，正在恢复旧数据库……"
	for file in "$GEOSITE_FILE" "$GEOIP_FILE" "$MMDB_FILE" "$ASN_FILE"; do
		if [ -f "$BACKUP_DIR/$file" ]; then
			mv -f "$BACKUP_DIR/$file" "$GEOX_DIR/$file"
		else
			rm -f "$GEOX_DIR/$file"
		fi
	done
	/etc/init.d/nikki restart >/dev/null 2>&1 || true
	die "已恢复旧数据库，请检查 Nikki 日志"
}

download() {
	name="$1"
	url="$2"
	output="$3"

	log "下载 $name……"
	curl --fail --location --silent --show-error \
		--connect-timeout 15 --max-time 300 \
		--retry 3 --retry-delay 2 \
		--user-agent "Nikki-GeoX-Updater/1.0" \
		--output "$output" "$url" ||
		die "$name 下载失败：$url"
}

check_size() {
	name="$1"
	file="$2"
	min_size="$3"
	size="$(wc -c < "$file" | tr -d ' ')"
	[ "$size" -ge "$min_size" ] ||
		die "$name 文件异常（仅 ${size} 字节）"
	log "$name 校验通过（${size} 字节）"
}

check_mmdb() {
	name="$1"
	file="$2"
	check_size "$name" "$file" 102400
	LC_ALL=C grep -a -q "MaxMind.com" "$file" ||
		die "$name 不是有效的 MMDB 文件"
}

[ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行"
command -v curl >/dev/null 2>&1 || die "缺少 curl，请先执行：opkg update && opkg install curl"
[ -x /etc/init.d/nikki ] || die "未检测到 /etc/init.d/nikki，请确认已安装 Nikki"
mkdir -p "$GEOX_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
	die "另一个 GeoX 更新任务正在运行；若确定没有任务，请删除 $LOCK_DIR"
fi
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$STAGE_DIR" "$BACKUP_DIR"

download "GeoSite" "$GEOSITE_URL" "$STAGE_DIR/$GEOSITE_FILE"
download "GeoIP DAT" "$GEOIP_URL" "$STAGE_DIR/$GEOIP_FILE"
download "Country MMDB" "$MMDB_URL" "$STAGE_DIR/$MMDB_FILE"
download "ASN MMDB" "$ASN_URL" "$STAGE_DIR/$ASN_FILE"

# DAT 是 protobuf 数据，没有稳定的文件头；用合理的最小体积拦截错误页和空文件。
check_size "GeoSite" "$STAGE_DIR/$GEOSITE_FILE" 102400
check_size "GeoIP DAT" "$STAGE_DIR/$GEOIP_FILE" 102400
check_mmdb "Country MMDB" "$STAGE_DIR/$MMDB_FILE"
check_mmdb "ASN MMDB" "$STAGE_DIR/$ASN_FILE"

log "备份并安装新数据库……"
for file in "$GEOSITE_FILE" "$GEOIP_FILE" "$MMDB_FILE" "$ASN_FILE"; do
	if [ -f "$GEOX_DIR/$file" ]; then
		cp -p "$GEOX_DIR/$file" "$BACKUP_DIR/$file"
	fi
	chmod 0644 "$STAGE_DIR/$file"
	mv -f "$STAGE_DIR/$file" "$GEOX_DIR/$file"
done
INSTALLED=1

if [ "$RESTART_NIKKI" = "1" ]; then
	log "重启 Nikki……"
	if ! /etc/init.d/nikki restart; then
		rollback
	fi
	sleep 3
	if ! /etc/init.d/nikki status >/dev/null 2>&1; then
		rollback
	fi
	log "Nikki 已正常运行"
else
	log "已跳过重启；请稍后手动执行：/etc/init.d/nikki restart"
fi

rm -rf "$BACKUP_DIR"
INSTALLED=0
log "GeoX 数据库全部更新完成"
