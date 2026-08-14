#!/bin/sh
#
# Nikki 全方位一键维护脚本
# 适用：OpenWrt/ImmortalWrt 等兼容固件，24.10 / 25.12 / 官方支持的 SNAPSHOT，BusyBox ash
# 功能：安装/更新 Nikki、切换 Mihomo 内核、更新 LightGBM/GeoX/Zashboard/rule-set、卸载清理
#
# 可选环境变量：
#   GITHUB_TOKEN=...          GitHub API Token（可避免匿名限流）
#   DIRECT_MIN_KBPS=64       直连持续低于该速度后切换反代（curl）
#   DIRECT_SLOW_TIME=15      直连或反代低速持续秒数
#   DOWNLOAD_MAX_TIME=900    单个文件最长下载时间
#   DOWNLOAD_ROUNDS=3        失败后从直连重新开始的轮数（固定最多三轮）
#   MIPS_FLOAT=auto          MIPS 可覆盖为 softfloat 或 hardfloat
#   KEEP_BACKUP_ON_SUCCESS=1 成功后保留事务备份（默认清理）
#   NIKKI_DISABLE_LIVE_INPUT=1 禁用手动多选菜单逐键刷新，改用回车确认
#   NIKKI_DETAIL=1            展开全部详细流程输出（默认只显示关键步骤）
#
# 非交互示例：
#   sh nikki_all_install_update.sh --action smart --lgbm auto --yes
#   sh nikki_all_install_update.sh --action alpha --yes
#   sh nikki_all_install_update.sh --action stable --yes
#   sh nikki_all_install_update.sh --action uninstall --yes

set -u

SCRIPT_VERSION="3.7.0-opt6"
ACTION=""; CLI_ACTION=""; MAIN_CHOICE=""; WORKFLOW_MODE="命令行维护"
ENVIRONMENT_READY=0; PKG_INDEX_READY=0; NIKKI_FEED_READY=0; NIKKI_FEED_ATTEMPTED=0; STATUS_SCAN_READY=0
NIKKI_FEED_ORIGINAL_ANY=0; NIKKI_FEED_ADDED_SESSION=0; NIKKI_FEED_EXIT_PROMPTED=0
NIKKI_UPDATE_CHOICE="update"; LGBM_CHOICE="auto"; LGBM_SET=0
GEOX_CHOICE="update"; ZASH_CHOICE="update"; ZASH_ASSET="dist.zip"; ZASH_VARIANT_LABEL="full"
RULESET_CHOICE="skip"; MODEL_MAINTAIN=0
CORE_SWITCH_ONLY=0; COMPONENT_ONLY=0; COMPONENT_ONLY_KIND=""; ASSUME_YES=0
AUTO_UPGRADE_ONLY=0; FORCE_MAINTENANCE=0; FORCE_NIKKI_REINSTALL=0
AUTO_SKIP_NIKKI=""; AUTO_SKIP_CORE=""; AUTO_SKIP_MODEL=""; AUTO_SKIP_GEOX=""; AUTO_SKIP_ZASH=""
NONDEFAULT_CORE_PRESERVED=0; PRESERVED_CORE_KIND=""; SERVICE_RESTART_VERIFIED=0
DETAIL_OUTPUT="${NIKKI_DETAIL:-0}"
DOWNLOAD_FAILURES=0
KEEP_BACKUP_ON_SUCCESS="${KEEP_BACKUP_ON_SUCCESS:-0}"; MIPS_FLOAT="${MIPS_FLOAT:-auto}"
DIRECT_MIN_KBPS="${DIRECT_MIN_KBPS:-64}"; DIRECT_SLOW_TIME="${DIRECT_SLOW_TIME:-15}"
DOWNLOAD_MAX_TIME="${DOWNLOAD_MAX_TIME:-900}"; WGET_MAX_TIME="${WGET_MAX_TIME:-$DOWNLOAD_MAX_TIME}"; DOWNLOAD_ROUNDS="${DOWNLOAD_ROUNDS:-3}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# 同一组反代统一用于 GitHub Raw、API 与 Release 下载。
GITHUB_PROXIES="${GITHUB_PROXIES:-https://gh.dpik.top/ https://gh.felicity.ac.cn/ https://gh.b52m.cn/ https://github-proxy.memory-echoes.cn/ https://gh.jasonzeng.dev/ https://github.dpik.top/ https://ghproxy.net/ https://gh-proxy.com/}"

NIKKI_REPO="nikkinikki-org/OpenWrt-nikki"; CORE_PATH="/usr/bin/mihomo"; NIKKI_INIT="/etc/init.d/nikki"
NIKKI_APK_KEY="/etc/apk/keys/nikki.pem"; NIKKI_DIR="/etc/nikki"; RUN_DIR="/etc/nikki/run"
MODEL_PATH="/etc/nikki/run/Model.bin"; UI_DIR="/etc/nikki/run/ui"; UI_NAME="zashboard"
UI_TARGET="${UI_DIR}/${UI_NAME}"
STATE_FILE="/etc/nikki/.all-update-state"
# 独立于 /etc/nikki，卸载 Nikki 后仍可恢复插件设置。
SETTINGS_BACKUP_DIR="${NIKKI_BACKUP_DIR:-/etc/nikki-backups}"

PID="$$"; WORK_DIR="/tmp/nikki-all-update.${PID}"; LOCK_DIR="/tmp/nikki-all-update.lock"; LOCKED=0
TRANSACTION_ACTIVE=0; WAS_RUNNING=0; MAINT_SUCCESS=0
NIKKI_UPDATE_STATUS=not_selected; CORE_UPDATE_STATUS=not_selected; MODEL_UPDATE_STATUS=not_selected
GEOX_UPDATE_STATUS=not_selected; ZASH_UPDATE_STATUS=not_selected
RULESET_UPDATE_STATUS=not_selected; RULESET_UPDATED_COUNT=0; RULESET_TOTAL_COUNT=0
UNINSTALL_REMOVE_FEED=0; TTY_RAW_ACTIVE=0; TTY_STTY_STATE=""; DOWNLOADER=""
PKG_MANAGER=unknown; FIREWALL=unknown; KERNEL_VERSION=unknown
FIRMWARE_NAME=OpenWrt; FIRMWARE_DESCRIPTION="OpenWrt unknown"; FIRMWARE_DISPLAY="OpenWrt unknown"
OPENWRT_VERSION=unknown; OPENWRT_ARCH=unknown; LUCI_BRANCH=""; LUCI_REVISION=""; LUCI_OPENWRT_SERIES=""
CPU_ARCH=unknown; CPU_MODEL=unknown; AMD64_LEVEL=""; ASSET_ARCH=""; OFFICIAL_BRANCH=""
MODEL_SHA_NEW=""

CORE_BACKUP="${CORE_PATH}.rollback.${PID}"; MODEL_BACKUP="${MODEL_PATH}.rollback.${PID}"
NONDEFAULT_CORE_BEFORE_NIKKI="${WORK_DIR}/nondefault-core.before-nikki"
UI_BACKUP="${UI_TARGET}.rollback.${PID}"; GEOX_BACKUP="${RUN_DIR}/.geox-rollback.${PID}"
CONFIG_BACKUP="/etc/config/nikki.rollback.${PID}"; SUBSCRIPTIONS_BACKUP="${WORK_DIR}/subscriptions.rollback"
CORE_EXISTED=0; MODEL_EXISTED=0; UI_EXISTED=0; CONFIG_EXISTED=0; SUBSCRIPTIONS_EXISTED=0

R='\033[31m'; G='\033[32m'; Y='\033[33m'; M='\033[35m'; C='\033[36m'; B='\033[1m'; N='\033[0m'; ALERT='\033[1;97;41m'

say()  { printf '%b\n' "$*"; }
info() { [ "$DETAIL_OUTPUT" = "1" ] || return 0; say "${C}[详细]${N} $*"; }
key_info() { say "${C}[信息]${N} $*"; }
ok()   { say "${G}[完成]${N} $*"; }
warn() { say "${Y}[警告]${N} $*" >&2; }
err()  { say "${R}[错误]${N} $*" >&2; }
menu_line() { say "${B}${C}$*${N}"; }
prompt() { printf '%b' "${B}${Y}$*${N}"; }
danger_prompt() { printf '%b' "${B}${R}$*${N}"; }
flow_title() { say ""; say "${B}${M}================ $* ================${N}"; }
progress_line() {
	pl_fraction="${1%% *}"; pl_num="${pl_fraction%%/*}"; pl_den="${pl_fraction#*/}"; pl_pct=""
	case "$pl_num" in ''|*[!0-9]*) ;; *)
		case "$pl_den" in ''|*[!0-9]*|0) ;; *) pl_pct=" $((pl_num * 100 / pl_den))%" ;; esac
		;;
	esac
	say "${B}${C}  ├─ [进度 ${1}${pl_pct}]${N} $2"
}
progress_done() { say "${B}${G}  └─ [完成]${N} $*"; }
progress_skip() { say "${B}${Y}  └─ [跳过]${N} $*"; }
paint_current() { printf '%b' "${B}${C}$*${N}"; }
paint_latest() { printf '%b' "${B}${M}$*${N}"; }
paint_size() { printf '%b' "${B}${G}$*${N}"; }
paint_missing() { printf '%b' "${B}${R}$*${N}"; }
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

session_feed_cleanup() {
	[ "$NIKKI_FEED_EXIT_PROMPTED" -eq 0 ] || return 0
	NIKKI_FEED_EXIT_PROMPTED=1
	[ "$NIKKI_FEED_ADDED_SESSION" -eq 1 ] || return 0
	[ "$NIKKI_FEED_ORIGINAL_ANY" -eq 0 ] || return 0
	if [ "$ASSUME_YES" -eq 1 ] || [ ! -c /dev/tty ]; then
		key_info "本次会话新添加的 Nikki 软件源将保留（非交互模式）"
		return 0
	fi
	say ""
	say "${B}${Y}本次会话新添加了 Nikki 官方软件源。退出前是否保留？${N}"
	say "  ${G}YES / y / 是${N}）保留软件源，方便下次直接安装"
	say "  ${R}NO / n / 否${N}）删除软件源及签名密钥"
	while :; do
		prompt '>>> 请选择 [YES/NO]：'
		IFS= read -r sf_answer </dev/tty || return 0
		sf_answer="$(normalize_menu_answer "$sf_answer")"
		case "$sf_answer" in
			YES|yes|Yes|Y|y|是) key_info "已选择保留 Nikki 官方软件源和签名密钥"; return 0 ;;
			NO|no|No|N|n|否)
				sf_file="$(feed_source_file 2>/dev/null || true)"
				if [ -n "$sf_file" ] && [ -f "$sf_file" ]; then
					case "$PKG_MANAGER" in
						opkg) sed -i '/^[[:space:]]*src\/gz[[:space:]][[:space:]]*nikki[[:space:]]/d' "$sf_file" 2>/dev/null || true ;;
						apk) sed -i '/\/nikki\/packages\.adb[[:space:]]*$/d' "$sf_file" 2>/dev/null || true ;;
					esac
				fi
				if [ "$PKG_MANAGER" = apk ]; then
					rm -f -- "$NIKKI_APK_KEY" 2>/dev/null || true
				else
					sf_tmp="/tmp/nikki-feed-exit.${PID}"; mkdir -p "$sf_tmp" 2>/dev/null || true
					if fetch_once 'https://nikkinikki.pages.dev/key-build.pub' "$sf_tmp/key-build.pub" && command -v opkg-key >/dev/null 2>&1; then
						opkg-key remove "$sf_tmp/key-build.pub" >/dev/null 2>&1 || true
					else
						warn "软件源已删除，但 OPKG 签名密钥未能自动移除，请手动清理"
					fi
					rm -rf -- "$sf_tmp" 2>/dev/null || true
				fi
				key_info "已删除本次会话新增的 Nikki 软件源及签名密钥"
				return 0
				;;
			*) warn "请输入 YES 保留或 NO 删除" ;;
		esac
	done
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
	session_feed_cleanup
	restore_tty
	if [ "$TRANSACTION_ACTIVE" -eq 0 ]; then
		[ ! -d "$WORK_DIR" ] || safe_rm_tree "$WORK_DIR" >/dev/null 2>&1 || true
	fi
	if [ "$LOCKED" -eq 1 ]; then
		[ ! -d "$LOCK_DIR" ] || rm -rf -- "$LOCK_DIR" 2>/dev/null || true
	fi
}

restore_tty() {
	if [ "$TTY_RAW_ACTIVE" -eq 1 ] && [ -n "$TTY_STTY_STATE" ] && [ -c /dev/tty ]; then
		stty "$TTY_STTY_STATE" </dev/tty >/dev/null 2>&1 || true
	fi
	TTY_RAW_ACTIVE=0
	TTY_STTY_STATE=""
}

trap cleanup EXIT
trap 'err "收到中断信号"; exit 130' INT
trap 'err "收到终止信号"; exit 143' TERM

usage() {
	say "用法：${0##*/} [选项]"
	cat <<'EOF'
  --action smart|alpha|stable|uninstall
  --lgbm auto|small|middle|large|skip
  --yes                 非交互确认
  --verbose             展开详细流程输出（默认仅关键步骤）
  --quiet               仅输出警告、错误和完成结果
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
			--verbose|--detail) DETAIL_OUTPUT=1; shift ;;
			--quiet) DETAIL_OUTPUT=0; shift ;;
			-h|--help) usage; exit 0 ;;
			*) fatal "未知参数：$1" ;;
		esac
	done
	case "$ACTION" in ""|smart|alpha|stable|uninstall) ;; *) fatal "无效 action：$ACTION" ;; esac
	case "$LGBM_CHOICE" in auto|small|middle|large|skip) ;; *) fatal "无效 LGBM 版本：$LGBM_CHOICE" ;; esac
	case "$DIRECT_MIN_KBPS:$DIRECT_SLOW_TIME:$DOWNLOAD_MAX_TIME:$WGET_MAX_TIME" in
		*[!0-9:]*|:*|*::*|*:) fatal "下载速度和超时参数必须为正整数" ;;
	esac
	[ "$DIRECT_MIN_KBPS" -gt 0 ] && [ "$DIRECT_SLOW_TIME" -gt 0 ] && [ "$DOWNLOAD_MAX_TIME" -gt 0 ] && [ "$WGET_MAX_TIME" -gt 0 ] ||
		fatal "下载速度和超时参数必须大于 0"
	[ "$WGET_MAX_TIME" -ge "$DIRECT_SLOW_TIME" ] || fatal "WGET_MAX_TIME 不能小于 DIRECT_SLOW_TIME"
	case "$DOWNLOAD_ROUNDS" in 3) ;; *) fatal "DOWNLOAD_ROUNDS 必须为 3（最多三轮）" ;; esac
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
	say "${B}${G}系统环境符合 Nikki 安装环境要求，将检测系统是否已安装 Nikki。${N}"
	return 0
}

run_environment_preflight() {
	print_official_requirements
	detect_environment
	print_environment
	if ! check_requirements; then
		say "${B}${R}脚本将在 20 秒后自动退出……${N}"
		sleep 20
		return 1
	fi
	ENVIRONMENT_READY=1
	return 0
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

fetch_method_retry() {
	# 每个下载方式最多尝试三次；两次失败之间等待 2 秒，再切换下一个方式。
	fmr_url="$1"; fmr_out="$2"; fmr_kind="$3"; fmr_label="$4"; fmr_try=1
	while [ "$fmr_try" -le 3 ]; do
		info "${fmr_label}尝试 ${fmr_try}/3：$fmr_url"
		if fetch_once "$fmr_url" "$fmr_out" && plausible_file "$fmr_out" "$fmr_kind"; then return 0; fi
		[ "$fmr_try" -lt 3 ] && sleep 2
		fmr_try=$((fmr_try + 1))
	done
	return 1
}

fetch_url() {
	fu_url="$1"; fu_out="$2"; fu_kind="${3:-file}"
	fu_round=1
	while [ "$fu_round" -le "$DOWNLOAD_ROUNDS" ]; do
		key_info "下载轮次 ${fu_round}/${DOWNLOAD_ROUNDS}：直连优先，失败/低速后切换反代"
		if fetch_method_retry "$fu_url" "$fu_out" "$fu_kind" "直连 "; then
			ok "直连下载成功：$(basename "$fu_out")"; return 0
		fi
		warn "直连连续 3 次失败、超时、持续低速或内容异常，开始轮换反代"
		fu_list="$GITHUB_PROXIES"
		for fu_proxy in $fu_list; do
			fu_proxy_url="$(apply_proxy "$fu_proxy" "$fu_url")"
			if fetch_method_retry "$fu_proxy_url" "$fu_out" "$fu_kind" "反代 ${fu_proxy} "; then
				ok "反代下载成功：$fu_proxy"; return 0
			fi
			warn "反代连续 3 次失败或内容异常，迅速切换下一个节点：$fu_proxy"
		done
		if [ "$fu_round" -lt "$DOWNLOAD_ROUNDS" ]; then
			warn "本轮全部节点失败，2 秒后从直连开始下一轮"
			sleep 2
		fi
		fu_round=$((fu_round + 1))
	done
	rm -f -- "$fu_out"
	DOWNLOAD_FAILURES=$((DOWNLOAD_FAILURES + 1))
	err "直连及全部反代连续 ${DOWNLOAD_ROUNDS} 轮失败：$fu_url，请稍后重试"
	return 1
}

fetch_json_cached() {
	fjc_url="$1"; fjc_out="$2"
	if [ -s "$fjc_out" ] && plausible_file "$fjc_out" json; then
		info "复用本轮状态查询缓存：$(basename "$fjc_out")"
		return 0
	fi
	fetch_url "$fjc_url" "$fjc_out" json
}

pkg_is_installed() {
	pi_name="$1"
	case "$PKG_MANAGER" in opkg) opkg list-installed "$pi_name" 2>/dev/null | grep -q "^${pi_name} " ;; apk) apk info -e "$pi_name" >/dev/null 2>&1 ;; *) return 1 ;; esac
}

pkg_update() {
	case "$PKG_MANAGER" in
		opkg) if [ "$DETAIL_OUTPUT" = 1 ]; then opkg update; else opkg update >/dev/null 2>&1; fi ;;
		apk) if [ "$DETAIL_OUTPUT" = 1 ]; then apk update; else apk update >/dev/null 2>&1; fi ;;
		*) return 1 ;;
	esac
}
pkg_update_once() {
	if [ "$PKG_INDEX_READY" -eq 1 ]; then
		info "复用本次脚本会话已刷新的软件包索引"
		return 0
	fi
	pkg_update || return 1
	PKG_INDEX_READY=1
}
invalidate_package_session_cache() {
	NIKKI_FEED_READY=0
	PKG_INDEX_READY=0
}
reset_nikki_feed_session() {
	invalidate_package_session_cache
	NIKKI_FEED_ATTEMPTED=0
	NIKKI_FEED_ORIGINAL_ANY=0
	NIKKI_FEED_ADDED_SESSION=0
}
pkg_install() {
	case "$PKG_MANAGER" in
		opkg) if [ "$DETAIL_OUTPUT" = 1 ]; then opkg install "$@"; else opkg install "$@" >/dev/null 2>&1; fi ;;
		apk) if [ "$DETAIL_OUTPUT" = 1 ]; then apk add "$@"; else apk add "$@" >/dev/null 2>&1; fi ;;
		*) return 1 ;;
	esac
}
pkg_remove() {
	case "$PKG_MANAGER" in
		opkg) if [ "$DETAIL_OUTPUT" = 1 ]; then opkg remove "$@"; else opkg remove "$@" >/dev/null 2>&1; fi ;;
		apk) if [ "$DETAIL_OUTPUT" = 1 ]; then apk del "$@"; else apk del "$@" >/dev/null 2>&1; fi ;;
		*) return 1 ;;
	esac
}

nikki_version() {
	case "$PKG_MANAGER" in
		opkg) opkg list-installed nikki 2>/dev/null | awk 'NR==1{print $3}' ;;
		apk) apk list --installed --manifest nikki 2>/dev/null | awk '$1=="nikki"{print $2;exit}' ;;
	esac
}

nikki_upgrade_version() {
	case "$PKG_MANAGER" in
		opkg) opkg list-upgradable 2>/dev/null | awk -F ' - ' '$1=="nikki"{print $3;exit}' ;;
		apk) apk list --upgradeable --manifest nikki 2>/dev/null | awk '$1=="nikki"{print $2;exit}' ;;
	esac
}

inspect_nikki_release_fallback() {
	info "正在通过 Nikki 官方 GitHub Release 交叉检查最新版本……"
	[ -n "$DOWNLOADER" ] || select_downloader
	inrf_json="$WORK_DIR/nikki-latest-release.json"
	fetch_json_cached "https://api.github.com/repos/${NIKKI_REPO}/releases/latest" "$inrf_json" || return 1
	inrf_tag="$(json_field tag_name "$inrf_json")"
	[ -n "$inrf_tag" ] || return 1
	inrf_latest="${inrf_tag#v}"
	inrf_installed="$(nikki_version 2>/dev/null || true)"
	NIKKI_AVAILABLE_VERSION="$inrf_tag"
	if [ -n "$inrf_installed" ] && version_ge "$inrf_installed" "$inrf_latest"; then
		NIKKI_AVAILABLE_VERSION=""
		NIKKI_UPDATE_STATE="latest"
	else
		NIKKI_UPDATE_STATE="update"
	fi
	return 0
}

inspect_nikki_update() {
	NIKKI_AVAILABLE_VERSION=""
	NIKKI_UPDATE_STATE="unknown"
	# 版本状态扫描不得触发 feed.sh；只有真正执行 Nikki 主体安装/更新时才处理软件源。
	if [ "$NIKKI_FEED_READY" -eq 1 ] && feed_current; then
		NIKKI_AVAILABLE_VERSION="$(nikki_upgrade_version)"
		if [ -n "$NIKKI_AVAILABLE_VERSION" ]; then NIKKI_UPDATE_STATE="update"; else NIKKI_UPDATE_STATE="latest"; fi
	else
		inspect_nikki_release_fallback || warn "官方 Release 查询失败，暂时无法判断 Nikki 是否有更新"
	fi
}

backup_install_state() {
	# 上一轮若曾失败并返回主菜单，先移除旧快照，避免清单追加后污染本轮回滚边界。
	[ ! -d "$WORK_DIR/install-backup" ] || safe_rm_tree "$WORK_DIR/install-backup" || return 1
	mkdir -p "$WORK_DIR/install-backup" || return 1
	: > "$WORK_DIR/install-backup/files.before" || return 1
	: > "$WORK_DIR/install-backup/dirs.before" || return 1
	: > "$WORK_DIR/install-backup/packages.before" || return 1
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
	ris_keep_feed="$NIKKI_FEED_READY"
	# 本次脚本启动时成功添加的软件源属于会话级准备步骤，不随安装事务回滚。
	for ris_pkg in nikki luci-app-nikki luci-i18n-nikki-zh-cn mihomo-meta mihomo-alpha; do
		if pkg_is_installed "$ris_pkg" && ! grep -qx "$ris_pkg" "$WORK_DIR/install-backup/packages.before" 2>/dev/null; then
			pkg_remove "$ris_pkg" >/dev/null 2>&1 || true
		fi
	done
	for ris_path in /etc/config/nikki /etc/opkg/customfeeds.conf /etc/apk/repositories.d/customfeeds.list; do
		case "$ris_path" in
			/etc/opkg/customfeeds.conf|/etc/apk/repositories.d/customfeeds.list)
				[ "$ris_keep_feed" -ne 1 ] || continue
				;;
		esac
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
	if [ "$ris_keep_feed" -eq 1 ]; then
		info "已保留本次会话添加的 Nikki 官方软件源，返回主菜单后继续复用"
	else
		# 本轮添加源从未成功，不重置 attempted，避免同一脚本会话重复执行 feed.sh。
		invalidate_package_session_cache
	fi
}

feed_source_file() {
	case "$PKG_MANAGER" in
		opkg) printf '%s\n' /etc/opkg/customfeeds.conf ;;
		apk) printf '%s\n' /etc/apk/repositories.d/customfeeds.list ;;
		*) return 1 ;;
	esac
}

feed_expected_line() {
	ff_branch="$OFFICIAL_BRANCH"; ff_arch="$OPENWRT_ARCH"
	[ -n "$ff_branch" ] && [ -n "$ff_arch" ] || return 1
	ff_url="https://nikkinikki.pages.dev/${ff_branch}/${ff_arch}/nikki"
	case "$PKG_MANAGER" in
		opkg) printf 'src/gz nikki %s\n' "$ff_url" ;;
		apk) printf '%s/packages.adb\n' "$ff_url" ;;
		*) return 1 ;;
	esac
}

feed_any() {
	ff_file="$(feed_source_file 2>/dev/null || true)"
	[ -n "$ff_file" ] && [ -f "$ff_file" ] || return 1
	grep -qi 'nikki' "$ff_file" 2>/dev/null
}

feed_current() {
	ff_file="$(feed_source_file 2>/dev/null || true)"; ff_line="$(feed_expected_line 2>/dev/null || true)"
	[ -n "$ff_file" ] && [ -n "$ff_line" ] && [ -f "$ff_file" ] || return 1
	grep -Fqx "$ff_line" "$ff_file" 2>/dev/null
}

# 兼容旧测试和外部调用；这里表示“存在与当前固件/架构一致的 Nikki 官方源”。
feed_present() { feed_current; }

check_existing_nikki_feed() {
	# 只在即将安装/更新 Nikki 主体时调用；状态扫描和组件单项维护不会触发添加源。
	if feed_any; then NIKKI_FEED_ORIGINAL_ANY=1; fi
	if feed_current; then
		key_info "检测到与当前 ${OFFICIAL_BRANCH}/${OPENWRT_ARCH} 一致的 Nikki 官方软件源，正在验证软件包索引"
		if pkg_update_once >/dev/null 2>&1; then
			NIKKI_FEED_READY=1
			return 0
		fi
		warn "Nikki 软件源存在但索引刷新失败，将重新执行官方 feed.sh"
	fi
	return 1
}

add_nikki_feed_once() {
	if [ "$NIKKI_FEED_ATTEMPTED" -eq 1 ]; then
		[ "$NIKKI_FEED_READY" -eq 1 ] && { key_info "复用本次会话的 Nikki 软件源和软件包索引"; return 0; }
		warn "本次会话已完成 Nikki 软件源处理但未成功，不再重复改写软件源"
		return 1
	fi
	NIKKI_FEED_ATTEMPTED=1
	if check_existing_nikki_feed; then
		key_info "Nikki 软件源校验通过，本次会话后续直接复用"
		return 0
	fi
	[ -n "$DOWNLOADER" ] || select_downloader
	anf_script="$WORK_DIR/feed.sh"
	anf_url="https://raw.githubusercontent.com/${NIKKI_REPO}/refs/heads/main/feed.sh"
	fetch_url "$anf_url" "$anf_script" script || {
		warn "Nikki 官方 feed.sh 下载失败，稍后将切换方案 B"
		return 1
	}
	grep -q 'nikkinikki.pages.dev' "$anf_script" || { warn "feed.sh 内容校验失败"; return 1; }
	anf_attempt=1
	while [ "$anf_attempt" -le 3 ]; do
		key_info "执行 Nikki 官方 feed.sh（尝试 ${anf_attempt}/3）"
		anf_feed_ok=0
		if [ "$DETAIL_OUTPUT" = 1 ]; then
			(cd "$WORK_DIR" && ash -e "$anf_script") && anf_feed_ok=1
		else
			(cd "$WORK_DIR" && ash -e "$anf_script") >/dev/null 2>&1 && anf_feed_ok=1
		fi
		if [ "$anf_feed_ok" -eq 1 ] && feed_current && pkg_update_once >/dev/null 2>&1; then
			NIKKI_FEED_READY=1
			NIKKI_FEED_ADDED_SESSION=1
			ok "Nikki 官方软件源已添加并通过索引验证；本次会话后续复用"
			return 0
		fi
		[ "$anf_attempt" -lt 3 ] && sleep 2
		anf_attempt=$((anf_attempt + 1))
	done
	NIKKI_FEED_READY=0; PKG_INDEX_READY=0
	warn "Nikki 官方软件源连续 3 次添加/索引验证失败，将切换方案 B"
	return 1
}

report_nikki_package_result() {
	rn_before="$1"
	rn_after="$(nikki_version 2>/dev/null || true)"
	[ -n "$rn_after" ] || { err "软件包命令执行结束，但未检测到 Nikki"; return 1; }
	if [ -z "$rn_before" ]; then
		ok "Nikki 已安装：${rn_after}"
	elif [ "$rn_before" != "$rn_after" ]; then
		ok "Nikki 已更新：${rn_before} -> ${rn_after}"
	elif [ "$FORCE_NIKKI_REINSTALL" -eq 1 ]; then
		ok "Nikki 已强制重装：${rn_after}"
	else
		ok "Nikki 已执行安装/升级检查，当前版本 ${rn_after}（仓库最新可安装版本）"
	fi
}

install_packages_from_feed() {
	ipf_refresh="${1:-1}"
	ipf_before="$(nikki_version 2>/dev/null || true)"
	if [ "$ipf_refresh" != "0" ]; then
		pkg_update_once || return 1
	fi
	case "$PKG_MANAGER" in
		opkg)
			if [ "$FORCE_NIKKI_REINSTALL" -eq 1 ] && [ -n "$ipf_before" ]; then
				# 三者共同构成 Nikki 主体；强制方案重装已有包，同时补齐缺失的必需 UI/语言包。
				if [ "$DETAIL_OUTPUT" = 1 ]; then opkg install --force-reinstall nikki luci-app-nikki luci-i18n-nikki-zh-cn
				else opkg install --force-reinstall nikki luci-app-nikki luci-i18n-nikki-zh-cn >/dev/null 2>&1; fi || return 1
			else
				# opkg install 会安装缺失包，并在索引存在较新版本时升级已安装包。
				pkg_install nikki luci-app-nikki luci-i18n-nikki-zh-cn || return 1
			fi
			;;
		apk)
			if [ -z "$ipf_before" ]; then
				# 首次安装严格采用 Nikki 官方方案 A；内核包由 nikki 的依赖自动解析。
				apk add nikki luci-app-nikki luci-i18n-nikki-zh-cn || return 1
			elif [ "$FORCE_NIKKI_REINSTALL" -eq 1 ]; then
				# 先升级并补齐必需包，再用 fix 强制校验/重装；兼容 apk 固件的修复语义。
				if [ "$DETAIL_OUTPUT" = 1 ]; then
					apk add --upgrade nikki luci-app-nikki luci-i18n-nikki-zh-cn && \
						apk fix nikki luci-app-nikki luci-i18n-nikki-zh-cn
				else
					apk add --upgrade nikki luci-app-nikki luci-i18n-nikki-zh-cn >/dev/null 2>&1 && \
						apk fix nikki luci-app-nikki luci-i18n-nikki-zh-cn >/dev/null 2>&1
				fi || return 1
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
	say "${B}${C}  ┌─ Nikki 安装/更新明细${N}"
	progress_line "1/4" "建立软件包、配置、软件源和现有内核备份"
	backup_install_state || { err "无法建立安装前备份（可能存储空间不足）"; return 1; }
	install_script="$WORK_DIR/install.sh"
	io_success=0
	progress_line "2/4" "复用本次脚本会话的软件源与索引，执行方案 A；失败时切换方案 B"
	if add_nikki_feed_once; then
		info "正在从本次会话添加的软件源安装/升级 Nikki 及依赖"
		if install_packages_from_feed 0; then
			ok "方案 A 完成"
			io_success=1
		else
			warn "方案 A 软件包安装/升级失败，将尝试方案 B"
		fi
	else
		warn "本次会话的软件源添加未成功，将直接尝试官方发行包方案 B"
	fi

	if [ "$io_success" -ne 1 ]; then
		# 方案 B 是同一主体安装事务的后备路径；方案 A 的临时下载失败不应阻断 B。
		DOWNLOAD_FAILURES=0
		install_url="https://raw.githubusercontent.com/${NIKKI_REPO}/refs/heads/main/install.sh"
		io_before="$(nikki_version 2>/dev/null || true)"
		io_b_ok=1
		fetch_url "$install_url" "$install_script" script || io_b_ok=0
		[ "$io_b_ok" -ne 1 ] || grep -q "Nikki's installer" "$install_script" || io_b_ok=0
		if [ "$io_b_ok" -eq 1 ]; then
			if [ "$DETAIL_OUTPUT" = 1 ]; then (cd "$WORK_DIR" && ash "$install_script") || io_b_ok=0
			else (cd "$WORK_DIR" && ash "$install_script") >/dev/null 2>&1 || io_b_ok=0; fi
		fi
		[ "$io_b_ok" -ne 1 ] || PKG_INDEX_READY=1
		if [ "$io_b_ok" -eq 1 ] && [ "$PKG_MANAGER" = "apk" ]; then
			io_repo="https://nikkinikki.pages.dev/${OFFICIAL_BRANCH}/${OPENWRT_ARCH}/nikki/packages.adb"
			apk add --upgrade --allow-untrusted -X "$io_repo" nikki luci-app-nikki luci-i18n-nikki-zh-cn || io_b_ok=0
		fi
		[ "$io_b_ok" -ne 1 ] || report_nikki_package_result "$io_before" || io_b_ok=0
		if [ "$io_b_ok" -ne 1 ]; then
			restore_install_state
			err "方案 A、B 均失败；已尽可能恢复配置、内核和本次新增包"
			return 1
		fi
	fi

	progress_line "3/4" "检查 Nikki 软件包、启动脚本和 Mihomo 内核完整性"
	if ! pkg_is_installed nikki || [ ! -x "$NIKKI_INIT" ] || [ ! -x "$CORE_PATH" ]; then
		restore_install_state
		err "Nikki 安装后完整性检查失败，已回滚"
		return 1
	fi
	progress_line "4/4" "重新选择下载器并清理安装阶段临时备份"
	# Nikki 的官方依赖包含 curl；重新选择后续大文件下载器。
	select_downloader
	# 安装阶段已经提交，释放可能包含模型/UI 的临时整目录备份，避免挤占 /tmp。
	[ ! -d "$WORK_DIR/install-backup" ] || safe_rm_tree "$WORK_DIR/install-backup" >/dev/null 2>&1 || true
	progress_done "Nikki 最新版及依赖已安装或更新完成"
	return 0
}

ensure_update_tools() {
	eut_missing=""
	command -v gzip >/dev/null 2>&1 || eut_missing="$eut_missing gzip"
	command -v unzip >/dev/null 2>&1 || eut_missing="$eut_missing unzip"
	command -v curl >/dev/null 2>&1 || eut_missing="$eut_missing curl"
	command -v yq >/dev/null 2>&1 || eut_missing="$eut_missing yq"
	if [ -n "$eut_missing" ]; then
		info "安装维护工具：$eut_missing"
		pkg_update_once >/dev/null 2>&1 || return 1
		# shellcheck disable=SC2086
		pkg_install $eut_missing || return 1
	fi
	select_downloader
	return 0
}

nikki_running() {
	if command -v pidof >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1; then return 0; fi
	"$NIKKI_INIT" status >/dev/null 2>&1
}

wait_nikki() {
	wn_i=0
	while [ "$wn_i" -lt 15 ]; do nikki_running && return 0; sleep 1; wn_i=$((wn_i + 1)); done
	return 1
}

preserve_nondefault_core_before_nikki() {
	NONDEFAULT_CORE_PRESERVED=0; PRESERVED_CORE_KIND=""
	[ "$NIKKI_UPDATE_CHOICE" = update ] && core_is_installed || return 0
	pscbn_version="$(core_installed_version)"
	pscbn_kind="$(core_installed_kind "$pscbn_version")"
	case "$pscbn_kind" in smart|alpha) ;; *) return 0 ;; esac
	# 明确切换到另一类型时尊重用户选择；日常维护、同类型维护和 Nikki-only 才保全。
	[ "$ACTION" = skip ] || [ "$ACTION" = "$pscbn_kind" ] || return 0
	cp -p "$CORE_PATH" "$NONDEFAULT_CORE_BEFORE_NIKKI" || return 1
	chmod 0755 "$NONDEFAULT_CORE_BEFORE_NIKKI" || return 1
	NONDEFAULT_CORE_PRESERVED=1; PRESERVED_CORE_KIND="$pscbn_kind"
	info "已临时保全更新前的 $(core_kind_label "$pscbn_kind") 内核，防止 Nikki 默认依赖覆盖"
}

restore_nondefault_core_after_nikki() {
	[ "$NONDEFAULT_CORE_PRESERVED" -eq 1 ] && [ -n "$PRESERVED_CORE_KIND" ] && [ -s "$NONDEFAULT_CORE_BEFORE_NIKKI" ] || return 0
	rscan_current="$(core_installed_version 2>/dev/null || true)"
	if [ "$(core_installed_kind "$rscan_current")" = "$PRESERVED_CORE_KIND" ]; then
		info "Nikki 更新后仍保持 $(core_kind_label "$PRESERVED_CORE_KIND") 内核，无需恢复保全副本"
		return 0
	fi
	rscan_new="${CORE_PATH}.restore.${PID}"
	cp -p "$NONDEFAULT_CORE_BEFORE_NIKKI" "$rscan_new" || return 1
	chmod 0755 "$rscan_new" || { rm -f -- "$rscan_new"; return 1; }
	mv "$rscan_new" "$CORE_PATH" || { rm -f -- "$rscan_new"; return 1; }
	CORE_UPDATE_STATUS="restored"
	warn "Nikki 更新曾覆盖 $(core_kind_label "$PRESERVED_CORE_KIND") 内核；已原子恢复更新前内核，随后继续更新同类型内核"
	return 0
}

binary_update_needs_restart() {
	case "$NIKKI_UPDATE_STATUS:$CORE_UPDATE_STATUS" in
		updated:*|*:updated|*:restored) return 0 ;;
		*) return 1 ;;
	esac
}

ensure_nikki_restarted_after_binary_update() {
	binary_update_needs_restart || return 0
	flow_title "最后一步：重启 Nikki 服务使主体/内核更新生效"
	if [ "$SERVICE_RESTART_VERIFIED" -eq 1 ] && nikki_running; then
		progress_done "Nikki 已在事务提交时完成整服务重启并验证，无需重复中断连接"
		return 0
	fi
	if ! "$NIKKI_INIT" restart || ! wait_nikki; then
		err "Nikki 主体或内核已更新，但整服务重启验证失败；请检查日志后手动执行 $NIKKI_INIT restart"
		return 1
	fi
	SERVICE_RESTART_VERIFIED=1
	progress_done "Nikki 整服务已重启并确认运行，新主体/内核已经生效"
	return 0
}

begin_transaction() {
	mkdir -p "$RUN_DIR" "$WORK_DIR" || return 1
	[ ! -e "$CORE_BACKUP" ] && [ ! -e "$MODEL_BACKUP" ] && [ ! -e "$UI_BACKUP" ] || return 1
	if nikki_running; then WAS_RUNNING=1; else WAS_RUNNING=0; fi
	if [ -f "$CORE_PATH" ]; then CORE_EXISTED=1; fi
	if [ -f "$MODEL_PATH" ]; then MODEL_EXISTED=1; fi
	if [ -d "$UI_TARGET" ]; then UI_EXISTED=1; fi
	if [ -f /etc/config/nikki ]; then CONFIG_EXISTED=1; cp -p /etc/config/nikki "$CONFIG_BACKUP" || return 1; fi
	if [ -d /etc/nikki/subscriptions ]; then
		SUBSCRIPTIONS_EXISTED=1
		cp -a /etc/nikki/subscriptions "$SUBSCRIPTIONS_BACKUP" || return 1
	fi
	mkdir "$GEOX_BACKUP" || return 1
	for bt_file in GeoSite.dat GeoIP.dat Country.mmdb ASN.mmdb; do
		if [ -f "$RUN_DIR/$bt_file" ]; then cp -p "$RUN_DIR/$bt_file" "$GEOX_BACKUP/$bt_file" || return 1; fi
	done
	TRANSACTION_ACTIVE=1
	return 0
}

rollback_transaction() {
	warn "维护事务失败，正在恢复内核、模型、GeoX、面板及 Nikki 配置……"
	"$NIKKI_INIT" stop >/dev/null 2>&1 || true
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
	if [ "$SUBSCRIPTIONS_EXISTED" -eq 1 ] && [ -d "$SUBSCRIPTIONS_BACKUP" ]; then
		rm -rf -- /etc/nikki/subscriptions
		cp -a "$SUBSCRIPTIONS_BACKUP" /etc/nikki/subscriptions || true
	elif [ "$SUBSCRIPTIONS_EXISTED" -eq 0 ]; then
		rm -rf -- /etc/nikki/subscriptions
	fi
	if [ "$WAS_RUNNING" -eq 1 ]; then "$NIKKI_INIT" restart >/dev/null 2>&1 || true; fi
	TRANSACTION_ACTIVE=0
	cleanup_transaction_backups
	err "已回滚到本次菜单操作开始前的状态"
}

cleanup_transaction_backups() {
	rm -f -- "$CORE_BACKUP" "$MODEL_BACKUP" "$CONFIG_BACKUP" 2>/dev/null || true
	[ ! -d "$UI_BACKUP" ] || safe_rm_tree "$UI_BACKUP" >/dev/null 2>&1 || true
	[ ! -d "$GEOX_BACKUP" ] || safe_rm_tree "$GEOX_BACKUP" >/dev/null 2>&1 || true
	[ ! -d "$SUBSCRIPTIONS_BACKUP" ] || safe_rm_tree "$SUBSCRIPTIONS_BACKUP" >/dev/null 2>&1 || true
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
	pc_json="$WORK_DIR/core-${pc_kind}-release.json"
	pc_gz="$WORK_DIR/mihomo.gz"
	pc_new="$WORK_DIR/mihomo.new"
	progress_line "1/6" "查询 ${pc_repo} 的最新发行资产"
	fetch_json_cached "$pc_api" "$pc_json" || return 1
	pc_record="$(core_asset_record "$pc_json")"
	[ -n "$pc_record" ] || { err "未找到 ${ASSET_ARCH} 对应内核"; return 1; }
	split_record "$pc_record"
	progress_line "2/6" "匹配当前 CPU 架构资产：$REC_NAME"
	progress_line "3/6" "下载内核；直连失败或低速时自动轮换反代"
	fetch_url "$REC_URL" "$pc_gz" gzip || return 1
	progress_line "4/6" "校验大小、SHA-256、Gzip，并验证新内核可执行性"
	verify_download "$pc_gz" "$REC_SHA" "$REC_SIZE" || { err "内核大小/SHA-256 校验失败"; return 1; }
	gzip -dc "$pc_gz" > "$pc_new" || return 1
	chmod 0755 "$pc_new" || return 1
	NEW_CORE_VERSION="$("$pc_new" -v 2>/dev/null | head -n 1 || true)"
	[ -n "$NEW_CORE_VERSION" ] || { err "新内核无法在当前 CPU 上执行"; return 1; }
	progress_line "5/6" "使用新内核检查现有 Nikki 配置兼容性"
	if [ -s "$RUN_DIR/config.yaml" ]; then
		info "使用新内核检查当前 Nikki 配置……"
		if ! "$pc_new" -t -d "$RUN_DIR" -f "$RUN_DIR/config.yaml" > "$WORK_DIR/core-test.log" 2>&1; then
			tail -n 20 "$WORK_DIR/core-test.log" >&2 || true
			err "新内核未通过当前配置检查"
			return 1
		fi
	else info "当前无运行配置，跳过配置语法检查"; fi
	progress_line "6/6" "备份当前内核并原子替换新文件"
	cp "$pc_new" "${CORE_PATH}.new.${PID}" || return 1
	chmod 0755 "${CORE_PATH}.new.${PID}" || return 1
	if [ -f "$CORE_PATH" ] && [ ! -e "$CORE_BACKUP" ]; then cp -p "$CORE_PATH" "$CORE_BACKUP" || return 1; fi
	mv "${CORE_PATH}.new.${PID}" "$CORE_PATH" || return 1
	CORE_KIND_NEW="$pc_kind"
	progress_done "内核已暂存安装：$NEW_CORE_VERSION"
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

backup_model_before_forced_replace() {
	[ "$FORCE_MAINTENANCE" -eq 1 ] && [ -s "$MODEL_PATH" ] || return 0
	bmfr_stamp="$(date '+%Y%m%d-%H%M%S' 2>/dev/null || printf '%s' "$PID")"
	mkdir -p "$SETTINGS_BACKUP_DIR" || return 1
	bmfr_target="$SETTINGS_BACKUP_DIR/Model.bin.before-force.${bmfr_stamp}.${PID}"
	cp -p "$MODEL_PATH" "$bmfr_target" || return 1
	ok "强制维护前的 LightGBM 已持久备份：$bmfr_target"
}

prepare_model() {
	pm_choice="$LGBM_CHOICE"
	progress_line "1/5" "确定本轮 LightGBM 模型规格"
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
	progress_line "2/5" "查询 LightGBM-Model 发行资产：$pm_name"
	if fetch_json_cached "$pm_api" "$pm_json"; then
		pm_record="$(asset_record_by_name "$pm_name" "$pm_json")"
	else pm_record=""; fi
	if [ -n "$pm_record" ]; then
		split_record "$pm_record"
	else
		warn "模型 API 不可用，使用固定 Release 地址"
		REC_URL="https://github.com/vernesong/mihomo/releases/download/LightGBM-Model/${pm_name}"
		REC_SHA=""; REC_SIZE=""; REC_NAME="$pm_name"
	fi
	progress_line "3/5" "下载模型；直连失败或低速时自动轮换反代"
	fetch_url "$REC_URL" "$pm_file" model || return 1
	progress_line "4/5" "校验文件格式、大小、SHA-256 和剩余存储空间"
	verify_download "$pm_file" "$REC_SHA" "$REC_SIZE" || { err "模型大小/SHA-256 校验失败"; return 1; }
	MODEL_SHA_NEW="$(sha256sum "$pm_file" 2>/dev/null | awk '{print $1}')"
	[ -n "$MODEL_SHA_NEW" ] || { err "无法计算 LightGBM SHA-256"; return 1; }
	pm_free="$(free_kb_at "$RUN_DIR")"; pm_need=$((($(wc -c < "$pm_file") + 1023) / 1024 + 12 * 1024))
	[ "$pm_free" -ge "$pm_need" ] || { err "模型分区空间不足（需含预留约 $((pm_need/1024)) MiB）"; return 1; }
	progress_line "5/5" "备份现有模型并原子替换"
	backup_model_before_forced_replace || { err "无法建立 LightGBM 持久备份"; return 1; }
	cp "$pm_file" "${MODEL_PATH}.new.${PID}" || return 1
	chmod 0644 "${MODEL_PATH}.new.${PID}" || return 1
	if [ -f "$MODEL_PATH" ] && [ ! -e "$MODEL_BACKUP" ]; then cp -p "$MODEL_PATH" "$MODEL_BACKUP" || return 1; fi
	mv "${MODEL_PATH}.new.${PID}" "$MODEL_PATH" || return 1
	LGBM_CHOICE="$pm_choice"
	MODEL_LABEL_NEW="$pm_label"
	progress_done "LightGBM 模型已暂存安装：$MODEL_LABEL_NEW"
	return 0
}

prepare_geox() {
	pg_api="https://api.github.com/repos/MetaCubeX/meta-rules-dat/releases/latest"
	pg_json="$WORK_DIR/geox-release.json"
	progress_line "1/3" "查询 GeoX 最新发行日期和四项资产"
	if fetch_json_cached "$pg_api" "$pg_json"; then
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
	pg_index=0
	for pg_item in "geosite.dat:GeoSite.dat:dat" "geoip.dat:GeoIP.dat:dat" "country.mmdb:Country.mmdb:mmdb" "GeoLite2-ASN.mmdb:ASN.mmdb:mmdb"; do
		pg_index=$((pg_index + 1))
		pg_remote="${pg_item%%:*}"; pg_rest="${pg_item#*:}"; pg_local="${pg_rest%%:*}"; pg_kind="${pg_rest#*:}"
		if [ "$pg_have_api" -eq 1 ]; then pg_record="$(asset_record_by_name "$pg_remote" "$pg_json")"; else pg_record=""; fi
		if [ -n "$pg_record" ]; then split_record "$pg_record";
		else REC_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/${pg_remote}"; REC_SHA=""; REC_SIZE=""; fi
		progress_line "2/3 · ${pg_index}/4" "下载并校验 GeoX：$pg_remote"
		fetch_url "$REC_URL" "$pg_stage/$pg_local" "$pg_kind" || { safe_rm_tree "$pg_stage" >/dev/null 2>&1 || true; return 1; }
		verify_download "$pg_stage/$pg_local" "$REC_SHA" "$REC_SIZE" || { err "$pg_remote 校验失败"; safe_rm_tree "$pg_stage" >/dev/null 2>&1 || true; return 1; }
	done
	progress_line "3/3" "整套替换四项数据库；任一失败则恢复原文件"
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
	progress_done "GeoX 数据库已暂存更新：$GEOX_DATE_NEW"
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
	progress_line "1/5" "查询 Zashboard 最新版本及发行包：$pz_asset"
	if fetch_json_cached "$pz_api" "$pz_json"; then
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
	progress_line "2/5" "下载并校验 Zashboard；直连失败或低速时自动轮换反代"
	fetch_url "$REC_URL" "$pz_zip" zip || return 1
	verify_download "$pz_zip" "$REC_SHA" "$REC_SIZE" || { err "Zashboard 校验失败"; return 1; }
	progress_line "3/5" "解压面板并验证 index.html 与 assets 目录"
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
	progress_line "4/5" "备份现有面板并安装到 $UI_TARGET"
	mkdir -p "$UI_DIR" || { safe_rm_tree "$pz_stage" >/dev/null 2>&1 || true; return 1; }
	if [ -d "$UI_TARGET" ] && [ ! -e "$UI_BACKUP" ]; then mv "$UI_TARGET" "$UI_BACKUP" || return 1; fi
	if ! mv "$pz_stage" "$UI_TARGET"; then
		[ ! -d "$UI_BACKUP" ] || mv "$UI_BACKUP" "$UI_TARGET" || true
		return 1
	fi
	progress_line "5/5" "同步 Nikki 面板目录、名称和下载地址配置"
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
	progress_done "Zashboard 已暂存更新：${ZASH_VERSION_NEW:-unknown}"
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

ruleset_provider_names() {
	[ -s "$RUN_DIR/config.yaml" ] || return 0
	command -v yq >/dev/null 2>&1 || return 0
	# 仅刷新现有 HTTP rule-provider；inline/file 类型没有远程资源可下载。
	yq -M -r '.rule-providers // {} | to_entries | .[] | select((.value.type // "http") == "http") | .key' "$RUN_DIR/config.yaml" 2>/dev/null || true
}

ruleset_provider_count() {
	rpc_count=0
	while IFS= read -r rpc_name; do [ -z "$rpc_name" ] || rpc_count=$((rpc_count + 1)); done <<EOF
$(ruleset_provider_names)
EOF
	printf '%s' "$rpc_count"
}

percent_encode_path_segment() {
	# 对整个 UTF-8 路径段百分号编码，避免中文、空格、斜杠和引号破坏 API 路径或 JSON。
	PE_PATH_VALUE="$1" yq -n -r 'strenv(PE_PATH_VALUE) | @uri' 2>/dev/null
}

mihomo_api_prepare() {
	[ -s "$RUN_DIR/config.yaml" ] || return 1
	command -v yq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || return 1
	map_tls="$(yq -M -r '."external-controller-tls" // ""' "$RUN_DIR/config.yaml" 2>/dev/null || true)"
	map_plain="$(yq -M -r '."external-controller" // ""' "$RUN_DIR/config.yaml" 2>/dev/null || true)"
	if [ -n "$map_tls" ]; then map_listen="$map_tls"; MIHOMO_API_SCHEME=https
	else map_listen="$map_plain"; MIHOMO_API_SCHEME=http; fi
	[ -n "$map_listen" ] || return 1
	MIHOMO_API_PORT="${map_listen##*:}"
	case "$MIHOMO_API_PORT" in ''|*[!0-9]*) return 1 ;; esac
	MIHOMO_API_SECRET="$(yq -M -r '.secret // ""' "$RUN_DIR/config.yaml" 2>/dev/null || true)"
	MIHOMO_API_BASE="${MIHOMO_API_SCHEME}://127.0.0.1:${MIHOMO_API_PORT}"
	return 0
}

mihomo_api_put() {
	maur_path="$1"
	if [ -n "$MIHOMO_API_SECRET" ]; then
		curl -k -sS -f -L --connect-timeout 5 --max-time 120 -X PUT \
			-H "Authorization: Bearer ${MIHOMO_API_SECRET}" -o /dev/null "${MIHOMO_API_BASE}${maur_path}"
	else
		curl -k -sS -f -L --connect-timeout 5 --max-time 120 -X PUT -o /dev/null "${MIHOMO_API_BASE}${maur_path}"
	fi
}

update_existing_rulesets() {
	RULESET_TOTAL_COUNT="$(ruleset_provider_count)"
	RULESET_UPDATED_COUNT=0
	if [ "$RULESET_TOTAL_COUNT" -eq 0 ]; then
		RULESET_UPDATE_STATUS="not_present"
		progress_skip "当前运行配置没有 HTTP rule-provider，不创建新规则集"
		return 0
	fi
	if ! nikki_running; then
		RULESET_UPDATE_STATUS="skipped"
		warn "Nikki 当前未运行，无法通过控制接口刷新 rule-set；已保留现有缓存"
		return 1
	fi
	if ! mihomo_api_prepare; then
		RULESET_UPDATE_STATUS="skipped"
		warn "无法读取或连接 Mihomo external-controller，不能刷新 rule-set"
		return 1
	fi
	uer_failed=0; uer_index=0
	while IFS= read -r uer_name; do
		[ -n "$uer_name" ] || continue
		uer_index=$((uer_index + 1))
		progress_line "${uer_index}/${RULESET_TOTAL_COUNT}" "刷新 rule-set：$uer_name"
		uer_encoded="$(percent_encode_path_segment "$uer_name" 2>/dev/null || true)"
		if [ -z "$uer_encoded" ]; then
			uer_failed=$((uer_failed + 1))
			warn "rule-set 名称编码失败，已跳过并保留现有缓存：$uer_name"
			continue
		fi
		uer_path="/providers/rules/${uer_encoded}"
		if mihomo_api_put "$uer_path" >/dev/null 2>&1; then
			RULESET_UPDATED_COUNT=$((RULESET_UPDATED_COUNT + 1))
			progress_done "rule-set 已刷新：$uer_name"
		else
			uer_failed=$((uer_failed + 1))
			warn "rule-set 刷新失败，已保留现有缓存：$uer_name"
		fi
	done <<EOF
$(ruleset_provider_names)
EOF
	if [ "$RULESET_UPDATED_COUNT" -eq "$RULESET_TOTAL_COUNT" ]; then RULESET_UPDATE_STATUS="updated"; return 0; fi
	if [ "$RULESET_UPDATED_COUNT" -gt 0 ]; then RULESET_UPDATE_STATUS="partial"; return 0; fi
	RULESET_UPDATE_STATUS="skipped"
	return 1
}

sanitize_state() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._+ /:()-'; }

write_state() {
	ws_tmp="${STATE_FILE}.new.${PID}"
	{
		printf 'CORE_KIND=%s\n' "$(sanitize_state "$CORE_KIND_NEW")"
		printf 'CORE_VERSION=%s\n' "$(sanitize_state "$NEW_CORE_VERSION")"
		printf 'MODEL=%s\n' "$(sanitize_state "${MODEL_LABEL_NEW:-不适用}")"
		printf 'MODEL_SHA256=%s\n' "$(sanitize_state "${MODEL_SHA_NEW:-}")"
		printf 'GEOX_DATE=%s\n' "$(sanitize_state "$GEOX_DATE_NEW")"
		printf 'ZASH_VERSION=%s\n' "$(sanitize_state "$ZASH_VERSION_NEW")"
		printf 'UPDATED_AT=%s\n' "$(date '+%Y/%m/%d %H:%M:%S' 2>/dev/null || true)"
	} > "$ws_tmp" || return 1
	mv "$ws_tmp" "$STATE_FILE" || return 1
}

commit_transaction() {
	if [ "$WAS_RUNNING" -eq 1 ]; then
		info "重启 Nikki 并验证服务状态……"
		if ! "$NIKKI_INIT" restart || ! wait_nikki; then return 1; fi
		ok "Nikki 已使用新内核正常运行"
		binary_update_needs_restart && SERVICE_RESTART_VERIFIED=1
	else
		info "更新前 Nikki 未运行，保持停止状态"
	fi
	if [ "$ZASH_UPDATE_STATUS" = "updated" ] && ! verify_zashboard_runtime; then return 1; fi
	write_state || return 1
	TRANSACTION_ACTIVE=0
	if [ "$KEEP_BACKUP_ON_SUCCESS" != "1" ]; then cleanup_transaction_backups; fi
	return 0
}

initialize_maintenance_state() {
	CORE_KIND_NEW=""
	NEW_CORE_VERSION="$("$CORE_PATH" -v 2>/dev/null | head -n 1 || true)"
	MODEL_LABEL_NEW="$(state_get MODEL)"
	MODEL_SHA_NEW="$(state_get MODEL_SHA256)"
	GEOX_DATE_NEW="$(state_get GEOX_DATE)"
	ZASH_VERSION_NEW="$(state_get ZASH_VERSION)"
	if [ -n "$NEW_CORE_VERSION" ]; then
		case "$NEW_CORE_VERSION" in *alpha-smart*) CORE_KIND_NEW="smart" ;; *alpha*) CORE_KIND_NEW="alpha" ;; *) CORE_KIND_NEW="stable" ;; esac
	else CORE_KIND_NEW="$(state_get CORE_KIND)"; NEW_CORE_VERSION="$(state_get CORE_VERSION)"; fi
	[ -n "$MODEL_LABEL_NEW" ] || { [ -s "$MODEL_PATH" ] && MODEL_LABEL_NEW="已安装（版本未知）" || MODEL_LABEL_NEW="未安装"; }
	[ -n "$GEOX_DATE_NEW" ] || GEOX_DATE_NEW="$(file_date "$RUN_DIR/GeoSite.dat")"
	[ -n "$ZASH_VERSION_NEW" ] || ZASH_VERSION_NEW="unknown"
}

run_maintenance() {
	rm_kind="$1"
	if [ "$rm_kind" = smart ] && [ "$LGBM_CHOICE" != skip ] && [ -z "$AUTO_SKIP_MODEL" ]; then MODEL_MAINTAIN=1; fi
	if [ "$rm_kind" = skip ] && [ "$MODEL_MAINTAIN" -eq 0 ] && [ "$GEOX_CHOICE" = skip ] && [ "$ZASH_CHOICE" = skip ] && [ "$RULESET_CHOICE" = skip ]; then
		flow_title "步骤 2/6：Mihomo 内核"
		if [ "$NIKKI_UPDATE_CHOICE" = update ]; then progress_skip "未指定额外内核，保留 Nikki 安装/更新后的默认稳定版 mihomo-meta"
		else progress_skip "已按计划跳过内核，保留原有版本"; fi
		flow_title "步骤 3/6：LightGBM 模型"
		progress_skip "已按计划跳过 LightGBM，保留当前文件"
		flow_title "步骤 4/6：GeoX 数据库"
		progress_skip "已按计划跳过 GeoX，保留当前数据库"
		flow_title "步骤 5/6：Zashboard 面板"
		progress_skip "已按计划跳过 Zashboard，保留当前面板"
		flow_title "步骤 6/6：rule-set 自定义规则集"
		progress_skip "已按计划跳过 rule-set 更新"
		CORE_UPDATE_STATUS="$(status_from_auto_skip "$AUTO_SKIP_CORE")"
		MODEL_UPDATE_STATUS="$(status_from_auto_skip "$AUTO_SKIP_MODEL")"
		GEOX_UPDATE_STATUS="$(status_from_auto_skip "$AUTO_SKIP_GEOX")"
		ZASH_UPDATE_STATUS="$(status_from_auto_skip "$AUTO_SKIP_ZASH")"
		RULESET_UPDATE_STATUS="user_skipped"
		return 0
	fi
	flow_title "维护事务准备"
	progress_line "1/2" "检查并补齐 gzip、unzip、curl 等维护工具"
	ensure_update_tools || fatal "维护工具安装失败"
	progress_line "2/2" "备份内核、模型、GeoX、面板、Nikki 配置和订阅缓存"
	if ! begin_transaction; then
		cleanup_transaction_backups
		fatal "无法建立事务备份；请检查 /tmp 与 overlay 可用空间"
	fi
	progress_done "事务备份已建立；后续失败可恢复原文件"
	initialize_maintenance_state
	MAINT_SUCCESS=0
	flow_title "步骤 2/6：Mihomo 内核"
	case "$rm_kind" in
		smart|alpha|stable)
			case "$rm_kind" in smart) rm_core_label="Smart" ;; alpha) rm_core_label="开发预览版" ;; stable) rm_core_label="稳定版" ;; esac
			rm_old_kind="$CORE_KIND_NEW"; rm_old_core_version="$NEW_CORE_VERSION"
			rm_old_core_status="$CORE_UPDATE_STATUS"
			if prepare_core "$rm_kind"; then CORE_UPDATE_STATUS="updated"; MAINT_SUCCESS=$((MAINT_SUCCESS + 1));
			else CORE_KIND_NEW="$rm_old_kind"; NEW_CORE_VERSION="$rm_old_core_version";
				if [ "$rm_old_core_status" = restored ]; then CORE_UPDATE_STATUS="restored"; else CORE_UPDATE_STATUS="skipped"; fi
				warn "无法更新 ${rm_core_label}内核，已跳过此项并保留原文件；建议稍后手动更新"; fi
			;;
		skip)
			[ "$CORE_UPDATE_STATUS" = restored ] || CORE_UPDATE_STATUS="$(status_from_auto_skip "$AUTO_SKIP_CORE")"
			MODEL_UPDATE_STATUS="not_selected"
			if [ "$NIKKI_UPDATE_CHOICE" = update ]; then progress_skip "未指定额外内核，保留 Nikki 安装/更新后的默认稳定版 mihomo-meta"
			else progress_skip "已按选择跳过内核更新，保留原有版本"; fi
			;;
	esac
	flow_title "步骤 3/6：LightGBM 模型"
	if [ "$MODEL_MAINTAIN" -eq 1 ]; then
		if prepare_model; then MODEL_UPDATE_STATUS="updated"; MAINT_SUCCESS=$((MAINT_SUCCESS + 1));
		else MODEL_UPDATE_STATUS="skipped"; warn "无法更新 LightGBM 模型，已跳过此项并保留原文件；建议稍后手动更新"; fi
	else
		MODEL_UPDATE_STATUS="$(status_from_auto_skip "$AUTO_SKIP_MODEL")"
		if [ "$AUTO_SKIP_MODEL" = protected ]; then progress_skip "检测到疑似自定义 LightGBM，自动维护已保护并保留现有模型"
		elif [ "$AUTO_SKIP_MODEL" = latest ]; then progress_skip "LightGBM 已是最新官方资产，跳过下载与替换"
		elif [ "$AUTO_SKIP_MODEL" = unknown ]; then progress_skip "LightGBM 最新资产状态查询失败，自动维护安全跳过"
		elif [ -s "$MODEL_PATH" ]; then progress_skip "本轮未选择 LightGBM 更新，保留现有模型"
		else progress_skip "当前 $(paint_missing '未安装') LightGBM，本轮不安装模型"; fi
		[ "$rm_kind" != smart ] || [ -s "$MODEL_PATH" ] || warn "当前未检测到 LightGBM 模型，Smart 内核相关功能可能不可用"
	fi
	flow_title "步骤 4/6：GeoX 数据库"
	if [ "$GEOX_CHOICE" = update ]; then
		rm_old_geox="$GEOX_DATE_NEW"
		if prepare_geox; then GEOX_UPDATE_STATUS="updated"; MAINT_SUCCESS=$((MAINT_SUCCESS + 1));
		else GEOX_DATE_NEW="$rm_old_geox"; GEOX_UPDATE_STATUS="skipped"; warn "无法更新 GeoX 数据库，已跳过此项并保留原文件；建议稍后手动更新"; fi
	else GEOX_UPDATE_STATUS="$(status_from_auto_skip "$AUTO_SKIP_GEOX")"; progress_auto_skip "GeoX" "$AUTO_SKIP_GEOX" "已按计划跳过更新，保留当前数据库"; fi
	flow_title "步骤 5/6：Zashboard 面板"
	if [ "$ZASH_CHOICE" = update ]; then
		rm_old_zash="$ZASH_VERSION_NEW"
		if prepare_zashboard; then ZASH_UPDATE_STATUS="updated"; MAINT_SUCCESS=$((MAINT_SUCCESS + 1));
		else ZASH_VERSION_NEW="$rm_old_zash"; ZASH_UPDATE_STATUS="skipped"; warn "无法更新 Zashboard，已跳过此项并保留原文件；建议在 Nikki 中手动更新面板"; fi
	else ZASH_UPDATE_STATUS="$(status_from_auto_skip "$AUTO_SKIP_ZASH")"; progress_auto_skip "Zashboard" "$AUTO_SKIP_ZASH" "已按计划跳过更新，保留当前面板"; fi
	flow_title "步骤 6/6：rule-set 自定义规则集"
	# 先提交会影响运行配置的文件，让随后刷新的 rule-provider 对应最新 YAML。
	if [ "$MAINT_SUCCESS" -gt 0 ]; then
		if ! commit_transaction; then rollback_transaction; fatal "新版本安装后服务验证失败"; fi
	else
		TRANSACTION_ACTIVE=0
		cleanup_transaction_backups
	fi

	say "${B}${Y}仅刷新当前 YAML 中已经存在的 HTTP rule-provider，不创建缺失项目。${N}"
	if [ "$RULESET_CHOICE" = update ]; then
		if update_existing_rulesets; then
			case "$RULESET_UPDATE_STATUS" in updated|partial) MAINT_SUCCESS=$((MAINT_SUCCESS + 1)) ;; esac
		else warn "无法刷新 rule-set，已跳过此项；建议稍后在面板中手动更新 provider"; fi
	else RULESET_UPDATE_STATUS="user_skipped"; progress_skip "已按计划跳过 rule-set 更新"; fi
	if [ "$MAINT_SUCCESS" -eq 0 ]; then warn "本次没有项目成功更新，现有文件和缓存保持不变"; fi
}

state_get() { sg_key="$1"; sed -n "s/^${sg_key}=//p" "$STATE_FILE" 2>/dev/null | head -n 1; }

file_date() {
	fd_file="$1"
	date -r "$fd_file" '+%Y/%m/%d' 2>/dev/null || printf '%s' unknown
}

print_core_compatibility_hint() {
	case "$1" in
		smart)
			say "${ALERT}【温馨提示】当前为 Smart 内核：建议使用支持 smart 策略组的 Nikki 设置或 YAML 配置文件；同时兼容 url-test、fallback、select 等常规策略组。${N}"
			;;
		alpha|stable)
			say "${ALERT}【温馨提示】当前 Dev/稳定版内核不支持 smart 策略组：请同步调整 Nikki 设置或 YAML 配置文件；如需 smart 策略，请切换为 Smart 内核。${N}"
			;;
	esac
}

summary_status() {
	ss_status="$1"; ss_updated="${2:-0}"; ss_total="${3:-0}"
	case "$ss_status" in
		updated|latest) printf '%s' "$ps_latest" ;; skipped) printf '%s' "$ps_failed" ;;
		user_skipped) printf '%s' "$ps_user_skipped" ;;
		unknown) printf '%b' "${B}${Y}远程版本未知，自动安全跳过${N}" ;;
		protected) printf '%b' "${B}${Y}疑似自定义文件，已保护并跳过${N}" ;;
		partial) printf '%b' "${B}${Y}部分成功（${ss_updated}/${ss_total}）${N}" ;;
		not_present) printf '%b' "${B}${Y}未配置，已安全跳过${N}" ;;
		*) return 0 ;;
	esac
}

print_summary() {
	[ "$RULESET_TOTAL_COUNT" -gt 0 ] || RULESET_TOTAL_COUNT="$(ruleset_provider_count)"
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
	ps_nikki_default_core="${B}${G}未指定额外内核，采用 Nikki 默认依赖 mihomo-meta${N}"
	ps_nikki_result="$(summary_status "$NIKKI_UPDATE_STATUS")"
	summary_item "当前 Nikki" "$ps_nikki" "$ps_nikki_result"
	case "$CORE_UPDATE_STATUS" in
		updated|latest) ps_core_result="$ps_latest" ;;
		restored) ps_core_result="${B}${G}Nikki 更新后已恢复原非默认内核并生效${N}" ;;
		unknown) ps_core_result="${B}${Y}远程版本未知，自动安全跳过${N}" ;;
		skipped) ps_core_result="$ps_failed" ;;
		user_skipped)
			if [ "$NIKKI_UPDATE_CHOICE" = update ] && [ "$ACTION" = skip ]; then ps_core_result="$ps_nikki_default_core"; else ps_core_result="$ps_user_skipped"; fi
			;;
		*) ps_core_result="" ;;
	esac
	case "$MODEL_UPDATE_STATUS" in
		updated|latest) ps_model_result="$ps_latest" ;;
		removed) ps_model_result="${B}${G}已清除（Dev/稳定版内核无需 LightGBM）${N}" ;;
		not_present) ps_model_result="${B}${G}未安装，无需清理${N}" ;;
		skipped) ps_model_result="$ps_failed" ;;
		user_skipped) ps_model_result="$ps_user_skipped" ;;
		unknown) ps_model_result="${B}${Y}远程版本未知，自动安全跳过${N}" ;;
		protected) ps_model_result="${B}${Y}疑似自定义模型，已保护并跳过${N}" ;;
		*) ps_model_result="" ;;
	esac
	ps_geox_result="$(summary_status "$GEOX_UPDATE_STATUS")"; ps_zash_result="$(summary_status "$ZASH_UPDATE_STATUS")"
	ps_ruleset_result="$(summary_status "$RULESET_UPDATE_STATUS" "$RULESET_UPDATED_COUNT" "$RULESET_TOTAL_COUNT")"
	case "$ps_kind" in
		smart)
			summary_item "当前 Smart 内核" "$ps_core" "$ps_core_result"
			if [ -s "$MODEL_PATH" ]; then summary_item "      LGBM模型" "${ps_model:-unknown}" "$ps_model_result"; else summary_missing "      LGBM模型"; fi
			;;
		alpha|stable)
			if [ "$ps_kind" = alpha ]; then ps_core_label="当前开发预览版内核（Prerelease-Alpha）"; else ps_core_label="当前稳定版内核（meta）"; fi
			summary_item "$ps_core_label" "$ps_core" "$ps_core_result"
			case "$MODEL_UPDATE_STATUS" in removed|not_present) summary_item "      LightGBM模型" "已清理检查" "$ps_model_result" ;; *) [ "$MODEL_MAINTAIN" -ne 1 ] || summary_item "现有 LightGBM模型" "${ps_model:-unknown}" "$ps_model_result" ;; esac
			;;
		*) summary_item "当前内核" "$ps_core" "" ;;
	esac
	print_core_compatibility_hint "$ps_kind"
	say ""
	say "${B}${Y}当前 GeoX数据库：${N}"
	for ps_line in "geosite:GeoSite.dat" "geoip:GeoIP.dat" "mmdb:Country.mmdb" "asn:ASN.mmdb"; do
		ps_label="${ps_line%%:*}"; ps_file="${ps_line#*:}"
		if [ -s "$RUN_DIR/$ps_file" ]; then summary_item "  ${ps_label}" "$ps_geox" "$ps_geox_result"; else summary_missing "  ${ps_label}"; fi
	done
	say ""
	if [ -s "$UI_TARGET/index.html" ]; then summary_item "当前 Zashboard" "$ps_zash" "$ps_zash_result"; else summary_missing "当前 Zashboard"; fi
	say ""
	summary_item "rule-set 自定义规则集" "已配置 ${RULESET_TOTAL_COUNT} 项 HTTP provider" "$ps_ruleset_result"
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

backup_archive_name() {
	ba_stamp="$(date '+%Y%m%d-%H%M%S' 2>/dev/null || printf '%s' unknown)"
	printf '%s/nikki-settings-%s.tar.gz\n' "$SETTINGS_BACKUP_DIR" "$ba_stamp"
}

backup_settings_create() {
	command -v tar >/dev/null 2>&1 || { warn "系统缺少 tar，无法创建设置备份"; return 1; }
	[ -f /etc/config/nikki ] || { warn "未找到 /etc/config/nikki，当前没有可备份的 Nikki 插件设置"; return 1; }
	mkdir -p "$SETTINGS_BACKUP_DIR" || { warn "无法创建备份目录：$SETTINGS_BACKUP_DIR"; return 1; }
	bs_archive="$(backup_archive_name)"
	bs_tmp="${bs_archive}.tmp.$$"
	if tar -czf "$bs_tmp" -C /etc/config nikki; then
		mv -f -- "$bs_tmp" "$bs_archive"
		chmod 600 "$bs_archive" 2>/dev/null || true
		ok "Nikki 插件设置备份完成：$bs_archive"
		return 0
	fi
	rm -f -- "$bs_tmp" 2>/dev/null || true
	warn "设置备份失败"
	return 1
}

backup_settings_export() {
	command -v tar >/dev/null 2>&1 || { warn "系统缺少 tar，无法导出设置备份"; return 1; }
	[ -f /etc/config/nikki ] || { warn "未找到 /etc/config/nikki，当前没有可导出的 Nikki 插件设置"; return 1; }
	say "导出备份会包含 Nikki 插件 UCI 设置，不包含内核、GeoX、Zashboard、订阅及自定义 YAML。"
	say "请输入路由器上的目标文件路径；完成后可用 scp 下载到电脑任意位置。"
	prompt '>>> 目标路径（留空使用 /tmp/nikki-settings-export.tar.gz）：'
	read_user_input || return 1
	be_path="$(normalize_menu_answer "$USER_INPUT")"
	[ -n "$be_path" ] || be_path=/tmp/nikki-settings-export.tar.gz
	case "$be_path" in */) be_path="${be_path}nikki-settings-export.tar.gz" ;; esac
	be_dir="${be_path%/*}"; [ "$be_dir" = "$be_path" ] && be_dir=.
	mkdir -p "$be_dir" || { warn "无法创建导出目录：$be_dir"; return 1; }
	be_tmp="${be_path}.tmp.$$"
	if tar -czf "$be_tmp" -C /etc/config nikki; then
		mv -f -- "$be_tmp" "$be_path"
		chmod 600 "$be_path" 2>/dev/null || true
		ok "设置备份已导出：$be_path"
		say "电脑端下载示例：scp root@路由器IP:$be_path ."
		return 0
	fi
	rm -f -- "$be_tmp" 2>/dev/null || true
	warn "设置备份导出失败"
	return 1
}

backup_settings_restore() {
	command -v tar >/dev/null 2>&1 || { warn "系统缺少 tar，无法恢复设置"; return 1; }
	br_default=""
	if [ -d "$SETTINGS_BACKUP_DIR" ]; then
		# 备份名含可排序时间戳；按文件名倒序可避免用 ls 解析路径。
		br_default="$(find "$SETTINGS_BACKUP_DIR" -maxdepth 1 -type f -name 'nikki-settings-*.tar.gz' 2>/dev/null | sort -r | head -n 1 || true)"
	fi
	say "恢复仅覆盖 /etc/config/nikki，不会修改内核、GeoX、Zashboard、订阅或自定义 YAML。"
	[ -n "$br_default" ] && say "最近备份：$br_default"
	prompt '>>> 请输入备份文件路径（留空使用最近备份）：'
	read_user_input || return 1
	br_archive="$(normalize_menu_answer "$USER_INPUT")"; [ -n "$br_archive" ] || br_archive="$br_default"
	[ -f "$br_archive" ] || { warn "备份文件不存在：$br_archive"; return 1; }
	br_tmp="/tmp/nikki-settings-restore.${PID}"
	rm -rf -- "$br_tmp" 2>/dev/null || true
	mkdir -p "$br_tmp" || return 1
	if ! tar -xzf "$br_archive" -C "$br_tmp" 2>/dev/null || [ ! -f "$br_tmp/nikki" ]; then
		rm -rf -- "$br_tmp"; warn "备份格式无效，未恢复任何文件"; return 1
	fi
	br_target="/etc/config/nikki.restore.${PID}"
	if cp -p "$br_tmp/nikki" "$br_target" && mv -f -- "$br_target" /etc/config/nikki; then
		rm -rf -- "$br_tmp"
		uci >/dev/null 2>&1 || true
		ok "Nikki 插件设置已恢复；如需生效，请在 LuCI 保存或重启 Nikki"
		return 0
	fi
	rm -f -- "$br_target" 2>/dev/null || true
	rm -rf -- "$br_tmp"; warn "设置恢复失败，原文件未被完整替换"; return 1
}

backup_menu() {
	while :; do
		flow_title "备份与恢复"
		menu_line "  1）一键备份 Nikki 插件设置"
		say "     仅备份 /etc/config/nikki，不包含内核、自定义 YAML、订阅和运行数据。"
		menu_line "  2）备份导出｜生成可用 scp 下载到电脑的压缩包"
		menu_line "  3）一键恢复备份｜仅恢复 Nikki 插件设置"
		menu_line "  4）返回主菜单"
		menu_line "================================================"
		prompt '>>> 请手动选择 [1-4]：'
		read_user_input || fatal "无法读取备份与恢复菜单选项"
		case "$USER_INPUT" in
			1) backup_settings_create || true ;;
			2) backup_settings_export || true ;;
			3) backup_settings_restore || true ;;
			4) return 0 ;;
			*) warn "无效选项，请重新输入" ;;
		esac
	done
}

core_is_installed() { [ -s "$CORE_PATH" ]; }

core_installed_version() {
	civ_version="$("$CORE_PATH" -v 2>/dev/null | head -n 1 || true)"
	[ -n "$civ_version" ] || civ_version="$(state_get CORE_VERSION)"
	[ -n "$civ_version" ] || civ_version="版本未知"
	printf '%s\n' "$civ_version"
}

core_installed_kind() {
	cik_version="$1"
	case "$cik_version" in
		*alpha-smart*) printf '%s\n' smart ;;
		*alpha*) printf '%s\n' alpha ;;
		*Meta*|*mihomo*) printf '%s\n' stable ;;
		*) cik_state="$(state_get CORE_KIND)"; [ -n "$cik_state" ] && printf '%s\n' "$cik_state" || printf '%s\n' unknown ;;
	esac
}

core_kind_label() {
	case "$1" in smart) printf '%s\n' 'Smart' ;; alpha) printf '%s\n' '开发预览版' ;; stable) printf '%s\n' '稳定版' ;; *) printf '%s\n' '未知类型' ;; esac
}

geox_is_installed() {
	for gii_file in GeoSite.dat GeoIP.dat Country.mmdb ASN.mmdb; do
		[ ! -s "$RUN_DIR/$gii_file" ] || return 0
	done
	return 1
}

installed_model_choice() {
	imc_label="$(state_get MODEL)"
	case "$imc_label" in
		*large*|*大型*) printf '%s\n' large; return 0 ;;
		*middle*|*中型*) printf '%s\n' middle; return 0 ;;
		*small*|*轻量*) printf '%s\n' small; return 0 ;;
	esac
	imc_size="$(wc -c < "$MODEL_PATH" 2>/dev/null | tr -d ' ')"
	case "$imc_size" in ""|*[!0-9]*) return 1 ;; esac
	if [ "$imc_size" -ge $((15 * 1024 * 1024)) ]; then printf '%s\n' large
	elif [ "$imc_size" -ge $((9 * 1024 * 1024)) ]; then printf '%s\n' middle
	else printf '%s\n' small; fi
}

set_zashboard_variant() {
	case "$1" in
		dist.zip) ZASH_ASSET=dist.zip; ZASH_VARIANT_LABEL=full ;;
		dist-no-fonts.zip) ZASH_ASSET=dist-no-fonts.zip; ZASH_VARIANT_LABEL=no-fonts ;;
		dist-cdn-fonts.zip) ZASH_ASSET=dist-cdn-fonts.zip; ZASH_VARIANT_LABEL=cdn-fonts ;;
		dist-firasans-only.zip) ZASH_ASSET=dist-firasans-only.zip; ZASH_VARIANT_LABEL=FiraSans ;;
		dist-misans-only.zip) ZASH_ASSET=dist-misans-only.zip; ZASH_VARIANT_LABEL=MiSans ;;
		dist-pingfang-only.zip) ZASH_ASSET=dist-pingfang-only.zip; ZASH_VARIANT_LABEL=PingFang ;;
		dist-sarasa-only.zip) ZASH_ASSET=dist-sarasa-only.zip; ZASH_VARIANT_LABEL=Sarasa ;;
		*) return 1 ;;
	esac
}

installed_zashboard_asset() {
	iza_hint="$(state_get ZASH_VERSION)"
	if command -v uci >/dev/null 2>&1; then iza_hint="$iza_hint $(uci -q get nikki.mixin.ui_url 2>/dev/null || true)"; fi
	iza_hint="$iza_hint $(yaml_external_ui_url "$RUN_DIR/config.yaml" 2>/dev/null || true)"
	case "$iza_hint" in
		*dist-no-fonts.zip*|*\(no-fonts\)*) printf '%s\n' dist-no-fonts.zip ;;
		*dist-cdn-fonts.zip*|*\(cdn-fonts\)*) printf '%s\n' dist-cdn-fonts.zip ;;
		*dist-firasans-only.zip*|*\(FiraSans\)*) printf '%s\n' dist-firasans-only.zip ;;
		*dist-misans-only.zip*|*\(MiSans\)*) printf '%s\n' dist-misans-only.zip ;;
		*dist-pingfang-only.zip*|*\(PingFang\)*) printf '%s\n' dist-pingfang-only.zip ;;
		*dist-sarasa-only.zip*|*\(Sarasa\)*) printf '%s\n' dist-sarasa-only.zip ;;
		*dist.zip*|*\(full\)*) printf '%s\n' dist.zip ;;
		*) return 1 ;;
	esac
}

existing_auto_eligible() {
	eae_installed="$1"
	if [ "$eae_installed" -ne 1 ]; then warn "当前不符合此项选择：Nikki 尚$(paint_missing '未安装')，请选择其他自动维护方案"; return 1; fi
	if ! core_is_installed; then warn "当前不符合此项选择：未检测到已安装内核，请选择其他自动维护方案"; return 1; fi
	eae_version="$(core_installed_version)"
	case "$(core_installed_kind "$eae_version")" in
		smart|alpha|stable) return 0 ;;
		*) warn "当前不符合此项选择：无法识别现有内核类型，请选择其他自动维护方案"; return 1 ;;
	esac
}

configure_existing_auto_plan() {
	AUTO_UPGRADE_ONLY=1; FORCE_MAINTENANCE=0; FORCE_NIKKI_REINSTALL=0
	CORE_SWITCH_ONLY=0; COMPONENT_ONLY=0; COMPONENT_ONLY_KIND=""
	ceap_version="$(core_installed_version)"
	ACTION="$(core_installed_kind "$ceap_version")"
	NIKKI_UPDATE_CHOICE=update; RULESET_CHOICE=update
	WORKFLOW_MODE="自动维护：保持现有组件类型"
	if [ -s "$MODEL_PATH" ]; then
		LGBM_CHOICE="$(installed_model_choice)" || LGBM_CHOICE=small
		MODEL_MAINTAIN=1
		LGBM_SET=1
	else
		LGBM_CHOICE=skip
		MODEL_MAINTAIN=0
	fi
	if geox_is_installed; then GEOX_CHOICE=update; else GEOX_CHOICE=skip; fi
	if zashboard_is_installed; then
		ZASH_CHOICE=update
		ceap_asset="$(installed_zashboard_asset 2>/dev/null || true)"
		if [ -z "$ceap_asset" ]; then
			ceap_asset=dist.zip
			warn "无法识别现有 Zashboard 发行包类型，将按完整版 dist.zip 更新"
		fi
		set_zashboard_variant "$ceap_asset" || return 1
	else
		ZASH_CHOICE=skip
	fi
	info "已识别现有内核：$(core_kind_label "$ACTION")（$ceap_version）"
	[ "$MODEL_MAINTAIN" -eq 0 ] || info "已识别现有 LightGBM：${LGBM_CHOICE}，将保持同规格更新"
	[ "$GEOX_CHOICE" = skip ] || info "检测到现有 GeoX 数据，将更新整套数据库"
	[ "$ZASH_CHOICE" = skip ] || info "已识别现有 Zashboard：${ZASH_ASSET}，将保持同版本类型更新"
	info "rule-set 仅在已有 HTTP provider 配置时更新；未配置会自动跳过"
}

configure_existing_reinstall_plan() {
	configure_existing_auto_plan || return 1
	AUTO_UPGRADE_ONLY=0; FORCE_MAINTENANCE=1; FORCE_NIKKI_REINSTALL=1
	WORKFLOW_MODE="自动维护：强制重装现有组件"
	# 12 是明确的强制重装动作：已有模型按识别出的同规格重装；prepare_model 会先持久备份旧文件。
	return 0
}

configure_full_auto_plan() {
	# 完整维护 2-4 是明确选择的既定方案：与手动维护相同，强制安装/更新全部方案项目。
	AUTO_UPGRADE_ONLY=0; FORCE_MAINTENANCE=1; FORCE_NIKKI_REINSTALL=1
	CORE_SWITCH_ONLY=0; COMPONENT_ONLY=0; COMPONENT_ONLY_KIND=""
	ACTION="$1"
	case "$ACTION" in smart|alpha|stable) ;; *) return 1 ;; esac
	WORKFLOW_MODE="自动维护：强制执行指定完整方案"
	NIKKI_UPDATE_CHOICE=update; GEOX_CHOICE=update; ZASH_CHOICE=update
	RULESET_CHOICE=update
	set_zashboard_variant dist.zip || return 1
	if [ "$ACTION" = smart ]; then
		LGBM_CHOICE=auto; LGBM_SET=1; MODEL_MAINTAIN=1
	else
		LGBM_CHOICE=skip; LGBM_SET=1; MODEL_MAINTAIN=0
	fi
	return 0
}

core_switch_auto_eligible() {
	csae_installed="$1"
	if [ "$csae_installed" -ne 1 ]; then
		warn "当前不符合仅内核切换条件：必须先安装 Nikki，请选择 2-4 的完整安装/更新方案"
		return 1
	fi
	return 0
}

component_only_auto_eligible() {
	coae_installed="$1"; coae_label="$2"
	if [ "$coae_installed" -ne 1 ]; then
		warn "当前无法仅维护 ${coae_label}：必须先安装 Nikki，请先选择 5）仅安装/更新 Nikki"
		return 1
	fi
	return 0
}

configure_core_switch_plan() {
	# 单项内核切换 6-8 是显式强制操作：不比较当前类型和版本。
	AUTO_UPGRADE_ONLY=0; FORCE_MAINTENANCE=1; FORCE_NIKKI_REINSTALL=0
	ACTION="$1"
	case "$ACTION" in smart|alpha|stable) ;; *) return 1 ;; esac
	CORE_SWITCH_ONLY=1; COMPONENT_ONLY=0; COMPONENT_ONLY_KIND=""
	WORKFLOW_MODE="自动维护：仅切换 Mihomo 内核"
	NIKKI_UPDATE_CHOICE=skip; GEOX_CHOICE=skip; ZASH_CHOICE=skip
	RULESET_CHOICE=skip
	LGBM_SET=1
	if [ "$ACTION" = smart ]; then
		LGBM_CHOICE=auto
		MODEL_MAINTAIN=1
	else
		LGBM_CHOICE=skip
		MODEL_MAINTAIN=0
	fi
	return 0
}

configure_component_only_plan() {
	COMPONENT_ONLY_KIND="$1"
	case "$COMPONENT_ONLY_KIND" in nikki|geox|zashboard|ruleset) ;; *) return 1 ;; esac
	# 自动菜单 5、11 是显式强制维护；9、10 才按版本状态自动跳过。
	case "$COMPONENT_ONLY_KIND" in
		nikki|ruleset)
			AUTO_UPGRADE_ONLY=0; FORCE_MAINTENANCE=1
			;;
		geox|zashboard)
			AUTO_UPGRADE_ONLY=1; FORCE_MAINTENANCE=0
			;;
	esac
	if [ "$COMPONENT_ONLY_KIND" = nikki ]; then FORCE_NIKKI_REINSTALL=1
	else FORCE_NIKKI_REINSTALL=0; fi
	CORE_SWITCH_ONLY=0; COMPONENT_ONLY=1; ACTION=skip
	WORKFLOW_MODE="自动维护：仅维护单项组件"
	NIKKI_UPDATE_CHOICE=skip; GEOX_CHOICE=skip; ZASH_CHOICE=skip
	RULESET_CHOICE=skip
	LGBM_CHOICE=skip; LGBM_SET=1; MODEL_MAINTAIN=0
	case "$COMPONENT_ONLY_KIND" in
		nikki) NIKKI_UPDATE_CHOICE=update ;;
		geox) GEOX_CHOICE=update ;;
		zashboard) ZASH_CHOICE=update; set_zashboard_variant dist.zip || return 1 ;;
		ruleset) RULESET_CHOICE=update ;;
	esac
	return 0
}

zashboard_is_installed() { [ -s "$UI_TARGET/index.html" ]; }

zashboard_installed_version() {
	ziv_version="$(state_get ZASH_VERSION)"
	[ -n "$ziv_version" ] || ziv_version="版本未知"
	printf '%s\n' "$ziv_version"
}

manual_record_name() { [ -n "$1" ] && printf '%s\n' "${1##*|}" || printf '%s\n' '查询失败'; }

manual_record_sha() {
	mrs_rest="${1#*|}"
	[ "$mrs_rest" != "$1" ] || return 0
	printf '%s\n' "${mrs_rest%%|*}"
}

manual_record_size() {
	mrz_rest="${1#*|}"; mrz_rest="${mrz_rest#*|}"
	[ "$mrz_rest" != "$1" ] || return 0
	printf '%s\n' "${mrz_rest%%|*}"
}

manual_size_label() {
	msl_size="$(manual_record_size "$1")"
	msl_fallback="$2"
	case "$msl_size" in
		""|*[!0-9]*) printf '%s\n' "$msl_fallback" ;;
		*) awk -v bytes="$msl_size" 'BEGIN{printf "%.2f MiB\n",bytes/1048576}' ;;
	esac
}

manual_mark() {
	if [ "$1" -eq 1 ]; then printf '%b' "${B}${G}[✔]${N}"
	else printf '%b' "${B}${C}[ ]${N}"; fi
}

manual_option() {
	mo_selected="$1"; mo_text="$2"; mo_detail="${3:-}"
	if [ "$mo_selected" -eq 1 ]; then
		say "  $(manual_mark 1) ${B}${G}${mo_text}${N}${mo_detail}"
	else
		say "  $(manual_mark 0) ${B}${C}${mo_text}${N}${mo_detail}"
	fi
}

manual_checksum_matches() {
	mcm_file="$1"; mcm_record="$2"; mcm_sha="$(manual_record_sha "$mcm_record")"
	[ -s "$mcm_file" ] || return 1
	case "$mcm_sha" in ""|*[!0-9A-Fa-f]*) return 1 ;; esac
	[ "${#mcm_sha}" -eq 64 ] || return 1
	command -v sha256sum >/dev/null 2>&1 || return 1
	mcm_actual="$(sha256sum "$mcm_file" 2>/dev/null | awk '{print $1}')"
	[ "$mcm_actual" = "$mcm_sha" ]
}

record_sha_valid() {
	rsv_sha="$(manual_record_sha "$1")"
	case "$rsv_sha" in ""|*[!0-9A-Fa-f]*) return 1 ;; esac
	[ "${#rsv_sha}" -eq 64 ]
}

model_record_for_choice() {
	case "$1" in
		small) printf '%s\n' "${MS_MODEL_SMALL_RECORD:-}" ;;
		middle) printf '%s\n' "${MS_MODEL_MIDDLE_RECORD:-}" ;;
		large) printf '%s\n' "${MS_MODEL_LARGE_RECORD:-}" ;;
		*) return 1 ;;
	esac
}

model_matches_any_current_official() {
	for mmaco_record in "${MS_MODEL_SMALL_RECORD:-}" "${MS_MODEL_MIDDLE_RECORD:-}" "${MS_MODEL_LARGE_RECORD:-}"; do
		[ -n "$mmaco_record" ] || continue
		manual_checksum_matches "$MODEL_PATH" "$mmaco_record" && return 0
	done
	return 1
}

model_is_managed_official() {
	[ -s "$MODEL_PATH" ] || return 1
	mimo_actual="$(sha256sum "$MODEL_PATH" 2>/dev/null | awk '{print $1}')"
	[ -n "$mimo_actual" ] || return 1
	mimo_saved="$(state_get MODEL_SHA256)"
	if [ -n "$mimo_saved" ]; then [ "$mimo_actual" = "$mimo_saved" ]; return $?; fi
	# 旧版状态文件尚未记录 SHA 时，只信任能够匹配当前官方资产的模型。
	model_matches_any_current_official
}

core_record_for_kind() {
	case "$1" in
		smart) printf '%s\n' "${MS_SMART_RECORD:-}" ;;
		alpha) printf '%s\n' "${MS_ALPHA_RECORD:-}" ;;
		stable) printf '%s\n' "${MS_STABLE_RECORD:-}" ;;
		*) return 1 ;;
	esac
}

geox_matches_latest_release() {
	for gml_pair in \
		"GeoSite.dat|${MS_GEOSITE_RECORD:-}" \
		"GeoIP.dat|${MS_GEOIP_RECORD:-}" \
		"Country.mmdb|${MS_MMDB_RECORD:-}" \
		"ASN.mmdb|${MS_ASN_RECORD:-}"; do
		gml_file="${gml_pair%%|*}"; gml_record="${gml_pair#*|}"
		record_sha_valid "$gml_record" || return 2
		manual_checksum_matches "$RUN_DIR/$gml_file" "$gml_record" || return 1
	done
	return 0
}

apply_auto_upgrade_filters() {
	[ "$AUTO_UPGRADE_ONLY" -eq 1 ] || return 0
	AUTO_SKIP_NIKKI=""; AUTO_SKIP_CORE=""; AUTO_SKIP_MODEL=""; AUTO_SKIP_GEOX=""; AUTO_SKIP_ZASH=""

	if [ "$NIKKI_UPDATE_CHOICE" = update ] && pkg_is_installed nikki; then
		case "${NIKKI_UPDATE_STATE:-unknown}" in
			latest) NIKKI_UPDATE_CHOICE=skip; AUTO_SKIP_NIKKI=latest ;;
			unknown) NIKKI_UPDATE_CHOICE=skip; AUTO_SKIP_NIKKI=unknown ;;
		esac
	fi

	case "$ACTION" in smart|alpha|stable)
		if core_is_installed; then
			auf_core_version="$(core_installed_version)"
			auf_core_kind="$(core_installed_kind "$auf_core_version")"
			if [ "$auf_core_kind" = "$ACTION" ]; then
				# Nikki 默认依赖可能把 Smart/Dev 覆盖成稳定版 mihomo-meta；非默认内核
				# 必须保留同类型维护步骤，更新前保全、更新后恢复并更新到最新版。
				if [ "$ACTION" != stable ] && [ "$NIKKI_UPDATE_CHOICE" = update ]; then
					info "Nikki 本轮存在更新：保留 $(core_kind_label "$ACTION") 内核维护步骤，防止默认依赖覆盖"
				else
					auf_core_record="$(core_record_for_kind "$ACTION")"
					auf_core_token="$(main_core_release_token "$auf_core_record" 2>/dev/null || true)"
					if [ -z "$auf_core_token" ]; then ACTION=skip; AUTO_SKIP_CORE=unknown
					else case "$auf_core_version" in *"$auf_core_token"*) ACTION=skip; AUTO_SKIP_CORE=latest ;; esac; fi
				fi
			fi
		fi
		;;
	esac

	if [ "$MODEL_MAINTAIN" -eq 1 ]; then
		auf_model_choice="$LGBM_CHOICE"
		if [ "$auf_model_choice" = auto ]; then
			auf_model_choice="$(auto_model_choice 2>/dev/null || true)"
			[ -z "$auf_model_choice" ] || LGBM_CHOICE="$auf_model_choice"
		fi
		if [ -s "$MODEL_PATH" ]; then
			auf_model_record="$(model_record_for_choice "$auf_model_choice" 2>/dev/null || true)"
			if [ -n "$auf_model_record" ] && manual_checksum_matches "$MODEL_PATH" "$auf_model_record"; then
				MODEL_MAINTAIN=0; AUTO_SKIP_MODEL=latest
			elif ! model_is_managed_official; then
				MODEL_MAINTAIN=0; AUTO_SKIP_MODEL=protected
			elif ! record_sha_valid "$auf_model_record"; then
				MODEL_MAINTAIN=0; AUTO_SKIP_MODEL=unknown
			fi
		fi
	fi

	if [ "$GEOX_CHOICE" = update ] && geox_is_installed; then
		auf_geox_rc=0
		geox_matches_latest_release || auf_geox_rc=$?
		case "$auf_geox_rc" in
			0) GEOX_CHOICE=skip; AUTO_SKIP_GEOX=latest ;;
			2) GEOX_CHOICE=skip; AUTO_SKIP_GEOX=unknown ;;
		esac
	fi

	if [ "$ZASH_CHOICE" = update ] && zashboard_is_installed; then
		if [ "${MS_ZASH_TAG:-查询失败}" = "查询失败" ]; then
			ZASH_CHOICE=skip; AUTO_SKIP_ZASH=unknown
		else
			auf_zash_current="$(state_get ZASH_VERSION)"
			auf_zash_expected="${MS_ZASH_TAG} (${ZASH_VARIANT_LABEL})"
			if [ "$auf_zash_current" = "$auf_zash_expected" ]; then ZASH_CHOICE=skip; AUTO_SKIP_ZASH=latest; fi
		fi
	fi
}

normalize_filtered_auto_plan() {
	if [ "$CORE_SWITCH_ONLY" -eq 1 ] && [ "$ACTION" = skip ]; then CORE_SWITCH_ONLY=0; fi
	# 9/10 即使已最新也保留单项工作流，由单项流程直接报告“已跳过”，
	# 避免无操作计划绕入完整六步维护流程。
}

manual_status_scan() {
	mss_installed="$1"
	MS_MODEL_STATUS=""; MS_GEOSITE_STATUS=""; MS_GEOIP_STATUS=""; MS_MMDB_STATUS=""; MS_ASN_STATUS=""
	[ -n "$DOWNLOADER" ] || select_downloader
	say ""
	menu_line "================ 正在查询组件版本状态 ================"
	if [ "$mss_installed" -eq 1 ]; then
		inspect_nikki_update
	else
		NIKKI_AVAILABLE_VERSION=""
		NIKKI_UPDATE_STATE="missing"
		inspect_nikki_release_fallback >/dev/null 2>&1 || true
		NIKKI_UPDATE_STATE="missing"
	fi

	MS_SMART_JSON="$WORK_DIR/core-smart-release.json"; MS_ALPHA_JSON="$WORK_DIR/core-alpha-release.json"
	MS_STABLE_JSON="$WORK_DIR/core-stable-release.json"; MS_MODEL_JSON="$WORK_DIR/model-release.json"
	MS_GEOX_JSON="$WORK_DIR/geox-release.json"; MS_ZASH_JSON="$WORK_DIR/zashboard-release.json"
	MS_SMART_RECORD=""; MS_ALPHA_RECORD=""; MS_STABLE_RECORD=""
	MS_MODEL_SMALL_RECORD=""; MS_MODEL_MIDDLE_RECORD=""; MS_MODEL_LARGE_RECORD=""
	MS_GEOSITE_RECORD=""; MS_GEOIP_RECORD=""; MS_MMDB_RECORD=""; MS_ASN_RECORD=""
	MS_ZASH_TAG="查询失败"; MS_GEOX_DATE="查询失败"
	MS_ZASH_FULL_RECORD=""; MS_ZASH_NOFONTS_RECORD=""; MS_ZASH_CDN_RECORD=""
	MS_ZASH_FIRA_RECORD=""; MS_ZASH_MI_RECORD=""; MS_ZASH_PING_RECORD=""; MS_ZASH_SARASA_RECORD=""

	if fetch_json_cached 'https://api.github.com/repos/vernesong/mihomo/releases/tags/Prerelease-Alpha' "$MS_SMART_JSON"; then
		MS_SMART_RECORD="$(core_asset_record "$MS_SMART_JSON")"
	fi
	if fetch_json_cached 'https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/Prerelease-Alpha' "$MS_ALPHA_JSON"; then
		MS_ALPHA_RECORD="$(core_asset_record "$MS_ALPHA_JSON")"
	fi
	if fetch_json_cached 'https://api.github.com/repos/MetaCubeX/mihomo/releases/latest' "$MS_STABLE_JSON"; then
		MS_STABLE_RECORD="$(core_asset_record "$MS_STABLE_JSON")"
	fi
	if fetch_json_cached 'https://api.github.com/repos/vernesong/mihomo/releases/tags/LightGBM-Model' "$MS_MODEL_JSON"; then
		MS_MODEL_SMALL_RECORD="$(asset_record_by_name Model.bin "$MS_MODEL_JSON")"
		MS_MODEL_MIDDLE_RECORD="$(asset_record_by_name Model-middle.bin "$MS_MODEL_JSON")"
		MS_MODEL_LARGE_RECORD="$(asset_record_by_name Model-large.bin "$MS_MODEL_JSON")"
	fi
	if fetch_json_cached 'https://api.github.com/repos/MetaCubeX/meta-rules-dat/releases/latest' "$MS_GEOX_JSON"; then
		MS_GEOX_DATE="$(json_field published_at "$MS_GEOX_JSON" | cut -c1-10 | tr '-' '/')"
		[ -n "$MS_GEOX_DATE" ] || MS_GEOX_DATE="查询失败"
		MS_GEOSITE_RECORD="$(asset_record_by_name geosite.dat "$MS_GEOX_JSON")"
		MS_GEOIP_RECORD="$(asset_record_by_name geoip.dat "$MS_GEOX_JSON")"
		MS_MMDB_RECORD="$(asset_record_by_name country.mmdb "$MS_GEOX_JSON")"
		MS_ASN_RECORD="$(asset_record_by_name GeoLite2-ASN.mmdb "$MS_GEOX_JSON")"
	fi
	if fetch_json_cached 'https://api.github.com/repos/Zephyruso/zashboard/releases/latest' "$MS_ZASH_JSON"; then
		MS_ZASH_TAG="$(json_field tag_name "$MS_ZASH_JSON")"
		[ -n "$MS_ZASH_TAG" ] || MS_ZASH_TAG="查询失败"
		MS_ZASH_FULL_RECORD="$(asset_record_by_name dist.zip "$MS_ZASH_JSON")"
		MS_ZASH_NOFONTS_RECORD="$(asset_record_by_name dist-no-fonts.zip "$MS_ZASH_JSON")"
		MS_ZASH_CDN_RECORD="$(asset_record_by_name dist-cdn-fonts.zip "$MS_ZASH_JSON")"
		MS_ZASH_FIRA_RECORD="$(asset_record_by_name dist-firasans-only.zip "$MS_ZASH_JSON")"
		MS_ZASH_MI_RECORD="$(asset_record_by_name dist-misans-only.zip "$MS_ZASH_JSON")"
		MS_ZASH_PING_RECORD="$(asset_record_by_name dist-pingfang-only.zip "$MS_ZASH_JSON")"
		MS_ZASH_SARASA_RECORD="$(asset_record_by_name dist-sarasa-only.zip "$MS_ZASH_JSON")"
	fi
	MS_RULESET_COUNT="$(ruleset_provider_count)"
	STATUS_SCAN_READY=1
	ok "组件版本状态查询完成；查询失败的项目在执行时仍会重新尝试"
}

main_core_release_token() {
	mcrt_name="$(manual_record_name "$1")"
	case "$mcrt_name" in 查询失败|"") return 1 ;; esac
	mcrt_name="${mcrt_name%.gz}"
	mcrt_prefix="mihomo-linux-${ASSET_ARCH}-"
	case "$mcrt_name" in "$mcrt_prefix"*) printf '%s\n' "${mcrt_name#"$mcrt_prefix"}" ;; *) printf '%s\n' "$mcrt_name" ;; esac
}

print_main_status_overview() {
	pmso_installed="$1"
	flow_title "当前组件状态"
	if [ "$pmso_installed" -eq 1 ]; then
		pmso_nikki="$(nikki_version 2>/dev/null || true)"; [ -n "$pmso_nikki" ] || pmso_nikki="版本未知"
		case "${NIKKI_UPDATE_STATE:-unknown}" in
			latest) pmso_nikki_state="${B}${G}已最新${N}" ;;
			update) pmso_nikki_state="可更新至 $(paint_latest "${NIKKI_AVAILABLE_VERSION:-查询失败}")" ;;
			*) pmso_nikki_state="${B}${Y}最新版本查询失败${N}" ;;
		esac
		say "${B}${Y}Nikki：${N}已安装，当前版本 $(paint_current "$pmso_nikki")，${pmso_nikki_state}"
	else
		say "${B}${Y}Nikki：${N}$(paint_missing '未安装')；最新版本 $(paint_latest "${NIKKI_AVAILABLE_VERSION:-查询失败}")"
	fi

	if core_is_installed; then
		pmso_core="$(core_installed_version)"; pmso_kind="$(core_installed_kind "$pmso_core")"
		case "$pmso_kind" in smart) pmso_record="${MS_SMART_RECORD:-}" ;; alpha) pmso_record="${MS_ALPHA_RECORD:-}" ;; stable) pmso_record="${MS_STABLE_RECORD:-}" ;; *) pmso_record="" ;; esac
		pmso_latest="$(main_core_release_token "$pmso_record" 2>/dev/null || true)"
		if [ -z "$pmso_latest" ]; then pmso_core_state="${B}${Y}最新版本查询失败${N}"
		else case "$pmso_core" in *"$pmso_latest"*) pmso_core_state="${B}${G}已最新${N}" ;; *) pmso_core_state="可更新至 $(paint_latest "$pmso_latest")" ;; esac; fi
		say "${B}${Y}内核：${N}已安装 $(core_kind_label "$pmso_kind")，当前版本 $(paint_current "$pmso_core")，${pmso_core_state}"
	else
		say "${B}${Y}内核：${N}$(paint_missing '未安装')"
	fi

	pmso_geox_count=0
	for pmso_file in GeoSite.dat GeoIP.dat Country.mmdb ASN.mmdb; do [ ! -s "$RUN_DIR/$pmso_file" ] || pmso_geox_count=$((pmso_geox_count + 1)); done
	if [ "$pmso_geox_count" -eq 0 ]; then
		say "${B}${Y}GeoX 数据：${N}$(paint_missing '未安装')；最新版本 $(paint_latest "${MS_GEOX_DATE:-查询失败}")"
	else
		pmso_geox="$(state_get GEOX_DATE)"; [ -n "$pmso_geox" ] || pmso_geox="$(file_date "$RUN_DIR/GeoSite.dat")"
		pmso_geox_latest=0
		if [ "$pmso_geox_count" -eq 4 ]; then
			[ "$pmso_geox" != "${MS_GEOX_DATE:-查询失败}" ] || pmso_geox_latest=1
			if manual_checksum_matches "$RUN_DIR/GeoSite.dat" "${MS_GEOSITE_RECORD:-}" && manual_checksum_matches "$RUN_DIR/GeoIP.dat" "${MS_GEOIP_RECORD:-}" && manual_checksum_matches "$RUN_DIR/Country.mmdb" "${MS_MMDB_RECORD:-}" && manual_checksum_matches "$RUN_DIR/ASN.mmdb" "${MS_ASN_RECORD:-}"; then pmso_geox_latest=1; fi
		fi
		if [ "$pmso_geox_count" -lt 4 ]; then pmso_geox_state="${B}${R}安装不完整（${pmso_geox_count}/4）${N}，可更新至 $(paint_latest "${MS_GEOX_DATE:-查询失败}")"
		elif [ "$pmso_geox_latest" -eq 1 ]; then pmso_geox_state="${B}${G}已最新${N}"
		else pmso_geox_state="可更新至 $(paint_latest "${MS_GEOX_DATE:-查询失败}")"; fi
		say "${B}${Y}GeoX 数据：${N}已安装，当前版本 $(paint_current "$pmso_geox")，${pmso_geox_state}"
	fi

	if zashboard_is_installed; then
		pmso_zash="$(zashboard_installed_version)"
		case "$pmso_zash" in "${MS_ZASH_TAG:-查询失败}"*) pmso_zash_state="${B}${G}已最新${N}" ;; *) pmso_zash_state="可更新至 $(paint_latest "${MS_ZASH_TAG:-查询失败}")" ;; esac
		say "${B}${Y}Zashboard：${N}已安装，当前版本 $(paint_current "$pmso_zash")，${pmso_zash_state}"
	else
		say "${B}${Y}Zashboard：${N}$(paint_missing '未安装')；最新版本 $(paint_latest "${MS_ZASH_TAG:-查询失败}")"
	fi
	menu_line "================================================"
}

manual_geox_line() {
	mgl_label="$1"; mgl_local="$2"; mgl_record="$3"
	if [ ! -s "$RUN_DIR/$mgl_local" ]; then
		printf '%b\n' "${mgl_label}：${B}${R}未安装${N}；最新 ${M}${MS_GEOX_DATE}${N}"
	elif manual_checksum_matches "$RUN_DIR/$mgl_local" "$mgl_record"; then
		printf '%b\n' "${mgl_label}：已安装，当前 ${C}$(file_date "$RUN_DIR/$mgl_local")${N}，${G}已最新${N}"
	else
		printf '%b\n' "${mgl_label}：已安装，当前 ${C}$(file_date "$RUN_DIR/$mgl_local")${N}，可更新至 ${M}${MS_GEOX_DATE}${N}"
	fi
}

manual_model_status() {
	if [ ! -s "$MODEL_PATH" ]; then printf '%b\n' "LightGBM ${B}${R}未安装${N}"; return 0; fi
	mms_label="$(state_get MODEL)"; mms_record=""
	case "$mms_label" in *large*) mms_record="$MS_MODEL_LARGE_RECORD" ;; *middle*) mms_record="$MS_MODEL_MIDDLE_RECORD" ;; *small*|*轻量*) mms_record="$MS_MODEL_SMALL_RECORD" ;; esac
	if [ -z "$mms_label" ]; then
		if manual_checksum_matches "$MODEL_PATH" "$MS_MODEL_LARGE_RECORD"; then mms_label='Model-large（大型版）'; mms_record="$MS_MODEL_LARGE_RECORD"
		elif manual_checksum_matches "$MODEL_PATH" "$MS_MODEL_MIDDLE_RECORD"; then mms_label='Model-middle（中型版）'; mms_record="$MS_MODEL_MIDDLE_RECORD"
		elif manual_checksum_matches "$MODEL_PATH" "$MS_MODEL_SMALL_RECORD"; then mms_label='Model-small（轻量版）'; mms_record="$MS_MODEL_SMALL_RECORD"
		else mms_label='型号未知'; fi
	fi
	if [ -n "$mms_record" ] && manual_checksum_matches "$MODEL_PATH" "$mms_record"; then
		printf '%b\n' "LightGBM 已安装，当前 ${C}${mms_label}${N}，${G}已最新${N}"
	else
		printf '%b\n' "LightGBM 已安装，当前 ${C}${mms_label}${N}，${M}可更新或重新校验${N}"
	fi
}

manual_batch_render() {
	say ""
	menu_line "================ 手动维护｜一次选完，统一执行 ================"
	if [ "$MB_INSTALLED" -eq 1 ]; then
		mbr_nv="$(nikki_version 2>/dev/null || true)"; [ -n "$mbr_nv" ] || mbr_nv="版本未知"
		case "${NIKKI_UPDATE_STATE:-unknown}" in
			latest) mbr_ns="${B}${G}已最新${N}" ;;
			update) mbr_ns="可更新至 $(paint_latest "${NIKKI_AVAILABLE_VERSION}")" ;;
			*) mbr_ns="${B}${Y}最新状态查询失败${N}" ;;
		esac
		say "${B}${Y}Nikki 插件主体：${N}已安装，当前 $(paint_current "$mbr_nv")，${mbr_ns}"
	else
		mbr_missing_latest="${NIKKI_AVAILABLE_VERSION:-查询失败}"
		say "${B}${R}Nikki：未安装（本次必须选择 1）${N}；最新 $(paint_latest "$mbr_missing_latest")"
	fi
	manual_option "$MB_NIKKI" "1）维护 Nikki 主体与必需依赖"
	say ""
	if core_is_installed; then
		mbr_cv="$(core_installed_version)"; mbr_ck="$(core_kind_label "$(core_installed_kind "$mbr_cv")")"
		say "${B}${Y}内核：${N}已安装 ${mbr_ck}内核，当前版本 $(paint_current "$mbr_cv")"
	else
		say "${B}${Y}内核：${N}$(paint_missing '未安装')"
	fi
	manual_option "$MB_CORE_SMART" "2）Smart 内核" "；最新 $(paint_latest "$(manual_record_name "$MS_SMART_RECORD")")"
	manual_option "$MB_CORE_ALPHA" "3）Dev 开发预览版内核" "；最新 $(paint_latest "$(manual_record_name "$MS_ALPHA_RECORD")")"
	manual_option "$MB_CORE_STABLE" "4）稳定版内核" "；最新 $(paint_latest "$(manual_record_name "$MS_STABLE_RECORD")")"
	say "${B}${Y}     可不选内核：跳过 Nikki 时保留当前内核；维护 Nikki 时由其依赖提供默认 mihomo-meta。${N}"
	say ""
	[ -n "${MS_MODEL_STATUS:-}" ] || MS_MODEL_STATUS="$(manual_model_status)"
	say "${B}${Y}${MS_MODEL_STATUS}；当前内核为 Smart 或选择 2）Smart 内核时可选${N}"
	manual_option "$MB_MODEL_AUTO" "5）自动选择 LightGBM 模型" "${B}${Y}（按性能与可用空间匹配）${N}"
	manual_option "$MB_MODEL_LARGE" "6）大型模型（Model-large.bin）" "，约 $(paint_size "$(manual_size_label "$MS_MODEL_LARGE_RECORD" '20.4 MiB')")"
	manual_option "$MB_MODEL_MIDDLE" "7）中型模型（Model-middle.bin）" "，约 $(paint_size "$(manual_size_label "$MS_MODEL_MIDDLE_RECORD" '10.6 MiB')")"
	manual_option "$MB_MODEL_SMALL" "8）轻量模型（Model.bin）" "，约 $(paint_size "$(manual_size_label "$MS_MODEL_SMALL_RECORD" '7.47 MiB')")"
	say ""
	say "${B}${Y}GeoX 数据库状态：${N}"
	[ -n "${MS_GEOSITE_STATUS:-}" ] || MS_GEOSITE_STATUS="$(manual_geox_line geosite GeoSite.dat "$MS_GEOSITE_RECORD")"
	[ -n "${MS_GEOIP_STATUS:-}" ] || MS_GEOIP_STATUS="$(manual_geox_line geoip GeoIP.dat "$MS_GEOIP_RECORD")"
	[ -n "${MS_MMDB_STATUS:-}" ] || MS_MMDB_STATUS="$(manual_geox_line mmdb Country.mmdb "$MS_MMDB_RECORD")"
	[ -n "${MS_ASN_STATUS:-}" ] || MS_ASN_STATUS="$(manual_geox_line asn ASN.mmdb "$MS_ASN_RECORD")"
	say "  $MS_GEOSITE_STATUS"
	say "  $MS_GEOIP_STATUS"
	say "  $MS_MMDB_STATUS"
	say "  $MS_ASN_STATUS"
	manual_option "$MB_GEOX" "9）更新 GeoX 全套数据库"
	say ""
	if zashboard_is_installed; then
		mbr_zv="$(zashboard_installed_version)"
		case "$mbr_zv" in "$MS_ZASH_TAG"*) mbr_zs="${B}${G}已最新${N}" ;; *) mbr_zs="可更新至 $(paint_latest "$MS_ZASH_TAG")" ;; esac
		say "${B}${Y}Zashboard：${N}已安装，当前 $(paint_current "$mbr_zv")，${mbr_zs}"
	else
		say "${B}${Y}Zashboard：${N}$(paint_missing '未安装')；最新 $(paint_latest "$MS_ZASH_TAG")"
	fi
	manual_option "$MB_ZASH_FULL" "10）完整版（dist.zip，全部内置字体）" "，约 $(paint_size "$(manual_size_label "$MS_ZASH_FULL_RECORD" '未知')")"
	manual_option "$MB_ZASH_NOFONTS" "11）无字体版（dist-no-fonts.zip）" "，约 $(paint_size "$(manual_size_label "$MS_ZASH_NOFONTS_RECORD" '未知')")"
	manual_option "$MB_ZASH_CDN" "12）CDN 字体版（dist-cdn-fonts.zip）" "，约 $(paint_size "$(manual_size_label "$MS_ZASH_CDN_RECORD" '未知')")"
	manual_option "$MB_ZASH_FIRA" "13）FiraSans 字体版（dist-firasans-only.zip）" "，约 $(paint_size "$(manual_size_label "$MS_ZASH_FIRA_RECORD" '未知')")"
	manual_option "$MB_ZASH_MI" "14）MiSans 字体版（dist-misans-only.zip）" "，约 $(paint_size "$(manual_size_label "$MS_ZASH_MI_RECORD" '未知')")"
	manual_option "$MB_ZASH_PING" "15）PingFang 字体版（dist-pingfang-only.zip）" "，约 $(paint_size "$(manual_size_label "$MS_ZASH_PING_RECORD" '未知')")"
	manual_option "$MB_ZASH_SARASA" "16）Sarasa 字体版（dist-sarasa-only.zip）" "，约 $(paint_size "$(manual_size_label "$MS_ZASH_SARASA_RECORD" '未知')")"
	say ""
	say "${B}${Y}YAML rule-set：只更新已配置项目${N}"
	if [ "${MS_RULESET_COUNT:-0}" -gt 0 ]; then
		say "  rule-set：当前 YAML 已配置 $(paint_current "$MS_RULESET_COUNT") 项 HTTP provider"
	else
		say "  rule-set：$(paint_missing '未配置') HTTP provider；选择后也不会创建新规则集"
	fi
	manual_option "$MB_RULESET" "17）更新 rule-set 规则集（如有）"
	say "${B}${Y}     未配置的 rule-provider 不会创建，直接跳过。${N}"
	say ""
	say "${B}${Y}返回${N}"
	manual_option "$MB_RETURN" "0）返回主菜单（必须单独选择）"
	menu_line "======================================================"
	say "${B}${Y}输入多个编号时用空格或英文逗号分隔，例如：1 2 5 9 10 17${N}"
	say "${B}${G}支持的终端会在输入过程中即时变色并显示 [✔]；按回车后统一校验。${N}"
}

manual_batch_reset() {
	MB_NIKKI=0; MB_CORE_SMART=0; MB_CORE_ALPHA=0; MB_CORE_STABLE=0
	MB_MODEL_AUTO=0; MB_MODEL_LARGE=0; MB_MODEL_MIDDLE=0; MB_MODEL_SMALL=0
	MB_GEOX=0; MB_ZASH_FULL=0; MB_ZASH_NOFONTS=0; MB_ZASH_CDN=0
	MB_ZASH_FIRA=0; MB_ZASH_MI=0; MB_ZASH_PING=0; MB_ZASH_SARASA=0
	MB_RULESET=0; MB_RETURN=0
}

manual_batch_parse() {
	manual_batch_reset
	mbp_input="$(printf '%s' "$1" | tr ',' ' ')"
	[ -n "$mbp_input" ] || { warn "未选择任何项目"; return 1; }
	for mbp_code in $mbp_input; do
		case "$mbp_code" in
			0) MB_RETURN=1 ;; 1) MB_NIKKI=1 ;; 2) MB_CORE_SMART=1 ;; 3) MB_CORE_ALPHA=1 ;; 4) MB_CORE_STABLE=1 ;;
			5) MB_MODEL_AUTO=1 ;; 6) MB_MODEL_LARGE=1 ;; 7) MB_MODEL_MIDDLE=1 ;; 8) MB_MODEL_SMALL=1 ;; 9) MB_GEOX=1 ;;
			10) MB_ZASH_FULL=1 ;; 11) MB_ZASH_NOFONTS=1 ;; 12) MB_ZASH_CDN=1 ;; 13) MB_ZASH_FIRA=1 ;;
			14) MB_ZASH_MI=1 ;; 15) MB_ZASH_PING=1 ;; 16) MB_ZASH_SARASA=1 ;;
			17) MB_RULESET=1 ;;
			*) warn "无效编号：$mbp_code"; return 1 ;;
		esac
	done
	mbp_core_count=$((MB_CORE_SMART + MB_CORE_ALPHA + MB_CORE_STABLE))
	mbp_model_count=$((MB_MODEL_AUTO + MB_MODEL_LARGE + MB_MODEL_MIDDLE + MB_MODEL_SMALL))
	mbp_zash_count=$((MB_ZASH_FULL + MB_ZASH_NOFONTS + MB_ZASH_CDN + MB_ZASH_FIRA + MB_ZASH_MI + MB_ZASH_PING + MB_ZASH_SARASA))
	mbp_action_count=$((MB_NIKKI + mbp_core_count + mbp_model_count + MB_GEOX + mbp_zash_count + MB_RULESET))
	if [ "$MB_RETURN" -eq 1 ]; then
		[ "$mbp_action_count" -eq 0 ] || { warn "0）返回主菜单不能与其他项目同时选择"; return 1; }
		return 0
	fi
	[ "$mbp_action_count" -gt 0 ] || { warn "请至少选择一个维护项目，或单独输入 0 返回主菜单"; return 1; }
	[ "$mbp_core_count" -le 1 ] || { warn "Smart、Dev、稳定版内核只能三选一"; return 1; }
	[ "$mbp_model_count" -le 1 ] || { warn "LightGBM 模型只能选择一种"; return 1; }
	[ "$mbp_zash_count" -le 1 ] || { warn "Zashboard 发行版本只能选择一种"; return 1; }
	if [ "$MB_INSTALLED" -ne 1 ] && [ "$MB_NIKKI" -ne 1 ]; then warn "Nikki $(paint_missing '未安装')，本次必须选择 1）Nikki 插件主体"; return 1; fi
	if ! core_is_installed && [ "$mbp_core_count" -eq 0 ] && [ "$MB_NIKKI" -ne 1 ]; then
		warn "内核$(paint_missing '未安装')：请选择 2-4 中的一种内核，或同时选择 1）Nikki 由其依赖安装默认 mihomo-meta"
		return 1
	fi
	if [ "$mbp_model_count" -gt 0 ] && [ "$MB_CORE_SMART" -ne 1 ]; then
		mbp_current_smart=0
		if [ "$mbp_core_count" -eq 0 ] && core_is_installed; then
			mbp_current_version="$(core_installed_version)"
			[ "$(core_installed_kind "$mbp_current_version")" != smart ] || mbp_current_smart=1
		fi
		[ "$mbp_current_smart" -eq 1 ] || { warn "LightGBM 仅能在保留当前 Smart 内核或选择 2）Smart 内核时维护"; return 1; }
	fi
	if [ "$MB_CORE_SMART" -eq 1 ] && [ ! -s "$MODEL_PATH" ] && [ "$mbp_model_count" -eq 0 ]; then warn "首次选择 Smart 内核且当前无模型，必须在 5-8 中选择一种 LightGBM 模型"; return 1; fi
	return 0
}

manual_batch_print_selection() {
	say ""
	menu_line "================ 已选择的维护计划 ================"
	if [ "$MB_NIKKI" -eq 1 ]; then menu_line "  [已选] Nikki：安装、更新或修复"; else say "  - Nikki：跳过，保留当前版本"; fi
	if [ "$MB_CORE_SMART" -eq 1 ]; then menu_line "  [已选] 内核：Smart"
	elif [ "$MB_CORE_ALPHA" -eq 1 ]; then menu_line "  [已选] 内核：Dev 开发预览版"
	elif [ "$MB_CORE_STABLE" -eq 1 ]; then menu_line "  [已选] 内核：稳定版"
	elif [ "$MB_NIKKI" -eq 1 ]; then say "  - 内核：未指定，随 Nikki 依赖安装/更新默认稳定版 mihomo-meta"
	else say "  - 内核：跳过，保留当前版本"; fi
	if [ "$MB_MODEL_AUTO" -eq 1 ]; then menu_line "  [已选] LightGBM：自动选择"
	elif [ "$MB_MODEL_LARGE" -eq 1 ]; then menu_line "  [已选] LightGBM：大型模型"
	elif [ "$MB_MODEL_MIDDLE" -eq 1 ]; then menu_line "  [已选] LightGBM：中型模型"
	elif [ "$MB_MODEL_SMALL" -eq 1 ]; then menu_line "  [已选] LightGBM：轻量模型"
	elif [ "$MB_CORE_SMART" -eq 1 ]; then say "  - LightGBM：跳过，保留当前模型"; fi
	if [ "$MB_GEOX" -eq 1 ]; then menu_line "  [已选] GeoX：更新整套数据库"; else say "  - GeoX：跳过，保留当前数据库"; fi
	if [ "$MB_ZASH_FULL" -eq 1 ]; then menu_line "  [已选] Zashboard：完整版"
	elif [ "$MB_ZASH_NOFONTS" -eq 1 ]; then menu_line "  [已选] Zashboard：无字体版"
	elif [ "$MB_ZASH_CDN" -eq 1 ]; then menu_line "  [已选] Zashboard：CDN 字体版"
	elif [ "$MB_ZASH_FIRA" -eq 1 ]; then menu_line "  [已选] Zashboard：FiraSans"
	elif [ "$MB_ZASH_MI" -eq 1 ]; then menu_line "  [已选] Zashboard：MiSans"
	elif [ "$MB_ZASH_PING" -eq 1 ]; then menu_line "  [已选] Zashboard：PingFang"
	elif [ "$MB_ZASH_SARASA" -eq 1 ]; then menu_line "  [已选] Zashboard：Sarasa"
	else say "  - Zashboard：跳过，保留当前面板"; fi
	if [ "$MB_RULESET" -eq 1 ]; then menu_line "  [已选] YAML：刷新现有 rule-set"; else say "  - YAML/rule-set：跳过"; fi
	menu_line "=================================================="
}

manual_batch_apply() {
	CORE_SWITCH_ONLY=0
	COMPONENT_ONLY=0
	COMPONENT_ONLY_KIND=""
	WORKFLOW_MODE="手动维护：按已确认选择强制执行"
	AUTO_UPGRADE_ONLY=0; FORCE_MAINTENANCE=1; FORCE_NIKKI_REINSTALL="$MB_NIKKI"
	if [ "$MB_NIKKI" -eq 1 ]; then NIKKI_UPDATE_CHOICE=update; else NIKKI_UPDATE_CHOICE=skip; fi
	if [ "$MB_CORE_SMART" -eq 1 ]; then ACTION=smart
	elif [ "$MB_CORE_ALPHA" -eq 1 ]; then ACTION=alpha
	elif [ "$MB_CORE_STABLE" -eq 1 ]; then ACTION=stable
	else ACTION=skip; fi
	LGBM_SET=1
	if [ "$MB_MODEL_AUTO" -eq 1 ]; then LGBM_CHOICE=auto
	elif [ "$MB_MODEL_LARGE" -eq 1 ]; then LGBM_CHOICE=large
	elif [ "$MB_MODEL_MIDDLE" -eq 1 ]; then LGBM_CHOICE=middle
	elif [ "$MB_MODEL_SMALL" -eq 1 ]; then LGBM_CHOICE=small
	else LGBM_CHOICE=skip; fi
	if [ "$LGBM_CHOICE" = skip ]; then MODEL_MAINTAIN=0; else MODEL_MAINTAIN=1; fi
	if [ "$MB_GEOX" -eq 1 ]; then GEOX_CHOICE=update; else GEOX_CHOICE=skip; fi
	ZASH_CHOICE=update
	if [ "$MB_ZASH_FULL" -eq 1 ]; then set_zashboard_variant dist.zip
	elif [ "$MB_ZASH_NOFONTS" -eq 1 ]; then set_zashboard_variant dist-no-fonts.zip
	elif [ "$MB_ZASH_CDN" -eq 1 ]; then set_zashboard_variant dist-cdn-fonts.zip
	elif [ "$MB_ZASH_FIRA" -eq 1 ]; then set_zashboard_variant dist-firasans-only.zip
	elif [ "$MB_ZASH_MI" -eq 1 ]; then set_zashboard_variant dist-misans-only.zip
	elif [ "$MB_ZASH_PING" -eq 1 ]; then set_zashboard_variant dist-pingfang-only.zip
	elif [ "$MB_ZASH_SARASA" -eq 1 ]; then set_zashboard_variant dist-sarasa-only.zip
	else ZASH_CHOICE=skip; fi
	if [ "$MB_RULESET" -eq 1 ]; then RULESET_CHOICE=update; else RULESET_CHOICE=skip; fi
}

manual_batch_preview() {
	manual_batch_reset
	mbv_input="$(printf '%s' "$1" | tr ',' ' ')"
	for mbv_code in $mbv_input; do
		case "$mbv_code" in
			0) MB_RETURN=1 ;; 1) MB_NIKKI=1 ;; 2) MB_CORE_SMART=1 ;; 3) MB_CORE_ALPHA=1 ;; 4) MB_CORE_STABLE=1 ;;
			5) MB_MODEL_AUTO=1 ;; 6) MB_MODEL_LARGE=1 ;; 7) MB_MODEL_MIDDLE=1 ;; 8) MB_MODEL_SMALL=1 ;; 9) MB_GEOX=1 ;;
			10) MB_ZASH_FULL=1 ;; 11) MB_ZASH_NOFONTS=1 ;; 12) MB_ZASH_CDN=1 ;; 13) MB_ZASH_FIRA=1 ;;
			14) MB_ZASH_MI=1 ;; 15) MB_ZASH_PING=1 ;; 16) MB_ZASH_SARASA=1 ;;
			17) MB_RULESET=1 ;;
		esac
	done
}

manual_live_input_supported() {
	[ "${NIKKI_DISABLE_LIVE_INPUT:-0}" != 1 ] || return 1
	[ -c /dev/tty ] && ( : </dev/tty ) 2>/dev/null || return 1
	command -v stty >/dev/null 2>&1 || return 1
	# dash 等 read 不支持 -n；在短管道的子 shell 中探测，绝不占用用户输入。
	# shellcheck disable=SC3045,SC2034
	printf x | ( IFS= read -r -n 1 mlis_char ) >/dev/null 2>&1
}

manual_batch_read_selection() {
	USER_INPUT=""
	if ! manual_live_input_supported; then
		manual_batch_render
		prompt '>>> 请一次性输入全部编号并按回车：'
		read_user_input
		return $?
	fi
	TTY_STTY_STATE="$(stty -g </dev/tty 2>/dev/null || true)"
	[ -n "$TTY_STTY_STATE" ] || {
		manual_batch_render
		prompt '>>> 请一次性输入全部编号并按回车：'
		read_user_input
		return $?
	}
	stty -echo -icanon min 1 time 0 </dev/tty || { TTY_STTY_STATE=""; return 1; }
	TTY_RAW_ACTIVE=1
	mbr_buffer=""; mbr_bs="$(printf '\010')"; mbr_del="$(printf '\177')"; mbr_ctrl_u="$(printf '\025')"
	while :; do
		manual_batch_preview "$mbr_buffer"
		printf '\033[2J\033[H'
		manual_batch_render
		prompt ">>> 当前输入：${mbr_buffer}"
		mbr_char=""
		# shellcheck disable=SC3045
		IFS= read -r -n 1 mbr_char </dev/tty || true
		case "$mbr_char" in
			"") break ;;
			"$mbr_bs"|"$mbr_del") [ -z "$mbr_buffer" ] || mbr_buffer="${mbr_buffer%?}" ;;
			"$mbr_ctrl_u") mbr_buffer="" ;;
			[0-9]|','|' ') mbr_buffer="${mbr_buffer}${mbr_char}" ;;
			*) printf '\a' ;;
		esac
	done
	restore_tty
	printf '\n'
	USER_INPUT="$mbr_buffer"
	return 0
}

manual_batch_menu() {
	MB_INSTALLED="$1"
	# 每次从主菜单进入都清空上轮勾选，避免确认过的计划被再次执行。
	manual_batch_reset
	[ "$STATUS_SCAN_READY" -eq 1 ] || manual_status_scan "$MB_INSTALLED"
	while :; do
		manual_batch_read_selection || fatal "无法读取手动维护选择"
		manual_batch_parse "$USER_INPUT" || continue
		if [ "$MB_RETURN" -eq 1 ]; then MANUAL_BATCH_CHOICE=main; return 0; fi
		# 输入完成后重绘一次，所选项目会显示绿色 [✔]，再统一确认。
		manual_batch_render
		manual_batch_print_selection
		menu_line "  1）是，确认以上选择并一键执行"
		menu_line "  2）否，返回选择界面重新调整"
		menu_line "  0）取消并直接返回主菜单"
		prompt '>>> 请确认 [1-2/0]：'
		read_user_input || fatal "无法读取维护计划确认"
		case "$USER_INPUT" in
			1) manual_batch_apply; MANUAL_BATCH_CHOICE=execute; return 0 ;;
			2) continue ;;
			0) MANUAL_BATCH_CHOICE=main; return 0 ;;
			*) warn "无效确认选项，将返回选择界面" ;;
		esac
	done
}

main_menu() {
	mm_installed="$1"
	print_main_status_overview "$mm_installed"
	while :; do
		say ""
		menu_line "================ Nikki 全方位维护 ================"
		menu_line "  1）自动维护｜选择预设方案，一键执行"
		menu_line "  2）手动维护｜自由多选组件与版本，统一执行"
		menu_line "  3）备份与恢复｜仅处理 Nikki 插件设置"
		menu_line "  4）卸载重置｜删除 Nikki 与运行数据，可选是否删除官方源"
		menu_line "  5）退出脚本"
		if [ "$DETAIL_OUTPUT" = 1 ]; then say "${B}${Y}日志模式：详细流程（可重新执行脚本时去掉 --verbose 恢复简洁输出）${N}"; else say "${B}${Y}日志模式：关键步骤（需要完整过程时使用 --verbose）${N}"; fi
		menu_line "================================================"
		prompt '>>> 请手动选择 [1-5]：'
		read_user_input || fatal "无法读取主菜单选项"
		case "$USER_INPUT" in
			1) MAIN_CHOICE="auto"; return 0 ;;
			2) MAIN_CHOICE="manual"; return 0 ;;
			3) MAIN_CHOICE="backup"; return 0 ;;
			4) MAIN_CHOICE="uninstall"; return 0 ;;
			5) MAIN_CHOICE="exit"; return 0 ;;
			*) warn "无效选项，请重新输入" ;;
		esac
	done
}

automatic_maintenance_menu() {
	amm_installed="${1:-0}"
	while :; do
		say ""
		menu_line "================ 自动维护｜预设方案 ================"
		menu_line "  1）日常更新｜仅升级已有组件，已最新自动跳过（需已安装 Nikki 和内核）"
		say "${B}${Y}     更新 Nikki、当前类型内核及已安装的模型、GeoX、面板和 rule-set；缺少的可选组件不新装。${N}"
		say "${B}${Y}     现有 Smart/Dev 等非默认内核会在 Nikki 更新前保全，更新后恢复并更新同类型最新版。${N}"
		menu_line "  2）完整维护｜Nikki + Smart 内核 + 自动 LGBM + GeoX + Zashboard 完整版"
		menu_line "  3）完整维护｜Nikki + Dev 内核 + GeoX + Zashboard 完整版"
		menu_line "  4）完整维护｜Nikki + 稳定版内核 + GeoX + Zashboard 完整版"
		say "${B}${Y}     2-4 按既定完整方案强制安装/更新；已有 rule-set 同步刷新，未配置则跳过。${N}"
		say ""
		say "${B}${M}---------------- 单项维护 ----------------${N}"
		menu_line "  5）Nikki 主体｜强制安装、更新或修复主体与依赖"
		say "${B}${Y}     保留官方软件源；Nikki 依赖可能安装默认稳定版 mihomo-meta。${N}"
		menu_line "  6）Smart 内核｜无条件强制安装/更新 Smart 并维护 LightGBM"
		menu_line "  7）Dev 内核｜无条件强制安装/更新开发预览版并清除 LightGBM"
		menu_line "  8）稳定内核｜无条件强制安装/更新 mihomo-meta 并清除 LightGBM"
		menu_line "  9）GeoX 数据｜安装或更新四项数据库，已最新自动跳过"
		menu_line " 10）Zashboard｜安装或更新完整版 dist.zip，已最新自动跳过"
		menu_line " 11）规则集｜强制刷新 YAML rule-set provider（如有）"
		say ""
		menu_line " 12）一键重装现有组件｜强制重装已有项目，缺少的不新增"
		say "${B}${Y}     保持当前内核、模型和面板类型；已有 LightGBM 替换前会持久备份。${N}"
		menu_line " 13）返回主菜单"
		menu_line "=================================================="
		prompt '>>> 请手动选择 [1-13]：'
		read_user_input || fatal "无法读取自动维护菜单选项"
		case "$USER_INPUT" in
			1) existing_auto_eligible "$amm_installed" || continue; AUTO_CHOICE="existing"; return 0 ;;
			2) AUTO_CHOICE="smart"; return 0 ;;
			3) AUTO_CHOICE="alpha"; return 0 ;;
			4) AUTO_CHOICE="stable"; return 0 ;;
			5) AUTO_CHOICE="only-nikki"; return 0 ;;
			6) core_switch_auto_eligible "$amm_installed" || continue; AUTO_CHOICE="core-smart"; return 0 ;;
			7) core_switch_auto_eligible "$amm_installed" || continue; AUTO_CHOICE="core-alpha"; return 0 ;;
			8) core_switch_auto_eligible "$amm_installed" || continue; AUTO_CHOICE="core-stable"; return 0 ;;
			9) component_only_auto_eligible "$amm_installed" "GeoX" || continue; AUTO_CHOICE="only-geox"; return 0 ;;
			10) component_only_auto_eligible "$amm_installed" "Zashboard" || continue; AUTO_CHOICE="only-zashboard"; return 0 ;;
			11) component_only_auto_eligible "$amm_installed" "rule-set" || continue; AUTO_CHOICE="only-ruleset"; return 0 ;;
			12) existing_auto_eligible "$amm_installed" || continue; AUTO_CHOICE="reinstall-existing"; return 0 ;;
			13) AUTO_CHOICE="return"; return 0 ;;
			*) warn "无效选项，请重新输入" ;;
		esac
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
		menu_line "  1）返回主菜单"
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

normalize_menu_answer() {
	printf '%s' "$1" | tr -d '\015\012' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

confirm_uninstall() {
	[ "$ASSUME_YES" -eq 1 ] && return 0
	while :; do
		say "${B}${R}【高风险操作】将卸载 Nikki 并删除配置、订阅、运行数据和内核。${N}"
		say "${B}${Y}确认卸载后，可选择保留或同时删除 Nikki 软件源与签名密钥。${N}"
		menu_line "  YES / yes / Y / y / 是）确认卸载"
		menu_line "  0）直接返回主菜单"
		danger_prompt '>>> 请输入 YES、yes、Y、y 或汉字 是 确认；输入 0 返回主菜单：'
		read_user_input || fatal "无法读取卸载确认选项"
		cu_answer="$(normalize_menu_answer "$USER_INPUT")"
		case "$cu_answer" in
			YES|yes|Yes|Y|y|是) return 0 ;;
			0) return 1 ;;
			*) warn "请输入 YES、yes、Y、y 或汉字 是 确认卸载；输入 0 直接返回主菜单" ;;
		esac
	done
}

choose_uninstall_feed_policy() {
	# 非交互 --yes 模式默认保留软件源，避免扩大自动化卸载范围。
	if [ "$ASSUME_YES" -eq 1 ]; then
		UNINSTALL_REMOVE_FEED=0
		info "非交互卸载默认保留 Nikki 官方软件源和签名密钥"
		return 0
	fi
	while :; do
		say ""
		say "${B}${Y}是否同时删除 Nikki 官方软件源及签名密钥？${N}"
		menu_line "  YES / yes / Y / y / 是）删除软件源和签名密钥"
		menu_line "  NO  / no  / N / n / 否）保留，方便以后直接重装"
		menu_line "  0）取消卸载并返回主菜单"
		prompt '>>> 请选择 [YES/NO/0]：'
		read_user_input || fatal "无法读取软件源处理选项"
		cufp_answer="$(normalize_menu_answer "$USER_INPUT")"
		case "$cufp_answer" in
			YES|yes|Yes|Y|y|是) UNINSTALL_REMOVE_FEED=1; return 0 ;;
			NO|no|No|N|n|否) UNINSTALL_REMOVE_FEED=0; return 0 ;;
			0) return 1 ;;
			*) warn "请输入 YES 删除、NO 保留，或输入 0 取消卸载" ;;
		esac
	done
}

remove_nikki_feed_and_key() {
	rnfk_backup="$1"
	case "$PKG_MANAGER" in
		opkg)
			command -v opkg-key >/dev/null 2>&1 || { warn "系统缺少 opkg-key，无法安全删除 Nikki 签名密钥"; return 1; }
			if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
				warn "系统缺少 curl/wget，无法取得 Nikki 公钥以从 OPKG 信任库移除"
				return 1
			fi
			[ -n "$DOWNLOADER" ] || select_downloader
			rnfk_key="$rnfk_backup/nikki.pub"
			rnfk_round=1
			while [ "$rnfk_round" -le "$DOWNLOAD_ROUNDS" ]; do
				info "下载 Nikki OPKG 公钥用于删除签名：${rnfk_round}/${DOWNLOAD_ROUNDS}"
				if fetch_once 'https://nikkinikki.pages.dev/key-build.pub' "$rnfk_key" && [ -s "$rnfk_key" ]; then break; fi
				rnfk_round=$((rnfk_round + 1))
			done
			[ -s "$rnfk_key" ] || { warn "Nikki OPKG 公钥下载失败，未删除软件源"; return 1; }
			opkg-key remove "$rnfk_key" >/dev/null 2>&1 || { warn "Nikki OPKG 签名密钥删除失败，未删除软件源"; return 1; }
			if grep -q nikki /etc/opkg/customfeeds.conf 2>/dev/null; then
				sed -i '/nikki/d' /etc/opkg/customfeeds.conf || return 1
			fi
			;;
		apk)
			if grep -q nikki /etc/apk/repositories.d/customfeeds.list 2>/dev/null; then
				sed -i '/nikki/d' /etc/apk/repositories.d/customfeeds.list || return 1
			fi
			rm -f "$NIKKI_APK_KEY" || return 1
			;;
		*) return 1 ;;
	esac
	if feed_present; then warn "Nikki 软件源条目删除后仍存在"; return 1; fi
	if [ "$PKG_MANAGER" = apk ] && [ -e "$NIKKI_APK_KEY" ]; then warn "Nikki APK 签名密钥删除后仍存在"; return 1; fi
	return 0
}

restore_feed_after_failed_removal() {
	rfafr_backup="$1"
	case "$PKG_MANAGER" in
		opkg)
			[ ! -f "$rfafr_backup/customfeeds.conf" ] || cp -p "$rfafr_backup/customfeeds.conf" /etc/opkg/customfeeds.conf 2>/dev/null || true
			[ ! -s "$rfafr_backup/nikki.pub" ] || opkg-key add "$rfafr_backup/nikki.pub" >/dev/null 2>&1 || true
			;;
		apk)
			[ ! -f "$rfafr_backup/customfeeds.list" ] || cp -p "$rfafr_backup/customfeeds.list" /etc/apk/repositories.d/customfeeds.list 2>/dev/null || true
			[ ! -f "$rfafr_backup/nikki.pem" ] || cp -p "$rfafr_backup/nikki.pem" "$NIKKI_APK_KEY" 2>/dev/null || true
			;;
	esac
}

uninstall_nikki() {
	# 卸载语言包、LuCI、Nikki、官方内核、配置、数据和运行残留；软件源与签名密钥
	# 由用户在确认卸载后单独选择保留或删除。
	confirm_uninstall || { warn "已取消卸载"; return 2; }
	choose_uninstall_feed_policy || { warn "已取消卸载"; return 2; }
	un_backup="/tmp/nikki-uninstall-backup.${PID}"
	mkdir "$un_backup" || fatal "无法创建卸载临时备份"
	: > "$un_backup/packages.before" || fatal "无法创建卸载包清单"
	[ ! -f /etc/config/nikki ] || cp -p /etc/config/nikki "$un_backup/config.nikki" || fatal "配置备份失败"
	[ ! -d "$NIKKI_DIR" ] || cp -a "$NIKKI_DIR" "$un_backup/nikki-dir" || fatal "数据备份失败"
	[ ! -f "$CORE_PATH" ] || cp -p "$CORE_PATH" "$un_backup/mihomo" || fatal "内核备份失败"
	[ ! -f /etc/opkg/customfeeds.conf ] || cp -p /etc/opkg/customfeeds.conf "$un_backup/customfeeds.conf" || true
	[ ! -f /etc/apk/repositories.d/customfeeds.list ] || cp -p /etc/apk/repositories.d/customfeeds.list "$un_backup/customfeeds.list" || true
	[ ! -f "$NIKKI_APK_KEY" ] || cp -p "$NIKKI_APK_KEY" "$un_backup/nikki.pem" || true
	"$NIKKI_INIT" stop >/dev/null 2>&1 || true
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
	rm -f "$CORE_PATH" 2>/dev/null || true
	for un_stale in /usr/bin/mihomo.rollback.* /usr/bin/mihomo.new.* /etc/config/nikki.rollback.*; do
		case "$un_stale" in /usr/bin/mihomo.rollback.*|/usr/bin/mihomo.new.*|/etc/config/nikki.rollback.*) [ ! -e "$un_stale" ] || rm -f -- "$un_stale" ;; esac
	done
	un_feed_cleanup_failed=0
	if [ "$UNINSTALL_REMOVE_FEED" -eq 1 ]; then
		progress_line "软件源" "删除 Nikki 软件源与签名密钥"
		if ! remove_nikki_feed_and_key "$un_backup"; then
			restore_feed_after_failed_removal "$un_backup"
			un_feed_cleanup_failed=1
			warn "软件源清理失败，已尽可能恢复卸载前的软件源与签名密钥"
		fi
	else
		progress_skip "已按选择保留 Nikki 软件源与签名密钥"
	fi
	# 不以命令退出码代替结果：逐项确认软件包与数据目录确实已经移除。
	un_residual="$un_feed_cleanup_failed"
	for un_pkg in $un_langs luci-app-nikki nikki mihomo-meta mihomo-alpha; do
		if pkg_is_installed "$un_pkg"; then warn "卸载后仍检测到软件包：$un_pkg"; un_residual=1; fi
	done
	case "$PKG_MANAGER" in
		opkg) un_langs_after="$(opkg list-installed 'luci-i18n-nikki-*' 2>/dev/null | awk '{print $1}')" ;;
		apk) un_langs_after="$(apk list --installed --manifest 'luci-i18n-nikki-*' 2>/dev/null | awk '{print $1}')" ;;
		*) un_langs_after="" ;;
	esac
	if [ -n "$un_langs_after" ]; then warn "卸载后仍检测到 Nikki 语言包：$un_langs_after"; un_residual=1; fi
	for un_path in /etc/config/nikki /etc/nikki /var/log/nikki /var/run/nikki "$CORE_PATH"; do
		if [ -e "$un_path" ]; then warn "卸载后仍检测到残留路径：$un_path"; un_residual=1; fi
	done
	if [ "$un_residual" -ne 0 ]; then
		fatal "卸载后完整性检查未通过；未输出成功状态，操作前备份保留在 $un_backup"
	fi
	if [ "$UNINSTALL_REMOVE_FEED" -eq 1 ]; then
		# 用户主动删除后允许本进程返回主菜单重新添加；这是唯一重置“一次/会话”标记的场景。
		reset_nikki_feed_session
		ok "Nikki 官方软件源和签名密钥已删除"
		say "Nikki 已卸载，相关数据、软件源及签名密钥已清理！"
	else
		ok "已按选择保留 Nikki 软件源与签名密钥；卸载流程未检查或改写现有源"
		say "Nikki 已卸载，相关数据残留已清理，软件源及签名密钥保持不变！"
	fi
	[ ! -d "$SETTINGS_BACKUP_DIR" ] || say "已保留插件设置备份目录：$SETTINGS_BACKUP_DIR"
	safe_rm_tree "$un_backup" >/dev/null 2>&1 || true
	return 0
}

set_all_update_statuses() {
	saus_value="$1"
	NIKKI_UPDATE_STATUS="$saus_value"; CORE_UPDATE_STATUS="$saus_value"; MODEL_UPDATE_STATUS="$saus_value"
	GEOX_UPDATE_STATUS="$saus_value"; ZASH_UPDATE_STATUS="$saus_value"
	RULESET_UPDATE_STATUS="$saus_value"
}

status_from_auto_skip() {
	case "$1" in latest|unknown|protected) printf '%s\n' "$1" ;; *) printf '%s\n' user_skipped ;; esac
}

progress_auto_skip() {
	pas_component="$1"; pas_reason="$2"; pas_default="$3"
	case "$pas_reason" in
		latest) progress_skip "$pas_component 已是最新版本，自动跳过" ;;
		unknown) progress_skip "$pas_component 远程版本查询失败，自动维护安全跳过" ;;
		protected) progress_skip "$pas_component 疑似自定义文件，已保护并跳过" ;;
		*) progress_skip "$pas_default" ;;
	esac
}

reset_workflow_state() {
	TRANSACTION_ACTIVE=0; WAS_RUNNING=0; MAINT_SUCCESS=0
	CORE_EXISTED=0; MODEL_EXISTED=0; UI_EXISTED=0; CONFIG_EXISTED=0; SUBSCRIPTIONS_EXISTED=0
	RULESET_UPDATED_COUNT=0; RULESET_TOTAL_COUNT=0
	NONDEFAULT_CORE_PRESERVED=0; PRESERVED_CORE_KIND=""; SERVICE_RESTART_VERIFIED=0
	set_all_update_statuses not_selected
}

print_execution_plan() {
	case "$ACTION" in smart) pep_core="Smart" ;; alpha) pep_core="Dev 开发预览版" ;; stable) pep_core="稳定版" ;; skip) pep_core="跳过" ;; *) pep_core="未知" ;; esac
	flow_title "本轮维护执行计划"
	say "${B}${Y}执行模式：${N}$(paint_current "$WORKFLOW_MODE")"
	if [ "$NIKKI_UPDATE_CHOICE" = update ]; then say "  ${G}✔${N} Nikki：安装、更新或修复"; else say "  ${Y}－${N} Nikki：跳过"; fi
	if [ "$ACTION" = skip ]; then
		if [ "$NIKKI_UPDATE_CHOICE" = update ] && core_is_installed && [ "$(core_installed_kind "$(core_installed_version)")" != stable ]; then
			pep_existing_kind="$(core_installed_kind "$(core_installed_version)")"
			say "  ${G}✔${N} 内核：保留现有 $(core_kind_label "$pep_existing_kind")；若被 Nikki 默认依赖覆盖则自动恢复"
		elif [ "$NIKKI_UPDATE_CHOICE" = update ]; then say "  ${Y}－${N} 内核：未指定，使用 Nikki 默认依赖 $(paint_latest 'mihomo-meta')"
		else say "  ${Y}－${N} 内核：跳过并保留原有版本"; fi
	else say "  ${G}✔${N} 内核：$(paint_latest "$pep_core")"; fi
	if [ "$MODEL_MAINTAIN" -eq 1 ]; then say "  ${G}✔${N} LightGBM：$(paint_latest "$LGBM_CHOICE")"; else say "  ${Y}－${N} LightGBM：跳过"; fi
	if [ "$GEOX_CHOICE" = update ]; then say "  ${G}✔${N} GeoX：更新整套数据库"; else say "  ${Y}－${N} GeoX：跳过"; fi
	if [ "$ZASH_CHOICE" = update ]; then say "  ${G}✔${N} Zashboard：$(paint_latest "$ZASH_ASSET")"; else say "  ${Y}－${N} Zashboard：跳过"; fi
	if [ "$RULESET_CHOICE" = update ]; then say "  ${G}✔${N} YAML/rule-set：刷新已配置 HTTP provider（不存在则跳过）"; else say "  ${Y}－${N} YAML/rule-set：跳过"; fi
}

print_core_switch_plan() {
	case "$ACTION" in smart) pcsp_core="Smart" ;; alpha) pcsp_core="Dev 开发预览版" ;; stable) pcsp_core="稳定版" ;; *) pcsp_core="未知" ;; esac
	flow_title "仅内核切换执行计划"
	say "${B}${Y}执行模式：${N}$(paint_current "$WORKFLOW_MODE")"
	say "  ${G}✔${N} Mihomo 内核：安装或切换为 $(paint_latest "$pcsp_core")"
	if [ "$ACTION" = smart ]; then
		say "  ${G}✔${N} LightGBM：根据性能和存储空间自动选择模型"
	else
		say "  ${G}✔${N} LightGBM：清除现有模型（如有）"
	fi
	say "  ${Y}－${N} Nikki、GeoX、Zashboard 和 rule-set：保持不变"
}

run_core_switch_workflow() {
	DOWNLOAD_FAILURES=0
	reset_workflow_state
	set_all_update_statuses user_skipped
	CORE_UPDATE_STATUS="not_selected"; MODEL_UPDATE_STATUS="not_selected"
	print_core_switch_plan
	flow_title "仅内核切换事务"
	progress_line "1/3" "检查并补齐内核下载、解压和校验工具"
	if ! ensure_update_tools; then
		CORE_UPDATE_STATUS="skipped"; MODEL_UPDATE_STATUS="skipped"
		err "维护工具安装失败，未改动当前内核"
		print_summary
		return 0
	fi
	select_downloader
	progress_line "2/3" "备份当前内核、LightGBM 模型和 Nikki 运行状态"
	if ! begin_transaction; then
		cleanup_transaction_backups
		CORE_UPDATE_STATUS="skipped"; MODEL_UPDATE_STATUS="skipped"
		err "无法建立切换事务备份，未改动当前内核"
		print_summary
		return 0
	fi
	initialize_maintenance_state
	progress_line "3/3" "安装目标内核并处理对应 LightGBM 模型"
	if ! prepare_core "$ACTION"; then
		CORE_UPDATE_STATUS="skipped"; MODEL_UPDATE_STATUS="user_skipped"
		rollback_transaction
		warn "目标内核未通过下载、架构或当前 YAML 兼容性检查，已保留原内核"
		print_summary
		return 0
	fi
	CORE_UPDATE_STATUS="updated"
	if [ "$ACTION" = smart ]; then
		if ! prepare_model; then
			CORE_UPDATE_STATUS="skipped"; MODEL_UPDATE_STATUS="skipped"
			rollback_transaction
			warn "自动 LightGBM 模型安装失败，Smart 内核切换已整体回滚"
			print_summary
			return 0
		fi
		MODEL_UPDATE_STATUS="updated"
		MAINT_SUCCESS=2
	else
		if [ -f "$MODEL_PATH" ]; then
			if ! cp -p "$MODEL_PATH" "$MODEL_BACKUP" || ! rm -f -- "$MODEL_PATH" || [ -e "$MODEL_PATH" ]; then
				CORE_UPDATE_STATUS="skipped"; MODEL_UPDATE_STATUS="skipped"
				rollback_transaction
				warn "LightGBM 模型清理失败，内核切换已整体回滚"
				print_summary
				return 0
			fi
			MODEL_UPDATE_STATUS="removed"
			progress_done "已清除 LightGBM 模型；Dev/稳定版内核不使用该模型"
		else
			MODEL_UPDATE_STATUS="not_present"
			progress_skip "未检测到 LightGBM 模型，无需清理"
		fi
		MODEL_LABEL_NEW="none"
		MAINT_SUCCESS=1
	fi
	if ! commit_transaction; then
		CORE_UPDATE_STATUS="skipped"; MODEL_UPDATE_STATUS="skipped"
		rollback_transaction
		warn "新内核未能通过 Nikki 服务验证，已恢复切换前的内核和模型"
		print_summary
		return 0
	fi
	ensure_nikki_restarted_after_binary_update || { print_summary; return 2; }
	progress_done "仅内核切换事务完成，正在直接进入当前维护结果"
	print_summary
	return 0
}

print_component_only_plan() {
	case "$COMPONENT_ONLY_KIND" in
		nikki) pcop_label="Nikki 主体及必需依赖" ;;
		geox) pcop_label="GeoX 数据库" ;;
		zashboard) pcop_label="Zashboard 完整版（dist.zip / full）" ;;
		ruleset) pcop_label="YAML rule-set 自定义规则集" ;;
		*) pcop_label="未知组件" ;;
	esac
	flow_title "仅单项维护执行计划"
	say "${B}${Y}执行模式：${N}$(paint_current "$WORKFLOW_MODE")"
	say "  ${G}✔${N} 本轮仅维护：$(paint_latest "$pcop_label")"
	say "  ${Y}－${N} 其他组件保持不变；完成后直接显示当前维护结果"
}

set_component_only_default_statuses() {
	set_all_update_statuses user_skipped
}

run_component_only_workflow() {
	DOWNLOAD_FAILURES=0
	reset_workflow_state
	set_component_only_default_statuses
	print_component_only_plan
	case "$COMPONENT_ONLY_KIND" in
			nikki)
			NIKKI_UPDATE_STATUS="not_selected"
			flow_title "仅安装、更新或修复 Nikki"
			select_downloader
			if ! preserve_nondefault_core_before_nikki; then
				NIKKI_UPDATE_STATUS="skipped"
				err "无法保全当前非默认内核，已取消 Nikki 单项维护"
				print_summary
				return 0
			fi
			if install_or_update_nikki; then
				NIKKI_UPDATE_STATUS="updated"
			else
				NIKKI_UPDATE_STATUS="skipped"
				warn "Nikki 单项维护失败，已执行安装阶段回滚并保留原状态"
				print_summary
				return 0
			fi
			if ! restore_nondefault_core_after_nikki; then
				err "Nikki 更新后无法恢复保全的非默认内核；保全副本仍位于 $NONDEFAULT_CORE_BEFORE_NIKKI"
				print_summary
				return 2
			fi
			ensure_nikki_restarted_after_binary_update || { print_summary; return 2; }
			progress_done "Nikki 单项维护完成，正在直接进入当前维护结果"
			;;
		geox|zashboard)
			[ "$COMPONENT_ONLY_KIND" != geox ] || GEOX_UPDATE_STATUS="not_selected"
			[ "$COMPONENT_ONLY_KIND" != zashboard ] || ZASH_UPDATE_STATUS="not_selected"
			if [ "$COMPONENT_ONLY_KIND" = geox ] && [ "$GEOX_CHOICE" != update ]; then
				GEOX_UPDATE_STATUS="$(status_from_auto_skip "$AUTO_SKIP_GEOX")"
				progress_auto_skip "GeoX" "$AUTO_SKIP_GEOX" "已按计划跳过 GeoX，保留当前数据库"
				print_summary
				return 0
			fi
			if [ "$COMPONENT_ONLY_KIND" = zashboard ] && [ "$ZASH_CHOICE" != update ]; then
				ZASH_UPDATE_STATUS="$(status_from_auto_skip "$AUTO_SKIP_ZASH")"
				progress_auto_skip "Zashboard" "$AUTO_SKIP_ZASH" "已按计划跳过 Zashboard，保留当前面板"
				print_summary
				return 0
			fi
			flow_title "仅组件维护事务"
			progress_line "1/3" "检查并补齐下载、解压和校验工具"
			if ! ensure_update_tools; then
				[ "$COMPONENT_ONLY_KIND" != geox ] || GEOX_UPDATE_STATUS="skipped"
				[ "$COMPONENT_ONLY_KIND" != zashboard ] || ZASH_UPDATE_STATUS="skipped"
				err "维护工具安装失败，未改动目标组件"
				print_summary
				return 0
			fi
			progress_line "2/3" "建立目标组件和 Nikki 运行状态备份"
			if ! begin_transaction; then
				cleanup_transaction_backups
				[ "$COMPONENT_ONLY_KIND" != geox ] || GEOX_UPDATE_STATUS="skipped"
				[ "$COMPONENT_ONLY_KIND" != zashboard ] || ZASH_UPDATE_STATUS="skipped"
				err "无法建立事务备份，未改动目标组件"
				print_summary
				return 0
			fi
			initialize_maintenance_state
			progress_line "3/3" "下载、校验并原子替换目标组件"
			if [ "$COMPONENT_ONLY_KIND" = geox ]; then
				if prepare_geox; then GEOX_UPDATE_STATUS="updated"; MAINT_SUCCESS=1
				else GEOX_UPDATE_STATUS="skipped"; rollback_transaction; warn "GeoX 单项维护失败，已恢复原数据库"; print_summary; return 0; fi
			else
				if prepare_zashboard; then ZASH_UPDATE_STATUS="updated"; MAINT_SUCCESS=1
				else ZASH_UPDATE_STATUS="skipped"; rollback_transaction; warn "Zashboard 单项维护失败，已恢复原面板"; print_summary; return 0; fi
			fi
			if ! commit_transaction; then
				[ "$COMPONENT_ONLY_KIND" != geox ] || GEOX_UPDATE_STATUS="skipped"
				[ "$COMPONENT_ONLY_KIND" != zashboard ] || ZASH_UPDATE_STATUS="skipped"
				rollback_transaction
				warn "目标组件未通过服务验证，已恢复维护前状态"
				print_summary
				return 0
			fi
			progress_done "单项组件维护完成，正在直接进入当前维护结果"
			;;
		ruleset)
			RULESET_UPDATE_STATUS="not_selected"
			flow_title "仅 rule-set 自定义规则集维护"
			if ensure_update_tools && update_existing_rulesets; then
				progress_done "rule-set 单项维护完成，正在直接进入当前维护结果"
			else
				[ "$RULESET_UPDATE_STATUS" != not_selected ] || RULESET_UPDATE_STATUS="skipped"
				warn "rule-set 更新失败、未配置或无法连接；现有缓存保持不变"
			fi
			;;
		*) err "未知单项维护计划：$COMPONENT_ONLY_KIND"; return 1 ;;
	esac
	print_summary
	return 0
}

run_update_workflow() {
	reset_workflow_state
	DOWNLOAD_FAILURES=0
	if [ "$ENVIRONMENT_READY" -ne 1 ]; then
		run_environment_preflight || return 2
	fi
	if [ -n "$CLI_ACTION" ]; then
		GEOX_CHOICE=update
		ZASH_CHOICE=update
		RULESET_CHOICE=update
		if [ "$ACTION" = smart ]; then
			if [ "$LGBM_SET" -eq 0 ]; then LGBM_CHOICE=auto; LGBM_SET=1; fi
			MODEL_MAINTAIN=1
		else
			MODEL_MAINTAIN=0
		fi
	fi
	print_execution_plan
	flow_title "步骤 1/6：Nikki 插件主体及依赖"
	if [ "$NIKKI_UPDATE_CHOICE" = update ]; then
		select_downloader
		if ! preserve_nondefault_core_before_nikki; then
			NIKKI_UPDATE_STATUS="skipped"
			err "无法保全当前非默认内核，为避免 Nikki 更新后无法恢复，已取消本轮主体更新"
			print_summary
			return 2
		fi
		if ! install_or_update_nikki; then
			NIKKI_UPDATE_STATUS="skipped"
			warn "Nikki 安装/更新失败，已执行回滚；请检查网络后从主菜单重试"
			print_summary
			return 2
		fi
		NIKKI_UPDATE_STATUS="updated"
		if ! restore_nondefault_core_after_nikki; then
			err "Nikki 更新后无法恢复保全的非默认内核；保全副本仍位于 $NONDEFAULT_CORE_BEFORE_NIKKI"
			print_summary
			return 2
		fi
	else
		NIKKI_UPDATE_STATUS="$(status_from_auto_skip "$AUTO_SKIP_NIKKI")"
		progress_auto_skip "Nikki" "$AUTO_SKIP_NIKKI" "已按选择跳过 Nikki 及其依赖更新，当前安装保持不变"
	fi
	case "$ACTION" in smart|alpha|stable|skip) ;; *) fatal "维护计划缺少有效内核动作" ;; esac
	run_maintenance "$ACTION"
	ensure_nikki_restarted_after_binary_update || { print_summary; return 2; }
	print_summary
	return 0
}

reset_menu_plan() {
	ACTION=""; MAIN_CHOICE=""; AUTO_CHOICE=""; MANUAL_BATCH_CHOICE=""
	NIKKI_UPDATE_CHOICE=update; LGBM_CHOICE=auto; LGBM_SET=0; MODEL_MAINTAIN=0
	GEOX_CHOICE=update; ZASH_CHOICE=update; ZASH_ASSET=dist.zip; ZASH_VARIANT_LABEL=full
	RULESET_CHOICE=skip
	CORE_SWITCH_ONLY=0; COMPONENT_ONLY=0; COMPONENT_ONLY_KIND=""; WORKFLOW_MODE="交互维护"
	AUTO_UPGRADE_ONLY=0; FORCE_MAINTENANCE=0; FORCE_NIKKI_REINSTALL=0
	AUTO_SKIP_NIKKI=""; AUTO_SKIP_CORE=""; AUTO_SKIP_MODEL=""; AUTO_SKIP_GEOX=""; AUTO_SKIP_ZASH=""
}

main() {
	parse_args "$@"
	CLI_ACTION="$ACTION"
	[ "$(id -u)" -eq 0 ] || fatal "请使用 root 用户运行"
	acquire_lock
	mkdir -p "$WORK_DIR" || fatal "无法创建临时目录：$WORK_DIR"
	# 官方要求、系统环境和兼容性只在脚本开头检查一次；返回主菜单时不重复输出。
	run_environment_preflight || exit 1
	key_info "Nikki 软件源仅在执行 Nikki 主体安装/更新时处理；组件状态扫描不会添加或改写软件源"

	# 命令行模式保持适合自动化的单次执行语义。
	if [ -n "$CLI_ACTION" ]; then
		FORCE_MAINTENANCE=1
		if [ "$CLI_ACTION" = "uninstall" ]; then
			uninstall_nikki || exit 1
		else
			run_update_workflow || exit 1
		fi
		exit 0
	fi

	# 交互模式始终返回这里重新检测 Nikki 状态，不递归启动脚本。
	while :; do
		reset_menu_plan
		if pkg_is_installed nikki; then mm_installed=1; else mm_installed=0; fi
		manual_status_scan "$mm_installed"
		main_menu "$mm_installed"
		[ "$MAIN_CHOICE" != exit ] || exit 0
		if [ "$MAIN_CHOICE" = backup ]; then
			backup_menu
			continue
		fi
		if [ "$MAIN_CHOICE" = uninstall ]; then
			if ! uninstall_nikki; then warn "卸载未执行，返回主菜单"; continue; fi
			if post_action_menu uninstall; then continue; else exit 0; fi
		fi

		if [ "$MAIN_CHOICE" = auto ]; then
			automatic_maintenance_menu "$mm_installed"
			[ "$AUTO_CHOICE" != return ] || continue
			case "$AUTO_CHOICE" in
				existing) configure_existing_auto_plan || { warn "无法建立现有组件更新计划，返回自动维护菜单"; continue; } ;;
				reinstall-existing) configure_existing_reinstall_plan || { warn "无法建立现有组件重装计划，返回自动维护菜单"; continue; } ;;
				only-nikki) configure_component_only_plan nikki || { warn "无法建立 Nikki 单项维护计划"; continue; } ;;
				core-smart) configure_core_switch_plan smart || { warn "无法建立 Smart 内核切换计划"; continue; } ;;
				core-alpha) configure_core_switch_plan alpha || { warn "无法建立 Dev 内核切换计划"; continue; } ;;
				core-stable) configure_core_switch_plan stable || { warn "无法建立稳定版内核切换计划"; continue; } ;;
				only-geox) configure_component_only_plan geox || { warn "无法建立 GeoX 单项维护计划"; continue; } ;;
				only-zashboard) configure_component_only_plan zashboard || { warn "无法建立 Zashboard 单项维护计划"; continue; } ;;
				only-ruleset) configure_component_only_plan ruleset || { warn "无法建立 rule-set 单项维护计划"; continue; } ;;
				*) configure_full_auto_plan "$AUTO_CHOICE" || { warn "无法建立完整自动维护计划，返回自动维护菜单"; continue; } ;;
			esac
			apply_auto_upgrade_filters
			normalize_filtered_auto_plan
			if [ "$CORE_SWITCH_ONLY" -eq 1 ]; then info "前置环境检查已通过；将仅切换内核并处理 LightGBM，随后直接显示当前维护结果"
			elif [ "$COMPONENT_ONLY" -eq 1 ]; then info "前置环境检查已通过；将仅维护已选择的单项组件，随后直接显示当前维护结果"
			else info "前置环境检查已通过；将自动执行 Nikki、组件及已有 YAML 关联资源维护，无需再次人工选择"; fi
		else
			manual_batch_menu "$mm_installed"
			[ "$MANUAL_BATCH_CHOICE" != main ] || continue
		fi

		if [ "$CORE_SWITCH_ONLY" -eq 1 ]; then ruw_command=run_core_switch_workflow
		elif [ "$COMPONENT_ONLY" -eq 1 ]; then ruw_command=run_component_only_workflow
		else ruw_command=run_update_workflow; fi
		if "$ruw_command"; then
			if [ "$DOWNLOAD_FAILURES" -gt 0 ]; then
				warn "至少有一个远程下载项目在直连和全部反代重试三轮后仍失败，请检查网络并从主菜单重试"
				continue
			fi
			if post_action_menu maintenance; then continue; else exit 0; fi
		else
			ruw_rc=$?
			case "$ruw_rc" in 2|3) continue ;; *) exit "$ruw_rc" ;; esac
		fi
	done
}

if [ "${NIKKI_LIB_ONLY:-0}" != "1" ]; then
	main "$@"
fi
