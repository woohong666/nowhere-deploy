#!/usr/bin/env bash
#
# Nowhere V2 Unified Manager v1.4.1
# Dedicated management line for NodePassProject/Nowhere v2.x.
# Deliberately isolated from the V1 manager and V1 filesystem/service names.
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 woohong666

set -Eeuo pipefail
umask 077

readonly SCRIPT_VERSION="1.4.1"
readonly SCRIPT_CHANNEL="v2"
# v1.4.1: pin tls=2 links whose certificate is not in the system trust store
#   (private CA is not the same as trusted); require exactly 64 hex key characters
#   on an exact v2.2.0 pin; take the build lock for backup and doctor --fix.
# v1.4.0: merge in a GPT-assisted review's fixes: flock build lock; install/configure
#   transactions with EXIT-trap recovery; paginated release resolution; integer
#   0..2147483647 rate; real IPv6 bracket validation; Morph-aware fingerprint through
#   the installed binary with colon normalization; python tar whitelist extraction;
#   stricter release tag/asset/digest checks; TMPDIR layout for telemetry and the TUI;
#   BUILD-INFO fallback; menu actions keep errexit and roll back on failure.
# v1.3.1: keep the other settings of a config whose shared key is pre-2.2, so the
#   wizard can prefill them and `configure -y --key` can rotate only the key.
# v1.3.0: align with the Nowhere v2.2.x series: 32-64 lowercase-hex shared keys,
#   2.2.0 key/certificate upgrade warnings, full8 morph default, drop log=event
#   (removed in 2.1.1), add --dial4/--dial6, auto-pin generated-cert client links.
# v1.2.8: self-update now defaults to this repository's main branch (no NOWHERE_V2_SELF_URL needed); clarify the doctor morph reminder.
# v1.2.7: serialise installs/release-pruning with the build lock; refresh manager.conf version fields on a binary-only install.
# v1.2.6: prompt_choice/prompt_key no longer spin forever without a terminal; reject link members in release tars; refuse a backup path inside the config dir.
# v1.2.5: re-read manager.conf before rewriting the unit (doctor --fix / config restore no longer reset persisted values); refuse manager downgrades; require Rust >= 1.85 for source builds.
# v1.2.4: translate the remaining operator-facing messages so LANG_CODE=zh no longer shows English errors.
# v1.2.3: default to latest-v2 instead of a pinned tag; drop dead code; match upstream's single-'@' rule for next=.
# v1.2.2: validate persisted/manager-supplied values before they reach the unit; warn when a morph=1 config crosses the 2.1.0 wire break.
# v1.2.1: register --morph-prelude as a CLI override so an existing manager.conf cannot silently discard it.
# v1.2.0: add Nowhere v2.1.0 support; introduce --morph-prelude and NOW_MORPH_TCP_PRELUDE environment variable.
# The core version resolves from the official releases at install time so the
# manager is never pinned to a stale tag. Override with --version or NOWHERE_V2_VERSION.
readonly DEFAULT_CORE_VERSION="latest-v2"
readonly UPSTREAM_REPO="NodePassProject/Nowhere"
readonly DEFAULT_REPO_URL="https://github.com/NodePassProject/Nowhere.git"
# Self-update source. Defaults to this repository's main branch so menu option
# [18] works out of the box; set NOWHERE_V2_SELF_URL to point at a fork or
# mirror, or set it empty to disable self-update entirely.
readonly DEFAULT_SELF_UPDATE_URL="https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v2.sh"
readonly SELF_UPDATE_URL="${NOWHERE_V2_SELF_URL-$DEFAULT_SELF_UPDATE_URL}"

# V2 is intentionally isolated from the V1 manager.
readonly SERVICE_NAME="nowhere-v2"
readonly RUN_USER="nowhere-v2"
readonly RUN_GROUP="nowhere-v2"
readonly INSTALL_ROOT="/opt/nowhere-v2"
readonly RELEASES_DIR="${INSTALL_ROOT}/releases"
readonly CURRENT_LINK="${INSTALL_ROOT}/current"
readonly BIN_LINK="/usr/local/bin/nowhere-v2"
readonly LAUNCHER="/usr/local/libexec/nowhere-v2-launch"
readonly CONFIG_DIR="/etc/nowhere-v2"
readonly URL_FILE="${CONFIG_DIR}/url.conf"
readonly META_FILE="${CONFIG_DIR}/manager.conf"
readonly UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly TLS_DIR="${CONFIG_DIR}/tls"

readonly SWAP_FILE="/var/tmp/nowhere-v2-build-swap"
readonly BUILD_LOCK_DIR="/run/nowhere-v2-build.lock.d"
readonly RUSTUP_HOME_DIR="/usr/local/rustup"
readonly CARGO_HOME_DIR="/usr/local/cargo"

# 2082 avoids the V1 manager's historical 2077 default when both are kept.
readonly DEFAULT_PORT="2082"
readonly DEFAULT_VECTOR_SOCKS="127.0.0.1:1082"
readonly DEFAULT_LOG="info"
readonly DEFAULT_KEEP_RELEASES="3"
readonly DEFAULT_MEMORY_PROFILE="throughput"
# Upstream switched the TCP Morph prelude default to full8 in Nowhere 2.2.0;
# low7 remains supported as an explicit choice (morph=1 paths only).
readonly DEFAULT_MORPH_PRELUDE="full8"

LANG_CODE="${NOWHERE_V2_LANG:-zh}"
ACTION="menu"
ASSUME_YES=0
INSTALL_METHOD="release"
VERSION="${NOWHERE_V2_VERSION:-$DEFAULT_CORE_VERSION}"
LIBC="${NOWHERE_V2_LIBC:-auto}"
KEEP_SOURCE="${NOWHERE_V2_KEEP_SOURCE:-0}"
KEEP_RELEASES="${NOWHERE_V2_KEEP_RELEASES:-$DEFAULT_KEEP_RELEASES}"
CONFIG_MODE="${NOWHERE_V2_CONFIG_MODE:-ask}"
COPY_CERT=0
PURGE=0
DOCTOR_FIX=0
FORCE_RECONFIGURE=0
UPGRADE_MODE=0
BACKUP_PATH=""
SWAP_MODE="${NOWHERE_V2_SWAP:-auto}"
BUILD_LOCK_HELD=0
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

ROLE="portal"
IMPORT_URL=""
KEY="${NOWHERE_V2_KEY:-}"
ENDPOINT=""
PUBLIC_HOST="${NOWHERE_V2_PUBLIC_HOST:-}"
NODE_NAME="${NOWHERE_V2_NAME:-}"
TLS="${NOWHERE_V2_TLS:-1}"
CERT="${NOWHERE_V2_CRT:-}"
TLS_KEY="${NOWHERE_V2_TLS_KEY:-}"
MORPH="${NOWHERE_V2_MORPH:-0}"
RATE="${NOWHERE_V2_RATE:-0}"
ETAR="${NOWHERE_V2_ETAR:-0}"
DIAL="${NOWHERE_V2_DIAL:-auto}"
DIAL4="${NOWHERE_V2_DIAL4:-auto}"
DIAL6="${NOWHERE_V2_DIAL6:-auto}"
LOG_LEVEL="${NOWHERE_V2_LOG:-$DEFAULT_LOG}"
OUT_SOCKS="${NOWHERE_V2_OUT_SOCKS:-none}"
NEXT="${NOWHERE_V2_NEXT:-none}"
UP="${NOWHERE_V2_UP:-auto}"
DOWN="${NOWHERE_V2_DOWN:-auto}"
MUX="${NOWHERE_V2_MUX:-0}"
SNI="${NOWHERE_V2_SNI:-none}"
PIN="${NOWHERE_V2_PIN:-none}"
VECTOR_SOCKS="${NOWHERE_V2_VECTOR_SOCKS:-$DEFAULT_VECTOR_SOCKS}"
MEMORY_PROFILE="${NOWHERE_V2_MEMORY_PROFILE:-$DEFAULT_MEMORY_PROFILE}"
MORPH_PRELUDE="${NOWHERE_V2_MORPH_PRELUDE:-$DEFAULT_MORPH_PRELUDE}"

CLIENT_UP="${NOWHERE_V2_CLIENT_UP:-auto}"
CLIENT_DOWN="${NOWHERE_V2_CLIENT_DOWN:-auto}"
CLIENT_MUX="${NOWHERE_V2_CLIENT_MUX:-0}"
CLIENT_SNI="${NOWHERE_V2_CLIENT_SNI:-auto}"
CLIENT_PIN="${NOWHERE_V2_CLIENT_PIN:-none}"

OLD_TARGET=""
CONFIG_SNAPSHOT_DIR=""
TX_DIR=""
TX_STARTED=0
TX_COMMITTED=0
TX_ACTIVE=0
TX_ENABLED=0
TX_OLD_TARGET=""
declare -a CLEANUP_PATHS=()
declare -A CLI_SET=()
declare -A CLI_VAL=()

if [[ -t 1 ]]; then
  C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
  C_BLUE='\033[1;34m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_NC=''
fi

info() { printf '%b[Nowhere V2]%b %s\n' "$C_BLUE" "$C_NC" "$*"; }
ok()   { printf '%b[OK]%b %s\n' "$C_GREEN" "$C_NC" "$*"; }
warn() { printf '%b[Warn]%b %s\n' "$C_YELLOW" "$C_NC" "$*" >&2; }
die()  { printf '%b[Error]%b %s\n' "$C_RED" "$C_NC" "$*" >&2; exit 1; }

resolve_language() {
  local requested="${1:-auto}" locale
  case "$requested" in
    auto)
      locale="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
      case "$locale" in zh*|ZH*) LANG_CODE="zh" ;; *) LANG_CODE="en" ;; esac
      ;;
    en|zh) LANG_CODE="$requested" ;;
    *) LANG_CODE="en" ;;
  esac
}

tr_msg() {
  local en="$1" zh="$2"
  [[ "$LANG_CODE" == zh ]] && printf '%s' "$zh" || printf '%s' "$en"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }
require_root() { [[ "$(id -u)" -eq 0 ]] || die "$(tr_msg "Run as root: sudo bash $0" "请以 root 权限运行: sudo bash $0")"; }
require_systemd() {
  has_cmd systemctl || die "$(tr_msg "systemctl is required." "缺少 systemctl。")"
  [[ -d /run/systemd/system ]] || die "$(tr_msg "systemd is not running." "systemd 未运行。")"
}
require_command() { has_cmd "$1" || die "$(tr_msg "Missing command: $1" "缺少命令: $1")"; }

cleanup_swap() {
  if awk -v p="$SWAP_FILE" 'NR>1 && $1==p {f=1} END{exit(f?0:1)}' /proc/swaps 2>/dev/null; then
    if ! { has_cmd swapoff && swapoff "$SWAP_FILE" 2>/dev/null; }; then
      warn "$(tr_msg "Could not deactivate temporary swap; leaving it in place." "临时 swap 无法卸载，保留文件避免误删活动 swap。")"
      return 1
    fi
  fi
  [[ "$BUILD_LOCK_HELD" -eq 1 ]] && rm -f -- "$SWAP_FILE" 2>/dev/null || true
}

release_build_lock() {
  if [[ "$BUILD_LOCK_HELD" -eq 1 ]]; then
    flock -u "$BUILD_LOCK_FD" || true
    exec {BUILD_LOCK_FD}>&-
    BUILD_LOCK_HELD=0
  fi
}

cleanup_all() {
  local rc=$? p
  trap - EXIT
  set +e
  if [[ "$TX_STARTED" == 1 && "$TX_COMMITTED" == 0 ]]; then rollback_transaction; fi
  for p in "${CLEANUP_PATHS[@]:-}"; do [[ -n "$p" ]] && rm -rf -- "$p" 2>/dev/null || true; done
  cleanup_swap || true
  release_build_lock
  exit "$rc"
}
trap cleanup_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

begin_transaction() {
  [[ "$TX_STARTED" == 1 ]] && return 0
  TX_DIR="$(mktemp -d)"; CLEANUP_PATHS+=("$TX_DIR")
  systemctl is-active --quiet "$SERVICE_NAME" && TX_ACTIVE=1 || true
  systemctl is-enabled --quiet "$SERVICE_NAME" && TX_ENABLED=1 || true
  TX_OLD_TARGET="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
  [[ ! -d "$CONFIG_DIR" ]] || cp -a "$CONFIG_DIR" "$TX_DIR/config"
  [[ ! -f "$UNIT_FILE" ]] || cp -a "$UNIT_FILE" "$TX_DIR/unit"
  [[ ! -f "$LAUNCHER" ]] || cp -a "$LAUNCHER" "$TX_DIR/launcher"
  TX_STARTED=1
}
rollback_transaction() {
  warn "$(tr_msg "V2 operation did not finish; restoring the previous config, service unit and binary link." "V2 操作未完成，恢复之前的配置、服务定义和二进制链接")"
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -rf -- "$CONFIG_DIR"
  [[ ! -d "$TX_DIR/config" ]] || cp -a "$TX_DIR/config" "$CONFIG_DIR"
  rm -f -- "$UNIT_FILE" "$LAUNCHER"
  [[ ! -f "$TX_DIR/unit" ]] || cp -a "$TX_DIR/unit" "$UNIT_FILE"
  [[ ! -f "$TX_DIR/launcher" ]] || cp -a "$TX_DIR/launcher" "$LAUNCHER"
  if [[ -n "$TX_OLD_TARGET" && -x "$TX_OLD_TARGET/nowhere" ]]; then
    ln -sfn "$TX_OLD_TARGET" "$CURRENT_LINK"; ln -sfn "$CURRENT_LINK/nowhere" "$BIN_LINK"
  else rm -f -- "$CURRENT_LINK" "$BIN_LINK"; fi
  systemctl daemon-reload
  if [[ "$TX_ENABLED" == 1 ]]; then systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  else systemctl disable "$SERVICE_NAME" >/dev/null 2>&1; fi
  if [[ "$TX_ACTIVE" == 1 ]]; then
    systemctl restart "$SERVICE_NAME" && wait_service 12 || warn "$(tr_msg "V2 service recovery failed; check the logs." "V2 服务恢复失败，请检查日志。")"
  fi
}

acquire_build_lock() {
  [[ "$BUILD_LOCK_HELD" -eq 1 ]] && return 0
  require_root; require_command flock
  exec {BUILD_LOCK_FD}>"${BUILD_LOCK_DIR%.d}"
  flock -n "$BUILD_LOCK_FD" || die "$(tr_msg "Another V2 management operation is running." "另一个 V2 管理操作正在运行。")"
  BUILD_LOCK_HELD=1
}

cleanup_stale_swap() {
  [[ "$BUILD_LOCK_HELD" -eq 1 ]] || die "$(tr_msg "Internal error: build lock required" "内部错误：需要构建锁")"
  [[ -e "$SWAP_FILE" ]] || return 0
  if awk -v p="$SWAP_FILE" 'NR>1 && $1==p {f=1} END{exit(f?0:1)}' /proc/swaps 2>/dev/null; then
    has_cmd swapoff || die "$(tr_msg "swapoff is required" "需要 swapoff")"
    swapoff "$SWAP_FILE" || die "$(tr_msg "Failed to deactivate stale swap" "无法关闭残留 swap")"
  fi
  rm -f -- "$SWAP_FILE" || die "$(tr_msg "Failed to remove stale swap" "无法删除残留 swap")"
}

pkg_manager() {
  local c
  for c in apt-get dnf yum apk zypper; do has_cmd "$c" && { printf '%s' "$c"; return 0; }; done
  return 1
}

install_runtime_deps() {
  local need=0 c pm
  for c in curl tar python3 sha256sum openssl timeout flock ss runuser; do has_cmd "$c" || need=1; done
  [[ "$need" -eq 0 ]] && return 0
  pm="$(pkg_manager)" || die "$(tr_msg "No supported package manager." "未找到受支持的软件包管理器。")"
  info "$(tr_msg "Installing runtime dependencies..." "正在安装运行依赖...")"
  case "$pm" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates tar python3 coreutils iproute2 openssl util-linux ;;
    dnf|yum) "$pm" install -y curl ca-certificates tar python3 coreutils iproute openssl util-linux ;;
    apk) apk add --no-cache curl ca-certificates tar python3 coreutils iproute2 openssl util-linux ;;
    zypper) zypper --non-interactive install curl ca-certificates tar python3 coreutils iproute2 openssl util-linux ;;
  esac
}

install_build_deps() {
  local need=0 pm
  has_cmd git || need=1; has_cmd cargo || need=1
  if ! has_cmd cc && ! has_cmd gcc && ! has_cmd clang; then need=1; fi
  [[ "$need" -eq 0 ]] && return 0
  pm="$(pkg_manager)" || die "$(tr_msg "No supported package manager." "未找到受支持的软件包管理器。")"
  case "$pm" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential git curl ca-certificates pkg-config ;;
    dnf|yum) "$pm" install -y gcc gcc-c++ make git curl ca-certificates pkgconf-pkg-config ;;
    apk) apk add --no-cache build-base git curl ca-certificates pkgconf ;;
    zypper) zypper --non-interactive install gcc gcc-c++ make git curl ca-certificates pkg-config ;;
  esac
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )) || die "$(tr_msg "Port must be 1-65535." "端口必须为 1-65535。")"
}
# Nowhere 2.2.x Portal listener / native next shared-key policy: 32-64 lowercase
# hex characters. 64 characters stays valid on an exact v2.2.0 pin as well,
# which is why random_key() generates 64; v2.2.1+ accepts 32-64.
is_valid_key_value() { [[ "$1" =~ ^[0-9a-f]{32,64}$ ]]; }
# An exact v2.2.0 pin is stricter than v2.2.1+: it requires exactly 64 hex
# characters. Unknown/unresolved versions (latest-v2, empty) stay permissive.
key_requires_64_hex() {
  local v="$1"
  [[ -n "$v" ]] && version_ge "$v" v2.2.0 && ! version_ge "$v" v2.2.1
}
validate_key() {
  is_valid_key_value "$1" || die "$(tr_msg "Portal/shared key must be 32-64 lowercase hex characters (Nowhere 2.2.0+; see 'nowhere generate-key')." "Portal/共享密钥必须为 32-64 位小写十六进制字符（Nowhere 2.2.0+ 规则；可用 'nowhere generate-key' 生成）。")"
  if key_requires_64_hex "$VERSION" && [[ ! "$1" =~ ^[0-9a-f]{64}$ ]]; then
    die "$(tr_msg "An exact v2.2.0 pin requires exactly 64 lowercase hex characters; use v2.2.1 or later for 32-character keys." "锁定到 v2.2.0 时密钥必须为恰好 64 位小写十六进制；如需 32 位密钥，请改用 v2.2.1 或更新版本。")"
  fi
}
# Vector is a client: upstream keeps accepting legacy 1-255 byte keys so a
# Vector can still reach a Portal that runs <=2.1. Keep that leniency for the
# Vector role, but never generate such keys here.
is_legacy_safe_key() { [[ "$1" =~ ^[A-Za-z0-9._~-]{1,255}$ ]]; }
validate_vector_key() {
  is_valid_key_value "$1" && return 0
  if is_legacy_safe_key "$1"; then
    warn "$(tr_msg "Non-hex Vector key accepted for compatibility with Nowhere <=2.1 Portals only; a 2.2.0+ Portal requires 32-64 lowercase hex characters." "已接受非十六进制 Vector 密钥，但仅兼容 Nowhere <=2.1 的 Portal；2.2.0+ Portal 要求 32-64 位小写十六进制字符。")"
    return 0
  fi
  die "$(tr_msg "Vector key must be 32-64 lowercase hex, or a legacy 1-255 safe URL key (<=2.1 Portal only)." "Vector 密钥必须为 32-64 位小写十六进制，或兼容 <=2.1 Portal 的 1-255 位安全 URL 字符。")"
}
validate_role() { [[ "$1" == portal || "$1" == vector ]] || die "$(tr_msg "role must be portal|vector" "role 必须为 portal|vector")"; }
validate_bool01() { [[ "$2" == 0 || "$2" == 1 ]] || die "$(tr_msg "${1} must be 0|1" "${1} 必须为 0|1")"; }
validate_mux() { [[ "$1" == 0 || "$1" == 1 ]] || die "$(tr_msg "mux must be 0|1" "mux 必须为 0|1")"; }
validate_tls() { [[ "$1" == 1 || "$1" == 2 ]] || die "$(tr_msg "tls must be 1|2" "tls 必须为 1|2")"; }
# 'event' was removed in Nowhere 2.1.1 and now fails service startup.
validate_log() { [[ "$1" =~ ^(none|debug|info|warn|error)$ ]] || die "$(tr_msg "invalid log level: ${1} (allowed: none|debug|info|warn|error; 'event' was removed in 2.1.1)" "无效的日志等级: ${1}（可选: none|debug|info|warn|error；'event' 已在 2.1.1 移除）")"; }
validate_rate() {
  [[ "$1" =~ ^[0-9]{1,10}$ ]] && ((10#$1 <= 2147483647)) || die "$(tr_msg "rate/etar must be an integer 0..2147483647 Mbps" "rate/etar 必须为 0..2147483647 的整数 Mbps")"
}
validate_keep_releases() { [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1>=0 && 10#$1<=20)) || die "$(tr_msg "keep-releases must be 0-20" "keep-releases 必须为 0-20")"; }
validate_config_mode() { [[ "$1" == ask || "$1" == quick || "$1" == advanced ]] || die "$(tr_msg "config-mode must be ask|quick|advanced" "config-mode 必须为 ask|quick|advanced")"; }
is_valid_memory_profile() { [[ "$1" == memory || "$1" == balanced || "$1" == throughput ]]; }
is_valid_morph_prelude() { [[ "$1" == low7 || "$1" == full8 ]]; }
validate_memory_profile() { is_valid_memory_profile "$1" || die "$(tr_msg "memory-profile must be memory|balanced|throughput" "memory-profile 必须为 memory|balanced|throughput")"; }
validate_morph_prelude() { is_valid_morph_prelude "$1" || die "$(tr_msg "morph-prelude must be low7|full8" "morph-prelude 必须为 low7|full8")"; }
validate_sni() { [[ "$1" == none || -z "$1" || "$1" =~ ^[A-Za-z0-9.-]+$ ]] || die "$(tr_msg "sni must be DNS name or none" "sni 必须为 DNS 域名或 none")"; }
validate_pin() { [[ "$1" == none || -z "$1" || "$1" =~ ^[A-Fa-f0-9]{64}$ ]] || die "$(tr_msg "pin must be none or 64 hex characters" "pin 必须为 none 或 64 位十六进制")"; }
validate_version_arg() {
  local v="$1"
  [[ "$v" == latest-v2 || "$v" =~ ^v2\.[0-9]+\.[0-9]+$ ]] || die "$(tr_msg "Version must be latest-v2 or an exact stable v2.x.y tag; v3.x (NW3) is not supported by this manager." "版本必须为 latest-v2 或明确的稳定版 v2.x.y 标签；v3.x（NW3 协议）不在本管理器支持范围内。")"
}

# Outbound source binding (Nowhere 2.2.0+): dial is mutually exclusive with
# dial4/dial6, and each value is 'auto' or a bare IP literal of its family.
is_valid_dial_ip() { # is_valid_dial_ip <any|4|6> <value>
  python3 - "$1" "$2" <<'PY' >/dev/null 2>&1
import ipaddress,sys
fam,v=sys.argv[1],sys.argv[2]
if not v or any(c in v for c in '%[]/ '): sys.exit(1)
try:
    if fam=='4': ipaddress.IPv4Address(v)
    elif fam=='6':
        a=ipaddress.IPv6Address(v)
        if a.ipv4_mapped is not None: sys.exit(1)
    else: ipaddress.ip_address(v)
except Exception: sys.exit(1)
PY
}
validate_dial_value() {
  local fam="$1" v="$2" name
  [[ "$v" == auto ]] && return 0
  case "$fam" in 4) name=dial4 ;; 6) name=dial6 ;; *) name=dial ;; esac
  is_valid_dial_ip "$fam" "$v" || die "$(tr_msg "${name} must be 'auto' or a bare IP literal of the matching family." "${name} 必须为 'auto' 或与地址族匹配的裸 IP 字面量。")"
}
validate_dial_settings() {
  validate_dial_value any "$DIAL"; validate_dial_value 4 "$DIAL4"; validate_dial_value 6 "$DIAL6"
  if [[ "$DIAL" != auto && -n "$DIAL" ]] && { [[ "$DIAL4" != auto && -n "$DIAL4" ]] || [[ "$DIAL6" != auto && -n "$DIAL6" ]]; }; then
    die "$(tr_msg "dial is mutually exclusive with dial4/dial6 (Nowhere 2.2.0+)." "dial 与 dial4/dial6 互斥（Nowhere 2.2.0+）。")"
  fi
}

# 64 hex characters so the key also satisfies an exact v2.2.0 pin (64 only);
# Nowhere v2.2.1+ accepts 32-64.
random_key() {
  python3 -c 'import secrets; print(secrets.token_hex(32))'
}

urlencode() {
  local s="${1:-}" out="" c i LC_ALL=C
  for ((i=0;i<${#s};i++)); do
    c="${s:i:1}"
    case "$c" in [A-Za-z0-9.~_-]) out+="$c" ;; *) printf -v c '%%%02X' "'$c"; out+="$c" ;; esac
  done
  printf '%s' "$out"
}

# Endpoint validator/canonicalizer for V2 grammar.
# Output: canonical<TAB>host<TAB>has_tcp<TAB>tcp_port<TAB>has_udp<TAB>udp_port
endpoint_info() {
  local role="$1" ep="$2"
  python3 - "$role" "$ep" <<'PY'
import ipaddress,re,sys
role,ep=sys.argv[1],sys.argv[2]
CARR={'tcp':('tcp',None),'tcp4':('tcp',4),'tcp6':('tcp',6),'udp':('udp',None),'udp4':('udp',4),'udp6':('udp',6)}
def fail(m): print(m,file=sys.stderr); sys.exit(2)
def port(v):
    if not re.fullmatch(r'[0-9]+',v or ''): fail('invalid port')
    try: n=int(v)
    except (ValueError,OverflowError): fail('invalid port')
    if not (1<=n<=65535): fail('invalid port')
    return n
def host_family(h):
    raw=h[1:-1] if h.startswith('[') and h.endswith(']') else h
    try: return ipaddress.ip_address(raw).version
    except ValueError: return None
def validate_host(h,allow_star):
    if h=='*':
        if not allow_star: fail('wildcard host is Portal-only')
        return
    if not h: fail('host is empty')
    if h.startswith('['):
        try: ipaddress.IPv6Address(h[1:-1])
        except ValueError: fail('invalid IPv6 literal')
    if any(ord(c)<33 for c in h): fail('invalid host')
    if ':' in h and not (h.startswith('[') and h.endswith(']')): fail('IPv6 literal must be bracketed')
    if not (h.startswith('[') and h.endswith(']')) and not re.fullmatch(r'[A-Za-z0-9._-]+',h): fail('invalid hostname')
allow_star=(role=='portal')
has_tcp=has_udp=False; tp=up=''; tfam=ufam='0'; host=''; canon=''
if '/' in ep:
    parts=ep.split('/')
    host=parts[0]; segs=parts[1:]
    validate_host(host,allow_star)
    if not segs or any(not s for s in segs) or len(segs)>2: fail('invalid carrier path')
    seen=set(); out=[]; fam=host_family(host)
    for s in segs:
        if ':' not in s: fail('carrier must be CARRIER:PORT')
        c,p=s.split(':',1)
        if c not in CARR: fail('unknown carrier')
        base,cfam=CARR[c]
        if base in seen: fail('duplicate carrier family')
        seen.add(base); pv=port(p)
        if fam and cfam and fam!=cfam: fail('carrier address family conflicts with IP literal')
        efffam=cfam or fam or 0
        if base=='tcp': has_tcp=True; tp=str(pv); tfam=str(efffam); out.append((0,c,pv))
        else: has_udp=True; up=str(pv); ufam=str(efffam); out.append((1,c,pv))
    out.sort()
    canon=host+''.join('/%s:%d'%(c,p) for _,c,p in out)
else:
    if ep.startswith('['):
        m=re.fullmatch(r'(\[[^\]]+\]):([0-9]+)',ep)
        if not m: fail('invalid bracketed compact endpoint')
        host=m.group(1); p=port(m.group(2))
    else:
        if ':' not in ep: fail('compact endpoint must be HOST:PORT')
        host,praw=ep.rsplit(':',1)
        if ':' in host: fail('IPv6 literal must be bracketed')
        if not host and role=='portal': host='*'
        validate_host(host,allow_star)
        p=port(praw)
    validate_host(host,allow_star)
    has_tcp=has_udp=True; tp=up=str(p); canon=f'{host}:{p}'
    fam=host_family(host) or 0; tfam=ufam=str(fam)
if role!='portal' and host=='*': fail('wildcard host is not dialable')
print('\t'.join([canon,host,'1' if has_tcp else '0',tp,'1' if has_udp else '0',up,tfam,ufam]))
PY
}

endpoint_canonical() { endpoint_info "$1" "$2" | awk -F '\t' '{print $1}'; }
endpoint_has_tcp() { endpoint_info "$1" "$2" | awk -F '\t' '{print $3}'; }
endpoint_tcp_port() { endpoint_info "$1" "$2" | awk -F '\t' '{print $4}'; }
endpoint_has_udp() { endpoint_info "$1" "$2" | awk -F '\t' '{print $5}'; }
endpoint_udp_port() { endpoint_info "$1" "$2" | awk -F '\t' '{print $6}'; }
endpoint_tcp_family() { endpoint_info "$1" "$2" | awk -F '\t' '{print $7}'; }
endpoint_udp_family() { endpoint_info "$1" "$2" | awk -F '\t' '{print $8}'; }
endpoint_host() { endpoint_info "$1" "$2" | awk -F '\t' '{print $2}'; }

endpoint_default_policy() {
  local role="$1" ep="$2" ht hu
  ht="$(endpoint_has_tcp "$role" "$ep")"; hu="$(endpoint_has_udp "$role" "$ep")"
  if [[ "$ht" == 1 && "$hu" == 0 ]]; then printf tcp
  elif [[ "$ht" == 0 && "$hu" == 1 ]]; then printf udp
  else printf tcp
  fi
}

endpoint_replace_host() {
  local role="$1" ep="$2" newhost="$3"
  python3 - "$role" "$ep" "$newhost" <<'PY'
import re,sys
role,ep,new=sys.argv[1:]
if ':' in new and not (new.startswith('[') and new.endswith(']')): new='['+new+']'
if '/' in ep:
    print(new+ep[ep.find('/'):],end='')
else:
    if ep.startswith('['):
        m=re.fullmatch(r'\[[^\]]+\]:([0-9]+)',ep); print(f'{new}:{m.group(1)}',end='')
    else:
        print(f'{new}:{ep.rsplit(":",1)[1]}',end='')
PY
}

query_get() {
  python3 - "$1" "$2" <<'PY'
import sys,urllib.parse
u=urllib.parse.urlsplit(sys.argv[1]); key=sys.argv[2]
for k,v in urllib.parse.parse_qsl(u.query,keep_blank_values=True):
    if k==key:
        print(v,end=''); break
PY
}

query_has() {
  python3 - "$1" "$2" <<'PY'
import sys,urllib.parse
try: u=urllib.parse.urlsplit(sys.argv[1])
except ValueError: sys.exit(1)
key=sys.argv[2]
sys.exit(0 if any(k==key for k,_ in urllib.parse.parse_qsl(u.query,keep_blank_values=True)) else 1)
PY
}

url_role() { python3 - "$1" <<'PY'
import sys,urllib.parse
print(urllib.parse.urlsplit(sys.argv[1]).scheme,end='')
PY
}
url_key() { python3 - "$1" <<'PY'
import sys,urllib.parse
u=urllib.parse.urlsplit(sys.argv[1]); print(urllib.parse.unquote(u.username or ''),end='')
PY
}
url_endpoint() {
  python3 - "$1" <<'PY'
import sys,urllib.parse
try:
    u=urllib.parse.urlsplit(sys.argv[1])
    h=u.hostname or ''
    p=u.port
except ValueError as e:
    print(f'invalid URL endpoint: {e}',file=sys.stderr); sys.exit(2)
if ':' in h: h='['+h+']'
if p is not None: print(f'{h}:{p}',end='')
else: print(h+(u.path or ''),end='')
PY
}

validate_socks_endpoint() {
  local v="$1"
  if ! python3 - "$v" <<'PY'
import re,sys,urllib.parse
s=sys.argv[1]
if not s or s=='none': sys.exit(2)
# Strip optional credentials from the last @.
d=s.rsplit('@',1)[-1]
if d.startswith('['): m=re.fullmatch(r'\[[^\]]+\]:([0-9]+)',d)
else:
    if d.count(':')!=1: sys.exit(2)
    m=re.fullmatch(r'[^:]*:([0-9]+)',d)
if not m or not (1<=int(m.group(1))<=65535): sys.exit(2)
PY
  then
    die "$(tr_msg "Invalid SOCKS endpoint" "无效的 SOCKS 端点")"
  fi
}

validate_next_endpoint() {
  local v="$1" keypart ep LC_ALL=C
  # Upstream splits on the last '@' and rejects a second one in the key
  # (vector/config.rs: "reserved shared-key characters must be percent-encoded").
  [[ "$v" != *@*@* ]] || die "$(tr_msg "next must contain exactly one '@'; percent-encode '@' in the shared key as %40" "next 必须只包含一个 '@'；共享密钥中的 '@' 请编码为 %40")"
  [[ "$v" == *@* ]] || die "$(tr_msg "next must be KEY@ENDPOINT" "next 必须为 KEY@ENDPOINT")"
  keypart="${v%@*}"; ep="${v##*@}"
  # Nowhere 2.2.0+ validates the nested key like the Portal listener key; a
  # legacy character set would make the outer Portal refuse to start.
  is_valid_key_value "$keypart" || die "$(tr_msg "next key must be 32-64 lowercase hex characters (Nowhere 2.2.0+)." "next 密钥必须为 32-64 位小写十六进制字符（Nowhere 2.2.0+）。")"
  if key_requires_64_hex "$VERSION" && [[ ! "$keypart" =~ ^[0-9a-f]{64}$ ]]; then
    die "$(tr_msg "next key must be exactly 64 lowercase hex characters on an exact v2.2.0 core." "在 v2.2.0 内核上，next 密钥必须为恰好 64 位小写十六进制。")"
  fi
  endpoint_info vector "$ep" >/dev/null || die "$(tr_msg "Invalid next endpoint" "无效的 next 端点")"
}

validate_policy_against_endpoint() {
  local role="$1" ep="$2" p="$3" ht hu
  [[ "$p" == auto ]] && return 0
  ht="$(endpoint_has_tcp "$role" "$ep")"; hu="$(endpoint_has_udp "$role" "$ep")"
  case "$p" in
    tcp) [[ "$ht" == 1 ]] || die "$(tr_msg "TCP policy selected but endpoint has no TCP carrier" "选择了 TCP 策略，但端点没有 TCP carrier")" ;;
    udp) [[ "$hu" == 1 ]] || die "$(tr_msg "UDP policy selected but endpoint has no UDP carrier" "选择了 UDP 策略，但端点没有 UDP carrier")" ;;
    mix) [[ "$ht" == 1 && "$hu" == 1 ]] || die "$(tr_msg "mix requires both TCP and UDP carriers" "mix 需要同时具备 TCP 和 UDP carrier")" ;;
    *) die "$(tr_msg "invalid policy: ${p}" "无效的策略: ${p}")" ;;
  esac
}

validate_imported_url() {
  local u="$1" ver="${2:-}"
  if ! python3 - "$u" "$ver" <<'PY'
import ipaddress,re,sys,urllib.parse
raw=sys.argv[1]
# An exact v2.2.0 pin accepts only 64-character keys; v2.2.1+ accepts 32-64.
strict64 = (sys.argv[2] if len(sys.argv)>2 else '')=='v2.2.0'
def fail(m): print(m,file=sys.stderr); sys.exit(2)
if '\n' in raw or '\r' in raw: fail('URL contains newline')
for m in re.finditer('%',raw):
    if m.start()+2>=len(raw) or not re.fullmatch(r'[0-9A-Fa-f]{2}',raw[m.start()+1:m.start()+3]): fail('malformed percent-encoding')
try: u=urllib.parse.urlsplit(raw)
except ValueError as e: fail(f'invalid URL: {e}')
if u.scheme not in ('portal','vector'): fail('scheme must be portal or vector')
if u.fragment: fail('fragments are not valid run configuration')
if u.password is not None: fail('password userinfo is invalid')
try: key=urllib.parse.unquote_to_bytes(u.username or '')
except Exception: fail('bad shared-key encoding')
# Portal listener keys follow the strict 2.2.x policy; Vector keeps the
# documented 1-255 byte client leniency so it can still reach <=2.1 Portals.
if u.scheme=='portal':
    try: key_text=key.decode('ascii')
    except Exception: fail('Portal shared key must be 32-64 lowercase hex characters')
    if strict64:
        if not re.fullmatch(r'[0-9a-f]{64}',key_text): fail('Portal shared key must be exactly 64 lowercase hex characters on an exact v2.2.0 core')
    elif not re.fullmatch(r'[0-9a-f]{32,64}',key_text): fail('Portal shared key must be 32-64 lowercase hex characters')
else:
    if not (1<=len(key)<=255): fail('shared key must be 1..255 bytes')
if b'\n' in key or b'\r' in key or b'\x00' in key: fail('shared key contains unsafe control bytes')
try:
    h=u.hostname or ''
    parsed_port=u.port
except ValueError as e:
    fail(f'invalid authority/port: {e}')
if ':' in h: h='['+h+']'
if parsed_port is not None:
    if u.path not in ('','/'): fail('compact port and carrier path cannot be combined')
    ep=f'{h}:{parsed_port}'
else:
    ep=h+(u.path or '')
if not ep: fail('missing endpoint')
# Match Nowhere v2.2.x exactly: recognized query keys use first occurrence;
# later duplicates and unknown keys are ignored by the core.
q={}
for k,v in urllib.parse.parse_qsl(u.query,keep_blank_values=True):
    q.setdefault(k,v)
# Unknown query keys follow upstream first-wins/ignore semantics.
# Preserve them so a newer V2 core can remain forward-compatible.
def oneof(k,vals,default=None):
    v=q.get(k,default)
    if v is not None and v not in vals: fail(f'invalid {k}')
    return v
def rate(k):
    v=q.get(k,'0')
    if not re.fullmatch(r'[0-9]{1,10}',v) or int(v)>2147483647: fail(f'invalid {k}')
def dialval(k,fam):
    v=q.get(k)
    if v is None or v=='auto': return
    if any(c in v for c in '%[]/ '): fail(f'invalid {k}')
    try:
        if fam=='4': ipaddress.IPv4Address(v)
        elif fam=='6':
            a=ipaddress.IPv6Address(v)
            if a.ipv4_mapped is not None: fail(f'invalid {k}')
        else: ipaddress.ip_address(v)
    except Exception: fail(f'invalid {k}')
rate('rate'); rate('etar')
# 'event' was removed in Nowhere 2.1.1 and now fails service startup.
oneof('morph',{'0','1'},'0'); oneof('mux',{'0','1'},'0'); oneof('log',{'none','debug','info','warn','error'},'info')
# Nowhere 2.2.0: dial is mutually exclusive with dial4/dial6.
dialval('dial','any'); dialval('dial4','4'); dialval('dial6','6')
if 'dial' in q and ('dial4' in q or 'dial6' in q): fail('dial conflicts with dial4/dial6')
for k in ('up','down'):
    if k in q and q[k] not in ('tcp','udp','mix'): fail(f'invalid {k}')
pin=q.get('pin','none')
if pin not in ('','none') and not re.fullmatch(r'[0-9A-Fa-f]{64}',pin): fail('invalid pin')
sni=q.get('sni','none')
if sni not in ('','none') and not re.fullmatch(r'[A-Za-z0-9.-]+',sni): fail('invalid sni')
if u.scheme=='portal':
    oneof('tls',{'1','2'},'1')
    if q.get('tls','1')=='2' and (not q.get('crt') or not q.get('key')): fail('tls=2 requires crt and key')
    if q.get('socks') and q.get('next'): fail('socks and next are mutually exclusive')
    if q.get('next'):
        nv=q['next']
        if '@' not in nv: fail('next must be KEY@ENDPOINT')
        nk,ne=nv.rsplit('@',1)
        if not nk or not ne or '*' in ne: fail('invalid next endpoint')
        if strict64:
            if not re.fullmatch(r'[0-9a-f]{64}',nk): fail('next shared key must be exactly 64 lowercase hex characters on an exact v2.2.0 core')
        elif not re.fullmatch(r'[0-9a-f]{32,64}',nk): fail('next shared key must be 32-64 lowercase hex characters')
else:
    if not q.get('socks'): fail('Vector requires socks=')
PY
  then
    die "$(tr_msg "Invalid V2 URL." "V2 URL 无效。")"
  fi
  query_has "$u" net && warn "$(tr_msg "net= is ignored by Nowhere V2; endpoint carriers control TCP/UDP availability." "Nowhere V2 会忽略 net=；TCP/UDP 可用性由端点的 carrier 决定。")"
  query_has "$u" alpn && warn "$(tr_msg "alpn= is ignored by Nowhere V2; V2 always uses fixed ALPN nw2." "Nowhere V2 会忽略 alpn=；V2 固定使用 ALPN nw2。")"
  local role ep up down
  role="$(url_role "$u")"; ep="$(url_endpoint "$u")"
  endpoint_info "$role" "$ep" >/dev/null || die "$(tr_msg "Invalid V2 endpoint" "无效的 V2 端点")"
  up="$(query_get "$u" up)"; down="$(query_get "$u" down)"
  [[ -z "$up" ]] || validate_policy_against_endpoint "$role" "$ep" "$up"
  [[ -z "$down" ]] || validate_policy_against_endpoint "$role" "$ep" "$down"
  if [[ "$role" == portal ]]; then
    local nx socks
    nx="$(query_get "$u" next)"; socks="$(query_get "$u" socks)"
    [[ -z "$nx" ]] || validate_next_endpoint "$nx"
    [[ -z "$socks" ]] || validate_socks_endpoint "$socks"
  else
    validate_socks_endpoint "$(query_get "$u" socks)"
  fi
}

build_portal_url() {
  validate_key "$KEY"; validate_tls "$TLS"; validate_bool01 morph "$MORPH"; validate_rate "$RATE"; validate_rate "$ETAR"; validate_log "$LOG_LEVEL"
  validate_dial_settings
  ENDPOINT="$(endpoint_canonical portal "$ENDPOINT")"
  local q="tls=${TLS}&morph=${MORPH}" eff_up eff_down eff_mux
  [[ "$RATE" == 0 ]] || q+="&rate=${RATE}"
  [[ "$ETAR" == 0 ]] || q+="&etar=${ETAR}"
  # Nowhere 2.2.0+ dual-stack source binding: emit dial4/dial6 only; a
  # non-auto dial already excludes them (validated above). 'auto' stays omitted.
  if [[ "$DIAL" == auto || -z "$DIAL" ]]; then
    [[ "$DIAL4" == auto || -z "$DIAL4" ]] || q+="&dial4=$(urlencode "$DIAL4")"
    [[ "$DIAL6" == auto || -z "$DIAL6" ]] || q+="&dial6=$(urlencode "$DIAL6")"
  else
    q+="&dial=$(urlencode "$DIAL")"
  fi
  [[ "$LOG_LEVEL" == info ]] || q+="&log=${LOG_LEVEL}"
  if [[ "$TLS" == 2 ]]; then
    [[ -f "$CERT" && -f "$TLS_KEY" ]] || die "$(tr_msg "tls=2 requires existing cert/key files" "tls=2 需要已存在的证书/私钥文件")"
    q+="&crt=$(urlencode "$CERT")&key=$(urlencode "$TLS_KEY")"
  fi
  [[ "$OUT_SOCKS" == none || "$NEXT" == none ]] || die "$(tr_msg "socks= and next= are mutually exclusive" "socks= 与 next= 互斥")"
  if [[ "$OUT_SOCKS" != none && -n "$OUT_SOCKS" ]]; then
    validate_socks_endpoint "$OUT_SOCKS"; q+="&socks=$(urlencode "$OUT_SOCKS")"
  elif [[ "$NEXT" != none && -n "$NEXT" ]]; then
    validate_next_endpoint "$NEXT"
    local next_ep="${NEXT##*@}"
    eff_up="$UP"; eff_down="$DOWN"
    [[ "$eff_up" == auto ]] && eff_up="$(endpoint_default_policy vector "$next_ep")"
    [[ "$eff_down" == auto ]] && eff_down="$(endpoint_default_policy vector "$next_ep")"
    validate_policy_against_endpoint vector "$next_ep" "$eff_up"
    validate_policy_against_endpoint vector "$next_ep" "$eff_down"
    validate_mux "$MUX"; validate_sni "$SNI"; validate_pin "$PIN"
    eff_mux="$MUX"; [[ "$eff_up" == udp && "$eff_down" == udp ]] && eff_mux=0
    q+="&next=$(urlencode "$NEXT")&up=${eff_up}&down=${eff_down}&mux=${eff_mux}"
    [[ "$SNI" == none || -z "$SNI" ]] || q+="&sni=$(urlencode "$SNI")"
    [[ "$PIN" == none || -z "$PIN" ]] || q+="&pin=${PIN}"
  fi
  printf 'portal://%s@%s?%s' "$(urlencode "$KEY")" "$ENDPOINT" "$q"
}

build_vector_url() {
  validate_vector_key "$KEY"; validate_bool01 morph "$MORPH"; validate_rate "$RATE"; validate_rate "$ETAR"; validate_log "$LOG_LEVEL"
  validate_mux "$MUX"; validate_sni "$SNI"; validate_pin "$PIN"; validate_socks_endpoint "$VECTOR_SOCKS"
  ENDPOINT="$(endpoint_canonical vector "$ENDPOINT")"
  local eup="$UP" edown="$DOWN" emux="$MUX" q
  [[ "$eup" == auto ]] && eup="$(endpoint_default_policy vector "$ENDPOINT")"
  [[ "$edown" == auto ]] && edown="$(endpoint_default_policy vector "$ENDPOINT")"
  validate_policy_against_endpoint vector "$ENDPOINT" "$eup"
  validate_policy_against_endpoint vector "$ENDPOINT" "$edown"
  [[ "$eup" == udp && "$edown" == udp ]] && emux=0
  q="up=${eup}&down=${edown}&mux=${emux}&morph=${MORPH}&socks=$(urlencode "$VECTOR_SOCKS")"
  [[ "$SNI" == none || -z "$SNI" ]] || q+="&sni=$(urlencode "$SNI")"
  [[ "$PIN" == none || -z "$PIN" ]] || q+="&pin=${PIN}"
  [[ "$RATE" == 0 ]] || q+="&rate=${RATE}"
  [[ "$ETAR" == 0 ]] || q+="&etar=${ETAR}"
  [[ "$LOG_LEVEL" == info ]] || q+="&log=${LOG_LEVEL}"
  printf 'vector://%s@%s?%s' "$(urlencode "$KEY")" "$ENDPOINT" "$q"
}

prompt() {
  local p="$1" d="${2:-}" v
  if [[ -n "$d" ]]; then read -r -p "$p [$d]: " v </dev/tty || v=""; printf '%s' "${v:-$d}"
  else read -r -p "$p: " v </dev/tty || v=""; printf '%s' "$v"; fi
}
prompt_yes() {
  local p="$1" a
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  read -r -p "$p [Y/n]: " a </dev/tty || a=""
  [[ -z "$a" || "$a" =~ ^[Yy]([Ee][Ss])?$ ]]
}
prompt_confirm() {
  local p="$1" a
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  read -r -p "$p [y/N]: " a </dev/tty || a=""
  [[ "$a" =~ ^[Yy]([Ee][Ss])?$ ]]
}
prompt_choice() {
  local p="$1" d="$2" input v; shift 2
  while true; do
    # A failed read means there is no usable terminal. Never spin in that case:
    # accept a valid default, otherwise stop and say which value was rejected.
    if ! read -r -p "$p [$d]: " input </dev/tty 2>/dev/null; then
      for v in "$@"; do [[ "$d" == "$v" ]] && { printf '%s' "$d"; return 0; }; done
      die "$(tr_msg "No terminal available to answer '${p}', and '${d}' is not a valid choice (allowed: $*)." "无可用终端回答「${p}」，且 '${d}' 不是有效选项（可选: $*）。")"
    fi
    input="${input:-$d}"
    for v in "$@"; do [[ "$input" == "$v" ]] && { printf '%s' "$input"; return 0; }; done
    warn "$(tr_msg "Invalid choice. Allowed: $*" "无效选项，可选: $*")"
  done
}
# A 2.2.x policy key is always accepted. Legacy safe keys are accepted only for
# the Vector role (client-side leniency, matching upstream), with a warning.
key_acceptable() {
  local v="$1"
  if is_valid_key_value "$v"; then
    if key_requires_64_hex "$VERSION" && [[ ! "$v" =~ ^[0-9a-f]{64}$ ]]; then
      warn "$(tr_msg "An exact v2.2.0 core requires a 64-character key; 32-character keys need v2.2.1 or later." "锁定到 v2.2.0 的内核要求 64 位密钥；32 位密钥需要 v2.2.1 及以上。")"
      return 1
    fi
    return 0
  fi
  if [[ "$ROLE" == vector ]] && [[ "$v" =~ ^[A-Za-z0-9._~-]{16,255}$ ]]; then
    warn "$(tr_msg "Non-hex key accepted for the Vector role only; a 2.2.0+ Portal requires 32-64 lowercase hex characters." "非十六进制密钥仅在 Vector 角色下被接受；2.2.0+ Portal 要求 32-64 位小写十六进制字符。")"
    return 0
  fi
  return 1
}
prompt_key() {
  local d="${KEY:-$(random_key)}" v
  while true; do
    # Same rule as prompt_choice: no terminal must never mean an endless loop.
    if ! read -r -p "$(tr_msg "Shared key" "共享密钥") [$d]: " v </dev/tty 2>/dev/null; then
      key_acceptable "$d" ||
        die "$(tr_msg "No terminal available to enter a valid shared key." "无可用终端输入合法共享密钥。")"
      KEY="$d"; return 0
    fi
    v="${v:-$d}"
    if key_acceptable "$v"; then KEY="$v"; return 0; fi
    warn "$(tr_msg "Key must be 32-64 lowercase hex characters (Portal), or 16-255 safe URL characters for the Vector role." "密钥必须为 32-64 位小写十六进制字符（Portal）；Vector 角色也可用 16-255 位安全 URL 字符。")"
  done
}

choose_endpoint_portal() {
  local mode p1 p2 custom
  printf '\n%s\n' "$(tr_msg "V2 Portal endpoint preset:" "V2 Portal 监听端点预设：")"
  printf '  1) %s\n' "$(tr_msg "TCP + UDP, shared port (recommended)" "TCP + UDP 共用端口（推荐）")"
  printf '  2) %s\n  3) %s\n  4) %s\n  5) %s\n' "$(tr_msg "TCP only" "仅 TCP")" "$(tr_msg "UDP only" "仅 UDP")" "$(tr_msg "TCP + UDP split ports" "TCP + UDP 分开端口")" "$(tr_msg "Manual V2 endpoint" "手动输入 V2 endpoint")"
  mode="$(prompt_choice "$(tr_msg "Choice" "选择")" 1 1 2 3 4 5)"
  p1="$(prompt "$(tr_msg "Primary port" "主端口")" "$DEFAULT_PORT")"; validate_port "$p1"
  case "$mode" in
    1) ENDPOINT="*:${p1}" ;;
    2) ENDPOINT="*/tcp:${p1}" ;;
    3) ENDPOINT="*/udp:${p1}" ;;
    4) p2="$(prompt "$(tr_msg "UDP port" "UDP 端口")" "$((10#$p1+1))")"; validate_port "$p2"; ENDPOINT="*/tcp:${p1}/udp:${p2}" ;;
    5) custom="$(prompt "$(tr_msg "Endpoint (e.g. */tcp4:2006/udp6:2017)" "Endpoint（例如 */tcp4:2006/udp6:2017）")" "*:${p1}")"; ENDPOINT="$custom" ;;
  esac
  ENDPOINT="$(endpoint_canonical portal "$ENDPOINT")"
}

choose_endpoint_vector() {
  local host mode p1 p2 custom
  host="$(prompt "$(tr_msg "Portal host/domain" "Portal 地址/域名")" "127.0.0.1")"
  printf '\n%s\n' "$(tr_msg "Remote carrier preset:" "远端载波预设：")"
  printf '  1) %s\n  2) %s\n  3) %s\n  4) %s\n  5) %s\n' "$(tr_msg "TCP + UDP shared port" "TCP + UDP 共用端口")" "$(tr_msg "TCP only" "仅 TCP")" "$(tr_msg "UDP only" "仅 UDP")" "$(tr_msg "TCP + UDP split ports" "TCP + UDP 分开端口")" "$(tr_msg "Manual V2 endpoint" "手动输入 V2 endpoint")"
  mode="$(prompt_choice "$(tr_msg "Choice" "选择")" 1 1 2 3 4 5)"
  p1="$(prompt "$(tr_msg "Portal port" "Portal 端口")" "$DEFAULT_PORT")"; validate_port "$p1"
  case "$mode" in
    1) ENDPOINT="${host}:${p1}" ;;
    2) ENDPOINT="${host}/tcp:${p1}" ;;
    3) ENDPOINT="${host}/udp:${p1}" ;;
    4) p2="$(prompt "$(tr_msg "UDP port" "UDP 端口")" "$((10#$p1+1))")"; validate_port "$p2"; ENDPOINT="${host}/tcp:${p1}/udp:${p2}" ;;
    5) custom="$(prompt "Endpoint" "${host}:${p1}")"; ENDPOINT="$custom" ;;
  esac
  ENDPOINT="$(endpoint_canonical vector "$ENDPOINT")"
}

choose_policy() {
  local ep="$1" role="$2" p
  if [[ "$(endpoint_has_tcp "$role" "$ep")" == 1 && "$(endpoint_has_udp "$role" "$ep")" == 1 ]]; then
    printf '\n1) %s\n2) udp/udp\n3) mix/mix\n4) udp/tcp\n5) tcp/udp\n' "$(tr_msg "tcp/tcp (V2 default)" "tcp/tcp（V2 默认）")"
    p="$(prompt_choice "$(tr_msg "Traffic policy" "流量策略")" 1 1 2 3 4 5)"
    case "$p" in 1) UP=tcp; DOWN=tcp ;; 2) UP=udp; DOWN=udp ;; 3) UP=mix; DOWN=mix ;; 4) UP=udp; DOWN=tcp ;; 5) UP=tcp; DOWN=udp ;; esac
  elif [[ "$(endpoint_has_tcp "$role" "$ep")" == 1 ]]; then UP=tcp; DOWN=tcp
  else UP=udp; DOWN=udp
  fi
}

quick_wizard() {
  ROLE="$(prompt_choice "$(tr_msg "Role portal/vector" "角色 portal/vector")" "$ROLE" portal vector)"
  prompt_key
  if [[ "$ROLE" == portal ]]; then
    choose_endpoint_portal
    TLS="$(prompt_choice "$(tr_msg "TLS mode 1=self-signed, 2=PEM" "TLS 模式 1=自签名，2=PEM 证书")" "${TLS:-1}" 1 2)"
    if [[ "$TLS" == 2 ]]; then
      CERT="$(prompt "$(tr_msg "Certificate PEM" "证书 PEM 文件")" "$CERT")"
      TLS_KEY="$(prompt "$(tr_msg "Private key PEM" "私钥 PEM 文件")" "$TLS_KEY")"
      if prompt_yes "$(tr_msg         "Copy cert/key into the V2-managed TLS directory so the service user can read them (recommended)"         "是否将证书/私钥复制到 V2 专用 TLS 目录，确保服务账户可读取（推荐）")"; then
        COPY_CERT=1
      else
        COPY_CERT=0
      fi
    fi
    MORPH="$(prompt_choice "$(tr_msg "Morph wire masking 0=off,1=on" "Morph 线路伪装 0=关闭，1=开启")" "${MORPH:-0}" 0 1)"
    PUBLIC_HOST="$(prompt "$(tr_msg "Public host for client link (optional)" "用于生成客户端链接的公网域名/IP（可留空）")" "$PUBLIC_HOST")"
    choose_policy "$ENDPOINT" portal
    CLIENT_UP="$UP"; CLIENT_DOWN="$DOWN"; CLIENT_MUX=0
  else
    choose_endpoint_vector
    VECTOR_SOCKS="$(prompt "$(tr_msg "Local SOCKS5 listen" "本地 SOCKS5 监听地址")" "$VECTOR_SOCKS")"; validate_socks_endpoint "$VECTOR_SOCKS"
    choose_policy "$ENDPOINT" vector
    if [[ "$UP" != udp || "$DOWN" != udp ]]; then MUX="$(prompt_choice "$(tr_msg "TLS Mux 0/1" "TLS Mux 复用 0/1")" "${MUX:-0}" 0 1)"; else MUX=0; fi
    MORPH="$(prompt_choice "$(tr_msg "Morph 0/1 (must match Portal)" "Morph 0/1（必须与 Portal 一致）")" "${MORPH:-0}" 0 1)"
    SNI="$(prompt "$(tr_msg "SNI (none or DNS name)" "SNI（none 或 DNS 域名）")" "$SNI")"
    PIN="$(prompt "$(tr_msg "Certificate SHA-256 pin (none or 64 hex)" "证书 SHA-256 pin（none 或 64 位十六进制）")" "$PIN")"
  fi
}

advanced_wizard() {
  quick_wizard
  RATE="$(prompt "$(tr_msg "Rate Mbps, 0=unlimited" "正向速率 Mbps，0=不限速")" "$RATE")"
  ETAR="$(prompt "$(tr_msg "Reverse rate Mbps, 0=unlimited" "反向速率 Mbps，0=不限速")" "$ETAR")"
  LOG_LEVEL="$(prompt_choice "$(tr_msg "Log level" "日志等级")" "$LOG_LEVEL" none debug info warn error)"
  MEMORY_PROFILE="$(prompt_choice "$(tr_msg "Transport memory profile" "传输内存模式")" "$MEMORY_PROFILE" memory balanced throughput)"
  MORPH_PRELUDE="$(prompt_choice "$(tr_msg "TCP Morph prelude policy (full8=default, low7=7-bit)" "TCP Morph prelude 策略（full8=默认，low7=7 位）")" "$MORPH_PRELUDE" low7 full8)"
  if [[ "$ROLE" == portal ]]; then
    DIAL="$(prompt "$(tr_msg "Source dial IP or auto" "出站源 IP 或 auto")" "$DIAL")"
    if [[ "$DIAL" == auto || -z "$DIAL" ]]; then
      # Nowhere 2.2.0+ dual-stack source binding; dial is mutually exclusive.
      DIAL4="$(prompt "$(tr_msg "IPv4 source dial4 (auto or IPv4)" "IPv4 出站源 dial4（auto 或 IPv4）")" "$DIAL4")"
      DIAL6="$(prompt "$(tr_msg "IPv6 source dial6 (auto or IPv6)" "IPv6 出站源 dial6（auto 或 IPv6）")" "$DIAL6")"
    else
      DIAL4=auto; DIAL6=auto
    fi
    local mode
    printf '\n1) %s\n2) %s\n3) %s\n' "$(tr_msg "Direct outbound" "直接出站")" "$(tr_msg "SOCKS5 outbound" "通过 SOCKS5 出站")" "$(tr_msg "Native V2 next Portal" "原生 V2 next Portal")"
    mode="$(prompt_choice "$(tr_msg "Outbound" "出站方式")" 1 1 2 3)"
    case "$mode" in
      1) OUT_SOCKS=none; NEXT=none ;;
      2) OUT_SOCKS="$(prompt "$(tr_msg "SOCKS5 upstream" "上游 SOCKS5")" "127.0.0.1:1080")"; NEXT=none ;;
      3)
        NEXT="$(prompt "$(tr_msg "next= KEY@HOST/CARRIER:PORT" "next= KEY@HOST/CARRIER:PORT")" "$NEXT")"; OUT_SOCKS=none
        validate_next_endpoint "$NEXT"
        choose_policy "${NEXT##*@}" vector
        [[ "$UP" == udp && "$DOWN" == udp ]] && MUX=0 || MUX="$(prompt_choice "$(tr_msg "Next-hop TLS Mux 0/1" "下一跳 TLS Mux 0/1")" "$MUX" 0 1)"
        SNI="$(prompt "$(tr_msg "Next-hop SNI" "下一跳 SNI")" "$SNI")"; PIN="$(prompt "$(tr_msg "Next-hop pin" "下一跳 pin")" "$PIN")"
        ;;
    esac
  fi
}

load_q() {
  local _v
  _v="$(query_get "$1" "$2")"
  [[ -z "$_v" ]] || printf -v "$3" '%s' "$_v"
}

load_existing_config() {
  [[ -s "$URL_FILE" ]] || return 0
  local u probe
  IFS= read -r u <"$URL_FILE" || return 0
  if ! ( validate_imported_url "$u" ) >/dev/null 2>&1; then
    # The usual reason is a pre-2.2 shared key. Keep the other settings so the
    # wizard can prefill them, but leave the key unloaded so a new one is entered.
    # Any other validation failure still loads nothing.
    probe="$(python3 - "$u" <<'PY'
import sys,urllib.parse
u=urllib.parse.urlsplit(sys.argv[1])
hostport=u.netloc.rsplit('@',1)[-1]
print(urllib.parse.urlunsplit((u.scheme,'0'*32+'@'+hostport,u.path,u.query,'')),end='')
PY
)" || return 0
    ( validate_imported_url "$probe" ) >/dev/null 2>&1 || return 0
    warn "$(tr_msg \
      "The saved shared key is not 32-64 lowercase hex, so it was not loaded; other settings are kept. Enter a new key (Enter generates one) and update every peer on that hop." \
      "已保存的共享密钥不是 32-64 位小写十六进制，未载入；其它设置已保留。请输入新密钥（回车自动生成），并同步更新该跳的所有对端。")"
    ROLE="$(url_role "$u")"; ENDPOINT="$(url_endpoint "$u")"
  else
    ROLE="$(url_role "$u")"; KEY="$(url_key "$u")"; ENDPOINT="$(url_endpoint "$u")"
  fi
  load_q "$u" tls TLS
  load_q "$u" morph MORPH
  load_q "$u" rate RATE
  load_q "$u" etar ETAR
  load_q "$u" dial DIAL
  load_q "$u" dial4 DIAL4
  load_q "$u" dial6 DIAL6
  load_q "$u" log LOG_LEVEL
  load_q "$u" crt CERT
  load_q "$u" key TLS_KEY
  if [[ "$ROLE" == vector ]]; then load_q "$u" socks VECTOR_SOCKS; else load_q "$u" socks OUT_SOCKS; fi
  load_q "$u" next NEXT
  load_q "$u" up UP
  load_q "$u" down DOWN
  load_q "$u" mux MUX
  load_q "$u" sni SNI
  load_q "$u" pin PIN
  return 0
}

write_meta() {
  install -d -m 750 -o root -g "$RUN_GROUP" "$CONFIG_DIR"
  cat >"$META_FILE" <<EOF2
SCRIPT_CHANNEL=v2
SCRIPT_VERSION=${SCRIPT_VERSION}
CORE_VERSION=${VERSION}
ROLE=${ROLE}
PUBLIC_HOST=${PUBLIC_HOST}
NODE_NAME=${NODE_NAME}
MEMORY_PROFILE=${MEMORY_PROFILE}
MORPH_PRELUDE=${MORPH_PRELUDE}
CLIENT_UP=${CLIENT_UP}
CLIENT_DOWN=${CLIENT_DOWN}
CLIENT_MUX=${CLIENT_MUX}
CLIENT_SNI=${CLIENT_SNI}
CLIENT_PIN=${CLIENT_PIN}
EOF2
  chmod 640 "$META_FILE"; chown root:"$RUN_GROUP" "$META_FILE"
}

load_meta() {
  [[ -r "$META_FILE" ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      PUBLIC_HOST) PUBLIC_HOST="$v" ;; NODE_NAME) NODE_NAME="$v" ;;
      # Persisted values are written into the systemd unit verbatim, so a corrupted
      # or hand-edited manager.conf must never reach write_unit unvalidated.
      MEMORY_PROFILE)
        if is_valid_memory_profile "$v"; then MEMORY_PROFILE="$v"
        else warn "$(tr_msg "Ignoring invalid MEMORY_PROFILE in manager.conf: ${v}" "忽略 manager.conf 中非法的 MEMORY_PROFILE: ${v}")"; fi ;;
      MORPH_PRELUDE)
        if is_valid_morph_prelude "$v"; then MORPH_PRELUDE="$v"
        else warn "$(tr_msg "Ignoring invalid MORPH_PRELUDE in manager.conf: ${v}" "忽略 manager.conf 中非法的 MORPH_PRELUDE: ${v}")"; fi ;;
      CLIENT_UP) CLIENT_UP="$v" ;; CLIENT_DOWN) CLIENT_DOWN="$v" ;; CLIENT_MUX) CLIENT_MUX="$v" ;;
      CLIENT_SNI) CLIENT_SNI="$v" ;; CLIENT_PIN) CLIENT_PIN="$v" ;;
    esac
  done <"$META_FILE"
}

# The binary-only install/upgrade path never rewrites manager.conf, so its
# SCRIPT_VERSION/CORE_VERSION fields go stale. Refresh just those two lines in
# place: rewriting the whole file is not safe there because load_meta does not
# restore every field (ROLE, for example), so the defaults would be written.
refresh_meta_versions() {
  [[ -r "$META_FILE" ]] || return 0
  local tmp
  tmp="$(mktemp)" || return 0
  CLEANUP_PATHS+=("$tmp")
  if awk -v sv="$SCRIPT_VERSION" -v cv="$VERSION" '
        /^SCRIPT_VERSION=/ { print "SCRIPT_VERSION=" sv; s=1; next }
        /^CORE_VERSION=/   { print "CORE_VERSION=" cv;   c=1; next }
        { print }
        END { if (!s) print "SCRIPT_VERSION=" sv; if (!c) print "CORE_VERSION=" cv }
      ' "$META_FILE" >"$tmp"; then
    # Write through the original path so its ownership and mode are preserved.
    cat "$tmp" >"$META_FILE" 2>/dev/null ||
      warn "$(tr_msg "Could not refresh the version fields in ${META_FILE}" "无法刷新 ${META_FILE} 中的版本字段")"
  fi
  rm -f -- "$tmp"
}

apply_cli_overrides() {
  local k
  for k in "${!CLI_SET[@]}"; do
    printf -v "$k" '%s' "${CLI_VAL[$k]}"
  done
}

has_cli_overrides() {
  (( ${#CLI_SET[@]} > 0 )) || [[ -n "$IMPORT_URL" ]]
}

warn_import_url_overrides() {
  local k
  local -a ignored=()
  # These values are encoded by --url itself and therefore cannot override it.
  # Meta-only options such as PUBLIC_HOST/NODE_NAME/MEMORY_PROFILE/CLIENT_* remain useful.
  for k in ROLE KEY ENDPOINT TLS CERT TLS_KEY MORPH RATE ETAR DIAL DIAL4 DIAL6 LOG_LEVEL OUT_SOCKS NEXT UP DOWN MUX SNI PIN VECTOR_SOCKS; do
    [[ -n "${CLI_SET[$k]+x}" ]] && ignored+=("$k")
  done
  if (( ${#ignored[@]} > 0 )); then
    warn "$(tr_msg "--url takes precedence; ignored URL-field CLI overrides: ${ignored[*]}" \
                    "--url 优先；以下 URL 字段命令行参数已忽略: ${ignored[*]}")"
  fi
}

ensure_user() {
  if ! getent group "$RUN_GROUP" >/dev/null 2>&1; then groupadd --system "$RUN_GROUP"; fi
  if ! id "$RUN_USER" >/dev/null 2>&1; then
    useradd --system --gid "$RUN_GROUP" --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin "$RUN_USER"
  fi
  install -d -m 755 "$INSTALL_ROOT" "$RELEASES_DIR"
  install -d -m 750 -o root -g "$RUN_GROUP" "$CONFIG_DIR" "$TLS_DIR"
}

write_launcher() {
  install -d -m 755 "$(dirname "$LAUNCHER")"
  cat >"$LAUNCHER" <<EOF2
#!/usr/bin/env bash
set -Eeuo pipefail
URL_FILE='${URL_FILE}'
BIN='${CURRENT_LINK}/nowhere'
[[ -r "\$URL_FILE" ]] || { echo 'missing V2 config' >&2; exit 1; }
IFS= read -r URL <"\$URL_FILE"
[[ -n "\$URL" ]] || { echo 'empty V2 config' >&2; exit 1; }
exec "\$BIN" "\$URL"
EOF2
  chmod 755 "$LAUNCHER"
}

write_unit() {
  cat >"$UNIT_FILE" <<EOF2
[Unit]
Description=Nowhere V2 (${SERVICE_NAME})
Documentation=https://github.com/${UPSTREAM_REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
ExecStart=${LAUNCHER}
Restart=on-failure
RestartSec=3s
TimeoutStopSec=10s
Environment=TMPDIR=/run/nowhere-v2
Environment=NOW_TRANSPORT_MEMORY_PROFILE=${MEMORY_PROFILE}
Environment=NOW_MORPH_TCP_PRELUDE=${MORPH_PRELUDE}
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
RuntimeDirectory=nowhere-v2
RuntimeDirectoryMode=0750

[Install]
WantedBy=multi-user.target
EOF2
  chmod 644 "$UNIT_FILE"
  systemctl daemon-reload
}

tls_files_readable_by_service() {
  runuser -u "$RUN_USER" -- test -r "$CERT" 2>/dev/null &&
    runuser -u "$RUN_USER" -- test -r "$TLS_KEY" 2>/dev/null
}

copy_tls_files_to_managed_dir() {
  local dc="$TLS_DIR/cert.pem" dk="$TLS_DIR/key.pem"
  install -d -m 750 -o root -g "$RUN_GROUP" "$TLS_DIR" ||
    die "$(tr_msg "Failed to prepare managed TLS directory." "无法创建 V2 专用 TLS 目录。")"

  if [[ "$(readlink -f "$CERT")" != "$(readlink -f "$dc" 2>/dev/null || true)" ]]; then
    install -m 640 -o root -g "$RUN_GROUP" "$CERT" "$dc" ||
      die "$(tr_msg "Failed to copy certificate into managed TLS directory." "复制证书到 V2 专用 TLS 目录失败。")"
  fi
  if [[ "$(readlink -f "$TLS_KEY")" != "$(readlink -f "$dk" 2>/dev/null || true)" ]]; then
    install -m 640 -o root -g "$RUN_GROUP" "$TLS_KEY" "$dk" ||
      die "$(tr_msg "Failed to copy private key into managed TLS directory." "复制私钥到 V2 专用 TLS 目录失败。")"
  fi

  CERT="$dc"
  TLS_KEY="$dk"
  COPY_CERT=1

  tls_files_readable_by_service ||
    die "$(tr_msg "Managed TLS files are still unreadable by the V2 service user." "复制后的 TLS 文件仍无法被 V2 服务账户读取。")"
  ok "$(tr_msg "TLS certificate/key copied to the V2-managed directory." "TLS 证书/私钥已复制到 V2 专用目录。")"
}

prepare_tls_files() {
  [[ "$TLS" == 2 ]] || return 0
  [[ -f "$CERT" && -f "$TLS_KEY" ]] ||
    die "$(tr_msg "tls=2 certificate/private-key file not found." "tls=2 的证书或私钥文件不存在。")"

  if [[ "$COPY_CERT" -eq 1 ]]; then
    copy_tls_files_to_managed_dir
    return 0
  fi

  # Direct paths are fine when the dedicated service account can already read them.
  tls_files_readable_by_service && return 0

  # Interactive menu/configure flow should never dead-end on a root-only PEM file.
  # Offer the safe managed-copy path here as a second line of defense, including
  # imported tls=2 URLs and any wizard path that did not set COPY_CERT earlier.
  if [[ "$ASSUME_YES" -eq 0 && -r /dev/tty ]]; then
    warn "$(tr_msg       "The V2 service user cannot read the selected TLS certificate/private key."       "V2 服务账户无法读取所选 TLS 证书/私钥（通常是 root:root 600 权限）。")"
    if prompt_yes "$(tr_msg       "Copy them to ${TLS_DIR} with secure service-readable permissions now"       "现在自动复制到 ${TLS_DIR} 并设置为服务账户可安全读取的权限")"; then
      copy_tls_files_to_managed_dir
      return 0
    fi
  fi

  die "$(tr_msg     "V2 service user cannot read TLS files. Use --copy-cert or make the files readable by ${RUN_USER}."     "V2 服务账户无法读取 TLS 文件。请选择自动复制，或使用 --copy-cert，或自行授予 ${RUN_USER} 只读权限。")"
}

write_config_url() {
  local u="$1"
  validate_imported_url "$u" "$VERSION"
  install -d -m 750 -o root -g "$RUN_GROUP" "$CONFIG_DIR"
  printf '%s\n' "$u" >"$URL_FILE"
  chmod 640 "$URL_FILE"; chown root:"$RUN_GROUP" "$URL_FILE"
}

snapshot_config_state() {
  CONFIG_SNAPSHOT_DIR="$(mktemp -d)" || die "$(tr_msg "Cannot create config snapshot" "无法创建配置快照")"
  CLEANUP_PATHS+=("$CONFIG_SNAPSHOT_DIR")
  [[ -e "$URL_FILE" ]] && cp -a -- "$URL_FILE" "$CONFIG_SNAPSHOT_DIR/url.conf"
  [[ -e "$META_FILE" ]] && cp -a -- "$META_FILE" "$CONFIG_SNAPSHOT_DIR/manager.conf"
  [[ -d "$TLS_DIR" ]] && cp -a -- "$TLS_DIR" "$CONFIG_SNAPSHOT_DIR/tls"
  return 0
}

restore_config_state() {
  [[ -n "$CONFIG_SNAPSHOT_DIR" && -d "$CONFIG_SNAPSHOT_DIR" ]] || return 1
  rm -f -- "$URL_FILE" "$META_FILE" || return 1
  rm -rf -- "$TLS_DIR" || return 1
  [[ -e "$CONFIG_SNAPSHOT_DIR/url.conf" ]] && cp -a -- "$CONFIG_SNAPSHOT_DIR/url.conf" "$URL_FILE"
  [[ -e "$CONFIG_SNAPSHOT_DIR/manager.conf" ]] && cp -a -- "$CONFIG_SNAPSHOT_DIR/manager.conf" "$META_FILE"
  [[ -d "$CONFIG_SNAPSHOT_DIR/tls" ]] && cp -a -- "$CONFIG_SNAPSHOT_DIR/tls" "$TLS_DIR"
  # The in-memory globals still hold the failed attempt's values. Re-read the
  # restored manager.conf so the unit matches the configuration that survived.
  load_meta
  write_launcher; write_unit
  if [[ -s "$URL_FILE" && -x "$CURRENT_LINK/nowhere" ]]; then systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true; wait_service 12; else systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true; fi
}

wait_service() {
  local n="${1:-12}" i stable=0
  for ((i=0;i<n;i++)); do
    if systemctl is-active --quiet "$SERVICE_NAME"; then stable=$((stable+1)); else stable=0; fi
    ((stable>=3)) && return 0
    sleep 1
  done
  return 1
}

curl_github() {
  local url="$1" out="$2"; shift 2
  local -a args=(--fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --connect-timeout 10 -H 'Accept: application/vnd.github+json')
  [[ -n "$GITHUB_TOKEN" ]] && args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  curl "${args[@]}" "$@" "$url" -o "$out"
}

resolve_version() {
  validate_version_arg "$VERSION"
  [[ "$VERSION" == latest-v2 ]] || return 0
  install_runtime_deps
  local tmp page found best="" count
  tmp="$(mktemp)"; CLEANUP_PATHS+=("$tmp")
  for ((page=1;page<=20;page++)); do
    curl_github "https://api.github.com/repos/${UPSTREAM_REPO}/releases?per_page=100&page=${page}" "$tmp" || die "$(tr_msg "Cannot fetch the official release list" "无法获取官方发布列表")"
    found="$(python3 - "$tmp" <<'PY'
import json,re,sys
r=json.load(open(sys.argv[1])); assert isinstance(r,list)
c=[(tuple(map(int,x['tag_name'][1:].split('.'))),x['tag_name']) for x in r if re.fullmatch(r'v2\.\d+\.\d+',x.get('tag_name','')) and not x.get('draft') and not x.get('prerelease')]
print(max(c)[1] if c else '')
print(len(r))
PY
)" || die "$(tr_msg "Invalid release metadata" "发布元数据无效")"
    count="${found##*$'\n'}"; found="${found%%$'\n'*}"
    if [[ -n "$found" ]] && { [[ -z "$best" ]] || version_ge "$found" "$best"; }; then best="$found"; fi
    if ((count<100)); then
      [[ -n "$best" ]] || die "$(tr_msg "No stable V2 release found" "未找到稳定的 V2 版本")"
      VERSION="$best"; return 0
    fi
  done
  die "$(tr_msg "Release list exceeds the scan limit; pin a stable tag explicitly" "发布列表超过扫描上限，请显式指定稳定版标签")"
}

release_asset_fields() {
  local json="$1" target="$2"
  python3 - "$json" "$target" <<'PY'
import json,sys
j=json.load(open(sys.argv[1],encoding='utf-8')); target=sys.argv[2].lower(); assets=j.get('assets',[])
c=[]
for a in assets:
    n=a.get('name',''); nl=n.lower()
    if target in nl and (nl.endswith('.tar.gz') or nl.endswith('.tgz')):
        c.append(a)
if not c:
    # Conservative fallback for naming changes: require every target component.
    parts=target.split('-')
    for a in assets:
        nl=a.get('name','').lower()
        if 'linux' in nl and parts[0] in nl and parts[-1] in nl and (nl.endswith('.tar.gz') or nl.endswith('.tgz')): c.append(a)
if len(c)!=1:
    print('ASSETS='+','.join(a.get('name','') for a in assets),file=sys.stderr); sys.exit(2)
a=c[0]
print(a.get('name','')); print(a.get('browser_download_url','')); print(a.get('digest',''))
PY
}

detect_libc() {
  case "$LIBC" in gnu|musl) printf '%s' "$LIBC"; return ;; auto) ;; *) die "$(tr_msg "--libc must be auto|gnu|musl" "--libc 必须为 auto|gnu|musl")" ;; esac
  if [[ -f /etc/alpine-release ]] || (has_cmd ldd && ldd --version 2>&1 | grep -qi musl); then printf musl; else printf gnu; fi
}

target_triple() {
  local arch libc
  case "$(uname -m)" in x86_64|amd64) arch=x86_64 ;; aarch64|arm64) arch=aarch64 ;; *) die "$(tr_msg "Unsupported CPU: $(uname -m)" "不支持的 CPU: $(uname -m)")" ;; esac
  libc="$(detect_libc)"; printf '%s-unknown-linux-%s' "$arch" "$libc"
}

safe_extract_tar() {
  python3 - "$1" "$2" <<'PY'
import sys,tarfile,pathlib,shutil
with tarfile.open(sys.argv[1],'r:gz') as t:
    members=t.getmembers()
    for m in members:
        p=pathlib.PurePosixPath(m.name)
        if p.is_absolute() or '..' in p.parts or not (m.isfile() or m.isdir()):
            raise SystemExit('Unsafe archive member')
    bins=[m for m in members if m.isfile() and pathlib.PurePosixPath(m.name).name=='nowhere']
    if len(bins)!=1: raise SystemExit('Expected exactly one nowhere binary')
    if bins[0].size>256*1024*1024: raise SystemExit('Oversized binary')
    with t.extractfile(bins[0]) as src, open(pathlib.Path(sys.argv[2])/'nowhere','wb') as dst:
        shutil.copyfileobj(src,dst)
PY
}

install_release() {
  install_runtime_deps; resolve_version
  local json fields name url digest expected actual tmp archive bin bsha target release_dir
  json="$(mktemp)"; CLEANUP_PATHS+=("$json")
  curl_github "https://api.github.com/repos/${UPSTREAM_REPO}/releases/tags/${VERSION}" "$json" || die "$(tr_msg "Failed to read release metadata" "读取发布元数据失败")"
  python3 - "$json" "$VERSION" <<'PYMETA' || die "$(tr_msg "Release tag is not a matching stable release" "发布标签不是匹配的稳定正式版")"
import json,sys
r=json.load(open(sys.argv[1]))
assert r.get('tag_name')==sys.argv[2] and not r.get('draft') and not r.get('prerelease')
PYMETA
  target="$(target_triple)"
  fields="$(release_asset_fields "$json" "$target")" || die "$(tr_msg "No unambiguous Linux asset for ${target}" "找不到与 ${target} 唯一对应的 Linux 资产")"
  name="$(sed -n '1p' <<<"$fields")"; url="$(sed -n '2p' <<<"$fields")"; digest="$(sed -n '3p' <<<"$fields")"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ && "$url" == https://github.com/NodePassProject/Nowhere/releases/download/* ]] || die "$(tr_msg "Release asset metadata incomplete" "发布资产元数据不完整")"
  [[ "$digest" =~ ^sha256:[0-9A-Fa-f]{64}$ ]] || die "$(tr_msg "GitHub release does not expose a SHA-256 digest for ${name}; refusing binary install" "GitHub 发布未提供 ${name} 的 SHA-256 摘要；拒绝安装二进制")"
  expected="${digest#sha256:}"
  tmp="$(mktemp -d)"; CLEANUP_PATHS+=("$tmp"); archive="$tmp/$name"
  info "$(tr_msg "Downloading verified ${VERSION} / ${name}" "正在下载并校验 ${VERSION} / ${name}")"
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --connect-timeout 10 -o "$archive" "$url"
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] || die "$(tr_msg "Release SHA-256 mismatch" "发布包 SHA-256 校验不匹配")"
  mkdir -p "$tmp/extracted"; safe_extract_tar "$archive" "$tmp/extracted"
  bin="$(find "$tmp/extracted" -type f -name nowhere -print -quit)"; [[ -n "$bin" ]] || die "$(tr_msg "No nowhere binary in release asset" "发布资产中没有 nowhere 二进制")"
  chmod 755 "$bin"; bsha="$(sha256sum "$bin" | awk '{print $1}')"
  release_dir="$RELEASES_DIR/${VERSION}-release-${bsha:0:12}"
  install -d -m 755 "$release_dir"; install -m 755 "$bin" "$release_dir/nowhere"
  cat >"$release_dir/RELEASE-INFO" <<EOF2
repository: https://github.com/${UPSTREAM_REPO}
tag: ${VERSION}
asset: ${name}
asset_sha256: ${expected}
binary_sha256: ${bsha}
installed_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
manager_channel: v2
EOF2
  ln -sfn "$release_dir" "$CURRENT_LINK"; ln -sfn "$CURRENT_LINK/nowhere" "$BIN_LINK"
  ok "$(tr_msg "Installed Nowhere ${VERSION} (${bsha:0:12})" "已安装 Nowhere ${VERSION} (${bsha:0:12})")"
}

ensure_rust() {
  if has_cmd rustc && has_cmd cargo; then
    # Upstream is edition 2024 (stabilised in Rust 1.85) and ships no
    # rust-toolchain file, so an older distro toolchain fails deep inside cargo
    # with a confusing error. Check up front and install a managed toolchain.
    local rv
    rv="$(rustc --version 2>/dev/null | awk '{print $2}')"
    if version_ge "$rv" "1.85.0"; then return 0; fi
    warn "$(tr_msg "System Rust ${rv:-unknown} is older than 1.85 and cannot build edition-2024 sources; installing a managed toolchain instead." "系统 Rust ${rv:-未知} 低于 1.85，无法编译 edition 2024 源码；改为安装受管工具链。")"
  fi
  local target tmp url expected actual
  target="$(target_triple)"; tmp="$(mktemp -d)"; CLEANUP_PATHS+=("$tmp")
  url="https://static.rust-lang.org/rustup/dist/${target}/rustup-init"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3 -o "$tmp/rustup-init" "$url"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3 -o "$tmp/rustup-init.sha256" "${url}.sha256"
  expected="$(awk '{print $1}' "$tmp/rustup-init.sha256")"; actual="$(sha256sum "$tmp/rustup-init" | awk '{print $1}')"
  [[ "${expected,,}" == "${actual,,}" ]] || die "$(tr_msg "rustup-init SHA-256 mismatch" "rustup-init SHA-256 校验不匹配")"
  chmod 700 "$tmp/rustup-init"
  RUSTUP_HOME="$RUSTUP_HOME_DIR" CARGO_HOME="$CARGO_HOME_DIR" "$tmp/rustup-init" -y --no-modify-path --profile minimal --default-toolchain stable
  export RUSTUP_HOME="$RUSTUP_HOME_DIR" CARGO_HOME="$CARGO_HOME_DIR" PATH="$CARGO_HOME_DIR/bin:$PATH"
}

ensure_build_swap() {
  [[ "$SWAP_MODE" == off ]] && return 0
  awk 'NR>1{f=1}END{exit(f?0:1)}' /proc/swaps 2>/dev/null && return 0
  local mem_kb mem_mb want free_mb
  mem_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"; mem_mb=$(( ${mem_kb:-0}/1024 )); want=0
  if [[ "$SWAP_MODE" == auto ]]; then ((mem_mb>=2048)) && return 0; ((mem_mb<1024)) && want=4096 || want=2048
  elif [[ "$SWAP_MODE" =~ ^[0-9]+$ ]]; then want="$SWAP_MODE"; else die "$(tr_msg "--swap must be auto|off|MB" "--swap 必须为 auto|off|MB")"; fi
  ((want>0)) || return 0
  free_mb="$(df -Pk /var/tmp | awk 'NR==2{print int($4/1024)}')"; ((free_mb>want+512)) || die "$(tr_msg "Not enough free disk for temporary swap" "磁盘剩余空间不足以创建临时 swap")"
  has_cmd mkswap && has_cmd swapon && has_cmd swapoff || die "$(tr_msg "mkswap/swapon/swapoff required" "需要 mkswap/swapon/swapoff")"
  fallocate -l "${want}M" "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$want" status=none
  chmod 600 "$SWAP_FILE"; mkswap "$SWAP_FILE" >/dev/null; swapon "$SWAP_FILE"
}

install_source() {
  acquire_build_lock; cleanup_stale_swap; resolve_version; install_runtime_deps; install_build_deps; ensure_rust; ensure_build_swap
  local tmp commit bsha release_dir
  tmp="$(mktemp -d /var/tmp/nowhere-v2-build.XXXXXX)"; [[ "$KEEP_SOURCE" -eq 1 ]] || CLEANUP_PATHS+=("$tmp")
  git clone --quiet --depth 1 --branch "$VERSION" "$DEFAULT_REPO_URL" "$tmp/src" || die "$(tr_msg "git clone failed" "git clone 失败")"
  (cd "$tmp/src"; export RUSTUP_HOME="$RUSTUP_HOME_DIR" CARGO_HOME="$CARGO_HOME_DIR" PATH="$CARGO_HOME_DIR/bin:$PATH"; cargo build --release --locked) || die "$(tr_msg "cargo build failed" "cargo 编译失败")"
  [[ -x "$tmp/src/target/release/nowhere" ]] || die "$(tr_msg "built binary not found" "未找到编译产物二进制")"
  commit="$(git -C "$tmp/src" rev-parse HEAD)"; bsha="$(sha256sum "$tmp/src/target/release/nowhere" | awk '{print $1}')"
  release_dir="$RELEASES_DIR/${VERSION}-source-${commit:0:8}-${bsha:0:12}"; install -d -m 755 "$release_dir"; install -m 755 "$tmp/src/target/release/nowhere" "$release_dir/nowhere"
  cat >"$release_dir/BUILD-INFO" <<EOF2
repository: ${DEFAULT_REPO_URL}
tag: ${VERSION}
commit: ${commit}
binary_sha256: ${bsha}
installed_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
manager_channel: v2
EOF2
  ln -sfn "$release_dir" "$CURRENT_LINK"; ln -sfn "$CURRENT_LINK/nowhere" "$BIN_LINK"
  cleanup_swap || true
  ok "$(tr_msg "Built and installed Nowhere ${VERSION}" "已编译并安装 Nowhere ${VERSION}")"
}

cleanup_old_releases() {
  require_root; validate_keep_releases "$KEEP_RELEASES"
  # Serialise against installs/builds: this walks and deletes inside the releases
  # directory. No-op when the caller already holds the lock.
  acquire_build_lock
  local quiet="${1:-0}" current previous d kept=0 removed=0
  [[ "$KEEP_RELEASES" -gt 0 ]] || { [[ "$quiet" == 1 ]] || info "$(tr_msg "Release pruning disabled" "旧版本自动清理已关闭")"; return 0; }
  [[ -d "$RELEASES_DIR" ]] || return 0
  current="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"; previous="$OLD_TARGET"
  [[ -n "$current" && -d "$current" ]] && kept=1
  if [[ -n "$previous" && -d "$previous" && "$previous" != "$current" && $kept -lt $KEEP_RELEASES ]]; then kept=$((kept+1)); else previous=""; fi
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue; [[ "$d" == "$current" || "$d" == "$previous" ]] && continue
    if ((kept<KEEP_RELEASES)); then kept=$((kept+1)); else rm -rf -- "$d"; removed=$((removed+1)); fi
  done < <(ls -1dt "$RELEASES_DIR"/* 2>/dev/null || true)
  ((removed>0)) && ok "$(tr_msg "Removed ${removed} old V2 release(s)" "已清理 ${removed} 个旧 V2 Release")" || [[ "$quiet" == 1 ]] || info "$(tr_msg "No old V2 releases need cleanup" "没有需要清理的旧 V2 Release")"
}

rollback_binary() {
  local old="$1"
  [[ -n "$old" && -x "$old/nowhere" ]] || return 1
  ln -sfn "$old" "$CURRENT_LINK"; ln -sfn "$CURRENT_LINK/nowhere" "$BIN_LINK"
  systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
  wait_service 12
}

installed_core_version() {
  local info="$CURRENT_LINK/RELEASE-INFO" v=""
  [[ -r "$info" ]] || info="$CURRENT_LINK/BUILD-INFO"
  [[ -r "$info" ]] && v="$(sed -n 's/^tag:[[:space:]]*//p' "$info" | head -1)"
  if [[ -z "$v" && -r "$META_FILE" ]]; then
    v="$(sed -n 's/^CORE_VERSION=//p' "$META_FILE" | head -1)"
  fi
  printf '%s' "$v"
}

# Numeric vX.Y.Z comparison, done with zero-padded string compare so it works on
# busybox (Alpine) where `sort -V` is unavailable.
version_ge() {
  local a="${1#v}" b="${2#v}" a1 a2 a3 b1 b2 b3 ap bp
  [[ "$a" =~ ^[0-9]+(\.[0-9]+)*$ && "$b" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  IFS=. read -r a1 a2 a3 <<<"$a"
  IFS=. read -r b1 b2 b3 <<<"$b"
  a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
  b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
  ap="$(printf '%05d%05d%05d' "$((10#$a1))" "$((10#$a2))" "$((10#$a3))")"
  bp="$(printf '%05d%05d%05d' "$((10#$b1))" "$((10#$b2))" "$((10#$b3))")"
  [[ "$ap" == "$bp" || "$ap" > "$bp" ]]
}

# Nowhere 2.1.0 changed the Morph wire format; morph-enabled 2.1 peers cannot talk
# to 2.0.x peers. Warn when this install/upgrade actually crosses that boundary.
warn_morph_upgrade_requirement() {
  local old_core="$1" u morph
  [[ -s "$URL_FILE" ]] || return 0
  IFS= read -r u <"$URL_FILE" || return 0
  morph="$(query_get "$u" morph)"; morph="${morph:-0}"
  [[ "$morph" == 1 ]] || return 0
  version_ge "$VERSION" v2.1.0 || return 0
  if [[ -z "$old_core" ]] || ! version_ge "$old_core" v2.1.0; then
    warn "$(tr_msg \
      "This config uses morph=1 and is being moved to Nowhere ${VERSION}. The Morph wire format changed in 2.1.0: every peer on this path (Portal, Vector, native next hop, alternate client) must also be on >=2.1.0, or traffic will stop." \
      "此配置为 morph=1，正在切换到 Nowhere ${VERSION}。Morph 线协议在 2.1.0 有破坏性变更：此链路上的所有对端（Portal / Vector / native next / 其它客户端）都必须同时为 >=2.1.0，否则流量会中断。")"
  fi
}

# Nowhere 2.1.1/2.2.0 admission changes: warn when an existing config is about
# to move onto a core that will refuse it. Old cores are unaffected, so these
# fire only when the upgrade actually crosses a boundary.
warn_22_upgrade_requirements() {
  local old_core="$1" u role key next nk pin logv
  [[ -s "$URL_FILE" ]] || return 0
  IFS= read -r u <"$URL_FILE" || return 0
  role="$(url_role "$u")"

  # 2.1.1 removed the 'event' log level; the core refuses to start with it.
  if version_ge "$VERSION" v2.1.1 && { [[ -z "$old_core" ]] || ! version_ge "$old_core" v2.1.1; }; then
    logv="$(query_get "$u" log)"; logv="${logv:-info}"
    if [[ "$logv" == event ]]; then
      warn "$(tr_msg \
        "This config still sets log=event, which Nowhere 2.1.1 removed. Change it to none|debug|info|warn|error or the service will fail to start." \
        "此配置仍在使用 log=event，该等级已在 Nowhere 2.1.1 移除。请改为 none|debug|info|warn|error，否则服务将无法启动。")"
    fi
  fi

  # 2.2.0 tightened key admission (Portal listener and native next) and made
  # certificate verification mandatory for native clients.
  version_ge "$VERSION" v2.2.0 || return 0
  if [[ -n "$old_core" ]] && version_ge "$old_core" v2.2.0; then return 0; fi

  if [[ "$role" == portal ]]; then
    key="$(url_key "$u")"
    if ! is_valid_key_value "$key"; then
      warn "$(tr_msg \
        "This Portal (or next-hop) key is not 32-64 lowercase hex. Nowhere 2.2.0+ refuses to start with a legacy key. Rotate only the key and keep every other setting: sudo bash nowhere-v2.sh configure -y --config-mode quick --key <new 64-hex key>. Then update every peer on that hop." \
        "此 Portal（或 next 跳）密钥不是 32-64 位小写十六进制。Nowhere 2.2.0+ 遇到旧格式密钥会拒绝启动。只轮换密钥、保留其它设置：sudo bash nowhere-v2.sh configure -y --config-mode quick --key <新的 64 位 hex 密钥>，然后同步更新该跳的所有对端。")"
    elif key_requires_64_hex "$VERSION" && [[ ! "$key" =~ ^[0-9a-f]{64}$ ]]; then
      warn "$(tr_msg \
        "An exact v2.2.0 core requires exactly 64 hex characters for the Portal key; this one is shorter and the service will refuse to start. Regenerate a 64-character key and update every peer on that hop." \
        "锁定到 v2.2.0 的内核要求 Portal 密钥恰好 64 位十六进制；当前密钥更短，服务会拒绝启动。请重新生成 64 位密钥并同步该跳所有对端。")"
    fi
    next="$(query_get "$u" next)"
    if [[ -n "$next" && "$next" != none ]]; then
      nk="${next%@*}"
      if ! is_valid_key_value "$nk"; then
        warn "$(tr_msg \
          "The next-hop key inside next= is not 32-64 lowercase hex; Nowhere 2.2.0+ will refuse it. Configure the same fresh key on both ends of that hop." \
          "next= 中的下一跳密钥不是 32-64 位小写十六进制；Nowhere 2.2.0+ 将拒绝该配置。请在该跳两端配置相同的新密钥。")"
      elif key_requires_64_hex "$VERSION" && [[ ! "$nk" =~ ^[0-9a-f]{64}$ ]]; then
        warn "$(tr_msg \
          "An exact v2.2.0 core requires exactly 64 hex characters for the next-hop key; this one is shorter. Configure a 64-character key on both ends of that hop." \
          "锁定到 v2.2.0 的内核要求下一跳密钥恰好 64 位十六进制；当前密钥更短。请在该跳两端配置 64 位密钥。")"
      fi
    fi
  fi

  pin="$(query_get "$u" pin)"; pin="${pin:-none}"
  if [[ "$pin" == none ]]; then
    if [[ "$role" == vector ]]; then
      warn "$(tr_msg \
        "This Vector config has no pin. Nowhere 2.2.0+ always verifies certificates against the system CA and the endpoint hostname: if the Portal uses a generated/self-signed certificate, traffic will fail until you add pin=<sha256> (see 'links' and 'fingerprint')." \
        "此 Vector 配置没有 pin。Nowhere 2.2.0+ 始终使用系统 CA 与端点主机名验证证书：若 Portal 使用生成/自签名证书，必须先添加 pin=<sha256>（见 'links' 与 'fingerprint'），否则流量会中断。")"
    elif [[ "$role" == portal ]]; then
      next="$(query_get "$u" next)"
      if [[ -n "$next" && "$next" != none ]]; then
        warn "$(tr_msg \
          "This Portal chain has no next-hop pin. Nowhere 2.2.0+ verifies chained Portal certificates: if the next hop uses a generated/self-signed certificate, traffic will fail until you add pin=<sha256>." \
          "此 Portal 链式配置没有下一跳 pin。Nowhere 2.2.0+ 会验证链式 Portal 证书：若下一跳使用生成/自签名证书，必须先添加 pin=<sha256>，否则流量会中断。")"
      fi
    fi
  fi
  return 0
}

install_action() {
  require_root; require_systemd; install_runtime_deps; acquire_build_lock; begin_transaction; ensure_user
  # Serialise installs: two concurrent runs would race on the releases directory
  # and the `current` symlink. Released by the EXIT trap.
  acquire_build_lock
  local had_config=0 old_core=""
  [[ -s "$URL_FILE" ]] && had_config=1
  if [[ "$UPGRADE_MODE" -eq 1 && "$had_config" -eq 0 ]]; then
    die "$(tr_msg "upgrade requires an existing V2 configuration; use 'install' for a fresh deployment" "upgrade 需要已有 V2 配置；首次部署请使用 install")"
  fi

  # Reinstall/upgrade is binary-only by default when a V2 config already exists.
  # Restore persisted meta before rewriting the unit so defaults/CLI values cannot
  # silently change MEMORY_PROFILE or other manager metadata.
  if [[ "$had_config" -eq 1 && "$FORCE_RECONFIGURE" -eq 0 ]]; then
    load_meta
    if has_cli_overrides; then
      warn "$(tr_msg "Existing V2 config found; install/upgrade replaces only the binary. Configuration CLI overrides were ignored. Use 'configure' or add --force-reconfigure." \
                      "检测到已有 V2 配置；install/upgrade 默认只更换二进制，配置类命令行参数已忽略。请使用 configure，或显式加 --force-reconfigure。")"
    fi
  fi

  OLD_TARGET="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
  old_core="$(installed_core_version)"
  if [[ "$INSTALL_METHOD" == source ]]; then install_source; else install_release; fi
  warn_morph_upgrade_requirement "$old_core"
  warn_22_upgrade_requirements "$old_core"
  write_launcher; write_unit

  if [[ "$had_config" -eq 0 || "$FORCE_RECONFIGURE" -eq 1 ]]; then
    configure_action 1
  else
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    if ! systemctl restart "$SERVICE_NAME" || ! wait_service 12; then
      warn "$(tr_msg "New V2 release failed to start; attempting binary rollback" "新版 V2 启动失败，正在尝试回滚二进制文件")"
      journalctl -u "$SERVICE_NAME" -n 40 --no-pager 2>/dev/null || true
      if rollback_binary "$OLD_TARGET"; then warn "$(tr_msg "Rolled back to previous V2 binary" "已回滚到上一版 V2 二进制文件")"; else die "$(tr_msg "New release failed and rollback did not recover service" "新版启动失败且自动回滚未能恢复服务")"; fi
      return 1
    fi
    # This path never rewrites manager.conf, so keep its version fields in step
    # with what is actually installed.
    refresh_meta_versions
  fi
  TX_COMMITTED=1
  cleanup_old_releases 1
  ok "$(tr_msg "Nowhere V2 ${VERSION} is active" "Nowhere V2 ${VERSION} 已正常运行")"
  show_links || true
}

configure_action() {
  local from_install="${1:-0}" u
  require_root; require_systemd; install_runtime_deps; acquire_build_lock; begin_transaction; ensure_user; load_meta; load_existing_config; apply_cli_overrides
  if [[ "$from_install" != 1 ]]; then
    local installed_version
    installed_version="$(installed_core_version)"
    [[ -z "$installed_version" ]] || VERSION="$installed_version"
  fi
  snapshot_config_state
  if [[ -n "$IMPORT_URL" ]]; then
    warn_import_url_overrides
    validate_imported_url "$IMPORT_URL" "$VERSION"
    ROLE="$(url_role "$IMPORT_URL")"
    u="$IMPORT_URL"
  else
    local mode="$CONFIG_MODE"
    if [[ "$mode" == ask ]]; then mode="$(prompt_choice "$(tr_msg "Config mode quick/advanced" "配置模式 quick/advanced")" quick quick advanced)"; fi
    if [[ "$ASSUME_YES" -eq 0 || -z "$ENDPOINT" || -z "$KEY" ]]; then
      if [[ "$mode" == advanced ]]; then advanced_wizard; else quick_wizard; fi
    fi
    prepare_tls_files
    if [[ "$ROLE" == portal ]]; then u="$(build_portal_url)"; else u="$(build_vector_url)"; fi
  fi
  # If imported tls=2 uses paths, verify service readability. We do not silently rewrite them.
  if [[ "$ROLE" == portal && "$(query_get "$u" tls)" == 2 ]]; then
    TLS=2; CERT="$(query_get "$u" crt)"; TLS_KEY="$(query_get "$u" key)"; prepare_tls_files
    if [[ "$COPY_CERT" -eq 1 ]]; then
      # Rebuild imported URL with copied paths using Python, preserving first query values.
      u="$(python3 - "$u" "$CERT" "$TLS_KEY" <<'PY'
import sys,urllib.parse
raw,crt,key=sys.argv[1:]
u=urllib.parse.urlsplit(raw); pairs=urllib.parse.parse_qsl(u.query,keep_blank_values=True)
out=[]; seen=set()
for k,v in pairs:
    if k in seen: continue
    seen.add(k)
    if k=='crt': v=crt
    if k=='key': v=key
    out.append((k,v))
print(urllib.parse.urlunsplit((u.scheme,u.netloc,u.path,urllib.parse.urlencode(out),'')),end='')
PY
)"
    fi
  fi
  write_config_url "$u"; write_meta; write_launcher; write_unit
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  if ! systemctl restart "$SERVICE_NAME" || ! wait_service 12; then
    warn "$(tr_msg "V2 configuration failed; restoring previous V2 configuration" "V2 配置应用失败，正在恢复之前的配置")"
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager 2>/dev/null || true
    restore_config_state || warn "$(tr_msg "Automatic config restore was incomplete; inspect ${CONFIG_DIR}" "自动恢复配置不完整，请检查 ${CONFIG_DIR}")"
    return 1
  fi
  [[ "$from_install" == 1 ]] || TX_COMMITTED=1
  ok "$(tr_msg "V2 configuration applied" "V2 配置已应用")"
  print_firewall_hint
  [[ "$from_install" == 1 ]] || show_links
}

print_firewall_hint() {
  [[ -s "$URL_FILE" ]] || return 0
  local u role ep p
  IFS= read -r u <"$URL_FILE"; role="$(url_role "$u")"
  [[ "$role" == portal ]] || return 0
  ep="$(url_endpoint "$u")"
  if [[ "$(endpoint_has_tcp portal "$ep")" == 1 ]]; then p="$(endpoint_tcp_port portal "$ep")"; info "$(tr_msg "Firewall: allow TCP ${p}" "防火墙请放行 TCP ${p}")"; fi
  if [[ "$(endpoint_has_udp portal "$ep")" == 1 ]]; then p="$(endpoint_udp_port portal "$ep")"; info "$(tr_msg "Firewall: allow UDP ${p}" "防火墙请放行 UDP ${p}")"; fi
}

show_status() {
  require_root; require_systemd
  local installed
  installed="$(installed_core_version)"; installed="${installed:-$VERSION}"
  printf '%b%s%b %s | %s %s\n' "$C_CYAN" "$(tr_msg "Nowhere V2 Manager" "Nowhere V2 管理器")" "$C_NC" "$SCRIPT_VERSION" "$(tr_msg "Core installed" "已安装 Core")" "$installed"
  printf '%s: ' "$(tr_msg 'Service' '服务状态')"; systemctl is-active "$SERVICE_NAME" 2>/dev/null || true
  printf '%s: ' "$(tr_msg 'Enabled' '开机启动')"; systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true
  printf '%s: %s\n' "$(tr_msg 'Current release' '当前 Release')" "$(readlink -f "$CURRENT_LINK" 2>/dev/null || echo none)"
  [[ -x "$BIN_LINK" ]] && { printf '%s: ' "$(tr_msg 'Binary' '二进制版本')"; "$BIN_LINK" --version 2>/dev/null || echo "$BIN_LINK"; }
  if [[ -s "$URL_FILE" ]]; then
    local u role ep
    IFS= read -r u <"$URL_FILE"; role="$(url_role "$u")"; ep="$(url_endpoint "$u")"
    printf '%s: %s\nEndpoint: %s\nMorph: %s\n' "$(tr_msg 'Role' '角色')" "$role" "$ep" "$(query_get "$u" morph)"
  fi
}

public_endpoint_from_portal() {
  local u="$1" ep host
  ep="$(url_endpoint "$u")"; host="$PUBLIC_HOST"
  [[ -n "$host" ]] || host="$(curl -4fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$host" ]] || return 1
  endpoint_replace_host portal "$ep" "$host"
}

build_native_vector_link_from_portal() {
  local u="$1" ep eup edown emux sni pin morph key q tls
  ep="$(public_endpoint_from_portal "$u")" || return 1; key="$(url_key "$u")"; morph="$(query_get "$u" morph)"; morph="${morph:-0}"
  eup="$CLIENT_UP"; edown="$CLIENT_DOWN"
  [[ "$eup" == auto ]] && eup="$(endpoint_default_policy vector "$ep")"
  [[ "$edown" == auto ]] && edown="$(endpoint_default_policy vector "$ep")"
  validate_policy_against_endpoint vector "$ep" "$eup"; validate_policy_against_endpoint vector "$ep" "$edown"
  emux="$CLIENT_MUX"; [[ "$eup" == udp && "$edown" == udp ]] && emux=0
  sni="$CLIENT_SNI"; pin="$CLIENT_PIN"
  tls="$(query_get "$u" tls)"; tls="${tls:-1}"
  if [[ "$sni" == auto ]]; then
    if [[ "$tls" == 2 && -n "$PUBLIC_HOST" && "$PUBLIC_HOST" != *:* && ! "$PUBLIC_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then sni="$PUBLIC_HOST"; else sni=none; fi
  fi
  # Nowhere 2.2.0+ clients verify the system CA plus hostname by default, and
  # pin=none no longer disables verification. A generated (tls=1) certificate
  # therefore only works with an explicit pin; fill it from the running local
  # service unless the operator supplied --client-pin. For a supplied (tls=2)
  # certificate, pin only when it is self-signed: pinning a CA-signed
  # certificate would break every client as soon as the certificate is renewed.
  if [[ "$pin" == none || -z "$pin" ]]; then
    if [[ "$tls" == 1 ]]; then
      local auto_pin
      if auto_pin="$(local_portal_fingerprint "$u")"; then
        pin="$auto_pin"
        warn "$(tr_msg "tls=1 link: pin auto-filled from the local Portal certificate. A generated certificate changes when the Portal restarts - regenerate links and update the client pin after each restart; prefer tls=2 for production." "tls=1 链接：已从本机 Portal 证书自动填入 pin。生成的证书会随 Portal 重启而变化——每次重启后请重新生成链接并更新客户端 pin；生产环境建议使用 tls=2。")"
      else
        warn "$(tr_msg "tls=1 link needs an explicit pin: Nowhere 2.2.0+ rejects generated certificates without one, and the local Portal is not reachable to auto-fill it. Start the service and re-run 'links', or run 'fingerprint'." "tls=1 链接需要显式 pin：Nowhere 2.2.0+ 对生成的证书不再放行，且本机 Portal 当前不可达无法自动填充。请启动服务后重新执行 'links'，或用 'fingerprint' 获取。")"
        return 1
      fi
    elif [[ "$tls" == 2 ]]; then
      local cert needs
      cert="$(query_get "$u" crt)"
      certificate_needs_pin "$cert"; needs=$?
      if [[ "$needs" == 0 ]]; then
        if ! pin="$(local_portal_fingerprint "$u")"; then
          warn "$(tr_msg "Self-signed or private-CA certificate could not be read for pinning; pass --client-pin <sha256> or check ${cert}." "自签名或私有 CA 证书无法读取以填入 pin；请显式指定 --client-pin <sha256>，或检查 ${cert}。")"
          return 1
        fi
        warn "$(tr_msg "tls=2 link: the certificate does not verify against the system trust store, so the pin was auto-filled. Regenerate the links after you rotate this certificate." "tls=2 链接：证书无法通过系统信任库验证，已自动填入 pin。若轮换该证书，请重新生成链接。")"
      elif [[ "$needs" == 2 ]]; then
        warn "$(tr_msg "Cannot inspect ${cert}; assuming normal CA verification. Pass --client-pin <sha256> if the certificate is self-signed or signed by a private CA." "无法读取 ${cert}；将按系统 CA 验证处理。若证书为自签名或私有 CA 签发，请显式指定 --client-pin <sha256>。")"
      fi
    fi
  fi
  q="up=${eup}&down=${edown}&mux=${emux}&morph=${morph}&socks=$(urlencode "$DEFAULT_VECTOR_SOCKS")"
  [[ "$sni" == none || -z "$sni" ]] || q+="&sni=$(urlencode "$sni")"
  [[ "$pin" == none || -z "$pin" ]] || q+="&pin=${pin}"
  validate_pin "$pin"
  printf 'vector://%s@%s?%s' "$(urlencode "$key")" "$ep" "$q"
}

show_links() {
  [[ -s "$URL_FILE" ]] || die "$(tr_msg "No V2 config" "没有 V2 配置")"
  install_runtime_deps
  local u role vlink generic name q
  IFS= read -r u <"$URL_FILE"; role="$(url_role "$u")"
  if [[ "$role" == vector ]]; then printf '%s\n' "$u"; return 0; fi
  if ! vlink="$(build_native_vector_link_from_portal "$u")"; then warn "$(tr_msg "Client links were not generated; see the notes above (missing public host, or a certificate pin that cannot be verified)." "未生成客户端链接；请查看上面的提示（缺少公网地址，或无法验证证书 pin）。")"; return 1; fi
  printf '\n%s\n%s\n' "$(tr_msg "Native V2 Vector URL:" "原生 V2 Vector URL：")" "$vlink"
  # Generic nowhere:// URI: only for alternate clients explicitly confirmed to speak Nowhere V2.
  generic="${vlink/vector:\/\//nowhere://}"; generic="$(python3 - "$generic" <<'PY'
import sys,urllib.parse
u=urllib.parse.urlsplit(sys.argv[1]); q=[(k,v) for k,v in urllib.parse.parse_qsl(u.query,keep_blank_values=True) if k!='socks']
print(urllib.parse.urlunsplit((u.scheme,u.netloc,u.path,urllib.parse.urlencode(q),'')),end='')
PY
)"
  name="${NODE_NAME:-Nowhere-V2}"
  printf '\n%s\n%s#%s\n' "$(tr_msg "Generic V2 share URI (client must explicitly support V2/nw2):" "通用 V2 分享 URI（客户端必须明确支持 V2/nw2）：")" "$generic" "$(urlencode "$name")"
}

# 0 = the certificate is self-signed, 1 = CA-signed, 2 = unreadable/unparsable.
# Used to decide whether a tls=2 link needs a pin (see build_native_vector_link_from_portal).
certificate_needs_pin() {
  local cert="$1" subj iss
  [[ -r "$cert" ]] || return 2
  subj="$(openssl x509 -in "$cert" -noout -subject 2>/dev/null || true)"; subj="${subj#*=}"
  iss="$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null || true)"; iss="${iss#*=}"
  [[ -n "$subj" && -n "$iss" ]] || return 2
  [[ "$subj" == "$iss" ]] && return 0
  # issuer != subject is NOT the same as system-trusted: a certificate signed by
  # a private CA fails verification too, and a pin-less link would then be
  # rejected by every client. Only skip the pin when the chain actually verifies.
  openssl verify -untrusted "$cert" "$cert" >/dev/null 2>&1 && return 1
  return 0
}

# Fetch the running local Portal's TLS certificate fingerprint. Also used to
# auto-pin client links (see build_native_vector_link_from_portal).
local_portal_fingerprint() {
  local u="$1" ep host port fp cert tls morph
  tls="$(query_get "$u" tls)"; tls="${tls:-1}"
  if [[ "$tls" == 2 ]]; then
    cert="$(query_get "$u" crt)"
    fp="$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null)" || return 1
    fp="${fp#*=}"
  else
    ep="$(url_endpoint "$u")"
    [[ "$(endpoint_has_tcp portal "$ep")" == 1 ]] || return 1
    host="$(endpoint_host portal "$ep")"; port="$(endpoint_tcp_port portal "$ep")"
    if [[ "$host" == '*' ]]; then
      [[ "$(endpoint_tcp_family portal "$ep")" == 6 ]] && host='[::1]' || host=127.0.0.1
    fi
    morph="$(query_get "$u" morph)"; morph="${morph:-0}"
    [[ -x "$BIN_LINK" ]] || return 1
    fp="$(timeout 12 "$BIN_LINK" fingerprint "nowhere://$(urlencode "$(url_key "$u")")@${host}:${port}?morph=${morph}" 2>/dev/null)" || return 1
  fi
  fp="${fp//:/}"; fp="${fp,,}"
  [[ "$fp" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$fp"
}

fingerprint() {
  require_root; install_runtime_deps
  [[ -s "$URL_FILE" ]] || die "$(tr_msg "No configuration" "没有配置")"
  local u
  IFS= read -r u <"$URL_FILE"
  [[ "$(url_role "$u")" == portal ]] || die "$(tr_msg "Fingerprint is a Portal operation" "仅 Portal 支持本机证书指纹")"
  local_portal_fingerprint "$u" || die "$(tr_msg "Cannot read the fingerprint; a UDP-only tls=1 Portal cannot be probed - use a persistent PEM certificate." "无法获取指纹；仅 UDP + tls=1 无法探测，请使用持久 PEM 证书。")"
}

port_listening_tcp() { port_listening tcp "$1" "${2:-0}"; }
port_listening_udp() { port_listening udp "$1" "${2:-0}"; }
port_listening() {
  local proto="$1" port="$2" family="${3:-0}" opt rows
  case "$proto:$family" in
    tcp:4) opt='-4ltn' ;; tcp:6) opt='-6ltn' ;; tcp:*) opt='-ltn' ;;
    udp:4) opt='-4lun' ;; udp:6) opt='-6lun' ;; udp:*) opt='-lun' ;;
    *) return 1 ;;
  esac
  rows="$(ss ${opt}H 2>/dev/null || ss ${opt} 2>/dev/null | awk 'NR>1')"
  awk '{print $4}' <<<"$rows" | grep -Eq "(^|[:.])${port}$"
}

doctor_action() {
  require_root; require_systemd; install_runtime_deps
  local fail=0 warnc=0 u role ep p fam tls f ik kk nx
  printf '\n%b%s%b\n' "$C_CYAN" "$(tr_msg 'Nowhere V2 Doctor' 'Nowhere V2 健康检查')" "$C_NC"
  if [[ -x "$CURRENT_LINK/nowhere" ]]; then ok "$(tr_msg "V2 binary exists" "V2 二进制文件存在")"; else warn "$(tr_msg "V2 binary missing" "V2 二进制文件缺失")"; fail=$((fail+1)); fi
  if [[ -L "$BIN_LINK" && -x "$BIN_LINK" ]]; then
    ok "$(tr_msg "V2 binary link is valid" "V2 二进制软链接正常")"
    local bv=""; bv="$("$BIN_LINK" --version 2>/dev/null || true)"
    if [[ -n "$bv" && ! "$bv" =~ (^|[^0-9])v?2\.[0-9]+\.[0-9]+ ]]; then warn "$(tr_msg "Installed binary version does not look like V2: $bv" "已安装的二进制版本看起来不是 V2: $bv")"; fail=$((fail+1)); fi
  else warn "$(tr_msg "V2 binary link missing/broken" "V2 二进制软链接缺失或损坏")"; fail=$((fail+1)); fi
  if [[ -s "$URL_FILE" ]]; then
    IFS= read -r u <"$URL_FILE"
    if ( validate_imported_url "$u" ) >/dev/null 2>&1; then ok "$(tr_msg "V2 config URL validates" "V2 配置 URL 校验通过")"; else warn "$(tr_msg "V2 config URL is invalid" "V2 配置 URL 无效")"; fail=$((fail+1)); u=""; fi
  else warn "$(tr_msg "V2 config missing" "V2 配置缺失")"; fail=$((fail+1)); u=""; fi
  if id "$RUN_USER" >/dev/null 2>&1; then ok "$(tr_msg "Dedicated user exists" "V2 专用用户存在")"; else warn "$(tr_msg "Dedicated V2 user missing" "V2 专用用户缺失")"; fail=$((fail+1)); fi
  systemctl is-enabled --quiet "$SERVICE_NAME" && ok "$(tr_msg "Service enabled" "服务已设置开机启动")" || { warn "$(tr_msg "Service not enabled" "服务未设置开机启动")"; warnc=$((warnc+1)); }
  systemctl is-active --quiet "$SERVICE_NAME" && ok "$(tr_msg "Service active" "服务正在运行")" || { warn "$(tr_msg "Service not active" "服务未运行")"; fail=$((fail+1)); }
  if [[ -n "$u" ]]; then
    role="$(url_role "$u")"; ep="$(url_endpoint "$u")"
    # A 2.2.0+ core refuses to start on legacy shared keys; surface the reason
    # instead of leaving only "service not active".
    ik="$(installed_core_version)"; ik="${ik:-$VERSION}"
    if version_ge "$ik" v2.2.0 && [[ "$role" == portal ]]; then
      kk="$(url_key "$u")"
      if ! is_valid_key_value "$kk"; then
        warn "$(tr_msg "Portal key is not 32-64 lowercase hex, and the installed core (${ik}) refuses to start with a legacy key. Rotate with an auto-generated key and update every peer." "Portal 密钥不是 32-64 位小写十六进制，而当前 Core（${ik}）会因旧格式密钥拒绝启动。请轮换为自动生成的新密钥并同步更新所有对端。")"
        warnc=$((warnc+1))
      fi
      nx="$(query_get "$u" next)"
      if [[ -n "$nx" && "$nx" != none ]] && ! is_valid_key_value "${nx%@*}"; then
        warn "$(tr_msg "Next-hop key inside next= is not 32-64 lowercase hex; a 2.2.0+ core refuses it." "next= 中的下一跳密钥不是 32-64 位小写十六进制；2.2.0+ Core 将拒绝该配置。")"
        warnc=$((warnc+1))
      fi
    fi
    if [[ "$role" == portal ]]; then
      if [[ "$(endpoint_has_tcp portal "$ep")" == 1 ]]; then p="$(endpoint_tcp_port portal "$ep")"; fam="$(endpoint_tcp_family portal "$ep")"; port_listening_tcp "$p" "$fam" && ok "$(tr_msg "TCP carrier listens on ${p} (family ${fam})" "TCP carrier 正在监听 ${p}（地址族 ${fam}）")" || { warn "$(tr_msg "TCP carrier not listening on ${p} for family ${fam}" "TCP carrier 未在 ${p} 监听（地址族 ${fam}）")"; fail=$((fail+1)); }; fi
      if [[ "$(endpoint_has_udp portal "$ep")" == 1 ]]; then p="$(endpoint_udp_port portal "$ep")"; fam="$(endpoint_udp_family portal "$ep")"; port_listening_udp "$p" "$fam" && ok "$(tr_msg "UDP carrier listens on ${p} (family ${fam})" "UDP carrier 正在监听 ${p}（地址族 ${fam}）")" || { warn "$(tr_msg "UDP carrier not listening on ${p} for family ${fam}" "UDP carrier 未在 ${p} 监听（地址族 ${fam}）")"; fail=$((fail+1)); }; fi
      tls="$(query_get "$u" tls)"; if [[ "$tls" == 2 ]]; then
        for f in "$(query_get "$u" crt)" "$(query_get "$u" key)"; do runuser -u "$RUN_USER" -- test -r "$f" 2>/dev/null && ok "$(tr_msg "TLS file readable: ${f}" "TLS 文件可读: ${f}")" || { warn "$(tr_msg "TLS file not readable by ${RUN_USER}: ${f}" "${RUN_USER} 无法读取 TLS 文件: ${f}")"; fail=$((fail+1)); }; done
      fi
    else
      p="$(query_get "$u" socks | sed 's/.*://')"; [[ "$p" =~ ^[0-9]+$ ]] && port_listening_tcp "$p" && ok "$(tr_msg "Vector SOCKS listens on ${p}" "Vector SOCKS 正在监听 ${p}")" || { warn "$(tr_msg "Vector SOCKS listener not detected" "未检测到 Vector SOCKS 监听")"; fail=$((fail+1)); }
    fi
    [[ "$(query_get "$u" morph)" == 1 ]] && { warn "$(tr_msg "Morph is enabled. Peer versions cannot be checked from this host: every peer on this hop must also run Nowhere >=2.1.0 with morph=1." "Morph 已启用（本机无法验证对端版本）：此跳所有对端都必须同样运行 Nowhere >=2.1.0 且开启 morph=1。")"; warnc=$((warnc+1)); }
  fi
  if systemctl list-unit-files --no-legend nowhere.service 2>/dev/null | grep -q '^nowhere\.service'; then
    warn "$(tr_msg "V1 service definition detected. V2 files are isolated, but network ports must not collide." "检测到 V1 服务。V1/V2 文件已隔离，但监听端口不能冲突。")"
    warnc=$((warnc+1))
  fi
  if [[ "$DOCTOR_FIX" -eq 1 ]]; then
    # Repairs rewrite the unit/launcher and restart the service, so serialise
    # them against install/configure like every other mutating action.
    acquire_build_lock
    info "$(tr_msg "doctor --fix may rewrite V2 management files and restart ${SERVICE_NAME}." "doctor --fix 可能重写 V2 管理文件并重启 ${SERVICE_NAME}。")"
    info "$(tr_msg "Applying safe V2 management repairs..." "正在应用安全的 V2 管理修复...")"
    ensure_user; [[ -x "$CURRENT_LINK/nowhere" ]] && ln -sfn "$CURRENT_LINK/nowhere" "$BIN_LINK"
    # write_unit interpolates MEMORY_PROFILE and MORPH_PRELUDE. Without re-reading
    # manager.conf first, a repair would silently reset a configured value to the
    # script default while manager.conf kept the original.
    load_meta
    write_launcher; write_unit
    [[ -s "$URL_FILE" ]] && { chmod 640 "$URL_FILE"; chown root:"$RUN_GROUP" "$URL_FILE"; }
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    [[ -s "$URL_FILE" && -x "$CURRENT_LINK/nowhere" ]] && systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
    wait_service 8 && ok "$(tr_msg "Doctor --fix restarted V2 service" "Doctor --fix 已重启 V2 服务")" || true
  fi
  if ((fail>0)); then
    printf '\n'; journalctl -u "$SERVICE_NAME" -n 30 --no-pager 2>/dev/null || true
    warn "$(tr_msg "Doctor: ${fail} critical issue(s), ${warnc} warning(s)" "Doctor：${fail} 个严重问题，${warnc} 个警告")"
    return 1
  fi
  ok "$(tr_msg "Doctor passed (${warnc} warning(s))" "Doctor 检查通过（${warnc} 个警告）")"
}

rollback_action() {
  require_root; require_systemd; acquire_build_lock
  local current d target=""
  current="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
  while IFS= read -r d; do [[ "$d" != "$current" && -x "$d/nowhere" ]] && { target="$d"; break; }; done < <(ls -1dt "$RELEASES_DIR"/* 2>/dev/null || true)
  [[ -n "$target" ]] || die "$(tr_msg "No previous valid V2 release found" "没有找到可回滚的旧 V2 Release")"
  info "$(tr_msg "Rolling back V2 binary to $target" "正在回滚 V2 二进制到 $target")"
  if rollback_binary "$target"; then ok "$(tr_msg "Rollback succeeded" "回滚成功")"; else [[ -n "$current" ]] && rollback_binary "$current" || true; die "$(tr_msg "Rollback target failed; original restored when possible" "目标版本回滚失败，已尽可能恢复原版本")"; fi
}

backup_action() {
  require_root; install_runtime_deps; acquire_build_lock
  local out="${1:-/root/nowhere-v2-backup-$(date +%Y%m%d-%H%M%S).tar.gz}"
  [[ ! -e "$out" ]] || die "$(tr_msg "Backup target already exists; refusing to overwrite: $out" "备份文件已存在，拒绝覆盖：$out")"
  [[ -d "$CONFIG_DIR" ]] || { warn "$(tr_msg "No V2 configuration directory found: ${CONFIG_DIR}" "未找到 V2 配置目录: ${CONFIG_DIR}")"; return 1; }
  # Refuse an output path inside the directory being archived: tar would try to
  # include its own output and warn about the file changing as it is read.
  local out_dir cfg_abs
  out_dir="$(readlink -f "$(dirname -- "$out")" 2>/dev/null || true)"
  cfg_abs="$(readlink -f "$CONFIG_DIR" 2>/dev/null || true)"
  if [[ -n "$out_dir" && -n "$cfg_abs" && ( "$out_dir" == "$cfg_abs" || "$out_dir" == "$cfg_abs"/* ) ]]; then
    die "$(tr_msg "Backup output must be outside ${CONFIG_DIR}." "备份输出不能放在 ${CONFIG_DIR} 目录内。")"
  fi
  if ! tar -czf "$out" -C "$(dirname "$CONFIG_DIR")" "$(basename "$CONFIG_DIR")"; then
    rm -f -- "$out" 2>/dev/null || true
    die "$(tr_msg "Backup failed" "备份失败")"
  fi
  chmod 600 "$out" || die "$(tr_msg "Backup created but chmod 600 failed: $out" "备份已创建，但设置 600 权限失败: $out")"
  ok "$(tr_msg "Config/TLS backup: $out" "配置/TLS 备份已创建: $out")"
}

clean_build() {
  require_root; acquire_build_lock; cleanup_stale_swap
  rm -rf /var/tmp/nowhere-v2-build.* 2>/dev/null || true
  cleanup_swap || true; release_build_lock; ok "$(tr_msg "V2 build leftovers cleaned" "V2 编译残留已清理")"
}

uninstall_action() {
  require_root; require_systemd; acquire_build_lock
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f -- "$UNIT_FILE" "$LAUNCHER" "$BIN_LINK"; rm -rf -- "$INSTALL_ROOT"; systemctl daemon-reload
  if [[ "$PURGE" -eq 1 ]]; then rm -rf -- "$CONFIG_DIR"; userdel "$RUN_USER" 2>/dev/null || true; groupdel "$RUN_GROUP" 2>/dev/null || true; fi
  ok "$(tr_msg "Nowhere V2 removed. V1 installation was not touched." "Nowhere V2 已卸载，V1 安装未被修改。")"
}

check_updates() {
  ( VERSION=latest-v2; resolve_version; printf '%s\n' "$VERSION" )
}

self_update() {
  [[ -n "$SELF_UPDATE_URL" ]] || { warn "$(tr_msg "Self-update is disabled (NOWHERE_V2_SELF_URL is empty)." "自更新已禁用（NOWHERE_V2_SELF_URL 为空）。")"; return 1; }
  require_command curl
  local tmp remote_ver remote_channel self backup staging
  tmp="$(mktemp)"; CLEANUP_PATHS+=("$tmp")
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 --max-time 15 -o "$tmp" "$SELF_UPDATE_URL" || return 1
  bash -n "$tmp" || { warn "$(tr_msg "Downloaded manager has syntax errors" "下载的管理脚本存在语法错误")"; return 1; }
  remote_ver="$(grep -oE '^readonly SCRIPT_VERSION="[^"]+"' "$tmp" | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  remote_channel="$(grep -oE '^readonly SCRIPT_CHANNEL="[^"]+"' "$tmp" | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  [[ "$remote_channel" == v2 ]] || { warn "$(tr_msg "Refusing cross-channel self-update" "拒绝跨通道自更新")"; return 1; }
  [[ "$remote_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { warn "$(tr_msg "Invalid remote script version" "远端脚本版本无效")"; return 1; }
  [[ "$remote_ver" != "$SCRIPT_VERSION" ]] || { info "$(tr_msg "Manager already up to date" "管理脚本已是最新")"; return 0; }
  version_ge "$remote_ver" "$SCRIPT_VERSION" || {
    warn "$(tr_msg "Refusing to downgrade the manager: remote ${remote_ver} is older than local ${SCRIPT_VERSION}." "拒绝降级管理脚本：远端 ${remote_ver} 低于本地 ${SCRIPT_VERSION}。")"
    return 1
  }
  prompt_confirm "$(tr_msg "Apply V2 manager update ${SCRIPT_VERSION} -> ${remote_ver}?" "应用 V2 管理脚本更新 ${SCRIPT_VERSION} -> ${remote_ver}？")" || return 0
  self="$(readlink -f "$0" 2>/dev/null || echo "$0")"; backup="${self}.bak.$(date +%s)"; cp "$self" "$backup" || return 1
  staging="${self}.upgrade.$$"; cp "$tmp" "$staging" && chmod 755 "$staging" && mv -f "$staging" "$self" || { rm -f "$staging"; return 1; }
  ok "$(tr_msg "V2 manager updated; backup: ${backup}" "V2 管理脚本已更新；备份: ${backup}")"; exit 0
}

show_v1_migration_note() {
  if [[ "$LANG_CODE" == zh ]]; then
    cat <<'EOF2'
Nowhere V2 与 V1 的线协议不兼容。
不要让 V1 Portal / Vector / native-next / 其它 V1 客户端直接连接此 V2 服务。
同一条流量路径上的所有节点都需要一起升级到 V2。V2 使用固定 ALPN nw2 和新的 endpoint carrier 语法。
本 V2 管理器不会修改 /etc/nowhere、/opt/nowhere、/usr/local/bin/nowhere 或 nowhere.service。
EOF2
  else
    cat <<'EOF2'
Nowhere V2 is wire-incompatible with V1.
Do not point a V1 Portal/Vector/native-next/alternate V1 client at this V2 service.
Upgrade every peer on a traffic path together. V2 uses fixed ALPN nw2 and endpoint carrier paths.
This V2 manager never edits /etc/nowhere, /opt/nowhere, /usr/local/bin/nowhere, or nowhere.service.
EOF2
  fi
}

interactive_menu() {
  require_root
  require_systemd
  if [[ "$LANG_CODE" == ask ]]; then
    printf '1) 中文\n2) English\n'
    local l
    read -r -p '请选择语言 / Language [1]: ' l </dev/tty || l=""
    [[ "$l" == 2 ]] && LANG_CODE=en || LANG_CODE=zh
  fi

  while true; do
    clear
    printf '\033[1;36m====================================================\033[0m\n'
    if [[ "$LANG_CODE" == zh ]]; then
      printf '\033[1;32m        Nowhere V2 管理器 v%s\033[0m\n' "$SCRIPT_VERSION"
    else
      printf '\033[1;32m        Nowhere V2 Manager v%s\033[0m\n' "$SCRIPT_VERSION"
    fi
    printf '\033[1;36m====================================================\033[0m\n'

    if [[ "$LANG_CODE" == zh ]]; then
      cat <<'EOF2'
 [1] 安装/重装官方 V2 预编译版
 [2] 从源码编译安装 V2
 [3] 修改 / 导入 V2 配置
 [4] 查看运行状态
 [5] 显示 V2 连接链接
 [6] 查看实时日志
 [7] 重启 V2 服务
 [8] 打开 V2 TUI 监控
 [9] 查看 TLS SHA-256 指纹
 [10] 回滚 V2 二进制版本
 [11] 健康检查 / Doctor
 [12] 健康检查并自动修复 / Doctor --fix
 [13] 清理旧的 V2 Release
 [14] 清理 V2 编译缓存
 [15] 检查最新稳定 V2 版本
 [16] 查看 V1 -> V2 兼容性说明
 [17] 仅卸载 V2
 [18] 更新 V2 管理脚本
 [0] 退出
EOF2
    else
      cat <<'EOF2'
 [1] Install/Reinstall official V2 release
 [2] Build/install V2 from source
 [3] Configure / Import V2 URL
 [4] Status
 [5] Show V2 links
 [6] Live logs
 [7] Restart V2 service
 [8] Open V2 TUI
 [9] TLS SHA-256 fingerprint
 [10] Rollback V2 binary
 [11] Doctor
 [12] Doctor --fix
 [13] Clean old V2 releases
 [14] Clean V2 build cache
 [15] Check latest stable V2
 [16] V1 -> V2 compatibility note
 [17] Uninstall V2 only
 [18] Self-update V2 manager
 [0] Exit
EOF2
    fi

    local c
    read -r -p "$(tr_msg 'Choice [0-18]: ' '请输入选项 [0-18]: ')" c </dev/tty || exit 0
    set +e
    # Subshells do not run the parent EXIT trap, so re-arm cleanup/rollback here:
    # a failing menu action must restore the transaction snapshot before the menu
    # resumes, exactly like a failing top-level CLI action does.
    ( set -e; trap cleanup_all EXIT
    case "$c" in
      1) ACTION=install; INSTALL_METHOD=release; install_action ;;
      2) ACTION=install; INSTALL_METHOD=source; install_action ;;
      3) configure_action ;;
      4) show_status ;;
      5) show_links || true ;;
      6) info "$(tr_msg 'Press Ctrl+C to stop viewing logs.' '按 Ctrl+C 退出实时日志。')"; journalctl -u "$SERVICE_NAME" -f || true ;;
      7) systemctl restart "$SERVICE_NAME" && ok "$(tr_msg 'Restarted.' 'V2 服务已重启。')" || warn "$(tr_msg 'Restart failed.' 'V2 服务重启失败。')" ;;
      8) [[ -x "$BIN_LINK" ]] && runuser -u "$RUN_USER" -- env TMPDIR=/run/nowhere-v2 "$BIN_LINK" tui || warn "$(tr_msg 'V2 binary not installed.' '尚未安装 V2 二进制文件。')" ;;
      9) fingerprint || true ;;
      10) rollback_action ;;
      11) DOCTOR_FIX=0; doctor_action ;;
      12) DOCTOR_FIX=1; doctor_action ;;
      13) cleanup_old_releases ;;
      14) clean_build ;;
      15) check_updates || true ;;
      16) show_v1_migration_note ;;
      17) prompt_confirm "$(tr_msg 'Purge V2 config too?' '是否同时删除 V2 配置和密钥？')" && PURGE=1 || PURGE=0; uninstall_action ;;
      18) self_update ;;
      0) exit 42 ;;
      *) warn "$(tr_msg 'Invalid choice.' '无效选项。')" ;;
    esac
    )
    local action_rc=$?
    set -e
    [[ "$action_rc" != 42 ]] || return 0
    printf '\n'
    read -r -p "$(tr_msg 'Press Enter to return...' '按回车键返回菜单...')" _ </dev/tty || true
  done
}

usage() {
  if [[ "$LANG_CODE" == zh ]]; then
    cat <<EOF2
Nowhere V2 管理器 v${SCRIPT_VERSION}（通道：${SCRIPT_CHANNEL}）
仅用于 Nowhere v2.x；不会修改 V1 的文件或服务。

用法：
  sudo bash nowhere-v2.sh
  sudo bash nowhere-v2.sh install [选项]
  sudo bash nowhere-v2.sh upgrade [--version latest-v2|v2.x.y]  （需要已有 V2 配置）
  sudo bash nowhere-v2.sh configure [选项]
  sudo bash nowhere-v2.sh doctor [--fix]
  sudo bash nowhere-v2.sh status | links | logs | restart | tui | fingerprint
  sudo bash nowhere-v2.sh rollback | clean-releases | clean-build | check-updates
  sudo bash nowhere-v2.sh backup [路径]                   （仅备份配置/TLS）
  sudo bash nowhere-v2.sh uninstall [--purge]
  sudo bash nowhere-v2.sh self-update                     （默认从本仓库 main 分支更新）

Core 版本策略：
  默认：${DEFAULT_CORE_VERSION}（安装时解析为官网最新稳定 v2.x.y）
  允许：指定稳定版 v2.x.y，或 latest-v2
  拒绝：V1、普通 latest、预发布版本、v3.x（NW3 协议，本管理器不支持）

主要 V2 参数：
  -y, --yes                    非交互模式
  --method release|source      预编译版 / 源码编译
  --force-reconfigure          install/upgrade 时明确重新应用配置参数
  --version v2.x.y|latest-v2   Core 版本
  --type portal|vector         节点角色
  --url 'portal://...' | 'vector://...'
  --key KEY                    共享密钥：32-64 位小写 hex（Nowhere 2.2.0+）
  --endpoint 'HOST:PORT' | 'HOST/tcp:PORT/udp:PORT'
  --public-host HOST           公网 IP / 域名
  --tls 1|2 --cert FILE --tls-key FILE --copy-cert
  --morph 0|1                  Morph 线路伪装
  --up auto|tcp|udp|mix --down auto|tcp|udp|mix --mux 0|1
  --sni NAME|none --pin SHA256|none
  --vector-socks HOST:PORT
  --out-socks HOST:PORT|none --next KEY@ENDPOINT|none
  --rate Mbps --etar Mbps --log LEVEL
  --dial auto|IP                         出站源 IP（与 --dial4/--dial6 互斥）
  --dial4 auto|IP --dial6 auto|IP        Nowhere 2.2.0+ 双栈出站源地址（auto 或裸 IP）
  --memory-profile memory|balanced|throughput
  --morph-prelude low7|full8   TCP Morph 客户端 prelude 策略（默认 full8）
  --config-mode ask|quick|advanced | --quick | --advanced
  --keep-releases N            保留旧 Release 数量（0-20）
  --libc auto|gnu|musl --swap auto|off|MB --keep-source
  --github-token TOKEN

V1/V2 隔离：
  服务：${SERVICE_NAME}
  配置：${CONFIG_DIR}
  安装目录：${INSTALL_ROOT}
  二进制：${BIN_LINK}
EOF2
  else
    cat <<EOF2
Nowhere V2 Manager v${SCRIPT_VERSION} (channel: ${SCRIPT_CHANNEL})
Dedicated to Nowhere v2.x; V1 files/services are never modified.

Usage:
  sudo bash nowhere-v2.sh
  sudo bash nowhere-v2.sh install [options]
  sudo bash nowhere-v2.sh upgrade [--version latest-v2|v2.x.y]  (existing V2 config required)
  sudo bash nowhere-v2.sh configure [options]
  sudo bash nowhere-v2.sh doctor [--fix]
  sudo bash nowhere-v2.sh status | links | logs | restart | tui | fingerprint
  sudo bash nowhere-v2.sh rollback | clean-releases | clean-build | check-updates
  sudo bash nowhere-v2.sh backup [PATH]                   (config/TLS only)
  sudo bash nowhere-v2.sh uninstall [--purge]
  sudo bash nowhere-v2.sh self-update                     (updates from this repo's main by default)

Core version policy:
  Default: ${DEFAULT_CORE_VERSION} (resolved to the newest stable v2.x.y at install time)
  Allowed: exact stable v2.x.y or latest-v2
  Rejected: V1, plain 'latest', prereleases, v3.x (NW3 is not supported by this manager)

Important V2 options:
  -y, --yes
  --method release|source
  --force-reconfigure           With install/upgrade, explicitly apply config CLI overrides
  --version v2.x.y|latest-v2
  --type portal|vector
  --url 'portal://...' | 'vector://...'
  --key KEY                      Shared key: 32-64 lowercase hex (Nowhere 2.2.0+)
  --endpoint 'HOST:PORT' | 'HOST/tcp:PORT/udp:PORT'
  --public-host HOST
  --tls 1|2 --cert FILE --tls-key FILE --copy-cert
  --morph 0|1
  --up auto|tcp|udp|mix --down auto|tcp|udp|mix --mux 0|1
  --sni NAME|none --pin SHA256|none
  --vector-socks HOST:PORT
  --out-socks HOST:PORT|none --next KEY@ENDPOINT|none
  --rate Mbps --etar Mbps --log LEVEL
  --dial auto|IP                        Outbound source IP (mutually exclusive with --dial4/--dial6)
  --dial4 auto|IP --dial6 auto|IP       Nowhere 2.2.0+ dual-stack outbound sources (auto or bare IP)
  --memory-profile memory|balanced|throughput
  --morph-prelude low7|full8    TCP Morph client prelude policy (default full8)
  --config-mode ask|quick|advanced | --quick | --advanced
  --keep-releases N (0-20)
  --libc auto|gnu|musl --swap auto|off|MB --keep-source
  --github-token TOKEN

Isolation:
  Service: ${SERVICE_NAME}
  Config:  ${CONFIG_DIR}
  Root:    ${INSTALL_ROOT}
  Binary:  ${BIN_LINK}
EOF2
  fi
}

set_cli() { CLI_SET["$1"]=1; CLI_VAL["$1"]="$2"; printf -v "$1" '%s' "$2"; }

parse_args() {
  if (($#>0)); then
    case "$1" in
      install|upgrade|update|configure|config|status|link|links|logs|log|restart|start|stop|tui|fingerprint|rollback|doctor|check|diagnose|clean-releases|clean-build|check-updates|backup|uninstall|remove|self-update|help) ACTION="$1"; shift ;;
    esac
  fi
  if [[ "$ACTION" == upgrade || "$ACTION" == update ]]; then UPGRADE_MODE=1; VERSION=latest-v2; fi
  while (($#)); do
    case "$1" in
      -y|--yes) ASSUME_YES=1; shift ;;
      --method) INSTALL_METHOD="${2:?missing --method}"; shift 2 ;;
      --version) VERSION="${2:?missing --version}"; validate_version_arg "$VERSION"; shift 2 ;;
      --libc) LIBC="${2:?missing --libc}"; shift 2 ;;
      --type|--role) set_cli ROLE "${2:?missing --type}"; shift 2 ;;
      --url) IMPORT_URL="${2:?missing --url}"; shift 2 ;;
      --key) set_cli KEY "${2:?missing --key}"; shift 2 ;;
      --endpoint) set_cli ENDPOINT "${2:?missing --endpoint}"; shift 2 ;;
      --public-host|--host) set_cli PUBLIC_HOST "${2:?missing --public-host}"; shift 2 ;;
      --name) set_cli NODE_NAME "${2:?missing --name}"; shift 2 ;;
      --tls) set_cli TLS "${2:?missing --tls}"; shift 2 ;;
      --cert|--crt) set_cli CERT "${2:?missing --cert}"; shift 2 ;;
      --tls-key) set_cli TLS_KEY "${2:?missing --tls-key}"; shift 2 ;;
      --copy-cert) COPY_CERT=1; shift ;;
      --morph) set_cli MORPH "${2:?missing --morph}"; shift 2 ;;
      --rate) set_cli RATE "${2:?missing --rate}"; shift 2 ;;
      --etar) set_cli ETAR "${2:?missing --etar}"; shift 2 ;;
      --dial) set_cli DIAL "${2:?missing --dial}"; validate_dial_value any "$DIAL"; shift 2 ;;
      --dial4) set_cli DIAL4 "${2:?missing --dial4}"; validate_dial_value 4 "$DIAL4"; shift 2 ;;
      --dial6) set_cli DIAL6 "${2:?missing --dial6}"; validate_dial_value 6 "$DIAL6"; shift 2 ;;
      --log) set_cli LOG_LEVEL "${2:?missing --log}"; shift 2 ;;
      --out-socks) set_cli OUT_SOCKS "${2:?missing --out-socks}"; shift 2 ;;
      --next) set_cli NEXT "${2:?missing --next}"; shift 2 ;;
      --up) set_cli UP "${2:?missing --up}"; shift 2 ;;
      --down) set_cli DOWN "${2:?missing --down}"; shift 2 ;;
      --mux) set_cli MUX "${2:?missing --mux}"; shift 2 ;;
      --sni) set_cli SNI "${2:?missing --sni}"; shift 2 ;;
      --pin) set_cli PIN "${2:?missing --pin}"; shift 2 ;;
      --vector-socks) set_cli VECTOR_SOCKS "${2:?missing --vector-socks}"; shift 2 ;;
      --client-up) set_cli CLIENT_UP "${2:?missing --client-up}"; shift 2 ;;
      --client-down) set_cli CLIENT_DOWN "${2:?missing --client-down}"; shift 2 ;;
      --client-mux) set_cli CLIENT_MUX "${2:?missing --client-mux}"; shift 2 ;;
      --client-sni) set_cli CLIENT_SNI "${2:?missing --client-sni}"; shift 2 ;;
      --client-pin) set_cli CLIENT_PIN "${2:?missing --client-pin}"; shift 2 ;;
      --memory-profile) set_cli MEMORY_PROFILE "${2:?missing --memory-profile}"; validate_memory_profile "$MEMORY_PROFILE"; shift 2 ;;
      --morph-prelude) set_cli MORPH_PRELUDE "${2:?missing --morph-prelude}"; validate_morph_prelude "$MORPH_PRELUDE"; shift 2 ;;
      --config-mode) CONFIG_MODE="${2:?missing --config-mode}"; validate_config_mode "$CONFIG_MODE"; shift 2 ;;
      --quick) CONFIG_MODE=quick; shift ;;
      --advanced) CONFIG_MODE=advanced; shift ;;
      --keep-releases) KEEP_RELEASES="${2:?missing --keep-releases}"; validate_keep_releases "$KEEP_RELEASES"; shift 2 ;;
      --swap) SWAP_MODE="${2:?missing --swap}"; shift 2 ;;
      --keep-source) KEEP_SOURCE=1; shift ;;
      --github-token) GITHUB_TOKEN="${2:?missing --github-token}"; shift 2 ;;
      --fix) DOCTOR_FIX=1; shift ;;
      --force-reconfigure) FORCE_RECONFIGURE=1; shift ;;
      --purge) PURGE=1; shift ;;
      -h|--help) ACTION=help; shift ;;
      *) if [[ "$ACTION" == backup && -z "$BACKUP_PATH" && "$1" != -* ]]; then BACKUP_PATH="$1"; shift; else die "$(tr_msg "Unknown option: ${1}" "未知选项: ${1}")"; fi ;;
    esac
  done
}

apply_noninteractive_defaults() {
  # Never synthesize credentials over an existing/imported configuration.
  [[ -s "$URL_FILE" || -n "$IMPORT_URL" ]] && return 0
  validate_role "$ROLE"; validate_bool01 morph "$MORPH"; validate_memory_profile "$MEMORY_PROFILE"; validate_morph_prelude "$MORPH_PRELUDE"
  [[ -n "$KEY" ]] || KEY="$(random_key)"
  if [[ -z "$ENDPOINT" ]]; then
    [[ "$ROLE" == portal ]] && ENDPOINT="*:${DEFAULT_PORT}" || die "$(tr_msg "Vector non-interactive mode requires --endpoint" "Vector 非交互模式需要 --endpoint")"
  fi
  if [[ "$ROLE" == vector ]]; then
    validate_socks_endpoint "$VECTOR_SOCKS"
  fi
}

main() {
  parse_args "$@"
  validate_version_arg "$VERSION"; validate_keep_releases "$KEEP_RELEASES"; validate_config_mode "$CONFIG_MODE"; validate_memory_profile "$MEMORY_PROFILE"; validate_morph_prelude "$MORPH_PRELUDE"; validate_dial_settings
  [[ "$LANG_CODE" == ask && "$ACTION" != menu ]] && resolve_language auto
  # Defaults are only synthesized for a fresh generated configuration. Existing
  # configs are loaded inside configure_action, and imported URLs carry their own key/endpoint.
  if [[ "$ASSUME_YES" -eq 1 && "$ACTION" =~ ^(install|configure|config)$ && ! -s "$URL_FILE" && -z "$IMPORT_URL" ]]; then
    apply_noninteractive_defaults
  fi
  case "$ACTION" in
    menu) interactive_menu ;;
    install|upgrade|update) [[ "$INSTALL_METHOD" == release || "$INSTALL_METHOD" == source ]] || die "$(tr_msg "--method must be release|source" "--method 必须为 release|source")"; install_action ;;
    configure|config) configure_action ;;
    status) show_status ;;
    link|links) show_links ;;
    logs|log) require_root; require_systemd; journalctl -u "$SERVICE_NAME" -f ;;
    restart|start|stop) require_root; require_systemd; systemctl "$ACTION" "$SERVICE_NAME" ;;
    tui) require_root; [[ -x "$BIN_LINK" ]] || die "$(tr_msg "V2 binary not installed" "尚未安装 V2 二进制")"; runuser -u "$RUN_USER" -- env TMPDIR=/run/nowhere-v2 "$BIN_LINK" tui ;;
    fingerprint) fingerprint ;;
    rollback) rollback_action ;;
    doctor|check|diagnose) doctor_action ;;
    clean-releases) cleanup_old_releases ;;
    clean-build) clean_build ;;
    check-updates) check_updates ;;
    backup) backup_action "$BACKUP_PATH" ;;
    uninstall|remove) uninstall_action ;;
    self-update) self_update ;;
    help) usage ;;
    *) usage; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
