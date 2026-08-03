#!/bin/sh
#
# Nikki Smart 内核一键更新脚本
# 数据源：vernesong/mihomo 的 Prerelease-Alpha（Smart Group）发行版
# 兼容：OpenWrt BusyBox ash，OpenWrt 24.10/opkg、25.12/apk 及 SNAPSHOT
#
# 可选环境变量：
#   RESTART_NIKKI=0        更新后不重启 Nikki
#   TEST_CONFIG=0          跳过使用新内核测试当前配置
#   FORCE_UPDATE=1         即使新旧二进制完全相同也重新安装
#   LGBM_MODEL=auto        auto、small、middle、large 或 skip
#   MODEL_PATH=/etc/nikki/run/Model.bin
#   AMD64_LEVEL=auto       auto、v1、v2、v3；默认自动检测
#   MIPS_FLOAT=softfloat   softfloat 或 hardfloat
#   CORE_PATH=/usr/bin/mihomo
#   RELEASE_TAG=Prerelease-Alpha
#   GITHUB_PROXIES="https://github.dpik.top/ https://ghproxy.net/ https://gh.jasonzeng.dev/ https://github-proxy.memory-echoes.cn/ https://gh.dpik.top/ https://gh.b52m.cn/ https://gh.felicity.ac.cn/ https://gh-proxy.com/"
#   GITHUB_PROXY=...       兼容旧用法；设置后覆盖 GITHUB_PROXIES
#   DIRECT_FIRST=1         1=直连优先，失败或持续低速后切换反代
#   DIRECT_MIN_KBPS=64     直连持续低于此速度时视为过慢
#   DIRECT_SLOW_TIME=20    低速持续多少秒后中止直连
#   DIRECT_MAX_TIME=600    单次直连下载最长时间（秒）
#   GITHUB_TOKEN=          可选，避免 GitHub API 匿名限流
#
# 管道运行时也可传参：
#   wget -qO- URL | sh -s -- --lgbm middle --no-restart
#

set -eu

REPO="${REPO:-vernesong/mihomo}"
RELEASE_TAG="${RELEASE_TAG:-Prerelease-Alpha}"
CORE_PATH="${CORE_PATH:-/usr/bin/mihomo}"
RESTART_NIKKI="${RESTART_NIKKI:-1}"
TEST_CONFIG="${TEST_CONFIG:-1}"
FORCE_UPDATE="${FORCE_UPDATE:-0}"
LGBM_MODEL="${LGBM_MODEL:-auto}"
MODEL_PATH="${MODEL_PATH:-/etc/nikki/run/Model.bin}"
MODEL_RESERVE_MB="${MODEL_RESERVE_MB:-4}"
AMD64_LEVEL="${AMD64_LEVEL:-auto}"
MIPS_FLOAT="${MIPS_FLOAT:-softfloat}"
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
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

API_URL="https://api.github.com/repos/${REPO}/releases/tags/${RELEASE_TAG}"
RELEASE_BASE="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
VERSION_URL="${RELEASE_BASE}/version.txt"
LGBM_TAG="LightGBM-Model"
LGBM_API_URL="https://api.github.com/repos/${REPO}/releases/tags/${LGBM_TAG}"
LGBM_BASE="https://github.com/${REPO}/releases/download/${LGBM_TAG}"

TMP_DIR="/tmp/nikki-smart-update.$$"
LOCK_DIR="/tmp/nikki-smart-update.lock"
INSTALL_TMP="${CORE_PATH}.new.$$"
BACKUP_CORE="${TMP_DIR}/mihomo.backup"
BACKUP_MODEL="${MODEL_PATH}.backup.$$"
ARCHIVE="${TMP_DIR}/mihomo.gz"
NEW_CORE="${TMP_DIR}/mihomo"
RELEASE_JSON="${TMP_DIR}/release.json"
LGBM_JSON="${TMP_DIR}/lgbm-release.json"
NEW_MODEL="${MODEL_PATH}.download.$$"
VERSION_FILE="${TMP_DIR}/version.txt"
TEST_LOG="${TMP_DIR}/config-test.log"

LOCK_ACQUIRED=0
CORE_INSTALLED=0
MODEL_INSTALLED=0
MODEL_HAD_OLD=0
WAS_RUNNING=0
DOWNLOADER=""
PKG_MANAGER="unknown"
OPENWRT_VERSION="unknown"
OPENWRT_ARCH="unknown"
CPU_ARCH="$(uname -m 2>/dev/null || printf '%s' unknown)"
ASSET_ARCH=""
ASSET_URL=""
ASSET_NAME=""
EXPECTED_SHA256=""
MODEL_ASSET_NAME=""
MODEL_ASSET_URL=""
MODEL_EXPECTED_SHA256=""
MODEL_EXPECTED_SIZE=""
MODEL_LABEL=""

log() {
	printf '%s\n' "[Nikki-Smart] $*"
}

warn() {
	printf '%s\n' "[Nikki-Smart] 警告：$*" >&2
}

die() {
	printf '%s\n' "[Nikki-Smart] 错误：$*" >&2
	exit 1
}

cleanup() {
	rm -f "$INSTALL_TMP" 2>/dev/null || true
	rm -f "$NEW_MODEL" 2>/dev/null || true
	if [ -f "$BACKUP_MODEL" ]; then
		if [ ! -f "$MODEL_PATH" ]; then
			mv -f "$BACKUP_MODEL" "$MODEL_PATH" 2>/dev/null || true
		else
			rm -f "$BACKUP_MODEL" 2>/dev/null || true
		fi
	fi
	rm -rf "$TMP_DIR" 2>/dev/null || true
	if [ "$LOCK_ACQUIRED" -eq 1 ]; then
		rm -rf "$LOCK_DIR" 2>/dev/null || true
	fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
	printf '%s\n' \
		"用法：" \
		"  update_nikki_smart.sh [选项]" \
		"  wget -qO- URL | sh -s -- [选项]" \
		"" \
		"选项：" \
		"  --lgbm auto|small|middle|large|skip" \
		"                         选择 LightGBM 模型；auto 按可用空间选最大档" \
		"  --proxy URL            只使用指定的一个 GitHub 反代" \
		"  --proxies \"URL ...\"   设置按顺序尝试的反代列表" \
		"  --no-proxy             禁用反代，只使用 GitHub 直连" \
		"  --direct-first         优先直连（默认）" \
		"  --proxy-first          优先反代，失败后尝试直连" \
		"  --min-speed KB/s       直连最低速度，默认 64 KB/s" \
		"  --slow-time 秒         持续低速熔断时间，默认 20 秒" \
		"  --direct-timeout 秒    单次直连最长时间，默认 600 秒" \
		"  --no-restart           更新后不重启 Nikki" \
		"  --no-config-test       不用新内核检查当前配置" \
		"  --force                强制重新安装" \
		"  -h, --help             显示帮助"
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--lgbm)
				[ "$#" -ge 2 ] || die "--lgbm 缺少参数"
				LGBM_MODEL="$2"
				shift 2
				;;
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
			--no-config-test)
				TEST_CONFIG=0
				shift
				;;
			--force)
				FORCE_UPDATE=1
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

	case "$LGBM_MODEL" in
		auto|small|middle|large|skip) ;;
		*) die "LGBM_MODEL 只能是 auto、small、middle、large 或 skip" ;;
	esac
	case "$DIRECT_FIRST" in
		0|1) ;;
		*) die "DIRECT_FIRST 只能是 0 或 1" ;;
	esac
	case "$MODEL_RESERVE_MB" in
		""|*[!0-9]*) die "MODEL_RESERVE_MB 必须是非负整数" ;;
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
	proxy="$1"
	url="$2"
	case "$proxy" in
		""|none|direct)
			printf '%s' "$url"
			;;
		*/)
			printf '%s%s' "$proxy" "$url"
			;;
		*)
			printf '%s/%s' "$proxy" "$url"
			;;
	esac
}

fetch() {
	f_url="$1"
	f_output="$2"
	f_mode="${3:-normal}"
	direct_speed_limit=$((DIRECT_MIN_KBPS * 1024))

	case "$DOWNLOADER" in
		curl)
			if [ "$f_mode" = "direct" ]; then
				curl --fail --location --silent --show-error \
					--connect-timeout 10 --max-time "$DIRECT_MAX_TIME" \
					--speed-limit "$direct_speed_limit" \
					--speed-time "$DIRECT_SLOW_TIME" \
					--retry 1 --retry-delay 1 \
					--user-agent "Nikki-Smart-Updater/1.0" \
					--output "$f_output" "$f_url"
			else
				curl --fail --location --silent --show-error \
					--connect-timeout 10 --max-time "$PROXY_MAX_TIME" \
					--speed-limit "$((PROXY_MIN_KBPS * 1024))" \
					--speed-time "$PROXY_SLOW_TIME" \
					--retry 1 --retry-delay 1 \
					--user-agent "Nikki-Smart-Updater/1.0" \
					--output "$f_output" "$f_url"
			fi
			;;
		wget)
			if [ "$f_mode" = "direct" ] &&
			   command -v timeout >/dev/null 2>&1; then
				timeout "$DIRECT_MAX_TIME" \
					wget -T "$DIRECT_SLOW_TIME" -q -O "$f_output" "$f_url"
			else
				if command -v timeout >/dev/null 2>&1; then
					timeout "$PROXY_MAX_TIME" \
						wget -T "$PROXY_SLOW_TIME" -q -O "$f_output" "$f_url"
				else
					wget -T "$PROXY_SLOW_TIME" -q -O "$f_output" "$f_url"
				fi
			fi
			;;
		*)
			return 1
			;;
	esac
}

fetch_api_direct() {
	api_url="$1"
	api_output="$2"

	if [ "$DOWNLOADER" = "curl" ] && [ -n "$GITHUB_TOKEN" ]; then
		curl --fail --location --silent --show-error \
			--connect-timeout 10 --max-time "$DIRECT_MAX_TIME" \
			--speed-limit "$((DIRECT_MIN_KBPS * 1024))" \
			--speed-time "$DIRECT_SLOW_TIME" \
			--retry 1 --retry-delay 1 \
			--user-agent "Nikki-Smart-Updater/1.0" \
			--header "Accept: application/vnd.github+json" \
			--header "Authorization: Bearer ${GITHUB_TOKEN}" \
			--header "X-GitHub-Api-Version: 2022-11-28" \
			--output "$api_output" "$api_url"
	else
		fetch "$api_url" "$api_output" direct
	fi
}

download_is_plausible() {
	url="$1"
	output="$2"
	kind="$3"
	[ -s "$output" ] || return 1

	if [ "$kind" = "version" ]; then
		candidate_version="$(tr -d '\r\n ' < "$output")"
		case "$candidate_version" in
			""|*[!A-Za-z0-9._-]*) return 1 ;;
			*) return 0 ;;
		esac
	fi
	if [ "$kind" = "api" ]; then
		grep -q '"assets"[[:space:]]*:' "$output" 2>/dev/null
		return
	fi
	case "$url" in
		*.gz)
			gzip -t "$output" >/dev/null 2>&1
			;;
		*.bin)
			file_size="$(wc -c < "$output" | tr -d ' ')"
			case "$file_size" in
				""|*[!0-9]*) return 1 ;;
			esac
			[ "$file_size" -ge 1048576 ] &&
				[ "$(head -n 1 "$output" 2>/dev/null | tr -d '\r')" = "tree" ]
			;;
		*)
			return 0
			;;
	esac
}

try_github_proxies() {
	tp_url="$1"
	tp_output="$2"
	tp_kind="$3"

	for tp_proxy in $GITHUB_PROXIES; do
		case "$tp_proxy" in
			http://*|https://*) ;;
			*)
				warn "跳过格式异常的反代：$tp_proxy"
				continue
				;;
		esac
		tp_proxy_url="$(apply_proxy "$tp_proxy" "$tp_url")"
		log "尝试 GitHub 反代：$tp_proxy"
		rm -f "$tp_output"
		if fetch "$tp_proxy_url" "$tp_output" proxy &&
		   download_is_plausible "$tp_url" "$tp_output" "$tp_kind"; then
			log "反代可用：$tp_proxy"
			return 0
		fi
		warn "反代失败、超时、持续低速或内容异常：$tp_proxy"
	done
	rm -f "$tp_output"
	return 1
}

fetch_github() {
	fg_url="$1"
	fg_output="$2"
	fg_kind="${3:-file}"

	if [ "$DIRECT_FIRST" != "1" ] && [ -n "$GITHUB_PROXIES" ]; then
		if try_github_proxies "$fg_url" "$fg_output" "$fg_kind"; then
			return 0
		fi
		warn "所有反代均不可用，回退 GitHub 直连"
	fi

	rm -f "$fg_output"
	if [ "$DOWNLOADER" = "curl" ]; then
		log "尝试 GitHub 直连（持续低于 ${DIRECT_MIN_KBPS} KB/s 达 ${DIRECT_SLOW_TIME} 秒将切换）"
	else
		log "尝试 GitHub 直连（超时后将切换反代）"
	fi
	if [ "$fg_kind" = "api" ]; then
		if fetch_api_direct "$fg_url" "$fg_output" &&
		   download_is_plausible "$fg_url" "$fg_output" "$fg_kind"; then
			return 0
		fi
	else
		if fetch "$fg_url" "$fg_output" direct &&
		   download_is_plausible "$fg_url" "$fg_output" "$fg_kind"; then
			return 0
		fi
	fi

	if [ "$DIRECT_FIRST" = "1" ] && [ -n "$GITHUB_PROXIES" ]; then
		warn "GitHub 直连失败、超时或持续低速，依次尝试备用反代"
		if try_github_proxies "$fg_url" "$fg_output" "$fg_kind"; then
			return 0
		fi
	fi

	rm -f "$fg_output"
	return 1
}

fetch_api() {
	fetch_github "$1" "$2" api
}

acquire_lock() {
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		LOCK_ACQUIRED=1
		printf '%s\n' "$$" > "$LOCK_DIR/pid"
		return
	fi

	old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
	if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
		die "已有更新任务正在运行（PID $old_pid）"
	fi

	warn "发现残留锁，正在清理"
	rm -rf "$LOCK_DIR"
	mkdir "$LOCK_DIR" || die "无法创建更新锁：$LOCK_DIR"
	LOCK_ACQUIRED=1
	printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

all_cpu_flags() {
	for required_flag in "$@"; do
		case " $CPU_FLAGS " in
			*" $required_flag "*)
				;;
			*)
				return 1
				;;
		esac
	done
	return 0
}

detect_amd64_level() {
	case "$AMD64_LEVEL" in
		v1|v2|v3)
			printf '%s' "$AMD64_LEVEL"
			return
			;;
		auto)
			;;
		*)
			die "AMD64_LEVEL 只能是 auto、v1、v2 或 v3"
			;;
	esac

	CPU_FLAGS="$(
		sed -n 's/^flags[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null |
			head -n 1
	)"

	# GOAMD64 v3 所需指令；未完整暴露时保守降级。
	if all_cpu_flags avx avx2 bmi1 bmi2 fma movbe osxsave; then
		printf '%s' "v3"
	elif all_cpu_flags cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3; then
		printf '%s' "v2"
	else
		printf '%s' "v1"
	fi
}

detect_asset_arch() {
	case "$CPU_ARCH" in
		x86_64|amd64)
			amd_level="$(detect_amd64_level)"
			ASSET_ARCH="amd64-${amd_level}"
			;;
		i386|i486|i586|i686|x86)
			ASSET_ARCH="386"
			;;
		aarch64|arm64)
			ASSET_ARCH="arm64"
			;;
		armv8l|armv7l|armv7*)
			ASSET_ARCH="armv7"
			;;
		armv6l|armv6*)
			ASSET_ARCH="armv6"
			;;
		armv5tel|armv5tejl|armv5*)
			ASSET_ARCH="armv5"
			;;
		mips64el|mips64le)
			ASSET_ARCH="mips64le"
			;;
		mips64)
			ASSET_ARCH="mips64"
			;;
		mipsel|mipsle)
			case "$MIPS_FLOAT" in
				softfloat|hardfloat)
					ASSET_ARCH="mipsle-${MIPS_FLOAT}"
					;;
				*)
					die "MIPS_FLOAT 只能是 softfloat 或 hardfloat"
					;;
			esac
			;;
		mips)
			case "$MIPS_FLOAT" in
				softfloat|hardfloat)
					ASSET_ARCH="mips-${MIPS_FLOAT}"
					;;
				*)
					die "MIPS_FLOAT 只能是 softfloat 或 hardfloat"
					;;
			esac
			;;
		riscv64)
			ASSET_ARCH="riscv64"
			;;
		loongarch64|loong64)
			ASSET_ARCH="loong64"
			;;
		s390x)
			ASSET_ARCH="s390x"
			;;
		*)
			die "暂不支持 CPU 架构：$CPU_ARCH"
			;;
	esac
}

read_openwrt_info() {
	[ -r /etc/openwrt_release ] ||
		die "未检测到 /etc/openwrt_release，本脚本仅支持 OpenWrt"

	# OpenWrt 自带且由系统维护的可信配置文件。
	# shellcheck disable=SC1091
	. /etc/openwrt_release
	OPENWRT_VERSION="${DISTRIB_RELEASE:-unknown}"
	OPENWRT_ARCH="${DISTRIB_ARCH:-unknown}"

	if command -v apk >/dev/null 2>&1; then
		PKG_MANAGER="apk"
	elif command -v opkg >/dev/null 2>&1; then
		PKG_MANAGER="opkg"
	else
		die "未检测到 apk 或 opkg"
	fi

	case "$OPENWRT_VERSION" in
		24.10*)
			[ "$PKG_MANAGER" = "opkg" ] ||
				warn "OpenWrt 24.10 通常使用 opkg，实际检测到 $PKG_MANAGER"
			;;
		25.12*)
			[ "$PKG_MANAGER" = "apk" ] ||
				warn "OpenWrt 25.12 通常使用 apk，实际检测到 $PKG_MANAGER"
			;;
		SNAPSHOT*|*SNAPSHOT*)
			warn "当前为 SNAPSHOT，最终以实际检测到的包管理器为准"
			;;
		*)
			warn "当前版本 $OPENWRT_VERSION 不在主要验证范围（24.10/25.12）"
			;;
	esac
}

select_downloader() {
	if command -v curl >/dev/null 2>&1; then
		DOWNLOADER="curl"
	elif command -v wget >/dev/null 2>&1; then
		DOWNLOADER="wget"
	else
		case "$PKG_MANAGER" in
			apk)
				die "缺少下载工具，请先执行：apk add curl"
				;;
			opkg)
				die "缺少下载工具，请先执行：opkg update && opkg install curl"
				;;
			*)
				die "缺少 curl/wget"
				;;
		esac
	fi

	command -v gzip >/dev/null 2>&1 ||
		case "$PKG_MANAGER" in
			apk) die "缺少 gzip，请先执行：apk add gzip" ;;
			opkg) die "缺少 gzip，请先执行：opkg update && opkg install gzip" ;;
			*) die "缺少 gzip" ;;
		esac
}

select_asset_from_api() {
	[ -s "$RELEASE_JSON" ] || return 1

	ASSET_URL="$(
		awk -v arch="$ASSET_ARCH" '
			/"browser_download_url"[[:space:]]*:/ {
				line = $0
				sub(/^[^:]*:[[:space:]]*"/, "", line)
				sub(/".*$/, "", line)
				name = line
				sub(/^.*\//, "", name)
				prefix = "mihomo-linux-" arch "-"
				if (index(name, prefix) == 1 &&
				    name ~ /\.gz$/ &&
				    name !~ /-go[0-9]+/) {
					print line
					exit
				}
			}
		' "$RELEASE_JSON"
	)"

	[ -n "$ASSET_URL" ] || return 1
	ASSET_NAME="${ASSET_URL##*/}"

	# GitHub Release API 新版本会返回资产 digest；旧版本没有时跳过。
	EXPECTED_SHA256="$(
		awk -v target="$ASSET_NAME" '
			/^[[:space:]]*"name"[[:space:]]*:/ {
				name = $0
				sub(/^[^:]*:[[:space:]]*"/, "", name)
				sub(/".*$/, "", name)
				digest = ""
			}
			/^[[:space:]]*"digest"[[:space:]]*:[[:space:]]*"sha256:/ {
				digest = $0
				sub(/^.*"sha256:/, "", digest)
				sub(/".*$/, "", digest)
			}
			/^[[:space:]]*"browser_download_url"[[:space:]]*:/ {
				if (name == target) {
					print digest
					exit
				}
			}
		' "$RELEASE_JSON"
	)"
	return 0
}

download_by_version_file() {
	fetch_github "$VERSION_URL" "$VERSION_FILE" version || return 1
	version="$(tr -d '\r\n ' < "$VERSION_FILE")"

	case "$version" in
		""|*[!A-Za-z0-9._-]*)
			return 1
			;;
	esac

	candidate="${RELEASE_BASE}/mihomo-linux-${ASSET_ARCH}-${version}.gz"
	if fetch_github "$candidate" "$ARCHIVE"; then
		ASSET_URL="$candidate"
		ASSET_NAME="${candidate##*/}"
		return 0
	fi

	# 兼容旧版发行资产的 amd64-compatible 命名。
	case "$ASSET_ARCH" in
		amd64-v1)
			candidate="${RELEASE_BASE}/mihomo-linux-amd64-compatible-${version}.gz"
			if fetch_github "$candidate" "$ARCHIVE"; then
				ASSET_URL="$candidate"
				ASSET_NAME="${candidate##*/}"
				return 0
			fi
			;;
	esac
	return 1
}

model_filename_for_choice() {
	case "$1" in
		small) printf '%s' "Model.bin" ;;
		middle) printf '%s' "Model-middle.bin" ;;
		large) printf '%s' "Model-large.bin" ;;
		*) return 1 ;;
	esac
}

model_label_for_choice() {
	case "$1" in
		small) printf '%s' "轻量版" ;;
		middle) printf '%s' "中等版" ;;
		large) printf '%s' "大型版" ;;
		*) return 1 ;;
	esac
}

available_model_kb() {
	model_dir="${MODEL_PATH%/*}"
	[ "$model_dir" != "$MODEL_PATH" ] || model_dir="."
	[ -d "$model_dir" ] || mkdir -p "$model_dir" ||
		die "无法创建模型目录：$model_dir"
	df -Pk "$model_dir" 2>/dev/null |
		awk 'NR == 2 {print $4; exit}'
}

choose_auto_model() {
	free_kb="$(available_model_kb)"
	case "$free_kb" in
		""|*[!0-9]*) die "无法读取 $MODEL_PATH 所在分区的剩余空间" ;;
	esac

	# 当前三档约为 7.5/10.6/20.4 MiB；额外预留空间供原子替换和配置写入。
	reserve_kb=$((MODEL_RESERVE_MB * 1024))
	if [ "$free_kb" -ge $((22 * 1024 + reserve_kb)) ]; then
		printf '%s' "large"
	elif [ "$free_kb" -ge $((12 * 1024 + reserve_kb)) ]; then
		printf '%s' "middle"
	elif [ "$free_kb" -ge $((9 * 1024 + reserve_kb)) ]; then
		printf '%s' "small"
	else
		die "模型分区仅剩 $((free_kb / 1024)) MiB，空间不足；可使用 --lgbm skip"
	fi
}

read_model_asset_from_api() {
	target="$1"
	asset_record="$(
		awk -v target="$target" '
			/^[[:space:]]*"name"[[:space:]]*:/ {
				name = $0
				sub(/^[^:]*:[[:space:]]*"/, "", name)
				sub(/".*$/, "", name)
				size = ""; digest = ""; url = ""
			}
			/^[[:space:]]*"size"[[:space:]]*:/ {
				size = $0
				sub(/^[^:]*:[[:space:]]*/, "", size)
				sub(/,.*/, "", size)
			}
			/^[[:space:]]*"digest"[[:space:]]*:[[:space:]]*"sha256:/ {
				digest = $0
				sub(/^.*"sha256:/, "", digest)
				sub(/".*$/, "", digest)
			}
			/^[[:space:]]*"browser_download_url"[[:space:]]*:/ {
				url = $0
				sub(/^[^:]*:[[:space:]]*"/, "", url)
				sub(/".*$/, "", url)
				if (name == target) {
					print size "|" digest "|" url
					exit
				}
			}
		' "$LGBM_JSON"
	)"
	[ -n "$asset_record" ] || return 1

	MODEL_EXPECTED_SIZE="${asset_record%%|*}"
	asset_record="${asset_record#*|}"
	MODEL_EXPECTED_SHA256="${asset_record%%|*}"
	MODEL_ASSET_URL="${asset_record#*|}"
	[ -n "$MODEL_ASSET_URL" ]
}

verify_model() {
	[ -s "$NEW_MODEL" ] || die "LightGBM 模型下载文件为空"
	actual_size="$(wc -c < "$NEW_MODEL" | tr -d ' ')"
	case "$actual_size" in
		""|*[!0-9]*) die "无法读取 LightGBM 模型大小" ;;
	esac
	[ "$actual_size" -ge 1048576 ] ||
		die "LightGBM 模型体积异常，下载内容可能是反代错误页面"
	[ "$(head -n 1 "$NEW_MODEL" 2>/dev/null | tr -d '\r')" = "tree" ] ||
		die "LightGBM 模型格式异常，下载内容可能不是模型文件"

	if [ -n "$MODEL_EXPECTED_SIZE" ]; then
		[ "$actual_size" = "$MODEL_EXPECTED_SIZE" ] ||
			die "LightGBM 模型大小校验失败"
	fi

	[ -n "$MODEL_EXPECTED_SHA256" ] || {
		warn "模型发行 API 未提供 SHA-256，仅检查文件大小"
		return
	}
	case "$MODEL_EXPECTED_SHA256" in
		*[!0-9A-Fa-f]*|'') die "模型 SHA-256 格式异常" ;;
	esac
	[ "${#MODEL_EXPECTED_SHA256}" -eq 64 ] ||
		die "模型 SHA-256 长度异常"

	if command -v sha256sum >/dev/null 2>&1; then
		actual_sha256="$(sha256sum "$NEW_MODEL" | awk '{print $1}')"
		[ "$actual_sha256" = "$MODEL_EXPECTED_SHA256" ] ||
			die "LightGBM 模型 SHA-256 校验失败"
		log "LightGBM 模型 SHA-256 校验通过"
	else
		warn "系统没有 sha256sum，无法核对模型摘要"
	fi
}

prepare_lgbm_model() {
	[ "$LGBM_MODEL" != "skip" ] || {
		log "已跳过 LightGBM 模型更新"
		return
	}

	model_free_kb="$(available_model_kb)"
	log "模型分区可用空间：$((model_free_kb / 1024)) MiB"
	if [ "$LGBM_MODEL" = "auto" ]; then
		LGBM_MODEL="$(choose_auto_model)"
	fi
	MODEL_ASSET_NAME="$(model_filename_for_choice "$LGBM_MODEL")"
	MODEL_LABEL="$(model_label_for_choice "$LGBM_MODEL")"
	MODEL_ASSET_URL="${LGBM_BASE}/${MODEL_ASSET_NAME}"

	log "LightGBM 模型：${MODEL_LABEL}（${MODEL_ASSET_NAME}）"
	if fetch_api "$LGBM_API_URL" "$LGBM_JSON"; then
		if ! read_model_asset_from_api "$MODEL_ASSET_NAME"; then
			warn "模型发行 API 中未找到 $MODEL_ASSET_NAME，使用固定发行地址"
			MODEL_ASSET_URL="${LGBM_BASE}/${MODEL_ASSET_NAME}"
		fi
	else
		warn "无法读取模型发行 API，使用固定发行地址"
	fi

	case "$MODEL_EXPECTED_SIZE" in
		""|*[!0-9]*)
			case "$LGBM_MODEL" in
				small) required_kb=$((9 * 1024)) ;;
				middle) required_kb=$((12 * 1024)) ;;
				large) required_kb=$((22 * 1024)) ;;
			esac
			;;
		*)
			required_kb=$(((MODEL_EXPECTED_SIZE + 1023) / 1024))
			;;
	esac
	required_kb=$((required_kb + MODEL_RESERVE_MB * 1024))
	[ "$model_free_kb" -ge "$required_kb" ] ||
		die "安装 ${MODEL_LABEL}模型至少需要 $((required_kb / 1024)) MiB 可用空间"

	if ! fetch_github "$MODEL_ASSET_URL" "$NEW_MODEL"; then
		die "LightGBM 模型下载失败：$MODEL_ASSET_URL"
	fi
	verify_model
}

verify_sha256() {
	[ -n "$EXPECTED_SHA256" ] || {
		warn "发行 API 未提供 SHA-256，继续执行 gzip 与二进制试运行校验"
		return
	}

	case "$EXPECTED_SHA256" in
		*[!0-9A-Fa-f]*|'')
			die "发行 API 返回了异常的 SHA-256：$EXPECTED_SHA256"
			;;
	esac
	[ "${#EXPECTED_SHA256}" -eq 64 ] ||
		die "发行 API 返回了长度异常的 SHA-256：$EXPECTED_SHA256"

	if ! command -v sha256sum >/dev/null 2>&1; then
		warn "系统没有 sha256sum，无法核对发行摘要"
		return
	fi

	actual_sha256="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
	[ "$actual_sha256" = "$EXPECTED_SHA256" ] ||
		die "SHA-256 校验失败，拒绝安装"
	log "SHA-256 校验通过"
}

test_new_core() {
	gzip -t "$ARCHIVE" || die "下载文件不是有效的 gzip 压缩包"
	gzip -dc "$ARCHIVE" > "$NEW_CORE" ||
		die "Smart 内核解压失败"
	chmod 0755 "$NEW_CORE"

	NEW_VERSION="$("$NEW_CORE" -v 2>/dev/null | head -n 1 || true)"
	[ -n "$NEW_VERSION" ] ||
		die "新内核无法在当前 CPU/系统上运行，可能选择了错误架构"
	log "新内核：$NEW_VERSION"

	if [ "$TEST_CONFIG" = "1" ] &&
	   [ -s /etc/nikki/run/config.yaml ]; then
		log "使用新内核检查 Nikki 当前配置……"
		if ! "$NEW_CORE" -t \
			-d /etc/nikki/run \
			-f /etc/nikki/run/config.yaml >"$TEST_LOG" 2>&1; then
			tail -n 20 "$TEST_LOG" >&2 || true
			die "新内核未通过当前配置检查，旧内核未被修改"
		fi
		log "配置检查通过"
	fi
}

nikki_is_running() {
	if command -v pidof >/dev/null 2>&1 &&
	   pidof mihomo >/dev/null 2>&1; then
		return 0
	fi
	/etc/init.d/nikki status >/dev/null 2>&1
}

wait_for_nikki() {
	wait_count=0
	while [ "$wait_count" -lt 10 ]; do
		if nikki_is_running; then
			return 0
		fi
		sleep 1
		wait_count=$((wait_count + 1))
	done
	return 1
}

restore_old_core() {
	warn "正在恢复旧内核……"
	[ -s "$BACKUP_CORE" ] || die "备份内核丢失，无法自动恢复"
	cp -p "$BACKUP_CORE" "$INSTALL_TMP" ||
		die "复制备份内核失败"
	chmod 0755 "$INSTALL_TMP"
	mv -f "$INSTALL_TMP" "$CORE_PATH" ||
		die "恢复旧内核失败"
	CORE_INSTALLED=0

	if [ "$MODEL_INSTALLED" -eq 1 ]; then
		warn "正在恢复旧 LightGBM 模型……"
		if [ "$MODEL_HAD_OLD" -eq 1 ]; then
			rm -f "$MODEL_PATH" ||
				die "移除新模型失败"
			mv -f "$BACKUP_MODEL" "$MODEL_PATH" ||
				die "恢复旧模型失败"
		else
			rm -f "$MODEL_PATH" ||
				die "移除新模型失败"
		fi
		MODEL_INSTALLED=0
	fi

	if [ "$WAS_RUNNING" -eq 1 ]; then
		/etc/init.d/nikki restart >/dev/null 2>&1 || true
	fi
	die "Nikki 使用新内核启动失败，旧内核和旧模型已恢复"
}

install_new_core() {
	cp -p "$CORE_PATH" "$BACKUP_CORE" ||
		die "无法备份旧内核到 $BACKUP_CORE"

	if [ "$LGBM_MODEL" != "skip" ]; then
		if [ -f "$MODEL_PATH" ]; then
			mv -f "$MODEL_PATH" "$BACKUP_MODEL" ||
				die "无法暂存旧 LightGBM 模型"
			MODEL_HAD_OLD=1
		fi
		chown 0:0 "$NEW_MODEL" 2>/dev/null || true
		chmod 0644 "$NEW_MODEL"
	fi

	cp "$NEW_CORE" "$INSTALL_TMP" ||
		die "无法把新内核写入 ${CORE_PATH%/*}"
	chown 0:0 "$INSTALL_TMP" 2>/dev/null || true
	chmod 0755 "$INSTALL_TMP"
	mv -f "$INSTALL_TMP" "$CORE_PATH" ||
		die "原子替换内核失败"
	CORE_INSTALLED=1

	if [ "$LGBM_MODEL" != "skip" ]; then
		if ! mv -f "$NEW_MODEL" "$MODEL_PATH"; then
			restore_old_core
		fi
		MODEL_INSTALLED=1
		log "LightGBM ${MODEL_LABEL}模型已安装：$MODEL_PATH"
	fi

	if [ "$RESTART_NIKKI" != "1" ]; then
		log "已按要求跳过重启；当前进程仍在使用旧内核"
		log "需要生效时执行：/etc/init.d/nikki restart"
		return
	fi

	if [ "$WAS_RUNNING" -eq 0 ]; then
		log "更新前 Nikki 未运行，保持停止状态"
		return
	fi

	log "重启 Nikki……"
	if ! /etc/init.d/nikki restart; then
		restore_old_core
	fi
	if ! wait_for_nikki; then
		restore_old_core
	fi
	log "Nikki 已使用新内核正常运行"
}

main() {
	parse_args "$@"
	[ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行"
	read_openwrt_info
	select_downloader
	detect_asset_arch

	[ -x /etc/init.d/nikki ] ||
		die "未检测到 /etc/init.d/nikki，请确认已安装 Nikki"
	[ -f "$CORE_PATH" ] ||
		die "未找到 Nikki 内核：$CORE_PATH"

	log "系统：OpenWrt $OPENWRT_VERSION"
	log "OpenWrt 架构：$OPENWRT_ARCH"
	log "CPU 架构：$CPU_ARCH"
	log "包管理器：$PKG_MANAGER"
	log "Smart 资产架构：$ASSET_ARCH"
	case "$GITHUB_PROXIES" in
		"") log "GitHub 下载：仅直连" ;;
		*)
			if [ "$DIRECT_FIRST" = "1" ]; then
				log "GitHub 下载：直连优先；失败、超时或持续低速后依次尝试反代"
				if [ "$DOWNLOADER" = "curl" ]; then
					log "直连低速阈值：${DIRECT_MIN_KBPS} KB/s，持续 ${DIRECT_SLOW_TIME} 秒"
				elif ! command -v timeout >/dev/null 2>&1; then
					warn "wget 环境缺少 timeout，只能检测连接/读取超时，建议安装 curl"
				fi
			else
				log "GitHub 下载：反代列表优先，全部失败后回退直连"
			fi
			log "备用反代：$GITHUB_PROXIES"
			;;
	esac
	log "当前内核：$("$CORE_PATH" -v 2>/dev/null | head -n 1 || printf '%s' unknown)"

	acquire_lock
	mkdir "$TMP_DIR" || die "无法创建临时目录：$TMP_DIR"

	if nikki_is_running; then
		WAS_RUNNING=1
	fi

	log "查询 ${REPO} 的 ${RELEASE_TAG} 发行资产……"
	if fetch_api "$API_URL" "$RELEASE_JSON" &&
	   select_asset_from_api; then
		log "匹配资产：$ASSET_NAME"
		if ! fetch_github "$ASSET_URL" "$ARCHIVE"; then
			die "Smart 内核下载失败：$ASSET_URL"
		fi
	else
		warn "无法通过 GitHub Release API 选择资产，尝试 version.txt 兼容方式"
		if ! download_by_version_file; then
			die "未找到适用于 $ASSET_ARCH 的 Smart 内核发行资产"
		fi
		log "匹配资产：$ASSET_NAME"
	fi

	[ -s "$ARCHIVE" ] || die "下载文件为空"
	verify_sha256
	test_new_core
	prepare_lgbm_model

	core_same=0
	model_same=1
	if command -v cmp >/dev/null 2>&1 &&
	   cmp -s "$CORE_PATH" "$NEW_CORE"; then
		core_same=1
	fi
	if [ "$LGBM_MODEL" != "skip" ]; then
		model_same=0
		if command -v cmp >/dev/null 2>&1 &&
		   [ -f "$MODEL_PATH" ] &&
		   cmp -s "$MODEL_PATH" "$NEW_MODEL"; then
			model_same=1
		fi
	fi

	if [ "$FORCE_UPDATE" != "1" ] &&
	   [ "$core_same" -eq 1 ] &&
	   [ "$model_same" -eq 1 ]; then
		if [ "$LGBM_MODEL" = "skip" ]; then
			log "当前 Smart 内核已是最新，无需更新"
		else
			log "当前 Smart 内核与 LightGBM 模型均为最新，无需更新"
		fi
		exit 0
	fi

	install_new_core
	log "Smart 内核更新完成"
	log "已安装：$NEW_VERSION"
}

main "$@"
