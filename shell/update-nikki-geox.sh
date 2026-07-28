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
#   GITHUB_PROXIES="https://github.dpik.top/ https://ghproxy.net/ https://gh.jasonzeng.dev/ https://github-proxy.memory-echoes.cn/ https://gh.dpik.top/ https://gh.b52m.cn/ https://gh.felicity.ac.cn/ https://gh-proxy.com/"
#   GITHUB_PROXY=...             # 兼容旧用法；设置后覆盖反代列表
#   DIRECT_FIRST=1              # 直连优先，失败或持续低速后切换反代
#   DIRECT_MIN_KBPS=64
#   DIRECT_SLOW_TIME=20
#   DIRECT_MAX_TIME=600
#

set -eu

GEOX_DIR="${GEOX_DIR:-/etc/nikki/run}"
RESTART_NIKKI="${RESTART_NIKKI:-1}"
GITHUB_PROXIES="${GITHUB_PROXIES-https://github.dpik.top/ https://ghproxy.net/ https://gh.jasonzeng.dev/ https://github-proxy.memory-echoes.cn/ https://gh.dpik.top/ https://gh.b52m.cn/ https://gh.felicity.ac.cn/ https://gh-proxy.com/}"
GITHUB_PROXY="${GITHUB_PROXY-}"
[ -z "$GITHUB_PROXY" ] || GITHUB_PROXIES="$GITHUB_PROXY"
DIRECT_FIRST="${DIRECT_FIRST:-1}"
DIRECT_MIN_KBPS="${DIRECT_MIN_KBPS:-64}"
DIRECT_SLOW_TIME="${DIRECT_SLOW_TIME:-20}"
DIRECT_MAX_TIME="${DIRECT_MAX_TIME:-600}"
PROXY_MIN_KBPS="${PROXY_MIN_KBPS:-32}"
PROXY_SLOW_TIME="${PROXY_SLOW_TIME:-20}"
PROXY_MAX_TIME="${PROXY_MAX_TIME:-600}"

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
OPENWRT_VERSION="unknown"
CPU_ARCH="$(uname -m 2>/dev/null || printf '%s' unknown)"
PKG_MANAGER="unknown"

log() {
	printf '%s\n' "[GeoX] $*"
}

die() {
	printf '%s\n' "[GeoX] 错误：$*" >&2
	exit 1
}

warn() {
	printf '%s\n' "[GeoX] 警告：$*" >&2
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

usage() {
	printf '%s\n' \
		"用法：" \
		"  update-nikki-geox.sh [选项]" \
		"  wget -qO- URL | sh -s -- [选项]" \
		"" \
		"选项：" \
		"  --proxy URL            只使用指定的一个 GitHub 反代" \
		"  --proxies \"URL ...\"   设置按顺序尝试的反代列表" \
		"  --no-proxy             禁用反代" \
		"  --direct-first         直连优先（默认）" \
		"  --proxy-first          反代优先" \
		"  --min-speed KB/s       直连最低速度，默认 64 KB/s" \
		"  --slow-time 秒         持续低速熔断时间，默认 20 秒" \
		"  --direct-timeout 秒    单次直连最长时间，默认 600 秒" \
		"  --no-restart           更新后不重启 Nikki" \
		"  -h, --help             显示帮助"
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--proxy)
				[ "$#" -ge 2 ] || die "--proxy 缺少 URL"
				GITHUB_PROXY="$2"
				GITHUB_PROXIES="$2"
				shift 2
				;;
			--proxies)
				[ "$#" -ge 2 ] || die "--proxies 缺少 URL 列表"
				GITHUB_PROXY=""
				GITHUB_PROXIES="$2"
				shift 2
				;;
			--no-proxy)
				GITHUB_PROXY=""
				GITHUB_PROXIES=""
				shift
				;;
			--direct-first)
				DIRECT_FIRST=1
				shift
				;;
			--proxy-first)
				DIRECT_FIRST=0
				shift
				;;
			--min-speed)
				[ "$#" -ge 2 ] || die "--min-speed 缺少数值"
				DIRECT_MIN_KBPS="$2"
				shift 2
				;;
			--slow-time)
				[ "$#" -ge 2 ] || die "--slow-time 缺少秒数"
				DIRECT_SLOW_TIME="$2"
				shift 2
				;;
			--direct-timeout)
				[ "$#" -ge 2 ] || die "--direct-timeout 缺少秒数"
				DIRECT_MAX_TIME="$2"
				shift 2
				;;
			--no-restart)
				RESTART_NIKKI=0
				shift
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				die "未知参数：$1（使用 --help 查看帮助）"
				;;
		esac
	done

	case "$DIRECT_FIRST" in
		0|1) ;;
		*) die "DIRECT_FIRST 只能是 0 或 1" ;;
	esac
	case "$DIRECT_MIN_KBPS:$DIRECT_SLOW_TIME:$DIRECT_MAX_TIME" in
		*[!0-9:]*|:*|*::*|*:) die "直连速度和超时参数必须是正整数" ;;
	esac
	[ "$DIRECT_MIN_KBPS" -gt 0 ] &&
		[ "$DIRECT_SLOW_TIME" -gt 0 ] &&
		[ "$DIRECT_MAX_TIME" -gt 0 ] ||
		die "直连速度和超时参数必须大于 0"
	case "$PROXY_MIN_KBPS:$PROXY_SLOW_TIME:$PROXY_MAX_TIME" in
		*[!0-9:]*|:*|*::*|*:) die "反代速度和超时参数必须是正整数" ;;
	esac
	[ "$PROXY_MIN_KBPS" -gt 0 ] &&
		[ "$PROXY_SLOW_TIME" -gt 0 ] &&
		[ "$PROXY_MAX_TIME" -gt 0 ] ||
		die "反代速度和超时参数必须大于 0"
}

apply_proxy() {
	ap_proxy="$1"
	ap_url="$2"
	case "$ap_url" in
		https://github.com/*|https://raw.githubusercontent.com/*|https://api.github.com/*)
			;;
		*)
			printf '%s' "$ap_url"
			return
			;;
	esac
	case "$ap_proxy" in
		""|none|direct) printf '%s' "$ap_url" ;;
		*/) printf '%s%s' "$ap_proxy" "$ap_url" ;;
		*) printf '%s/%s' "$ap_proxy" "$ap_url" ;;
	esac
}

fetch_file() {
	ff_url="$1"
	ff_output="$2"
	ff_mode="$3"

	if [ "$ff_mode" = "direct" ]; then
		curl --fail --location --silent --show-error \
			--connect-timeout 10 --max-time "$DIRECT_MAX_TIME" \
			--speed-limit "$((DIRECT_MIN_KBPS * 1024))" \
			--speed-time "$DIRECT_SLOW_TIME" \
			--retry 1 --retry-delay 1 \
			--user-agent "Nikki-GeoX-Updater/2.0" \
			--output "$ff_output" "$ff_url"
	else
		curl --fail --location --silent --show-error \
			--connect-timeout 10 --max-time "$PROXY_MAX_TIME" \
			--speed-limit "$((PROXY_MIN_KBPS * 1024))" \
			--speed-time "$PROXY_SLOW_TIME" \
			--retry 1 --retry-delay 1 \
			--user-agent "Nikki-GeoX-Updater/2.0" \
			--output "$ff_output" "$ff_url"
	fi
}

is_valid_download() {
	iv_type="$1"
	iv_file="$2"
	[ -s "$iv_file" ] || return 1
	iv_size="$(wc -c < "$iv_file" | tr -d ' ')"
	case "$iv_size" in
		""|*[!0-9]*) return 1 ;;
	esac
	[ "$iv_size" -ge 102400 ] || return 1
	if [ "$iv_type" = "mmdb" ]; then
		LC_ALL=C grep -a -q "MaxMind.com" "$iv_file"
	fi
}

try_proxies() {
	tp_name="$1"
	tp_type="$2"
	tp_url="$3"
	tp_output="$4"

	case "$tp_url" in
		https://github.com/*|https://raw.githubusercontent.com/*|https://api.github.com/*)
			;;
		*)
			return 1
			;;
	esac

	for tp_proxy in $GITHUB_PROXIES; do
		case "$tp_proxy" in
			http://*|https://*) ;;
			*)
				warn "跳过格式异常的反代：$tp_proxy"
				continue
				;;
		esac
		tp_proxy_url="$(apply_proxy "$tp_proxy" "$tp_url")"
		log "通过反代下载 $tp_name：$tp_proxy"
		rm -f "$tp_output"
		if fetch_file "$tp_proxy_url" "$tp_output" proxy &&
		   is_valid_download "$tp_type" "$tp_output"; then
			log "$tp_name 反代下载成功：$tp_proxy"
			return 0
		fi
		warn "$tp_name 反代失败、超时、持续低速或文件异常：$tp_proxy"
	done
	rm -f "$tp_output"
	return 1
}

download() {
	dl_name="$1"
	dl_type="$2"
	dl_url="$3"
	dl_output="$4"
	dl_can_proxy=0
	case "$dl_url" in
		https://github.com/*|https://raw.githubusercontent.com/*|https://api.github.com/*)
			dl_can_proxy=1
			;;
	esac

	if [ "$DIRECT_FIRST" = "0" ] &&
	   [ "$dl_can_proxy" -eq 1 ] &&
	   [ -n "$GITHUB_PROXIES" ]; then
		if try_proxies "$dl_name" "$dl_type" "$dl_url" "$dl_output"; then
			return 0
		fi
		warn "$dl_name 所有反代均不可用，回退直连"
	fi

	log "直连下载 $dl_name（低于 ${DIRECT_MIN_KBPS} KB/s 持续 ${DIRECT_SLOW_TIME} 秒将切换）"
	rm -f "$dl_output"
	if fetch_file "$dl_url" "$dl_output" direct &&
	   is_valid_download "$dl_type" "$dl_output"; then
		return 0
	fi

	if [ "$DIRECT_FIRST" = "1" ] &&
	   [ "$dl_can_proxy" -eq 1 ] &&
	   [ -n "$GITHUB_PROXIES" ]; then
		warn "$dl_name 直连失败、超时、持续低速或文件异常，依次尝试备用反代"
		if try_proxies "$dl_name" "$dl_type" "$dl_url" "$dl_output"; then
			return 0
		fi
	fi

	rm -f "$dl_output"
	if [ "$dl_can_proxy" -eq 1 ] && [ -n "$GITHUB_PROXIES" ]; then
		die "$dl_name 直连和所有反代均下载失败：$dl_url"
	fi
	die "$dl_name 下载失败：$dl_url"
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

parse_args "$@"
[ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行"

if [ -r /etc/openwrt_release ]; then
	OPENWRT_VERSION="$(
		sed -n "s/^DISTRIB_RELEASE=['\"]\\{0,1\\}\\([^'\"]*\\)['\"]\\{0,1\\}$/\\1/p" \
			/etc/openwrt_release | head -n 1
	)"
	[ -n "$OPENWRT_VERSION" ] || OPENWRT_VERSION="unknown"
else
	die "当前系统不是 OpenWrt，或缺少 /etc/openwrt_release"
fi

# 直接检测包管理器，避免依赖 OpenWrt 版本号判断。
if command -v apk >/dev/null 2>&1; then
	PKG_MANAGER="apk"
elif command -v opkg >/dev/null 2>&1; then
	PKG_MANAGER="opkg"
fi

log "系统：OpenWrt $OPENWRT_VERSION"
log "架构：$CPU_ARCH（GeoX 数据库与 CPU 架构无关）"
log "包管理器：$PKG_MANAGER"
case "$GITHUB_PROXIES" in
	"")
		log "GitHub 下载：仅直连"
		;;
	*)
		if [ "$DIRECT_FIRST" = "1" ]; then
			log "GitHub 下载：直连优先；失败、超时或持续低速后依次尝试反代"
			log "直连低速阈值：${DIRECT_MIN_KBPS} KB/s，持续 ${DIRECT_SLOW_TIME} 秒"
		else
			log "GitHub 下载：反代列表优先，全部失败后回退直连"
		fi
		log "备用反代：$GITHUB_PROXIES"
		;;
esac

if ! command -v curl >/dev/null 2>&1; then
	case "$PKG_MANAGER" in
		apk)
			die "缺少 curl，请先执行：apk add curl"
			;;
		opkg)
			die "缺少 curl，请先执行：opkg update && opkg install curl"
			;;
		*)
			die "缺少 curl，且未识别到 apk/opkg"
			;;
	esac
fi

[ -x /etc/init.d/nikki ] || die "未检测到 /etc/init.d/nikki，请确认已安装 Nikki"
mkdir -p "$GEOX_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
	die "另一个 GeoX 更新任务正在运行；若确定没有任务，请删除 $LOCK_DIR"
fi
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$STAGE_DIR" "$BACKUP_DIR"

download "GeoSite" dat "$GEOSITE_URL" "$STAGE_DIR/$GEOSITE_FILE"
download "GeoIP DAT" dat "$GEOIP_URL" "$STAGE_DIR/$GEOIP_FILE"
download "Country MMDB" mmdb "$MMDB_URL" "$STAGE_DIR/$MMDB_FILE"
download "ASN MMDB" mmdb "$ASN_URL" "$STAGE_DIR/$ASN_FILE"

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
