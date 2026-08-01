#!/bin/sh
#
# Nikki 全方位一键维护脚本
# 适用：OpenWrt/ImmortalWrt 等兼容固件，24.10 / 25.12 / 官方支持的 SNAPSHOT，BusyBox ash
# 功能：安装/更新 Nikki、切换 Mihomo 内核、更新 LightGBM/GeoX/Zashboard、卸载清理
#
# 可选环境变量：
#   GITHUB_TOKEN=...          GitHub API Token（可避免匿名限流）
#   DIRECT_MIN_KBPS=64       直连持续低于该速度后切换反代（curl）
#   DIRECT_SLOW_TIME=15      直连或反代低速持续秒数
#   DOWNLOAD_MAX_TIME=900    单个文件最长下载时间
#   MIPS_FLOAT=auto          MIPS 可覆盖为 softfloat 或 hardfloat
#   KEEP_BACKUP_ON_SUCCESS=1 成功后保留事务备份（默认清理）
#
# 非交互示例：
#   sh nikki_all_install_update_v2.5.1.sh --action smart --lgbm auto --yes
#   sh nikki_all_install_update_v2.5.1.sh --action alpha --yes
#   sh nikki_all_install_update_v2.5.1.sh --action stable --yes
#   sh nikki_all_install_update_v2.5.1.sh --action uninstall --yes

set -u

SCRIPT_VERSION="2.5.1"
ACTION=""
CLI_ACTION=""
MAIN_CHOICE=""
PLAN_PRESET=0
NIKKI_UPDATE_CHOICE="update"
LGBM_CHOICE="auto"
LGBM_SET=0
GEOX_CHOICE="update"
ZASH_CHOICE="update"
ZASH_ASSET="dist.zip"
ZASH_VARIANT_LABEL="full"
ASSUME_YES=0
KEEP_BACKUP_ON_SUCCESS="${KEEP_BACKUP_ON_SUCCESS:-0}"
DIRECT_MIN_KBPS="${DIRECT_MIN_KBPS:-64}"
DIRECT_SLOW_TIME="${DIRECT_SLOW_TIME:-15}"
DOWNLOAD_MAX_TIME="${DOWNLOAD_MAX_TIME:-900}"
WGET_MAX_TIME="${WGET_MAX_TIME:-30}"
DOWNLOAD_ROUNDS="${DOWNLOAD_ROUNDS:-3}"
MIPS_FLOAT="${MIPS_FLOAT:-auto}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# 同一组反代统一用于 GitHub Raw、API 与 Release 下载。
GITHUB_PROXIES="${GITHUB_PROXIES:-https://gh.dpik.top/ https://gh.felicity.ac.cn/ https://gh.b52m.cn/ https://github-proxy.memory-echoes.cn/ https://gh.jasonzeng.dev/ https://github.dpik.top/ https://ghproxy.net/ https://gh-proxy.com/}"

NIKKI_REPO="nikkinikki-org/OpenWrt-nikki"
CORE_PATH="/usr/bin/mihomo"
NIKKI_DIR="/etc/nikki"
RUN_DIR="/etc/nikki/run"
MODEL_PATH="/etc/nikki/run/Model.bin"
UI_DIR="/etc/nikki/run/ui"
UI_NAME="zashboard"
UI_TARGET="${UI_DIR}/${UI_NAME}"
STATE_FILE="/etc/nikki/.all-update-state"

PID="$$"
WORK_DIR="/tmp/nikki-all-update.${PID}"
LOCK_DIR="/tmp/nikki-all-update.lock"
LOCKED=0
TRANSACTION_ACTIVE=0
WAS_RUNNING=0
MAINT_SUCCESS=0
NIKKI_UPDATE_STATUS="not_selected"
CORE_UPDATE_STATUS="not_selected"
MODEL_UPDATE_STATUS="not_selected"
GEOX_UPDATE_STATUS="not_selected"
ZASH_UPDATE_STATUS="not_selected"
DOWNLOADER=""
PKG_MANAGER="unknown"
FIRMWARE_NAME="OpenWrt"
FIRMWARE_DESCRIPTION="OpenWrt unknown"
FIRMWARE_DISPLAY="OpenWrt unknown"
OPENWRT_VERSION="unknown"
OPENWRT_ARCH="unknown"
LUCI_BRANCH=""
LUCI_REVISION=""
LUCI_OPENWRT_SERIES=""
KERNEL_VERSION="unknown"
FIREWALL="unknown"
CPU_ARCH="unknown"
CPU_MODEL="unknown"
AMD64_LEVEL=""
ASSET_ARCH=""
OFFICIAL_BRANCH=""

CORE_BACKUP="${CORE_PATH}.rollback.${PID}"
MODEL_BACKUP="${MODEL_PATH}.rollback.${PID}"
UI_BACKUP="${UI_TARGET}.rollback.${PID}"
GEOX_BACKUP="${RUN_DIR}/.geox-rollback.${PID}"
CONFIG_BACKUP="/etc/config/nikki.rollback.${PID}"
CORE_EXISTED=0
MODEL_EXISTED=0
UI_EXISTED=0
CONFIG_EXISTED=0

R='\033[31m'; G='\033[32m'; Y='\033[33m'; M='\033[35m'; C='\033[36m'; B='\033[1m'; N='\033[0m'

say()  { printf '%b\n' "$*"; }
info() { say "${C}[信息]${N} $*"; }
ok()   { say "${G}[完成]${N} $*"; }
warn() { say "${Y}[警告]${N} $*" >&2; }
err()  { say "${R}[错误]${N} $*" >&2; }
menu_line() { say "${B}${C}$*${N}"; }
prompt() { printf '%b' "${B}${Y}$*${N}"; }
danger_prompt() { printf '%b' "${B}${R}$*${N}"; }
summary_item() {
	si_label="$1"; si_version="$2"; si_status="$3"
	if [ -n "$si_status" ]; then
		say "${B}${Y}${si_label}：${N}${B}${C}${si_version}${N} ${B}${M}→${N} ${si_status}"
	else
		say "${B}${Y}${si_label}：${N}${B}${C}${si_version}${N}"
	fi
}
summary_missing() { say "${B}${Y}$1：${N}${B}${R}未安装${N}"; }
fatal() {
	err "$*"
	exit 1
}

safe_rm_tree() {
	srt_path="$1"
	case "$srt_path" in
		/tmp/nikki-all-update.*|/tmp/nikki-uninstall-backup.*|/etc/nikki/run/.geox-rollback.*|/etc/nikki/run/.zashboard-stage.*|/etc/nikki/run/ui|/etc/nikki/run/ui/zashboard|/etc/nikki/run/ui/zashboard.rollback.*)
			[ -n "$srt_path" ] && [ "$srt_path" != "/" ] && rm -rf -- "$srt_path"
			;;
		*)
			warn "拒绝清理非预期目录：$srt_path"
			return 1
			;;
	esac
}

# 由 EXIT trap 间接调用。
# shellcheck disable=SC2329
cleanup() {
	if [ "$TRANSACTION_ACTIVE" -eq 0 ]; then
		[ ! -d "$WORK_DIR" ] || safe_rm_tree "$WORK_DIR" >/dev/null 2>&1 || true
	fi
	if [ "$LOCKED" -eq 1 ]; then
		[ ! -d "$LOCK_DIR" ] || rm -rf -- "$LOCK_DIR" 2>/dev/null || true
	fi
}

trap cleanup EXIT
trap 'err "收到中断信号"; exit 130' INT
trap 'err "收到终止信号"; exit 143' TERM

usage() {
	cat <<'EOF'
用法：nikki_all_install_update_v2.5.1.sh [选项]

  --action smart|alpha|stable|uninstall
  --lgbm auto|small|middle|large
  --yes                 非交互确认
  -h, --help            显示帮助
EOF
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--action)
				[ "$#" -ge 2 ] || fatal "--action 缺少参数"
				ACTION="$2"; shift 2 ;;
			--lgbm)
				[ "$#" -ge 2 ] || fatal "--lgbm 缺少参数"
				LGBM_CHOICE="$2"; LGBM_SET=1; shift 2 ;;
			--yes|-y) ASSUME_YES=1; shift ;;
			-h|--help) usage; exit 0 ;;
			*) fatal "未知参数：$1" ;;
		esac
	done
	case "$ACTION" in ""|smart|alpha|stable|uninstall) ;; *) fatal "无效 action：$ACTION" ;; esac
	case "$LGBM_CHOICE" in auto|small|middle|large) ;; *) fatal "无效 LGBM 版本：$LGBM_CHOICE" ;; esac
	case "$DIRECT_MIN_KBPS:$DIRECT_SLOW_TIME:$DOWNLOAD_MAX_TIME:$WGET_MAX_TIME" in
		*[!0-9:]*|:*|*::*|*:) fatal "下载速度和超时参数必须为正整数" ;;
	esac
	[ "$DIRECT_MIN_KBPS" -gt 0 ] && [ "$DIRECT_SLOW_TIME" -gt 0 ] && [ "$DOWNLOAD_MAX_TIME" -gt 0 ] && [ "$WGET_MAX_TIME" -gt 0 ] ||
		fatal "下载速度和超时参数必须大于 0"
	[ "$WGET_MAX_TIME" -ge "$DIRECT_SLOW_TIME" ] || fatal "WGET_MAX_TIME 不能小于 DIRECT_SLOW_TIME"
	case "$DOWNLOAD_ROUNDS" in 3|4|5) ;; *) fatal "DOWNLOAD_ROUNDS 必须为 3、4 或 5" ;; esac
}

acquire_lock() {
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		LOCKED=1
		printf '%s\n' "$PID" > "$LOCK_DIR/pid"
		return 0
	fi
	old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
	if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
		fatal "已有维护任务正在运行（PID $old_pid）"
	fi
	warn "发现残留锁，正在清理"
	rm -rf -- "$LOCK_DIR" || fatal "无法清理残留锁"
	mkdir "$LOCK_DIR" || fatal "无法创建维护锁"
	LOCKED=1
	printf '%s\n' "$PID" > "$LOCK_DIR/pid"
}

version_ge() {
	# 只比较点分数字；返回 0 表示 $1 >= $2。
	vg_a="$(printf '%s' "$1" | sed 's/[^0-9.].*$//')"
	vg_b="$2"
	awk -v a="$vg_a" -v b="$vg_b" 'BEGIN {
		n=split(a,A,"."); m=split(b,B,"."); max=(n>m?n:m);
		for(i=1;i<=max;i++){x=A[i]+0;y=B[i]+0;if(x>y)exit 0;if(x<y)exit 1} exit 0
	}'
}

all_flags() {
	for af_flag in "$@"; do
		case " $CPU_FLAGS " in *" $af_flag "*) ;; *) return 1 ;; esac
	done
	return 0
}

detect_amd64_level() {
	CPU_FLAGS="$(sed -n 's/^flags[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n 1)"
	if all_flags avx avx2 bmi1 bmi2 fma movbe osxsave; then
		AMD64_LEVEL="v3"
	elif all_flags cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3; then
		AMD64_LEVEL="v2"
	else
		AMD64_LEVEL="v1"
	fi
}

detect_asset_arch() {
	case "$CPU_ARCH" in
		x86_64|amd64) detect_amd64_level; ASSET_ARCH="amd64-${AMD64_LEVEL}" ;;
		i386|i486|i586|i686|x86) ASSET_ARCH="386" ;;
		aarch64|arm64) ASSET_ARCH="arm64" ;;
		armv8l|armv7l|armv7*) ASSET_ARCH="armv7" ;;
		armv6l|armv6*) ASSET_ARCH="armv6" ;;
		armv5tel|armv5tejl|armv5*) ASSET_ARCH="armv5" ;;
		mips64el|mips64le) ASSET_ARCH="mips64le" ;;
		mips64) ASSET_ARCH="mips64" ;;
		mipsel|mipsle)
			case "$MIPS_FLOAT" in auto|softfloat) ASSET_ARCH="mipsle-softfloat" ;; hardfloat) ASSET_ARCH="mipsle-hardfloat" ;; *) ASSET_ARCH="unsupported" ;; esac
			;;
		mips)
			case "$MIPS_FLOAT" in auto|softfloat) ASSET_ARCH="mips-softfloat" ;; hardfloat) ASSET_ARCH="mips-hardfloat" ;; *) ASSET_ARCH="unsupported" ;; esac
			;;
		riscv64) ASSET_ARCH="riscv64" ;;
		loongarch64|loong64) ASSET_ARCH="loong64" ;;
		s390x) ASSET_ARCH="s390x" ;;
		*) ASSET_ARCH="unsupported" ;;
	esac
}

detect_package_manager() {
	if command -v apk >/dev/null 2>&1; then PKG_MANAGER="apk";
	elif command -v opkg >/dev/null 2>&1; then PKG_MANAGER="opkg";
	else PKG_MANAGER="unknown"; fi
}

detect_environment() {
	[ -r /etc/openwrt_release ] || fatal "未检测到 /etc/openwrt_release，本脚本仅支持 OpenWrt 及其兼容衍生固件"
	# OpenWrt 系统自身维护的可信文件。
	# shellcheck disable=SC1091
	. /etc/openwrt_release
	FIRMWARE_NAME="${DISTRIB_ID:-OpenWrt}"
	OPENWRT_VERSION="${DISTRIB_RELEASE:-unknown}"
	OPENWRT_ARCH="${DISTRIB_ARCH:-unknown}"
	FIRMWARE_DESCRIPTION="${DISTRIB_DESCRIPTION:-}"
	if [ -z "$FIRMWARE_DESCRIPTION" ]; then
		FIRMWARE_DESCRIPTION="${FIRMWARE_NAME} ${OPENWRT_VERSION}"
		[ -z "${DISTRIB_REVISION:-}" ] || FIRMWARE_DESCRIPTION="${FIRMWARE_DESCRIPTION} ${DISTRIB_REVISION}"
	fi
	if command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
		lvi_json="$(ubus call luci getVersion 2>/dev/null || true)"
		if [ -n "$lvi_json" ]; then
			LUCI_BRANCH="$(printf '%s' "$lvi_json" | jsonfilter -e '@.branch' 2>/dev/null || true)"
			LUCI_REVISION="$(printf '%s' "$lvi_json" | jsonfilter -e '@.revision' 2>/dev/null || true)"
		fi
	fi
	FIRMWARE_DISPLAY="$FIRMWARE_DESCRIPTION"
	lvi_suffix="$LUCI_BRANCH${LUCI_REVISION:+ $LUCI_REVISION}"
	[ -z "$lvi_suffix" ] || FIRMWARE_DISPLAY="${FIRMWARE_DISPLAY} / ${lvi_suffix}"
	LUCI_OPENWRT_SERIES="$(printf '%s' "$LUCI_BRANCH" | sed -n 's/.*openwrt-\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
	KERNEL_VERSION="$(uname -r 2>/dev/null || printf '%s' unknown)"
	CPU_ARCH="$(uname -m 2>/dev/null || printf '%s' unknown)"
	CPU_MODEL="$(sed -n -e 's/^model name[[:space:]]*:[[:space:]]*//p' -e 's/^Hardware[[:space:]]*:[[:space:]]*//p' -e 's/^Processor[[:space:]]*:[[:space:]]*//p' -e 's/^system type[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n 1)"
	[ -n "$CPU_MODEL" ] || CPU_MODEL="$CPU_ARCH"
	detect_package_manager
	if [ -x /sbin/fw4 ] || command -v fw4 >/dev/null 2>&1; then FIREWALL="firewall4";
	elif [ -x /sbin/fw3 ] || command -v fw3 >/dev/null 2>&1; then FIREWALL="firewall3";
	elif command -v iptables >/dev/null 2>&1; then FIREWALL="iptables/firewall3"; fi
	detect_asset_arch
	case "$OPENWRT_VERSION" in
		24.10*) OFFICIAL_BRANCH="openwrt-24.10" ;;
		25.12*) OFFICIAL_BRANCH="openwrt-25.12" ;;
		SNAPSHOT|*SNAPSHOT*) OFFICIAL_BRANCH="SNAPSHOT" ;;
		*) OFFICIAL_BRANCH="" ;;
	esac
}

print_official_requirements() {
	say ""
	say "脚本版本：${SCRIPT_VERSION}"
	menu_line "=============== Nikki 官方安装环境要求 ==============="
	say "${B}${Y}固件版本：OpenWrt >= 24.10${N}"
	say "${B}${Y}内核版本：Linux Kernel >= 5.13${N}"
	say "${B}${Y}防火墙：firewall4${N}"
	menu_line "======================================================="
}

print_environment() {
	say ""
	say "================ 系统环境检测 ================"
	case "$CPU_ARCH" in
		x86_64|amd64) say "CPU架构：X86/64（AMD64 ${AMD64_LEVEL}）" ;;
		aarch64|arm64|arm*) say "CPU架构：ARM（${CPU_ARCH}）" ;;
		*) say "CPU架构：${CPU_ARCH}" ;;
	esac
	say "CPU信息：${CPU_MODEL}${AMD64_LEVEL:+（AMD64 ${AMD64_LEVEL}）}"
	say "固件版本：${FIRMWARE_DISPLAY}"
	say "内核版本：Linux Kernel ${KERNEL_VERSION}"
	say "防火墙：${FIREWALL}"
	say "包管理：$(printf '%s' "$PKG_MANAGER" | tr '[:lower:]' '[:upper:]')"
	say "固件包架构：${OPENWRT_ARCH}"
	say "Mihomo资产架构：${ASSET_ARCH}"
	say "================================================"
}

check_requirements() {
	cr_bad=0
	cr_pass="${B}${G}✓${N}"
	cr_fail="${B}${R}✗${N}"
	cr_fw="$cr_pass"
	cr_ow="$cr_pass"
	cr_kernel="$cr_pass"
	cr_pkg="$cr_pass"
	cr_arch="$cr_pass"
	if ! version_ge "$OPENWRT_VERSION" "24.10" && [ "$OFFICIAL_BRANCH" != "SNAPSHOT" ]; then cr_bad=1; cr_ow="$cr_fail"; fi
	# 官方 feed/install 脚本只认识其已发布分支；未知未来版本不能盲装。
	if [ -z "$OFFICIAL_BRANCH" ]; then cr_bad=1; cr_ow="${cr_fail}（Nikki 官方源暂无对应分支）"; fi
	if ! version_ge "$KERNEL_VERSION" "5.13"; then cr_bad=1; cr_kernel="$cr_fail"; fi
	if [ "$FIREWALL" != "firewall4" ]; then cr_bad=1; cr_fw="${cr_fail}（必须为 firewall4）"; fi
	if [ "$PKG_MANAGER" = "unknown" ]; then cr_bad=1; cr_pkg="$cr_fail"; fi
	if [ "$ASSET_ARCH" = "unsupported" ]; then cr_bad=1; cr_arch="$cr_fail"; fi

	if [ "$cr_bad" -ne 0 ]; then
		say ""
		say "固件版本：${FIRMWARE_DISPLAY}（要求兼容 OpenWrt >= 24.10 且 Nikki 官方源支持） ${cr_ow}"
		say "内核版本：Linux Kernel ${KERNEL_VERSION}（要求 >= 5.13） ${cr_kernel}"
		say "防火墙：${FIREWALL}（要求 firewall4） ${cr_fw}"
		say "包管理：${PKG_MANAGER}（要求 APK 或 OPKG） ${cr_pkg}"
		say "CPU架构：${CPU_ARCH} ${cr_arch}"
		say "${B}${R}系统环境不符合 Nikki 安装环境要求，如需继续安装，请先升级系统！${N}"
		return 1
	fi

	say ""
	if [ "$OFFICIAL_BRANCH" = "SNAPSHOT" ]; then
		say "固件版本：${FIRMWARE_DISPLAY}（Nikki 官方支持的 SNAPSHOT） ${cr_pass}"
	else
		say "固件版本：${FIRMWARE_DISPLAY}（兼容 OpenWrt >= 24.10） ${cr_pass}"
	fi
	say "内核版本：Linux Kernel ${KERNEL_VERSION} >= 5.13 ${cr_pass}"
	say "防火墙：${FIREWALL}（符合 firewall4 要求） ${cr_pass}"
	if [ -n "$LUCI_OPENWRT_SERIES" ] && [ "$OFFICIAL_BRANCH" = "openwrt-${LUCI_OPENWRT_SERIES}" ]; then
		say "Nikki源分支：${OFFICIAL_BRANCH}（系统发行版本判定，LuCI 分支交叉校验一致） ${cr_pass}"
	elif [ -n "$LUCI_OPENWRT_SERIES" ] && [ "$OFFICIAL_BRANCH" != "SNAPSHOT" ]; then
		say "Nikki源分支：${OFFICIAL_BRANCH}（依据系统发行版本；LuCI 显示 openwrt-${LUCI_OPENWRT_SERIES}，仅作参考） ${cr_pass}"
	else
		say "Nikki源分支：${OFFICIAL_BRANCH}（依据系统发行版本） ${cr_pass}"
	fi
	say "${B}${G}系统环境符合 Nikki 安装环境要求，将进行下一步……${N}"
}

select_downloader() {
	if command -v curl >/dev/null 2>&1; then DOWNLOADER="curl";
	elif command -v wget >/dev/null 2>&1; then DOWNLOADER="wget";
	else fatal "系统缺少 curl/wget，无法下载"; fi
}

apply_proxy() {
	ap_proxy="$1"; ap_url="$2"
	case "$ap_proxy" in ""|direct) printf '%s' "$ap_url" ;; */) printf '%s%s' "$ap_proxy" "$ap_url" ;; *) printf '%s/%s' "$ap_proxy" "$ap_url" ;; esac
}

fetch_once() {
	fo_url="$1"; fo_out="$2"
	rm -f -- "$fo_out"
	if [ "$DOWNLOADER" = "curl" ]; then
		fo_headers=""
		if [ -n "$GITHUB_TOKEN" ]; then
			case "$fo_url" in https://api.github.com/*) fo_headers="Authorization: Bearer ${GITHUB_TOKEN}" ;; esac
		fi
		if [ -n "$fo_headers" ]; then
			curl --fail --location --silent --show-error --connect-timeout 10 --max-time "$DOWNLOAD_MAX_TIME" \
				--speed-limit "$((DIRECT_MIN_KBPS * 1024))" --speed-time "$DIRECT_SLOW_TIME" \
				--user-agent "Nikki-All-Updater/${SCRIPT_VERSION}" --header "$fo_headers" --output "$fo_out" "$fo_url"
		else
			curl --fail --location --silent --show-error --connect-timeout 10 --max-time "$DOWNLOAD_MAX_TIME" \
				--speed-limit "$((DIRECT_MIN_KBPS * 1024))" --speed-time "$DIRECT_SLOW_TIME" \
				--user-agent "Nikki-All-Updater/${SCRIPT_VERSION}" --output "$fo_out" "$fo_url"
		fi
	else
		# wget 没有 curl 的 --speed-limit；用轻量看门狗统一实现低速和总超时切换。
		wget -T 10 -q -O "$fo_out" "$fo_url" &
		fo_pid=$!
		fo_elapsed=0; fo_slow=0; fo_last=0; fo_step=3
		while kill -0 "$fo_pid" 2>/dev/null; do
			sleep "$fo_step"
			kill -0 "$fo_pid" 2>/dev/null || break
			fo_elapsed=$((fo_elapsed + fo_step))
			if [ -f "$fo_out" ]; then fo_size="$(wc -c < "$fo_out" | tr -d ' ')"; else fo_size=0; fi
			case "$fo_size" in ""|*[!0-9]*) fo_size=0 ;; esac
			fo_delta=$((fo_size - fo_last)); [ "$fo_delta" -ge 0 ] || fo_delta=0
			fo_rate=$((fo_delta / fo_step / 1024))
			if [ "$fo_rate" -lt "$DIRECT_MIN_KBPS" ]; then fo_slow=$((fo_slow + fo_step)); else fo_slow=0; fi
			if [ "$fo_slow" -ge "$DIRECT_SLOW_TIME" ] || [ "$fo_elapsed" -ge "$WGET_MAX_TIME" ]; then
				kill "$fo_pid" 2>/dev/null || true
				wait "$fo_pid" 2>/dev/null || true
				rm -f -- "$fo_out"
				return 1
			fi
			fo_last="$fo_size"
		done
		wait "$fo_pid"
	fi
}

plausible_file() {
	pf_out="$1"; pf_kind="$2"
	[ -s "$pf_out" ] || return 1
	case "$pf_kind" in
		json) grep -q '"assets"[[:space:]]*:' "$pf_out" 2>/dev/null ;;
		gzip) gzip -t "$pf_out" >/dev/null 2>&1 ;;
		zip) unzip -t "$pf_out" >/dev/null 2>&1 ;;
		script) head -n 1 "$pf_out" | grep -q '^#!/bin/sh' ;;
		dat|mmdb)
			pf_size="$(wc -c < "$pf_out" | tr -d ' ')"
			[ "$pf_size" -ge 102400 ] 2>/dev/null && ! head -c 64 "$pf_out" 2>/dev/null | grep -qi '<html'
			;;
		model)
			pf_size="$(wc -c < "$pf_out" | tr -d ' ')"
			[ "$pf_size" -ge 1048576 ] 2>/dev/null && [ "$(head -n 1 "$pf_out" 2>/dev/null | tr -d '\r')" = "tree" ]
			;;
		*) return 0 ;;
	esac
}

fetch_url() {
	fu_url="$1"; fu_out="$2"; fu_kind="${3:-file}"
	fu_round=1
	while [ "$fu_round" -le "$DOWNLOAD_ROUNDS" ]; do
		info "下载轮次 ${fu_round}/${DOWNLOAD_ROUNDS}：先尝试直连"
		info "尝试直连：$fu_url"
		if fetch_once "$fu_url" "$fu_out" && plausible_file "$fu_out" "$fu_kind"; then return 0; fi
		warn "直连失败、超时、持续低速或内容异常，开始切换反代"
		fu_list="$GITHUB_PROXIES"
		for fu_proxy in $fu_list; do
			fu_proxy_url="$(apply_proxy "$fu_proxy" "$fu_url")"
			info "尝试反代：$fu_proxy"
			if fetch_once "$fu_proxy_url" "$fu_out" && plausible_file "$fu_out" "$fu_kind"; then
				ok "反代可用：$fu_proxy"
				return 0
			fi
			warn "反代不可用或下载内容异常：$fu_proxy"
		done
		if [ "$fu_round" -lt "$DOWNLOAD_ROUNDS" ]; then
			warn "本轮全部节点失败，2 秒后从直连开始下一轮"
			sleep 2
		fi
		fu_round=$((fu_round + 1))
	done
	rm -f -- "$fu_out"
	err "直连及全部反代连续 ${DOWNLOAD_ROUNDS} 轮失败：$fu_url"
	return 1
}

pkg_is_installed() {
	pi_name="$1"
	case "$PKG_MANAGER" in opkg) opkg list-installed "$pi_name" 2>/dev/null | grep -q "^${pi_name} " ;; apk) apk info -e "$pi_name" >/dev/null 2>&1 ;; *) return 1 ;; esac
}

pkg_update() { case "$PKG_MANAGER" in opkg) opkg update ;; apk) apk update ;; esac; }
pkg_install() { case "$PKG_MANAGER" in opkg) opkg install "$@" ;; apk) apk add "$@" ;; esac; }
pkg_remove() { case "$PKG_MANAGER" in opkg) opkg remove "$@" ;; apk) apk del "$@" ;; esac; }

nikki_version() {
	case "$PKG_MANAGER" in
		opkg) opkg list-installed nikki 2>/dev/null | awk 'NR==1{print $3}' ;;
		apk) apk list --installed --manifest nikki 2>/dev/null | awk '$1=="nikki"{print $2;exit}' ;;
	esac
}

backup_install_state() {
	mkdir -p "$WORK_DIR/install-backup" || return 1
	for bis_path in /etc/config/nikki /etc/opkg/customfeeds.conf /etc/apk/repositories.d/customfeeds.list; do
		if [ -f "$bis_path" ]; then
			bis_name="$(printf '%s' "$bis_path" | sed 's#/#_#g')"
			cp -p "$bis_path" "$WORK_DIR/install-backup/$bis_name" || return 1
			printf '%s\n' "$bis_path" >> "$WORK_DIR/install-backup/files.before"
		fi
	done
	if [ -d "$NIKKI_DIR" ]; then
		cp -a "$NIKKI_DIR" "$WORK_DIR/install-backup/nikki-dir" || return 1
		printf '%s\n' "$NIKKI_DIR" >> "$WORK_DIR/install-backup/dirs.before"
	fi
	if [ -f "$CORE_PATH" ]; then cp -p "$CORE_PATH" "$WORK_DIR/install-backup/mihomo" || return 1; fi
	for bis_pkg in nikki luci-app-nikki luci-i18n-nikki-zh-cn mihomo-meta mihomo-alpha; do
		if pkg_is_installed "$bis_pkg"; then printf '%s\n' "$bis_pkg" >> "$WORK_DIR/install-backup/packages.before"; fi
	done
	return 0
}

restore_install_state() {
	warn "安装/更新失败，正在恢复操作前状态……"
	for ris_pkg in nikki luci-app-nikki luci-i18n-nikki-zh-cn mihomo-meta mihomo-alpha; do
		if pkg_is_installed "$ris_pkg" && ! grep -qx "$ris_pkg" "$WORK_DIR/install-backup/packages.before" 2>/dev/null; then
			pkg_remove "$ris_pkg" >/dev/null 2>&1 || true
		fi
	done
	for ris_path in /etc/config/nikki /etc/opkg/customfeeds.conf /etc/apk/repositories.d/customfeeds.list; do
		ris_name="$(printf '%s' "$ris_path" | sed 's#/#_#g')"
		if [ -f "$WORK_DIR/install-backup/$ris_name" ]; then
			mkdir -p "${ris_path%/*}" && cp -p "$WORK_DIR/install-backup/$ris_name" "$ris_path"
		elif ! grep -qx "$ris_path" "$WORK_DIR/install-backup/files.before" 2>/dev/null; then
			rm -f -- "$ris_path" 2>/dev/null || true
		fi
	done
	if [ -d "$WORK_DIR/install-backup/nikki-dir" ]; then
		rm -rf -- "$NIKKI_DIR" 2>/dev/null || true
		cp -a "$WORK_DIR/install-backup/nikki-dir" "$NIKKI_DIR" || true
	elif ! grep -qx "$NIKKI_DIR" "$WORK_DIR/install-backup/dirs.before" 2>/dev/null; then
		rm -rf -- "$NIKKI_DIR" 2>/dev/null || true
	fi
	if [ -f "$WORK_DIR/install-backup/mihomo" ]; then cp -p "$WORK_DIR/install-backup/mihomo" "$CORE_PATH" || true;
	else rm -f -- "$CORE_PATH" 2>/dev/null || true; fi
	if [ "$PKG_MANAGER" = "opkg" ] && ! grep -q nikki "$WORK_DIR/install-backup/_etc_opkg_customfeeds.conf" 2>/dev/null; then
		sed -i '/nikki/d' /etc/opkg/customfeeds.conf 2>/dev/null || true
	fi
	if [ "$PKG_MANAGER" = "apk" ] && ! grep -q nikki "$WORK_DIR/install-backup/_etc_apk_repositories.d_customfeeds.list" 2>/dev/null; then
		sed -i '/nikki/d' /etc/apk/repositories.d/customfeeds.list 2>/dev/null || true
		rm -f /etc/apk/keys/nikki.pem 2>/dev/null || true
	fi
}

feed_present() {
	case "$PKG_MANAGER" in
		opkg) grep -q '^[[:space:]]*src/gz[[:space:]][[:space:]]*nikki[[:space:]]' /etc/opkg/customfeeds.conf 2>/dev/null ;;
		apk) grep -q '/nikki/packages\.adb[[:space:]]*$' /etc/apk/repositories.d/customfeeds.list 2>/dev/null ;;
		*) return 1 ;;
	esac
}

feed_current() {
	fc_expected="/${OFFICIAL_BRANCH}/${OPENWRT_ARCH}/nikki"
	case "$PKG_MANAGER" in
		opkg) grep '^[[:space:]]*src/gz[[:space:]][[:space:]]*nikki[[:space:]]' /etc/opkg/customfeeds.conf 2>/dev/null | grep -Fq "$fc_expected" ;;
		apk) grep '/nikki/packages\.adb[[:space:]]*$' /etc/apk/repositories.d/customfeeds.list 2>/dev/null | grep -Fq "$fc_expected/packages.adb" ;;
		*) return 1 ;;
	esac
}

report_nikki_package_result() {
	rn_before="$1"
	rn_after="$(nikki_version 2>/dev/null || true)"
	[ -n "$rn_after" ] || { err "软件包命令执行结束，但未检测到 Nikki"; return 1; }
	if [ -z "$rn_before" ]; then
		ok "Nikki 已安装：${rn_after}"
	elif [ "$rn_before" != "$rn_after" ]; then
		ok "Nikki 已更新：${rn_before} -> ${rn_after}"
	else
		ok "Nikki 已执行安装/升级检查，当前版本 ${rn_after}（仓库最新可安装版本）"
	fi
}

install_packages_from_feed() {
	ipf_refresh="${1:-1}"
	ipf_before="$(nikki_version 2>/dev/null || true)"
	[ "$ipf_refresh" = "0" ] || pkg_update || return 1
	case "$PKG_MANAGER" in
		opkg)
			# opkg install 会安装缺失包，并在索引存在较新版本时升级已安装包。
			pkg_install nikki luci-app-nikki luci-i18n-nikki-zh-cn || return 1
			;;
		apk)
			if [ -z "$ipf_before" ]; then
				# 首次安装严格采用 Nikki 官方方案 A；内核包由 nikki 的依赖自动解析。
				apk add nikki luci-app-nikki luci-i18n-nikki-zh-cn || return 1
			else
				# 普通 apk add 会倾向保留已安装版本；后续维护使用 --upgrade。
				apk add --upgrade nikki luci-app-nikki luci-i18n-nikki-zh-cn || return 1
			fi
			;;
		*) return 1 ;;
	esac
	report_nikki_package_result "$ipf_before"
}

install_or_update_nikki() {
	say ""
	say "================ Nikki 安装/更新 ================"
	backup_install_state || fatal "无法建立安装前备份（可能存储空间不足）"
	feed_script="$WORK_DIR/feed.sh"
	install_script="$WORK_DIR/install.sh"
	io_success=0
	if feed_present && feed_current; then
		info "已检测到 Nikki 官方软件源，正在刷新索引并安装/升级 Nikki 及依赖"
		if install_packages_from_feed; then
			ok "方案 A 完成"
			io_success=1
		else
			warn "方案 A 更新失败，将尝试方案 B"
		fi
	else
		if feed_present; then
			warn "现有 Nikki 软件源与当前固件分支/架构不匹配，将按官方脚本刷新"
		else
			info "未检测到 Nikki 软件源，正在按官方方案 A 添加"
		fi
		feed_url="https://raw.githubusercontent.com/${NIKKI_REPO}/refs/heads/main/feed.sh"
		if fetch_url "$feed_url" "$feed_script" script && grep -q 'nikkinikki.pages.dev' "$feed_script" && (cd "$WORK_DIR" && ash "$feed_script") && install_packages_from_feed 0; then
			ok "方案 A 添加软件源并安装完成"
			io_success=1
		else
			warn "方案 A 失败，将尝试官方发行包方案 B"
		fi
	fi

	if [ "$io_success" -ne 1 ]; then
		install_url="https://raw.githubusercontent.com/${NIKKI_REPO}/refs/heads/main/install.sh"
		io_before="$(nikki_version 2>/dev/null || true)"
		io_b_ok=1
		fetch_url "$install_url" "$install_script" script || io_b_ok=0
		[ "$io_b_ok" -ne 1 ] || grep -q "Nikki's installer" "$install_script" || io_b_ok=0
		[ "$io_b_ok" -ne 1 ] || (cd "$WORK_DIR" && ash "$install_script") || io_b_ok=0
		if [ "$io_b_ok" -eq 1 ] && [ "$PKG_MANAGER" = "apk" ]; then
			io_repo="https://nikkinikki.pages.dev/${OFFICIAL_BRANCH}/${OPENWRT_ARCH}/nikki/packages.adb"
			apk add --upgrade --allow-untrusted -X "$io_repo" nikki luci-app-nikki luci-i18n-nikki-zh-cn || io_b_ok=0
		fi
		[ "$io_b_ok" -ne 1 ] || report_nikki_package_result "$io_before" || io_b_ok=0
		if [ "$io_b_ok" -ne 1 ]; then
			restore_install_state
			fatal "方案 A、B 均失败；已尽可能恢复配置、内核、软件源和本次新增包"
		fi
	fi

	if ! pkg_is_installed nikki || [ ! -x /etc/init.d/nikki ] || [ ! -x "$CORE_PATH" ]; then
		restore_install_state
		fatal "Nikki 安装后完整性检查失败，已回滚"
	fi
	# Nikki 的官方依赖包含 curl；重新选择后续大文件下载器。
	select_downloader
	# 安装阶段已经提交，释放可能包含模型/UI 的临时整目录备份，避免挤占 /tmp。
	[ ! -d "$WORK_DIR/install-backup" ] || safe_rm_tree "$WORK_DIR/install-backup" >/dev/null 2>&1 || true
	ok "Nikki 最新版及依赖已安装或更新完成。"
}

ensure_update_tools() {
	eut_missing=""
	command -v gzip >/dev/null 2>&1 || eut_missing="$eut_missing gzip"
	command -v unzip >/dev/null 2>&1 || eut_missing="$eut_missing unzip"
	command -v curl >/dev/null 2>&1 || eut_missing="$eut_missing curl"
	if [ -n "$eut_missing" ]; then
		info "安装维护工具：$eut_missing"
		pkg_update >/dev/null 2>&1 || return 1
		# shellcheck disable=SC2086
		pkg_install $eut_missing || return 1
	fi
	select_downloader
	return 0
}

nikki_running() {
	if command -v pidof >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1; then return 0; fi
	/etc/init.d/nikki status >/dev/null 2>&1
}

wait_nikki() {
	wn_i=0
	while [ "$wn_i" -lt 15 ]; do nikki_running && return 0; sleep 1; wn_i=$((wn_i + 1)); done
	return 1
}

begin_transaction() {
	mkdir -p "$RUN_DIR" "$WORK_DIR" || return 1
	[ ! -e "$CORE_BACKUP" ] && [ ! -e "$MODEL_BACKUP" ] && [ ! -e "$UI_BACKUP" ] || return 1
	if nikki_running; then WAS_RUNNING=1; else WAS_RUNNING=0; fi
	if [ -f "$CORE_PATH" ]; then CORE_EXISTED=1; fi
	if [ -f "$MODEL_PATH" ]; then MODEL_EXISTED=1; fi
	if [ -d "$UI_TARGET" ]; then UI_EXISTED=1; fi
	if [ -f /etc/config/nikki ]; then CONFIG_EXISTED=1; cp -p /etc/config/nikki "$CONFIG_BACKUP" || return 1; fi
	mkdir "$GEOX_BACKUP" || return 1
	for bt_file in GeoSite.dat GeoIP.dat Country.mmdb ASN.mmdb; do
		if [ -f "$RUN_DIR/$bt_file" ]; then cp -p "$RUN_DIR/$bt_file" "$GEOX_BACKUP/$bt_file" || return 1; fi
	done
	TRANSACTION_ACTIVE=1
	return 0
}

rollback_transaction() {
	warn "维护事务失败，正在恢复内核、模型、GeoX、面板及 Nikki 配置……"
	/etc/init.d/nikki stop >/dev/null 2>&1 || true
	if [ -e "$CORE_BACKUP" ]; then rm -f -- "$CORE_PATH"; mv "$CORE_BACKUP" "$CORE_PATH" || true;
	elif [ "$CORE_EXISTED" -eq 0 ]; then rm -f -- "$CORE_PATH"; fi
	if [ -e "$MODEL_BACKUP" ]; then rm -f -- "$MODEL_PATH"; mv "$MODEL_BACKUP" "$MODEL_PATH" || true;
	elif [ "$MODEL_EXISTED" -eq 0 ]; then rm -f -- "$MODEL_PATH"; fi
	if [ -e "$UI_BACKUP" ]; then safe_rm_tree "$UI_TARGET" >/dev/null 2>&1 || true; mv "$UI_BACKUP" "$UI_TARGET" || true;
	elif [ "$UI_EXISTED" -eq 0 ] && [ -d "$UI_TARGET" ]; then safe_rm_tree "$UI_TARGET" >/dev/null 2>&1 || true; fi
	for rt_file in GeoSite.dat GeoIP.dat Country.mmdb ASN.mmdb; do
		if [ -f "$GEOX_BACKUP/$rt_file" ]; then cp -p "$GEOX_BACKUP/$rt_file" "$RUN_DIR/$rt_file" || true;
		else rm -f -- "$RUN_DIR/$rt_file"; fi
	done
	if [ -f "$CONFIG_BACKUP" ]; then cp -p "$CONFIG_BACKUP" /etc/config/nikki || true;
	elif [ "$CONFIG_EXISTED" -eq 0 ]; then rm -f /etc/config/nikki; fi
	if [ "$WAS_RUNNING" -eq 1 ]; then /etc/init.d/nikki restart >/dev/null 2>&1 || true; fi
	TRANSACTION_ACTIVE=0
	cleanup_transaction_backups
	err "已回滚到本次菜单操作开始前的状态"
}

cleanup_transaction_backups() {
	rm -f -- "$CORE_BACKUP" "$MODEL_BACKUP" "$CONFIG_BACKUP" 2>/dev/null || true
	[ ! -d "$UI_BACKUP" ] || safe_rm_tree "$UI_BACKUP" >/dev/null 2>&1 || true
	[ ! -d "$GEOX_BACKUP" ] || safe_rm_tree "$GEOX_BACKUP" >/dev/null 2>&1 || true
}

json_field() {
	jf_key="$1"; jf_file="$2"
	tr -d '\r\n' < "$jf_file" | awk -v key="$jf_key" '
		function strfield(s,k, marker,p,v) {
			marker="\"" k "\""; p=index(s,marker); if(!p)return "";
			v=substr(s,p+length(marker)); sub(/^[[:space:]]*:[[:space:]]*"/,"",v); sub(/".*$/,"",v); return v
		}
		{v=strfield($0,key);if(v!=""){print v;exit}}
	'
}

asset_lines() {
	al_json="$1"
	# 兼容 GitHub 直连返回的格式化 JSON，以及部分反代返回的单行 JSON。
	tr -d '\r\n' < "$al_json" |
		sed 's/{[[:space:]]*"url"[[:space:]]*:[[:space:]]*"https:\/\/api.github.com\/repos\/[^\"]*\/releases\/assets\//\
&/g' |
		sed '1d'
}

asset_record_by_name() {
	ar_name="$1"; ar_json="$2"
	asset_lines "$ar_json" 2>/dev/null | awk -v target="$ar_name" '
		function strfield(s,k, marker,p,v) {marker="\"" k "\"";p=index(s,marker);if(!p)return "";v=substr(s,p+length(marker));sub(/^[[:space:]]*:[[:space:]]*"/,"",v);sub(/".*$/,"",v);return v}
		function numfield(s,k, marker,p,v) {marker="\"" k "\"";p=index(s,marker);if(!p)return "";v=substr(s,p+length(marker));sub(/^[[:space:]]*:[[:space:]]*/,"",v);sub(/[,}].*$/,"",v);return v}
		{name=strfield($0,"name");if(name==target){url=strfield($0,"browser_download_url");digest=strfield($0,"digest");sub(/^sha256:/,"",digest);size=numfield($0,"size");print url "|" digest "|" size "|" name;exit}}
	'
}

core_asset_record() {
	car_json="$1"; car_prefix="mihomo-linux-${ASSET_ARCH}-"
	asset_lines "$car_json" 2>/dev/null | awk -v prefix="$car_prefix" '
		function strfield(s,k, marker,p,v) {marker="\"" k "\"";p=index(s,marker);if(!p)return "";v=substr(s,p+length(marker));sub(/^[[:space:]]*:[[:space:]]*"/,"",v);sub(/".*$/,"",v);return v}
		function numfield(s,k, marker,p,v) {marker="\"" k "\"";p=index(s,marker);if(!p)return "";v=substr(s,p+length(marker));sub(/^[[:space:]]*:[[:space:]]*/,"",v);sub(/[,}].*$/,"",v);return v}
		{name=strfield($0,"name");if(index(name,prefix)==1 && name ~ /\.gz$/ && name !~ /-go[0-9]+/){url=strfield($0,"browser_download_url");digest=strfield($0,"digest");sub(/^sha256:/,"",digest);size=numfield($0,"size");print url "|" digest "|" size "|" name;exit}}
	'
}

split_record() {
	sr_record="$1"
	REC_URL="${sr_record%%|*}"; sr_record="${sr_record#*|}"
	REC_SHA="${sr_record%%|*}"; sr_record="${sr_record#*|}"
	REC_SIZE="${sr_record%%|*}"; REC_NAME="${sr_record#*|}"
}

verify_download() {
	vd_file="$1"; vd_sha="$2"; vd_size="$3"
	vd_actual_size="$(wc -c < "$vd_file" | tr -d ' ')"
	case "$vd_size" in ""|*[!0-9]*) ;; *) [ "$vd_actual_size" = "$vd_size" ] || return 1 ;; esac
	case "$vd_sha" in
		"") warn "上游 API 未提供 SHA-256，将依靠格式及运行校验" ;;
		*[!0-9A-Fa-f]*) return 1 ;;
		*)
			[ "${#vd_sha}" -eq 64 ] || return 1
			if command -v sha256sum >/dev/null 2>&1; then
				vd_actual_sha="$(sha256sum "$vd_file" | awk '{print $1}')"
				[ "$vd_actual_sha" = "$vd_sha" ] || return 1
				ok "SHA-256 校验通过"
			else warn "系统缺少 sha256sum，无法核对摘要"; fi
			;;
	esac
	return 0
}

prepare_core() {
	pc_kind="$1"
	case "$pc_kind" in
		smart) pc_repo="vernesong/mihomo"; pc_api="https://api.github.com/repos/${pc_repo}/releases/tags/Prerelease-Alpha" ;;
		alpha) pc_repo="MetaCubeX/mihomo"; pc_api="https://api.github.com/repos/${pc_repo}/releases/tags/Prerelease-Alpha" ;;
		stable) pc_repo="MetaCubeX/mihomo"; pc_api="https://api.github.com/repos/${pc_repo}/releases/latest" ;;
		*) return 1 ;;
	esac
	pc_json="$WORK_DIR/core-release.json"
	pc_gz="$WORK_DIR/mihomo.gz"
	pc_new="$WORK_DIR/mihomo.new"
	info "查询 ${pc_repo} 的发行资产……"
	fetch_url "$pc_api" "$pc_json" json || return 1
	pc_record="$(core_asset_record "$pc_json")"
	[ -n "$pc_record" ] || { err "未找到 ${ASSET_ARCH} 对应内核"; return 1; }
	split_record "$pc_record"
	info "匹配资产：$REC_NAME"
	fetch_url "$REC_URL" "$pc_gz" gzip || return 1
	verify_download "$pc_gz" "$REC_SHA" "$REC_SIZE" || { err "内核大小/SHA-256 校验失败"; return 1; }
	gzip -dc "$pc_gz" > "$pc_new" || return 1
	chmod 0755 "$pc_new" || return 1
	NEW_CORE_VERSION="$("$pc_new" -v 2>/dev/null | head -n 1 || true)"
	[ -n "$NEW_CORE_VERSION" ] || { err "新内核无法在当前 CPU 上执行"; return 1; }
	if [ -s "$RUN_DIR/config.yaml" ]; then
		info "使用新内核检查当前 Nikki 配置……"
		if ! "$pc_new" -t -d "$RUN_DIR" -f "$RUN_DIR/config.yaml" > "$WORK_DIR/core-test.log" 2>&1; then
			tail -n 20 "$WORK_DIR/core-test.log" >&2 || true
			err "新内核未通过当前配置检查"
			return 1
		fi
	fi
	cp "$pc_new" "${CORE_PATH}.new.${PID}" || return 1
	chmod 0755 "${CORE_PATH}.new.${PID}" || return 1
	if [ -f "$CORE_PATH" ] && [ ! -e "$CORE_BACKUP" ]; then cp -p "$CORE_PATH" "$CORE_BACKUP" || return 1; fi
	mv "${CORE_PATH}.new.${PID}" "$CORE_PATH" || return 1
	CORE_KIND_NEW="$pc_kind"
	ok "内核已暂存安装：$NEW_CORE_VERSION"
	return 0
}

memory_mb() { awk '/MemTotal:/{print int($2/1024);exit}' /proc/meminfo 2>/dev/null; }
cpu_count() { grep -c '^processor[[:space:]]*:' /proc/cpuinfo 2>/dev/null || printf '1'; }
free_kb_at() { df -Pk "$1" 2>/dev/null | awk 'NR==2{print $4;exit}'; }

auto_model_choice() {
	am_mem="$(memory_mb)"; am_cpu="$(cpu_count)"; am_free="$(free_kb_at "$RUN_DIR")"
	case "$am_mem" in ""|*[!0-9]*) am_mem=0 ;; esac
	case "$am_cpu" in ""|*[!0-9]*) am_cpu=1 ;; esac
	case "$am_free" in ""|*[!0-9]*) am_free=0 ;; esac
	# 同时满足内存、CPU 核心数和持久存储空间；保留至少约 12 MiB 余量。
	if [ "$am_mem" -ge 1024 ] && [ "$am_cpu" -ge 4 ] && [ "$am_free" -ge $((34 * 1024)) ]; then printf '%s' large
	elif [ "$am_mem" -ge 512 ] && [ "$am_cpu" -ge 2 ] && [ "$am_free" -ge $((24 * 1024)) ]; then printf '%s' middle
	elif [ "$am_mem" -ge 128 ] && [ "$am_free" -ge $((20 * 1024)) ]; then printf '%s' small
	else return 1; fi
}

prepare_model() {
	pm_choice="$LGBM_CHOICE"
	if [ "$pm_choice" = "auto" ]; then
		pm_choice="$(auto_model_choice)" || { err "性能或存储不足以安全安装轻量模型"; return 1; }
		info "自动评估：内存 $(memory_mb) MiB、CPU $(cpu_count) 核、可用空间 $(( $(free_kb_at "$RUN_DIR") / 1024 )) MiB，选择 ${pm_choice}"
	fi
	case "$pm_choice" in
		small) pm_name="Model.bin"; pm_label="Model-small（轻量版）" ;;
		middle) pm_name="Model-middle.bin"; pm_label="Model-middle（中型版）" ;;
		large) pm_name="Model-large.bin"; pm_label="Model-large（大型版）" ;;
		*) return 1 ;;
	esac
	pm_api="https://api.github.com/repos/vernesong/mihomo/releases/tags/LightGBM-Model"
	pm_json="$WORK_DIR/model-release.json"
	pm_file="$WORK_DIR/$pm_name"
	if fetch_url "$pm_api" "$pm_json" json; then
		pm_record="$(asset_record_by_name "$pm_name" "$pm_json")"
	else pm_record=""; fi
	if [ -n "$pm_record" ]; then
		split_record "$pm_record"
	else
		warn "模型 API 不可用，使用固定 Release 地址"
		REC_URL="https://github.com/vernesong/mihomo/releases/download/LightGBM-Model/${pm_name}"
		REC_SHA=""; REC_SIZE=""; REC_NAME="$pm_name"
	fi
	fetch_url "$REC_URL" "$pm_file" model || return 1
	verify_download "$pm_file" "$REC_SHA" "$REC_SIZE" || { err "模型大小/SHA-256 校验失败"; return 1; }
	pm_free="$(free_kb_at "$RUN_DIR")"; pm_need=$((($(wc -c < "$pm_file") + 1023) / 1024 + 12 * 1024))
	[ "$pm_free" -ge "$pm_need" ] || { err "模型分区空间不足（需含预留约 $((pm_need/1024)) MiB）"; return 1; }
	cp "$pm_file" "${MODEL_PATH}.new.${PID}" || return 1
	chmod 0644 "${MODEL_PATH}.new.${PID}" || return 1
	if [ -f "$MODEL_PATH" ] && [ ! -e "$MODEL_BACKUP" ]; then cp -p "$MODEL_PATH" "$MODEL_BACKUP" || return 1; fi
	mv "${MODEL_PATH}.new.${PID}" "$MODEL_PATH" || return 1
	LGBM_CHOICE="$pm_choice"
	MODEL_LABEL_NEW="$pm_label"
	ok "LightGBM 模型已暂存安装：$MODEL_LABEL_NEW"
	return 0
}

prepare_geox() {
	pg_api="https://api.github.com/repos/MetaCubeX/meta-rules-dat/releases/latest"
	pg_json="$WORK_DIR/geox-release.json"
	if fetch_url "$pg_api" "$pg_json" json; then
		pg_have_api=1
		GEOX_DATE_NEW="$(json_field published_at "$pg_json" | cut -c1-10 | tr '-' '/')"
		[ -n "$GEOX_DATE_NEW" ] || GEOX_DATE_NEW="unknown"
	else
		pg_have_api=0
		GEOX_DATE_NEW="latest"
		warn "GeoX API 不可用，改用官方 latest 固定地址"
	fi
	pg_stage="$RUN_DIR/.geox-stage.${PID}"
	mkdir "$pg_stage" || return 1
	for pg_item in "geosite.dat:GeoSite.dat:dat" "geoip.dat:GeoIP.dat:dat" "country.mmdb:Country.mmdb:mmdb" "GeoLite2-ASN.mmdb:ASN.mmdb:mmdb"; do
		pg_remote="${pg_item%%:*}"; pg_rest="${pg_item#*:}"; pg_local="${pg_rest%%:*}"; pg_kind="${pg_rest#*:}"
		if [ "$pg_have_api" -eq 1 ]; then pg_record="$(asset_record_by_name "$pg_remote" "$pg_json")"; else pg_record=""; fi
		if [ -n "$pg_record" ]; then split_record "$pg_record";
		else REC_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/${pg_remote}"; REC_SHA=""; REC_SIZE=""; fi
		info "下载 GeoX：$pg_remote"
		fetch_url "$REC_URL" "$pg_stage/$pg_local" "$pg_kind" || { safe_rm_tree "$pg_stage" >/dev/null 2>&1 || true; return 1; }
		verify_download "$pg_stage/$pg_local" "$REC_SHA" "$REC_SIZE" || { err "$pg_remote 校验失败"; safe_rm_tree "$pg_stage" >/dev/null 2>&1 || true; return 1; }
	done
	for pg_file in GeoSite.dat GeoIP.dat Country.mmdb ASN.mmdb; do
		if ! mv "$pg_stage/$pg_file" "$RUN_DIR/$pg_file"; then
			for pg_restore in GeoSite.dat GeoIP.dat Country.mmdb ASN.mmdb; do
				if [ -f "$GEOX_BACKUP/$pg_restore" ]; then cp -p "$GEOX_BACKUP/$pg_restore" "$RUN_DIR/$pg_restore" || true;
				else rm -f -- "$RUN_DIR/$pg_restore"; fi
			done
			safe_rm_tree "$pg_stage" >/dev/null 2>&1 || true
			return 1
		fi
	done
	rmdir "$pg_stage" 2>/dev/null || true
	ok "GeoX 数据库已暂存更新：$GEOX_DATE_NEW"
	return 0
}

yaml_external_ui_url() {
	awk '
		/^[[:space:]]*external-ui-url[[:space:]]*:/ {
			sub(/^[^:]*:[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, ""); gsub(/^"|"$/, ""); print; exit
		}' "$1" 2>/dev/null
}

yaml_external_ui_name() {
	awk '
		/^[[:space:]]*external-ui-name[[:space:]]*:/ {
			sub(/^[^:]*:[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, ""); gsub(/^"|"$/, ""); print; exit
		}' "$1" 2>/dev/null
}

zashboard_url_for_asset() {
	zua_url="$1"; zua_asset="$2"
	case "$zua_url" in
		*Zephyruso/zashboard/releases/*/download/*.zip*) printf '%s/%s' "${zua_url%/*}" "$zua_asset" ;;
		*) printf 'https://github.com/Zephyruso/zashboard/releases/latest/download/%s' "$zua_asset" ;;
	esac
}

prepare_zashboard() {
	pz_api="https://api.github.com/repos/Zephyruso/zashboard/releases/latest"
	pz_json="$WORK_DIR/zashboard-release.json"
	pz_zip="$WORK_DIR/zashboard.zip"
	pz_asset="$ZASH_ASSET"
	case "$pz_asset" in dist.zip|dist-no-fonts.zip|dist-cdn-fonts.zip|dist-firasans-only.zip|dist-misans-only.zip|dist-pingfang-only.zip|dist-sarasa-only.zip) ;; *) err "不支持的 Zashboard 发行包：$pz_asset"; return 1 ;; esac
	if fetch_url "$pz_api" "$pz_json" json; then
		pz_tag="$(json_field tag_name "$pz_json")"
		pz_record="$(asset_record_by_name "$pz_asset" "$pz_json")"
	else
		warn "Zashboard API 不可用，改用官方 latest 下载地址"
		pz_tag="latest"
		pz_record=""
	fi
	[ -n "$pz_tag" ] || pz_tag="latest"
	ZASH_VERSION_NEW="${pz_tag} (${ZASH_VARIANT_LABEL})"
	if [ -n "$pz_record" ]; then split_record "$pz_record";
	else REC_URL="https://github.com/Zephyruso/zashboard/releases/latest/download/${pz_asset}"; REC_SHA=""; REC_SIZE=""; fi
	fetch_url "$REC_URL" "$pz_zip" zip || return 1
	verify_download "$pz_zip" "$REC_SHA" "$REC_SIZE" || { err "Zashboard 校验失败"; return 1; }
	pz_stage="$RUN_DIR/.zashboard-stage.${PID}"
	mkdir "$pz_stage" || return 1
	unzip -q "$pz_zip" -d "$pz_stage" || { safe_rm_tree "$pz_stage" >/dev/null 2>&1 || true; return 1; }
	# 兼容压缩包外层包含 dist/ 目录的情况。
	if [ ! -f "$pz_stage/index.html" ] && [ -f "$pz_stage/dist/index.html" ]; then
		mv "$pz_stage/dist" "${pz_stage}.inner" || return 1
		safe_rm_tree "$pz_stage" >/dev/null 2>&1 || true
		mv "${pz_stage}.inner" "$pz_stage" || return 1
	fi
	[ -s "$pz_stage/index.html" ] && [ -d "$pz_stage/assets" ] || { err "Zashboard 压缩包目录结构不完整"; safe_rm_tree "$pz_stage" >/dev/null 2>&1 || true; return 1; }
	mkdir -p "$UI_DIR" || { safe_rm_tree "$pz_stage" >/dev/null 2>&1 || true; return 1; }
	if [ -d "$UI_TARGET" ] && [ ! -e "$UI_BACKUP" ]; then mv "$UI_TARGET" "$UI_BACKUP" || return 1; fi
	if ! mv "$pz_stage" "$UI_TARGET"; then
		[ ! -d "$UI_BACKUP" ] || mv "$UI_BACKUP" "$UI_TARGET" || true
		return 1
	fi
	if command -v uci >/dev/null 2>&1; then
		pz_uci_ok=1
		uci set nikki.mixin.ui_path='ui' || pz_uci_ok=0
		[ "$pz_uci_ok" -ne 1 ] || uci set nikki.mixin.ui_name="$UI_NAME" || pz_uci_ok=0
		pz_current_url="$(uci -q get nikki.mixin.ui_url 2>/dev/null || true)"
		pz_yaml_url="$(yaml_external_ui_url "$RUN_DIR/config.yaml" || true)"
		pz_candidate=""
		case "$pz_current_url" in
			*Zephyruso/zashboard/releases/*/download/*.zip*) pz_candidate="$pz_current_url" ;;
		esac
		if [ -z "$pz_candidate" ]; then
			case "$pz_yaml_url" in *Zephyruso/zashboard/releases/*/download/*.zip*) pz_candidate="$pz_yaml_url" ;; esac
		fi
		pz_keep_url="$(zashboard_url_for_asset "$pz_candidate" "$pz_asset")"
		info "设置 Zashboard ${ZASH_VARIANT_LABEL} 版本下载地址：$pz_keep_url"
		[ "$pz_uci_ok" -ne 1 ] || uci set nikki.mixin.ui_url="$pz_keep_url" || pz_uci_ok=0
		[ "$pz_uci_ok" -ne 1 ] || uci commit nikki || pz_uci_ok=0
		if [ "$pz_uci_ok" -ne 1 ]; then
			safe_rm_tree "$UI_TARGET" >/dev/null 2>&1 || true
			[ ! -d "$UI_BACKUP" ] || mv "$UI_BACKUP" "$UI_TARGET" || true
			[ ! -f "$CONFIG_BACKUP" ] || cp -p "$CONFIG_BACKUP" /etc/config/nikki || true
			return 1
		fi
	fi
	[ -s "$UI_TARGET/index.html" ] && [ -d "$UI_TARGET/assets" ] || {
		err "Zashboard 安装后目录验证失败：$UI_TARGET"
		safe_rm_tree "$UI_TARGET" >/dev/null 2>&1 || true
		[ ! -d "$UI_BACKUP" ] || mv "$UI_BACKUP" "$UI_TARGET" || true
		[ ! -f "$CONFIG_BACKUP" ] || cp -p "$CONFIG_BACKUP" /etc/config/nikki || true
		return 1
	}
	ok "Zashboard 目标目录验证通过：$UI_TARGET"
	ok "Zashboard 已暂存更新：${ZASH_VERSION_NEW:-unknown}"
	return 0
}

verify_zashboard_runtime() {
	[ -s "$UI_TARGET/index.html" ] && [ -d "$UI_TARGET/assets" ] || { err "Zashboard 目标目录不存在或不完整：$UI_TARGET"; return 1; }
	if command -v uci >/dev/null 2>&1; then
		vzr_path="$(uci -q get nikki.mixin.ui_path 2>/dev/null || true)"
		vzr_name="$(uci -q get nikki.mixin.ui_name 2>/dev/null || true)"
		[ "$vzr_path" = "ui" ] && [ "$vzr_name" = "$UI_NAME" ] || { err "Nikki UCI 面板配置不匹配：ui_path=${vzr_path:-空}, ui_name=${vzr_name:-空}"; return 1; }
	fi
	if [ "$WAS_RUNNING" -eq 1 ] && [ -s "$RUN_DIR/config.yaml" ]; then
		vzr_yaml_name="$(yaml_external_ui_name "$RUN_DIR/config.yaml" || true)"
		[ "$vzr_yaml_name" = "$UI_NAME" ] || { err "运行配置未生成 external-ui-name: $UI_NAME"; return 1; }
	fi
	ok "Zashboard 运行路径确认：/ui/${UI_NAME}/"
	return 0
}

sanitize_state() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._+ /:()-'; }

write_state() {
	ws_tmp="${STATE_FILE}.new.${PID}"
	{
		printf 'CORE_KIND=%s\n' "$(sanitize_state "$CORE_KIND_NEW")"
		printf 'CORE_VERSION=%s\n' "$(sanitize_state "$NEW_CORE_VERSION")"
		printf 'MODEL=%s\n' "$(sanitize_state "${MODEL_LABEL_NEW:-不适用}")"
		printf 'GEOX_DATE=%s\n' "$(sanitize_state "$GEOX_DATE_NEW")"
		printf 'ZASH_VERSION=%s\n' "$(sanitize_state "$ZASH_VERSION_NEW")"
		printf 'UPDATED_AT=%s\n' "$(date '+%Y/%m/%d %H:%M:%S' 2>/dev/null || true)"
	} > "$ws_tmp" || return 1
	mv "$ws_tmp" "$STATE_FILE" || return 1
}

commit_transaction() {
	if [ "$WAS_RUNNING" -eq 1 ]; then
		info "重启 Nikki 并验证服务状态……"
		if ! /etc/init.d/nikki restart || ! wait_nikki; then return 1; fi
		ok "Nikki 已使用新内核正常运行"
	else
		info "更新前 Nikki 未运行，保持停止状态"
	fi
	if [ "$ZASH_UPDATE_STATUS" = "updated" ] && ! verify_zashboard_runtime; then return 1; fi
	write_state || return 1
	TRANSACTION_ACTIVE=0
	if [ "$KEEP_BACKUP_ON_SUCCESS" != "1" ]; then cleanup_transaction_backups; fi
	return 0
}

run_maintenance() {
	rm_kind="$1"
	if [ "$rm_kind" = skip ] && [ "$GEOX_CHOICE" = skip ] && [ "$ZASH_CHOICE" = skip ]; then
		CORE_UPDATE_STATUS="user_skipped"
		MODEL_UPDATE_STATUS="not_selected"
		GEOX_UPDATE_STATUS="user_skipped"
		ZASH_UPDATE_STATUS="user_skipped"
		info "内核、GeoX 和 Zashboard 均已选择跳过，保留当前文件"
		return 0
	fi
	ensure_update_tools || fatal "维护工具安装失败"
	if ! begin_transaction; then
		cleanup_transaction_backups
		fatal "无法建立事务备份；请检查 /tmp 与 overlay 可用空间"
	fi
	CORE_KIND_NEW=""
	NEW_CORE_VERSION="$("$CORE_PATH" -v 2>/dev/null | head -n 1 || true)"
	MODEL_LABEL_NEW="$(state_get MODEL)"
	GEOX_DATE_NEW="$(state_get GEOX_DATE)"
	ZASH_VERSION_NEW="$(state_get ZASH_VERSION)"
	if [ -n "$NEW_CORE_VERSION" ]; then
		case "$NEW_CORE_VERSION" in *alpha-smart*) CORE_KIND_NEW="smart" ;; *alpha*) CORE_KIND_NEW="alpha" ;; *) CORE_KIND_NEW="stable" ;; esac
	else CORE_KIND_NEW="$(state_get CORE_KIND)"; NEW_CORE_VERSION="$(state_get CORE_VERSION)"; fi
	[ -n "$MODEL_LABEL_NEW" ] || { [ -s "$MODEL_PATH" ] && MODEL_LABEL_NEW="已安装（版本未知）" || MODEL_LABEL_NEW="未安装"; }
	[ -n "$GEOX_DATE_NEW" ] || GEOX_DATE_NEW="$(file_date "$RUN_DIR/GeoSite.dat")"
	[ -n "$ZASH_VERSION_NEW" ] || ZASH_VERSION_NEW="unknown"
	MAINT_SUCCESS=0
	case "$rm_kind" in
		smart)
			rm_old_kind="$CORE_KIND_NEW"; rm_old_core_version="$NEW_CORE_VERSION"
			if prepare_core smart; then CORE_UPDATE_STATUS="updated"; MAINT_SUCCESS=$((MAINT_SUCCESS + 1));
			else CORE_KIND_NEW="$rm_old_kind"; NEW_CORE_VERSION="$rm_old_core_version"; CORE_UPDATE_STATUS="skipped"; warn "无法更新 Smart 内核，已跳过此项并保留原文件；建议稍后手动更新"; fi
			if [ "$LGBM_CHOICE" = skip ]; then
				MODEL_UPDATE_STATUS="user_skipped"
				info "已按选择跳过 LightGBM 模型更新"
				[ -s "$MODEL_PATH" ] || warn "当前未检测到 LightGBM 模型，Smart 内核相关功能可能不可用"
			elif prepare_model; then MODEL_UPDATE_STATUS="updated"; MAINT_SUCCESS=$((MAINT_SUCCESS + 1));
			else MODEL_UPDATE_STATUS="skipped"; warn "无法更新 LightGBM 模型，已跳过此项并保留原文件；建议稍后手动更新"; fi
			;;
		alpha)
			rm_old_kind="$CORE_KIND_NEW"; rm_old_core_version="$NEW_CORE_VERSION"
			if prepare_core alpha; then CORE_UPDATE_STATUS="updated"; MODEL_LABEL_NEW="不适用"; MAINT_SUCCESS=$((MAINT_SUCCESS + 1));
			else CORE_KIND_NEW="$rm_old_kind"; NEW_CORE_VERSION="$rm_old_core_version"; CORE_UPDATE_STATUS="skipped"; warn "无法更新开发预览版内核，已跳过此项并保留原文件；建议稍后手动更新"; fi
			;;
		stable)
			rm_old_kind="$CORE_KIND_NEW"; rm_old_core_version="$NEW_CORE_VERSION"
			if prepare_core stable; then CORE_UPDATE_STATUS="updated"; MODEL_LABEL_NEW="不适用"; MAINT_SUCCESS=$((MAINT_SUCCESS + 1));
			else CORE_KIND_NEW="$rm_old_kind"; NEW_CORE_VERSION="$rm_old_core_version"; CORE_UPDATE_STATUS="skipped"; warn "无法更新稳定版内核，已跳过此项并保留原文件；建议稍后手动更新"; fi
			;;
		skip)
			CORE_UPDATE_STATUS="user_skipped"
			MODEL_UPDATE_STATUS="not_selected"
			info "已按选择跳过内核更新"
			;;
	esac
	if [ "$GEOX_CHOICE" = update ]; then
		rm_old_geox="$GEOX_DATE_NEW"
		if prepare_geox; then GEOX_UPDATE_STATUS="updated"; MAINT_SUCCESS=$((MAINT_SUCCESS + 1));
		else GEOX_DATE_NEW="$rm_old_geox"; GEOX_UPDATE_STATUS="skipped"; warn "无法更新 GeoX 数据库，已跳过此项并保留原文件；建议稍后手动更新"; fi
	else GEOX_UPDATE_STATUS="user_skipped"; info "已按选择跳过 GeoX 数据库更新"; fi
	if [ "$ZASH_CHOICE" = update ]; then
		rm_old_zash="$ZASH_VERSION_NEW"
		if prepare_zashboard; then ZASH_UPDATE_STATUS="updated"; MAINT_SUCCESS=$((MAINT_SUCCESS + 1));
		else ZASH_VERSION_NEW="$rm_old_zash"; ZASH_UPDATE_STATUS="skipped"; warn "无法更新 Zashboard，已跳过此项并保留原文件；建议在 Nikki 中手动更新面板"; fi
	else ZASH_UPDATE_STATUS="user_skipped"; info "已按选择跳过 Zashboard 更新"; fi
	if [ "$MAINT_SUCCESS" -eq 0 ]; then
		TRANSACTION_ACTIVE=0
		cleanup_transaction_backups
		warn "本次所有维护项目均更新失败，原文件保持不变"
		return 0
	fi
	if ! commit_transaction; then rollback_transaction; fatal "新版本安装后服务验证失败"; fi
}

state_get() { sg_key="$1"; sed -n "s/^${sg_key}=//p" "$STATE_FILE" 2>/dev/null | head -n 1; }

file_date() {
	fd_file="$1"
	date -r "$fd_file" '+%Y/%m/%d' 2>/dev/null || printf '%s' unknown
}

print_summary() {
	ps_nikki="$(nikki_version)"; [ -n "$ps_nikki" ] || ps_nikki="unknown"
	ps_core="$("$CORE_PATH" -v 2>/dev/null | head -n 1 || true)"; [ -n "$ps_core" ] || ps_core="unknown"
	ps_kind="$(state_get CORE_KIND)"; ps_model="$(state_get MODEL)"; ps_geox="$(state_get GEOX_DATE)"; ps_zash="$(state_get ZASH_VERSION)"
	case "$ps_core" in *alpha-smart*) ps_kind=smart ;; *alpha*) ps_kind=alpha ;; unknown) ;; *) ps_kind=stable ;; esac
	[ -n "$ps_geox" ] || ps_geox="$(file_date "$RUN_DIR/GeoSite.dat")"
	[ -n "$ps_zash" ] || ps_zash="unknown"
	say ""
	menu_line "================ 当前维护结果 ================"
	ps_latest="${B}${G}已最新${N}"
	ps_failed="${B}${R}本次更新失败，已保留原版本${N}"
	ps_user_skipped="${B}${Y}已按选择跳过，保留当前版本${N}"
	case "$NIKKI_UPDATE_STATUS" in updated) ps_nikki_result="$ps_latest" ;; user_skipped) ps_nikki_result="$ps_user_skipped" ;; *) ps_nikki_result="" ;; esac
	summary_item "当前 Nikki" "$ps_nikki" "$ps_nikki_result"
	case "$CORE_UPDATE_STATUS" in updated) ps_core_result="$ps_latest" ;; skipped) ps_core_result="$ps_failed" ;; user_skipped) ps_core_result="$ps_user_skipped" ;; *) ps_core_result="" ;; esac
	case "$MODEL_UPDATE_STATUS" in updated) ps_model_result="$ps_latest" ;; skipped) ps_model_result="$ps_failed" ;; user_skipped) ps_model_result="$ps_user_skipped" ;; *) ps_model_result="" ;; esac
	case "$GEOX_UPDATE_STATUS" in updated) ps_geox_result="$ps_latest" ;; skipped) ps_geox_result="$ps_failed" ;; user_skipped) ps_geox_result="$ps_user_skipped" ;; *) ps_geox_result="" ;; esac
	case "$ZASH_UPDATE_STATUS" in updated) ps_zash_result="$ps_latest" ;; skipped) ps_zash_result="$ps_failed" ;; user_skipped) ps_zash_result="$ps_user_skipped" ;; *) ps_zash_result="" ;; esac
	case "$ps_kind" in
		smart) summary_item "当前 Smart 内核" "$ps_core" "$ps_core_result"; summary_item "      LGBM模型" "${ps_model:-unknown}" "$ps_model_result" ;;
		alpha) summary_item "当前开发预览版内核（Prerelease-Alpha）" "$ps_core" "$ps_core_result" ;;
		stable) summary_item "当前稳定版内核（meta）" "$ps_core" "$ps_core_result" ;;
		*) summary_item "当前内核" "$ps_core" "" ;;
	esac
	say ""
	say "${B}${Y}当前 GeoX数据库：${N}"
	for ps_line in "geosite:GeoSite.dat" "geoip:GeoIP.dat" "mmdb:Country.mmdb" "asn:ASN.mmdb"; do
		ps_label="${ps_line%%:*}"; ps_file="${ps_line#*:}"
		if [ -s "$RUN_DIR/$ps_file" ]; then summary_item "  ${ps_label}" "$ps_geox" "$ps_geox_result"; else summary_missing "  ${ps_label}"; fi
	done
	say ""
	if [ -s "$UI_TARGET/index.html" ]; then summary_item "当前 Zashboard" "$ps_zash" "$ps_zash_result"; else summary_missing "当前 Zashboard"; fi
	menu_line "================================================"
}

# 通过 wget/curl | sh 执行时，标准输入属于脚本管道；交互选择必须从控制终端读取。
# 没有控制终端时再回退到标准输入，便于本地文件执行或测试重定向。
read_user_input() {
	USER_INPUT=""
	if [ -c /dev/tty ] && ( : </dev/tty ) 2>/dev/null; then
		IFS= read -r USER_INPUT </dev/tty
	else
		IFS= read -r USER_INPUT
	fi
}

main_menu() {
	mm_installed="$1"
	while :; do
		say ""
		menu_line "================ Nikki 全方位维护主菜单 ================"
		if [ "$mm_installed" -eq 1 ]; then
			say "${B}${G}Nikki 已安装（当前版本：$(nikki_version 2>/dev/null || printf '%s' unknown)）${N}"
		else
			say "${B}${Y}Nikki 未安装${N}"
		fi
		menu_line "  1）自动维护（一键自动化操作）"
		menu_line "  2）手动维护（可自定义版本及选择是否更新）"
		menu_line "  3）一键卸载重置并清理 Nikki 相关残留"
		menu_line "  4）退出脚本"
		menu_line "================================================"
		prompt '>>> 请手动选择 [1-4]：'
		read_user_input || fatal "无法读取主菜单选项"
		case "$USER_INPUT" in 1) MAIN_CHOICE="auto"; return 0 ;; 2) MAIN_CHOICE="manual"; return 0 ;; 3) MAIN_CHOICE="uninstall"; return 0 ;; 4) MAIN_CHOICE="exit"; return 0 ;; *) warn "无效选项，请重新输入" ;; esac
	done
}

automatic_maintenance_menu() {
	while :; do
		say ""
		menu_line "================ 自动维护项目菜单 ================"
		menu_line "  1）一键安装或更新 Nikki + Smart 内核 + 自动 LGBM + GeoX + Zashboard 完整版（dist.zip）"
		say "${B}${Y}     LGBM 将根据系统性能和剩余存储空间自动选择大、中、小模型。${N}"
		menu_line "  2）一键安装或更新 Nikki + Dev 预览版内核 + GeoX + Zashboard 完整版（dist.zip）"
		menu_line "  3）一键安装或更新 Nikki + 稳定版内核 + GeoX + Zashboard 完整版（dist.zip）"
		menu_line "  4）返回上一级菜单"
		menu_line "=================================================="
		prompt '>>> 请手动选择 [1-4]：'
		read_user_input || fatal "无法读取自动维护菜单选项"
		case "$USER_INPUT" in 1) AUTO_CHOICE="smart"; return 0 ;; 2) AUTO_CHOICE="alpha"; return 0 ;; 3) AUTO_CHOICE="stable"; return 0 ;; 4) AUTO_CHOICE="return"; return 0 ;; *) warn "无效选项，请重新输入" ;; esac
	done
}

manual_nikki_menu() {
	mnm_installed="$1"
	while :; do
		say ""
		menu_line "================ 手动维护：Nikki 项目 ================"
		if [ "$mnm_installed" -eq 1 ]; then
			say "${B}${G}Nikki 已安装（当前版本：$(nikki_version 2>/dev/null || printf '%s' unknown)）${N}"
			menu_line "  1）安装、更新或修复 Nikki 及其依赖"
			menu_line "  2）跳过 Nikki 更新，保留当前安装"
			menu_line "  3）返回上一级菜单"
			menu_line "======================================================"
			prompt '>>> 请手动选择 [1-3]：'
			read_user_input || fatal "无法读取 Nikki 手动维护选项"
			case "$USER_INPUT" in 1) MANUAL_NIKKI_CHOICE="update"; return 0 ;; 2) MANUAL_NIKKI_CHOICE="skip"; return 0 ;; 3) MANUAL_NIKKI_CHOICE="return"; return 0 ;; *) warn "无效选项，请重新输入" ;; esac
		else
			say "${B}${Y}Nikki 未安装${N}"
			menu_line "  1）安装 Nikki 最新版及其依赖"
			menu_line "  2）返回上一级菜单"
			menu_line "======================================================"
			prompt '>>> 请手动选择 [1-2]：'
			read_user_input || fatal "无法读取 Nikki 手动维护选项"
			case "$USER_INPUT" in 1) MANUAL_NIKKI_CHOICE="update"; return 0 ;; 2) MANUAL_NIKKI_CHOICE="return"; return 0 ;; *) warn "无效选项，请重新输入" ;; esac
		fi
	done
}

post_action_menu() {
	pam_context="$1"
	while :; do
		say ""
		if [ "$pam_context" = "uninstall" ]; then
			menu_line "================ 卸载完成 ================"
		else
			menu_line "================ 本轮维护完成 ================"
		fi
		menu_line "  1）返回开头的主菜单"
		menu_line "  2）退出脚本"
		menu_line "============================================"
		prompt '>>> 请手动选择 [1-2]：'
		read_user_input || fatal "无法读取完成菜单选项"
		case "$USER_INPUT" in
			1) return 0 ;;
			2) return 1 ;;
			*) warn "无效选项，请重新输入" ;;
		esac
	done
}

choose_lgbm() {
	while :; do
		say ""
		menu_line "================ LGBM 模型版本选择 ================"
		menu_line "  1）自动安装（按内存、CPU 核数和剩余存储空间选择）"
		menu_line "  2）轻量版（Model-small）"
		menu_line "  3）中型版（Model-middle）"
		menu_line "  4）大型版（Model-large）"
		menu_line "  5）跳过 LGBM 模型更新（保留现有模型，仅在已有兼容模型时建议）"
		menu_line "  0）返回上一级菜单"
		menu_line "===================================================="
		prompt '>>> 请手动选择 [0-5，默认1]：'
		read_user_input || fatal "无法读取模型选项"
		cl_choice="$USER_INPUT"
		case "$cl_choice" in
			""|1) LGBM_CHOICE=auto; LGBM_SET=1; return 0 ;;
			2) LGBM_CHOICE=small; LGBM_SET=1; return 0 ;;
			3) LGBM_CHOICE=middle; LGBM_SET=1; return 0 ;;
			4) LGBM_CHOICE=large; LGBM_SET=1; return 0 ;;
			5) LGBM_CHOICE=skip; LGBM_SET=1; return 0 ;;
			0) return 2 ;;
			*) warn "无效模型选项，请重新输入" ;;
		esac
	done
}

choose_action() {
	while :; do
		say ""
		menu_line "================ 内核维护项目 ================"
		say "${B}${Y}提示：安装或更新 Nikki 时会默认安装稳定版内核（mihomo-meta），以下按需选择！${N}"
		menu_line "  1）Smart 内核（Alpha with Smart Group，随后选择 LGBM）"
		menu_line "  2）开发预览版内核（Prerelease-Alpha）"
		menu_line "  3）稳定版内核（meta）"
		menu_line "  4）跳过内核更新（保留当前内核）"
		menu_line "  0）返回上一级菜单"
		menu_line "================================================"
		prompt '>>> 请手动选择 [0-4]：'
		read_user_input || fatal "无法读取维护菜单选项"
		ca_choice="$USER_INPUT"
		case "$ca_choice" in
			1) ACTION=smart; return 0 ;;
			2) ACTION=alpha; return 0 ;;
			3) ACTION=stable; return 0 ;;
			4) ACTION=skip; return 0 ;;
			0) ACTION="return"; return 0 ;;
			*) warn "无效菜单选项，请重新输入" ;;
		esac
	done
}

choose_geox() {
	while :; do
		say ""
		menu_line "================ GeoX 数据库维护项目 ================"
		say "${B}${Y}提示：配置直接引用 geosite/geoip 时必须安装；使用 rule-set 自定义 MRS 等格式数据库时可不安装。${N}"
		menu_line "  1）更新 GeoX 数据库（geosite、geoip、mmdb、asn）"
		menu_line "  2）跳过 GeoX 数据库更新（保留现有文件）"
		menu_line "  0）返回上一级菜单"
		menu_line "======================================================"
		prompt '>>> 请手动选择 [0-2]：'
		read_user_input || fatal "无法读取 GeoX 菜单选项"
		case "$USER_INPUT" in 1) GEOX_CHOICE=update; return 0 ;; 2) GEOX_CHOICE=skip; return 0 ;; 0) return 2 ;; *) warn "无效 GeoX 选项，请重新输入" ;; esac
	done
}

choose_zashboard() {
	while :; do
		say ""
		menu_line "================ Zashboard 维护项目 ================"
		menu_line "  1）完整版（dist.zip，全部内置字体）"
		menu_line "  2）无字体版（dist-no-fonts.zip，使用系统字体）"
		menu_line "  3）CDN 字体版（dist-cdn-fonts.zip）"
		menu_line "  4）FiraSans 字体版（dist-firasans-only.zip）"
		menu_line "  5）MiSans 字体版（dist-misans-only.zip）"
		menu_line "  6）PingFang 字体版（dist-pingfang-only.zip）"
		menu_line "  7）Sarasa 字体版（dist-sarasa-only.zip）"
		menu_line "  8）跳过 Zashboard 更新（保留现有面板）"
		menu_line "  0）返回上一级菜单"
		menu_line "===================================================="
		prompt '>>> 请手动选择 [0-8，默认1]：'
		read_user_input || fatal "无法读取 Zashboard 菜单选项"
		case "$USER_INPUT" in
			""|1) ZASH_CHOICE=update; ZASH_ASSET=dist.zip; ZASH_VARIANT_LABEL=full; return 0 ;;
			2) ZASH_CHOICE=update; ZASH_ASSET=dist-no-fonts.zip; ZASH_VARIANT_LABEL=no-fonts; return 0 ;;
			3) ZASH_CHOICE=update; ZASH_ASSET=dist-cdn-fonts.zip; ZASH_VARIANT_LABEL=cdn-fonts; return 0 ;;
			4) ZASH_CHOICE=update; ZASH_ASSET=dist-firasans-only.zip; ZASH_VARIANT_LABEL=FiraSans; return 0 ;;
			5) ZASH_CHOICE=update; ZASH_ASSET=dist-misans-only.zip; ZASH_VARIANT_LABEL=MiSans; return 0 ;;
			6) ZASH_CHOICE=update; ZASH_ASSET=dist-pingfang-only.zip; ZASH_VARIANT_LABEL=PingFang; return 0 ;;
			7) ZASH_CHOICE=update; ZASH_ASSET=dist-sarasa-only.zip; ZASH_VARIANT_LABEL=Sarasa; return 0 ;;
			8) ZASH_CHOICE=skip; return 0 ;;
			0) return 2 ;;
			*) warn "无效 Zashboard 选项，请重新输入" ;;
		esac
	done
}

choose_maintenance_plan() {
	cmp_stage=core
	while :; do
		case "$cmp_stage" in
			core)
				ACTION=""
				LGBM_SET=0
				choose_action
				[ "$ACTION" != return ] || return 2
				if [ "$ACTION" = smart ]; then
					choose_lgbm
					cmp_rc=$?
					[ "$cmp_rc" -ne 2 ] || continue
				fi
				cmp_stage=geox
				;;
			geox)
				choose_geox
				cmp_rc=$?
				if [ "$cmp_rc" -eq 2 ]; then cmp_stage=core; else cmp_stage=zashboard; fi
				;;
			zashboard)
				choose_zashboard
				cmp_rc=$?
				if [ "$cmp_rc" -eq 2 ]; then cmp_stage=geox; else return 0; fi
				;;
		esac
	done
}

confirm_uninstall() {
	[ "$ASSUME_YES" -eq 1 ] && return 0
	while :; do
		say "${B}${R}【高风险操作】此操作会删除 Nikki 配置、订阅、运行数据、内核和软件源。${N}"
		menu_line "  YES）确认卸载"
		menu_line "  0）返回上一级菜单"
		danger_prompt '>>> 请手动选择 [YES/0]：'
		read_user_input || fatal "无法读取卸载确认选项"
		cu_answer="$USER_INPUT"
		case "$cu_answer" in
			YES) return 0 ;;
			0) return 1 ;;
			*) warn "请输入 YES 确认卸载，或输入 0 返回上一级菜单" ;;
		esac
	done
}

uninstall_nikki() {
	# 清理范围逐项对齐 Nikki 官方 uninstall.sh：语言包、LuCI、Nikki、两种官方内核、
	# /etc/config/nikki、/etc/nikki、日志、运行目录、软件源和签名密钥；此处另加确认与回滚。
	confirm_uninstall || { warn "已取消卸载"; return 2; }
	un_backup="/tmp/nikki-uninstall-backup.${PID}"
	mkdir "$un_backup" || fatal "无法创建卸载临时备份"
	: > "$un_backup/packages.before" || fatal "无法创建卸载包清单"
	[ ! -f /etc/config/nikki ] || cp -p /etc/config/nikki "$un_backup/config.nikki" || fatal "配置备份失败"
	[ ! -d "$NIKKI_DIR" ] || cp -a "$NIKKI_DIR" "$un_backup/nikki-dir" || fatal "数据备份失败"
	[ ! -f "$CORE_PATH" ] || cp -p "$CORE_PATH" "$un_backup/mihomo" || fatal "内核备份失败"
	[ ! -f /etc/opkg/customfeeds.conf ] || cp -p /etc/opkg/customfeeds.conf "$un_backup/customfeeds.conf" || true
	[ ! -f /etc/apk/repositories.d/customfeeds.list ] || cp -p /etc/apk/repositories.d/customfeeds.list "$un_backup/customfeeds.list" || true
	/etc/init.d/nikki stop >/dev/null 2>&1 || true
	un_failed=0
	case "$PKG_MANAGER" in
		opkg) un_langs="$(opkg list-installed 'luci-i18n-nikki-*' 2>/dev/null | awk '{print $1}')" ;;
		apk) un_langs="$(apk list --installed --manifest 'luci-i18n-nikki-*' 2>/dev/null | awk '{print $1}')" ;;
		*) un_langs="" ;;
	esac
	for un_pkg in $un_langs luci-app-nikki nikki mihomo-meta mihomo-alpha; do
		if pkg_is_installed "$un_pkg"; then printf '%s\n' "$un_pkg" >> "$un_backup/packages.before"; fi
	done
	for un_pkg in $un_langs; do pkg_remove "$un_pkg" >/dev/null 2>&1 || un_failed=1; done
	for un_pkg in luci-app-nikki nikki mihomo-meta mihomo-alpha; do
		if pkg_is_installed "$un_pkg"; then pkg_remove "$un_pkg" >/dev/null 2>&1 || un_failed=1; fi
	done
	if [ "$un_failed" -ne 0 ]; then
		while IFS= read -r un_restore_pkg; do
			[ -z "$un_restore_pkg" ] || pkg_install "$un_restore_pkg" >/dev/null 2>&1 || true
		done < "$un_backup/packages.before"
		[ ! -f "$un_backup/config.nikki" ] || cp -p "$un_backup/config.nikki" /etc/config/nikki || true
		if [ -d "$un_backup/nikki-dir" ]; then
			rm -rf -- "$NIKKI_DIR" 2>/dev/null || true
			cp -a "$un_backup/nikki-dir" "$NIKKI_DIR" || true
		fi
		[ ! -f "$un_backup/mihomo" ] || cp -p "$un_backup/mihomo" "$CORE_PATH" || true
		fatal "部分软件包卸载失败；配置备份仍保留在 $un_backup"
	fi
	# 目标均为 Nikki 的固定专用路径，不使用变量或通配符扩大删除范围。
	rm -f /etc/config/nikki
	rm -rf -- /etc/nikki /var/log/nikki /var/run/nikki
	case "$PKG_MANAGER" in
		opkg)
			sed -i '/nikki/d' /etc/opkg/customfeeds.conf 2>/dev/null || true
			if command -v opkg-key >/dev/null 2>&1 && [ -n "$DOWNLOADER" ] && fetch_once 'https://nikkinikki.pages.dev/key-build.pub' "$un_backup/nikki.pub"; then
				opkg-key remove "$un_backup/nikki.pub" >/dev/null 2>&1 || true
			else
				warn "无法取得官方公钥文件，OPKG 信任库中可能仍保留 Nikki 公钥"
			fi
			;;
		apk) sed -i '/nikki/d' /etc/apk/repositories.d/customfeeds.list 2>/dev/null || true; rm -f /etc/apk/keys/nikki.pem ;;
	esac
	rm -f "$CORE_PATH" 2>/dev/null || true
	for un_stale in /usr/bin/mihomo.rollback.* /usr/bin/mihomo.new.* /etc/config/nikki.rollback.*; do
		case "$un_stale" in /usr/bin/mihomo.rollback.*|/usr/bin/mihomo.new.*|/etc/config/nikki.rollback.*) [ ! -e "$un_stale" ] || rm -f -- "$un_stale" ;; esac
	done
	safe_rm_tree "$un_backup" >/dev/null 2>&1 || true
	say "Nikki已卸载，相关数据残留已清理！"
	return 0
}

reset_workflow_state() {
	TRANSACTION_ACTIVE=0
	WAS_RUNNING=0
	CORE_EXISTED=0
	MODEL_EXISTED=0
	UI_EXISTED=0
	CONFIG_EXISTED=0
	MAINT_SUCCESS=0
	NIKKI_UPDATE_STATUS="not_selected"
	CORE_UPDATE_STATUS="not_selected"
	MODEL_UPDATE_STATUS="not_selected"
	GEOX_UPDATE_STATUS="not_selected"
	ZASH_UPDATE_STATUS="not_selected"
}

run_update_workflow() {
	reset_workflow_state
	print_official_requirements
	detect_environment
	print_environment
	if ! check_requirements; then return 2; fi
	if [ "$NIKKI_UPDATE_CHOICE" = update ]; then
		select_downloader
		install_or_update_nikki
		NIKKI_UPDATE_STATUS="updated"
	else
		NIKKI_UPDATE_STATUS="user_skipped"
		info "已按选择跳过 Nikki 及其依赖更新，当前安装保持不变"
	fi
	if [ -n "$CLI_ACTION" ]; then
		GEOX_CHOICE=update
		ZASH_CHOICE=update
		if [ "$ACTION" = smart ] && [ "$LGBM_SET" -eq 0 ]; then LGBM_CHOICE=auto; LGBM_SET=1; fi
	elif [ "$PLAN_PRESET" -eq 0 ]; then
		choose_maintenance_plan
		cmp_rc=$?
		if [ "$cmp_rc" -eq 2 ]; then return 2; fi
		[ "$cmp_rc" -eq 0 ] || return "$cmp_rc"
	fi
	run_maintenance "$ACTION"
	print_summary
	return 0
}

main() {
	parse_args "$@"
	CLI_ACTION="$ACTION"
	[ "$(id -u)" -eq 0 ] || fatal "请使用 root 用户运行"
	acquire_lock
	mkdir -p "$WORK_DIR" || fatal "无法创建临时目录：$WORK_DIR"

	# 命令行模式保持适合自动化的单次执行语义。
	if [ -n "$CLI_ACTION" ]; then
		PLAN_PRESET=1
		if [ "$CLI_ACTION" = "uninstall" ]; then
			detect_environment
			if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then select_downloader; fi
			uninstall_nikki || exit 1
		else
			run_update_workflow || exit 1
		fi
		exit 0
	fi

	# 交互模式始终返回这里重新检测 Nikki 状态，不递归启动脚本。
	while :; do
		detect_package_manager
		ACTION=""
		MAIN_CHOICE=""
		AUTO_CHOICE=""
		MANUAL_NIKKI_CHOICE=""
		PLAN_PRESET=0
		NIKKI_UPDATE_CHOICE="update"
		LGBM_CHOICE="auto"
		LGBM_SET=0
		GEOX_CHOICE="update"
		ZASH_CHOICE="update"
		ZASH_ASSET="dist.zip"
		ZASH_VARIANT_LABEL="full"
		if pkg_is_installed nikki; then mm_installed=1; else mm_installed=0; fi
		main_menu "$mm_installed"
		[ "$MAIN_CHOICE" != exit ] || exit 0
		if [ "$MAIN_CHOICE" = uninstall ]; then
			detect_environment
			if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then select_downloader; fi
			if ! uninstall_nikki; then warn "卸载未执行，返回主菜单"; continue; fi
			if post_action_menu uninstall; then continue; else exit 0; fi
		fi

		if [ "$MAIN_CHOICE" = auto ]; then
			automatic_maintenance_menu
			[ "$AUTO_CHOICE" != return ] || continue
			ACTION="$AUTO_CHOICE"
			PLAN_PRESET=1
			NIKKI_UPDATE_CHOICE=update
			GEOX_CHOICE=update
			ZASH_CHOICE=update
			ZASH_ASSET="dist.zip"
			ZASH_VARIANT_LABEL="full"
			if [ "$ACTION" = smart ]; then LGBM_CHOICE=auto; LGBM_SET=1; fi
			info "已进入自动维护；将完整输出环境检测、安装条件判断、Nikki 安装或更新、组件维护及最终结果，无需再次人工选择"
		else
			manual_nikki_menu "$mm_installed"
			[ "$MANUAL_NIKKI_CHOICE" != return ] || continue
			[ "$MANUAL_NIKKI_CHOICE" != skip ] || NIKKI_UPDATE_CHOICE=skip
		fi

		if run_update_workflow; then
			if post_action_menu maintenance; then continue; else exit 0; fi
		else
			ruw_rc=$?
			[ "$ruw_rc" -eq 2 ] && continue
			exit "$ruw_rc"
		fi
	done
}

if [ "${NIKKI_LIB_ONLY:-0}" != "1" ]; then
	main "$@"
fi
