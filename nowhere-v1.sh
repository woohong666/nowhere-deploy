#!/usr/bin/env bash
#
# Nowhere Unified Management Script v2.5.2
# Merged from v2.3.0 (self-update, version picker, i18n, status panel, read</dev/tty, swap cleanup)
#            and v3.0.0 (URL import/migrate, Vector role, fingerprint, --copy-cert, launcher, advanced params)
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 woohong666
#
set -Eeuo pipefail
umask 077

# ============================================================
# 常量
# ============================================================
readonly SCRIPT_VERSION="2.5.3"
readonly UPSTREAM_REPO="NodePassProject/Nowhere"
readonly DEFAULT_REPO_URL="https://github.com/NodePassProject/Nowhere.git"
readonly SCRIPT_CHANNEL="v1-stable"
readonly PINNED_NOWHERE_VERSION="v1.8.3"
readonly DEFAULT_VERSION="$PINNED_NOWHERE_VERSION"
readonly MIN_RUSTC="1.85.0"
readonly SELF_UPDATE_URL="${NOWHERE_SELF_URL:-https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v1.sh}"

readonly SERVICE_NAME="nowhere"
readonly RUN_USER="nowhere"
readonly RUN_GROUP="nowhere"
readonly INSTALL_ROOT="/opt/nowhere"
readonly RELEASES_DIR="${INSTALL_ROOT}/releases"
readonly CURRENT_LINK="${INSTALL_ROOT}/current"
readonly BIN_LINK="/usr/local/bin/nowhere"
readonly LAUNCHER="/usr/local/libexec/nowhere-launch"
readonly CONFIG_DIR="/etc/nowhere"
readonly URL_FILE="${CONFIG_DIR}/url.conf"
readonly META_FILE="${CONFIG_DIR}/manager.conf"
readonly UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly TLS_DIR="${CONFIG_DIR}/tls"

readonly SRC_DIR="/var/tmp/nowhere-build"
readonly SWAP_FILE="/var/tmp/nowhere-build-swap"
readonly BUILD_LOCK_DIR="/run/nowhere-build.lock.d"
readonly RUSTUP_HOME_DIR="/usr/local/rustup"
readonly CARGO_HOME_DIR="/usr/local/cargo"

readonly DEFAULT_PORT="2077"
readonly DEFAULT_NET="mix"
readonly DEFAULT_TLS="1"
readonly DEFAULT_ALPN="now/1"
readonly DEFAULT_LOG="info"
readonly DEFAULT_VECTOR_SOCKS="127.0.0.1:1080"
readonly DEFAULT_UP="udp"
readonly DEFAULT_DOWN="udp"
readonly DEFAULT_MUX="0"
readonly DEFAULT_KEEP_RELEASES="3"

# ============================================================
# 运行状态
# ============================================================
LANG_CODE="${NOWHERE_LANG:-ask}"
ACTION="menu"
ASSUME_YES=0
INSTALL_METHOD="release"
VERSION="${NOWHERE_VERSION:-$DEFAULT_VERSION}"
LIBC="${NOWHERE_LIBC:-auto}"
KEEP_SOURCE="${NOWHERE_KEEP_SOURCE:-0}"
KEEP_RELEASES="${NOWHERE_KEEP_RELEASES:-$DEFAULT_KEEP_RELEASES}"
CONFIG_MODE="${NOWHERE_CONFIG_MODE:-ask}"
PURGE=0
COPY_CERT=0
SWAP_MODE="${NOWHERE_SWAP:-auto}"
SWAP_CREATED=0
BUILD_LOCK_HELD=0
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

ROLE="portal"
IMPORT_URL=""
KEY="${NOWHERE_KEY:-}"
PORT="${NOWHERE_PORT:-$DEFAULT_PORT}"
LISTEN_HOST="${NOWHERE_LISTEN_HOST:-}"
PUBLIC_HOST="${NOWHERE_CLIENT_HOST:-}"
NODE_NAME="${NOWHERE_CLIENT_NAME:-}"
NET="${NOWHERE_NET:-$DEFAULT_NET}"
TLS="${NOWHERE_TLS:-$DEFAULT_TLS}"
CERT="${NOWHERE_CERT:-}"
TLS_KEY="${NOWHERE_TLS_KEY:-}"
ALPN="$DEFAULT_ALPN"
RATE="0"
ETAR="0"
DIAL="auto"
LOG_LEVEL="$DEFAULT_LOG"
OUT_SOCKS="none"
NEXT="none"
UP="$DEFAULT_UP"
DOWN="$DEFAULT_DOWN"
MUX="$DEFAULT_MUX"
SNI="none"
PIN="none"
VECTOR_SOCKS="$DEFAULT_VECTOR_SOCKS"
CLIENT_UP="auto"
CLIENT_DOWN="auto"
CLIENT_MUX="auto"
CLIENT_SNI="auto"
CLIENT_PIN="none"

CLEANUP_PATHS=()
OLD_TARGET=""
NEW_TARGET=""
BUILD_DIR=""
PARSED_KEY=""; PARSED_HOST=""; PARSED_PORT=""
declare -A CLI_SET=()
declare -A CLI_VAL=()

# ============================================================
# 颜色 / 日志
# ============================================================
if [[ -t 1 ]]; then
  C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
  C_BLUE='\033[1;34m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_NC=''
fi

info() { printf '%b[Nowhere]%b %s\n' "$C_BLUE" "$C_NC" "$*"; }
ok()   { printf '%b[OK]%b %s\n' "$C_GREEN" "$C_NC" "$*"; }
warn() { printf '%b[Warn]%b %s\n' "$C_YELLOW" "$C_NC" "$*" >&2; }
die()  { printf '%b[Error]%b %s\n' "$C_RED" "$C_NC" "$*" >&2; exit 1; }

# ============================================================
# i18n
# ============================================================
resolve_language() {
  local requested="${1:-auto}" locale
  case "$requested" in
    auto)
      locale="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
      case "$locale" in
        zh*|ZH*) LANG_CODE="zh" ;;
        ru*|RU*) LANG_CODE="ru" ;;
        *) LANG_CODE="en" ;;
      esac
      ;;
    en|zh|ru) LANG_CODE="$requested" ;;
    *) LANG_CODE="en" ;;
  esac
}

tr_msg() {
  local en="$1" zh="$2" ru="$3"
  case "$LANG_CODE" in
    zh) printf '%s' "$zh" ;;
    ru) printf '%s' "$ru" ;;
    *) printf '%s' "$en" ;;
  esac
}

# ============================================================
# 清理
# ============================================================
acquire_build_lock() {
  [[ "$BUILD_LOCK_HELD" -eq 1 ]] && return 0
  [[ "$(id -u)" -eq 0 ]] || die "$(tr_msg "Build lock requires root." "构建锁需要 root 权限。" "Для блокировки сборки нужен root.")"
  local attempt pid=""
  for attempt in 1 2 3; do
    if mkdir -m 700 "$BUILD_LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" >"${BUILD_LOCK_DIR}/pid"
      BUILD_LOCK_HELD=1
      return 0
    fi

    pid=""
    if [[ -r "${BUILD_LOCK_DIR}/pid" ]]; then
      IFS= read -r pid <"${BUILD_LOCK_DIR}/pid" || true
    fi
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      die "$(tr_msg "Another Nowhere source build/cleanup is running (PID ${pid})." \
                     "另一个 Nowhere 源码构建/清理正在运行（PID ${pid}）。" \
                     "Другая сборка/очистка Nowhere уже запущена (PID ${pid}).")"
    fi

    warn "$(tr_msg "Removing stale build lock: ${BUILD_LOCK_DIR}" \
                   "发现残留构建锁，正在清理: ${BUILD_LOCK_DIR}" \
                   "Удаление устаревшей блокировки: ${BUILD_LOCK_DIR}")"
    rm -rf -- "$BUILD_LOCK_DIR" 2>/dev/null || true
  done
  die "$(tr_msg "Cannot acquire build lock." "无法获取构建锁。" "Не удалось получить блокировку сборки.")"
}

release_build_lock() {
  if [[ "$BUILD_LOCK_HELD" -eq 1 ]]; then
    rm -rf -- "$BUILD_LOCK_DIR" 2>/dev/null || true
    BUILD_LOCK_HELD=0
  fi
}

swap_file_active() {
  awk -v p="$SWAP_FILE" 'NR>1 && $1==p {found=1} END{exit(found?0:1)}' /proc/swaps 2>/dev/null
}

cleanup_swap() {
  if swap_file_active; then
    if has_cmd swapoff && swapoff "$SWAP_FILE" 2>/dev/null; then
      SWAP_CREATED=0
    else
      warn "$(tr_msg "Could not deactivate temporary swap; leaving file in place: ${SWAP_FILE}" "无法卸载临时 swap，保留文件避免活动 swap 被误删: ${SWAP_FILE}" "Не удалось отключить swap; файл оставлен: ${SWAP_FILE}")"
      return 1
    fi
  else
    SWAP_CREATED=0
  fi
  # Only the process holding the build lock owns this fixed swap path.
  if [[ "$BUILD_LOCK_HELD" -eq 1 ]]; then
    rm -f "$SWAP_FILE" 2>/dev/null || true
  fi
}

cleanup_all() {
  local p
  if (( ${#CLEANUP_PATHS[@]} > 0 )); then
    for p in "${CLEANUP_PATHS[@]}"; do
      [[ -n "$p" ]] && rm -rf -- "$p" 2>/dev/null || true
    done
  fi
  cleanup_swap || true
  release_build_lock
}
trap cleanup_all EXIT

# Only call after acquire_build_lock(): avoids disabling swap used by another live build.
cleanup_stale_swap() {
  [[ "$BUILD_LOCK_HELD" -eq 1 ]] || die "$(tr_msg "Internal error: build lock is required before swap cleanup." \
                                                     "内部错误：清理 swap 前必须先取得构建锁。" \
                                                     "Внутренняя ошибка: перед очисткой swap нужна блокировка.")"
  [[ -e "$SWAP_FILE" ]] || return 0
  if command -v swapon >/dev/null 2>&1 && \
     swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAP_FILE"; then
    has_cmd swapoff || die "$(tr_msg "swapoff is required to clean stale swap." "清理残留 swap 需要 swapoff 命令。" "Для очистки swap требуется swapoff.")"
    warn "$(tr_msg "Found stale swap in use, deactivating: ${SWAP_FILE}" \
                   "发现残留 swap 正在使用，正在卸载: ${SWAP_FILE}" \
                   "Обнаружен устаревший активный swap: ${SWAP_FILE}")"
    swapoff "$SWAP_FILE" 2>/dev/null || die "$(tr_msg "Failed to deactivate stale swap: ${SWAP_FILE}" \
                                                     "无法卸载残留 swap: ${SWAP_FILE}" \
                                                     "Не удалось отключить swap: ${SWAP_FILE}")"
  fi
  rm -f "$SWAP_FILE" 2>/dev/null || die "$(tr_msg "Failed to remove stale swap: ${SWAP_FILE}" \
                                                   "无法删除残留 swap: ${SWAP_FILE}" \
                                                   "Не удалось удалить swap: ${SWAP_FILE}")"
}

# ============================================================
# 环境检查
# ============================================================
require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "$(tr_msg "Run as root: sudo bash $0" "请以 root 权限运行: sudo bash $0" "Запустите от root: sudo bash $0")"
}
require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "$(tr_msg "systemctl required." "缺少 systemctl。" "Требуется systemctl.")"
  [[ -d /run/systemd/system ]] || die "$(tr_msg "systemd not running." "systemd 未运行。" "systemd не запущен.")"
}
require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$(tr_msg "Missing command: $1" "缺少命令: $1" "Отсутствует: $1")"
}
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# ============================================================
# 验证器
# ============================================================
validate_version() {
  [[ "$1" == "$PINNED_NOWHERE_VERSION" ]] ||
    die "$(tr_msg "This stable script is pinned to Nowhere ${PINNED_NOWHERE_VERSION}; requested: $1" \
                   "此稳定脚本已固定使用 Nowhere ${PINNED_NOWHERE_VERSION}；拒绝版本: $1" \
                   "Этот стабильный скрипт закреплён на Nowhere ${PINNED_NOWHERE_VERSION}; запрошено: $1")"
}
validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )) || die "$(tr_msg "Port must be 1-65535." "端口必须 1-65535。" "Порт 1-65535.")"
}
validate_key() {
  [[ "$1" =~ ^[A-Za-z0-9._~-]{16,255}$ ]] ||
    die "$(tr_msg "Key must be 16-255 chars (A-Z a-z 0-9 . _ ~ -)." "密钥必须 16-255 位，仅允许 A-Z a-z 0-9 . _ ~ -" "Ключ 16-255 символов.")"
}
validate_role() { [[ "$1" == portal || "$1" == vector ]] || die "$(tr_msg "role must be portal|vector" "type 只能是 portal|vector" "role = portal|vector")"; }
validate_net() { [[ "$1" == mix || "$1" == tcp || "$1" == udp ]] || die "$(tr_msg "net must be mix|tcp|udp" "net 只能是 mix|tcp|udp" "net = mix|tcp|udp")"; }
validate_carrier() { [[ "$1" == mix || "$1" == tcp || "$1" == udp ]] || die "$(tr_msg "up/down must be mix|tcp|udp" "up/down 只能是 mix|tcp|udp" "up/down = mix|tcp|udp")"; }
validate_mux() { [[ "$1" == 0 || "$1" == 1 ]] || die "$(tr_msg "mux must be 0|1" "mux 只能是 0|1" "mux = 0|1")"; }
validate_tls() { [[ "$1" == 1 || "$1" == 2 ]] || die "$(tr_msg "tls must be 1|2" "tls 只能是 1|2" "tls = 1|2")"; }
validate_log() { [[ "$1" =~ ^(none|debug|info|warn|error|event)$ ]] || die "$(tr_msg "log invalid: $1" "log 等级无效: $1" "log invalid: $1")"; }
validate_rate() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "$(tr_msg "rate/etar must be non-negative" "rate/etar 必须非负" "rate/etar >= 0")"; }
validate_keep_releases() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 0 && 10#$1 <= 20 )) ||
    die "$(tr_msg "keep-releases must be 0-20 (0 disables auto cleanup)." "keep-releases 必须为 0-20（0 表示关闭自动清理）。" "keep-releases должен быть 0-20 (0 отключает автоочистку).")"
}
validate_config_mode() {
  [[ "$1" == ask || "$1" == quick || "$1" == advanced ]] ||
    die "$(tr_msg "config-mode must be ask|quick|advanced" "config-mode 只能是 ask|quick|advanced" "config-mode = ask|quick|advanced")"
}
validate_single_line() { [[ "$2" != *$'\n'* && "$2" != *$'\r'* ]] || die "$(tr_msg "$1 cannot contain newline" "$1 不能包含换行符" "$1 не может содержать перевод строки")"; }
validate_alpn() {
  local v="${1:-}" LC_ALL=C
  validate_single_line alpn "$v"
  (( ${#v} >= 1 && ${#v} <= 255 )) || die "$(tr_msg "ALPN must be 1-255 bytes." "ALPN 必须为 1-255 字节。" "ALPN должен быть 1-255 байт.")"
}
validate_pin() {
  local v="${1:-none}"
  [[ -z "$v" || "$v" == none || "$v" =~ ^[A-Fa-f0-9]{64}$ ]] || die "$(tr_msg "pin must be none or 64 hex characters." "pin 必须为 none 或 64 位十六进制 SHA-256。" "pin = none или 64 hex символа.")"
}
validate_sni() {
  local v="${1:-none}"
  [[ -z "$v" || "$v" == none || "$v" =~ ^[A-Za-z0-9.-]+$ ]] || die "$(tr_msg "sni must be a DNS name or none." "sni 必须为 DNS 名称或 none。" "sni должен быть DNS-именем или none.")"
}
validate_import_key() {
  local v="$1" LC_ALL=C
  validate_single_line key "$v"
  (( ${#v} >= 1 && ${#v} <= 255 )) || die "$(tr_msg "Imported shared key must be 1-255 bytes." "导入的共享密钥必须为 1-255 字节。" "Импортированный ключ должен быть 1-255 байт.")"
}
validate_percent_encoding() {
  local s="$1" tail hex
  tail="$s"
  while [[ "$tail" == *%* ]]; do
    tail="${tail#*%}"
    (( ${#tail} >= 2 )) || die "$(tr_msg "Malformed percent-encoding in URL." "URL 中存在不完整的百分号编码。" "Некорректное percent-encoding в URL.")"
    hex="${tail:0:2}"
    [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ ]] || die "$(tr_msg "Malformed percent-encoding in URL: %${hex}" "URL 百分号编码无效: %${hex}" "Некорректное percent-encoding: %${hex}")"
    tail="${tail:2}"
  done
}
validate_host_port_endpoint() {
  local endpoint="$1" allow_empty_host="${2:-0}" host port
  [[ -n "$endpoint" ]] || die "$(tr_msg "Endpoint cannot be empty." "地址不能为空。" "Адрес не может быть пустым.")"
  if [[ "$endpoint" == \[*\]:* ]]; then
    host="${endpoint#\[}"; host="${host%%\]*}"; port="${endpoint##*:}"
  else
    [[ "$endpoint" == *:* ]] || die "$(tr_msg "Endpoint must be HOST:PORT." "地址必须为 HOST:PORT。" "Адрес должен быть HOST:PORT.")"
    host="${endpoint%:*}"; port="${endpoint##*:}"
    [[ "$host" != *:* ]] || die "$(tr_msg "IPv6 endpoint must use [IPv6]:PORT." "IPv6 地址必须写成 [IPv6]:PORT。" "IPv6 должен быть в виде [IPv6]:PORT.")"
  fi
  [[ -n "$host" || "$allow_empty_host" == 1 ]] || die "$(tr_msg "Endpoint host cannot be empty." "地址主机不能为空。" "Хост не может быть пустым.")"
  validate_port "$port"
}
validate_socks_endpoint() {
  local endpoint="$1" allow_empty_host="${2:-0}" dest="$1" creds
  [[ -n "$endpoint" && "$endpoint" != none ]] || die "$(tr_msg "SOCKS endpoint cannot be empty/none when enabled." "启用 SOCKS 时地址不能为空/none。" "SOCKS-адрес не может быть пустым/none.")"
  if [[ "$dest" == *@* ]]; then
    creds="${dest%@*}"; dest="${dest##*@}"
    [[ -n "$creds" ]] || die "$(tr_msg "SOCKS credentials before @ cannot be empty." "SOCKS 的 @ 前认证信息不能为空。" "SOCKS credentials перед @ не могут быть пустыми.")"
  fi
  validate_host_port_endpoint "$dest" "$allow_empty_host"
}
validate_next_endpoint() {
  local endpoint="$1" keypart dest LC_ALL=C
  [[ "$endpoint" == *@* ]] || die "$(tr_msg "next must be KEY@HOST:PORT." "next 必须为 KEY@HOST:PORT。" "next должен быть KEY@HOST:PORT.")"
  keypart="${endpoint%@*}"; dest="${endpoint##*@}"
  (( ${#keypart} >= 1 && ${#keypart} <= 255 )) || die "$(tr_msg "next shared key must be 1-255 bytes." "next 共享密钥必须为 1-255 字节。" "Ключ next должен быть 1-255 байт.")"
  validate_host_port_endpoint "$dest" 0
}
extract_endpoint_port() {
  local endpoint="${1:-}" dest
  dest="${endpoint##*@}"
  [[ "$dest" == *:* ]] || return 1
  printf '%s' "${dest##*:}"
}

# ============================================================
# 输入工具（全部 </dev/tty）
# ============================================================
prompt() {
  local p="$1" d="${2:-}" v
  if [[ -n "$d" ]]; then
    read -r -p "$p [$d]: " v </dev/tty || v=""
    printf '%s' "${v:-$d}"
  else
    read -r -p "$p: " v </dev/tty || v=""
    printf '%s' "$v"
  fi
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

# v2.4.2: 默认值改为当前 PORT，并循环校验，直接写入全局 PORT
prompt_port() {
  local input default="${PORT:-$DEFAULT_PORT}"
  while true; do
    read -rp "$(tr_msg "Listen port [1-65535] (Default: ${default}): " \
                     "监听端口 [1-65535] (默认 ${default}): " \
                     "Порт [1-65535] (по умолчанию ${default}): ")" input </dev/tty || input=""
    input="${input:-$default}"
    if [[ "$input" =~ ^[0-9]+$ ]] && (( 10#$input >= 1 && 10#$input <= 65535 )); then
      PORT="$input"; return 0
    fi
    warn "$(tr_msg "Invalid port." "端口无效。" "Неверный порт.")"
  done
}

# v2.4.2: 默认值改为当前 KEY；为空时随机；循环校验，直接写入全局 KEY
prompt_key() {
  local input default
  default="${KEY:-$(random_key)}"
  while true; do
    read -rp "$(tr_msg "Shared key (Default: ${default}): " \
                     "共享密钥 (回车保留: ${default}): " \
                     "Ключ (по умолчанию: ${default}): ")" input </dev/tty || input=""
    input="${input:-$default}"
    if [[ "$input" =~ ^[A-Za-z0-9._~-]{16,255}$ ]]; then
      KEY="$input"; return 0
    fi
    warn "$(tr_msg "Key 16-255 chars (A-Z a-z 0-9 . _ ~ -)." \
                   "密钥 16-255 位，仅允许 A-Z a-z 0-9 . _ ~ -" \
                   "Ключ 16-255 символов.")"
  done
}

prompt_choice() {
  local prompt="$1" default="$2"; shift 2
  local input v
  while true; do
    read -rp "${prompt} (Default: ${default}): " input </dev/tty || input=""
    input="${input:-$default}"
    for v in "$@"; do
      if [[ "$input" == "$v" ]]; then printf '%s' "$input"; return 0; fi
    done
    warn "$(tr_msg "Invalid choice. Allowed: $*" "无效选项，允许: $*" "Неверный выбор: $*")"
  done
}

random_key() {
  if has_cmd openssl; then
    openssl rand -base64 24 | tr '+/' '-_' | tr -d '=\n'
  else
    LC_ALL=C tr -dc 'A-Za-z0-9._~-' </dev/urandom | head -c 32
    printf '\n'
  fi
}

# ============================================================
# URL 工具
# ============================================================
urlencode() {
  local s="${1:-}" out="" c i
  local LC_ALL=C
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9.~_-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

urldecode() {
  local s="${1:-}"
  printf '%b' "${s//%/\\x}" 2>/dev/null || printf '%s' "$s"
}

format_host() {
  local h="${1:-}"
  if [[ -z "$h" ]]; then printf ''; return 0; fi
  if [[ "$h" == \[*\] ]]; then printf '%s' "$h"; return 0; fi
  if [[ "$h" == *:* ]]; then printf '[%s]' "$h"; return 0; fi
  printf '%s' "$h"
}

strip_brackets() { local h="${1:-}"; h="${h#[}"; h="${h%]}"; printf '%s' "$h"; }

is_ip_literal() {
  local h; h="$(strip_brackets "${1:-}")"
  [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$h" == *:* ]]
}

query_get() {
  local url="$1" key="$2" query part
  query="${url#*\?}"; [[ "$query" != "$url" ]] || return 0
  query="${query%%#*}"
  local -a _parts
  IFS='&' read -r -a _parts <<< "$query"
  for part in "${_parts[@]}"; do
    if [[ "${part%%=*}" == "$key" ]]; then printf '%s' "${part#*=}"; return 0; fi
  done
  return 0
}

query_strip() {
  local url="$1" key="$2" base query frag="" part out=""
  if [[ "$url" == *#* ]]; then frag="#${url#*#}"; url="${url%%#*}"; fi
  if [[ "$url" != *\?* ]]; then printf '%s%s' "$url" "$frag"; return 0; fi
  base="${url%%\?*}"; query="${url#*\?}"
  local -a _parts
  IFS='&' read -r -a _parts <<< "$query"
  for part in "${_parts[@]}"; do
    if [[ -z "$part" || "${part%%=*}" == "$key" ]]; then continue; fi
    out+="${out:+&}${part}"
  done
  printf '%s%s%s' "$base" "${out:+?${out}}" "$frag"
}

query_append() {
  local url="$1" pair="$2" frag=""
  if [[ "$url" == *#* ]]; then frag="#${url#*#}"; url="${url%%#*}"; fi
  if [[ "$url" == *\?* ]]; then
    printf '%s&%s%s' "$url" "$pair" "$frag"
  else
    printf '%s?%s%s' "$url" "$pair" "$frag"
  fi
}

# 迁移旧格式：nowhere:// → vector://；spec= / pool= 迁移
migrate_url() {
  local url="$1" up down was_nowhere=0
  validate_single_line url "$url"
  if [[ "$url" == nowhere://* ]]; then
    was_nowhere=1
    url="${url%%#*}"
    url="vector://${url#nowhere://}"
  elif [[ "$url" == *#* ]]; then
    warn "$(tr_msg "Fragment not allowed in run URL; stripped." "运行 URL 不允许 fragment，已移除。" "Fragment не разрешён в run URL.")"
    url="${url%%#*}"
  fi
  if [[ "$was_nowhere" -eq 1 && -z "$(query_get "$url" socks)" ]]; then
    url="$(query_append "$url" "socks=$(urlencode "$DEFAULT_VECTOR_SOCKS")")"
  fi
  if [[ -n "$(query_get "$url" spec)" ]]; then
    url="$(query_strip "$url" spec)"
    warn "$(tr_msg "Removed deprecated spec= (Nowhere 1.5)." "已移除 Nowhere 1.5 废弃参数 spec=。" "Удалён spec= (Nowhere 1.5).")"
  fi
  if [[ -n "$(query_get "$url" pool)" ]]; then
    up="$(query_get "$url" up)"; down="$(query_get "$url" down)"
    url="$(query_strip "$url" pool)"
    if [[ "$up" == tcp && "$down" == tcp && -z "$(query_get "$url" mux)" ]]; then
      url="$(query_append "$url" 'mux=1')"
    fi
    warn "$(tr_msg "Migrated pool= to mux semantics (Nowhere 1.8)." "已把 Nowhere 1.8 废弃参数 pool= 迁移为 mux 语义。" "pool= мигрирован в mux (Nowhere 1.8).")"
  fi
  if [[ "$(query_get "$url" up)" == udp && "$(query_get "$url" down)" == udp && "$(query_get "$url" mux)" == 1 ]]; then
    url="$(query_strip "$url" mux)"; url="$(query_append "$url" 'mux=0')"
  fi
  printf '%s' "$url"
}

detect_role_from_url() {
  case "$1" in
    portal://*) printf portal ;;
    vector://*|nowhere://*) printf vector ;;
    *) return 1 ;;
  esac
}

parse_authority() {
  local u="$1" scheme rest auth
  u="${u%%#*}"; scheme="${u%%://*}"; rest="${u#*://}"
  [[ "$rest" != "$u" ]] || return 1
  auth="${rest%%\?*}"
  [[ "$auth" == *@* ]] || return 1
  PARSED_KEY="$(urldecode "${auth%%@*}")"
  rest="${auth#*@}"
  if [[ "$rest" == \[*\]:* ]]; then
    PARSED_HOST="${rest#\[}"; PARSED_HOST="${PARSED_HOST%%\]*}"
    PARSED_PORT="${rest##*:}"
  else
    PARSED_PORT="${rest##*:}"; PARSED_HOST="${rest%:${PARSED_PORT}}"
  fi
  [[ "$PARSED_PORT" =~ ^[0-9]+$ ]] || return 1
}

# ============================================================
# 构建 URL
# ============================================================
carrier_mux_pair() {
  local up="$1" down="$2" mux="$3"
  if [[ "$up" == udp && "$down" == udp ]]; then printf 0; else printf '%s' "$mux"; fi
}

build_portal_url() {
  validate_key "$KEY"; validate_port "$PORT"; validate_net "$NET"; validate_tls "$TLS"
  validate_log "$LOG_LEVEL"; validate_rate "$RATE"; validate_rate "$ETAR"; validate_alpn "$ALPN"
  [[ "$OUT_SOCKS" == none || "$NEXT" == none ]] || die "$(tr_msg "socks= and next= are mutually exclusive." "socks= 与 next= 互斥。" "socks= и next= взаимоисключающие.")"
  local host query url eff_mux
  host="$(format_host "$LISTEN_HOST")"
  query="tls=${TLS}&net=${NET}"
  [[ "$ALPN" == "$DEFAULT_ALPN" ]] || query+="&alpn=$(urlencode "$ALPN")"
  [[ "$RATE" == 0 ]] || query+="&rate=${RATE}"
  [[ "$ETAR" == 0 ]] || query+="&etar=${ETAR}"
  [[ "$DIAL" == auto || -z "$DIAL" ]] || query+="&dial=$(urlencode "$DIAL")"
  [[ "$LOG_LEVEL" == "$DEFAULT_LOG" ]] || query+="&log=${LOG_LEVEL}"
  if [[ "$TLS" == 2 ]]; then
    [[ -f "$CERT" && -f "$TLS_KEY" ]] || die "$(tr_msg "tls=2 requires existing --cert and --tls-key." "tls=2 必须提供存在的 --cert 与 --tls-key。" "tls=2 требует --cert и --tls-key.")"
    query+="&crt=$(urlencode "$CERT")&key=$(urlencode "$TLS_KEY")"
  fi
  if [[ "$OUT_SOCKS" != none && -n "$OUT_SOCKS" ]]; then
    validate_socks_endpoint "$OUT_SOCKS" 0
    query+="&socks=$(urlencode "$OUT_SOCKS")"
  elif [[ "$NEXT" != none && -n "$NEXT" ]]; then
    validate_next_endpoint "$NEXT"
    validate_carrier "$UP"; validate_carrier "$DOWN"; validate_mux "$MUX"; validate_sni "$SNI"; validate_pin "$PIN"
    eff_mux="$(carrier_mux_pair "$UP" "$DOWN" "$MUX")"
    query+="&next=$(urlencode "$NEXT")&up=${UP}&down=${DOWN}&mux=${eff_mux}"
    [[ "$SNI" == none || -z "$SNI" ]] || query+="&sni=$(urlencode "$SNI")"
    [[ "$PIN" == none || -z "$PIN" ]] || query+="&pin=$(urlencode "$PIN")"
  fi
  url="portal://$(urlencode "$KEY")@${host}:${PORT}?${query}"
  printf '%s' "$url"
}

build_vector_url() {
  validate_key "$KEY"; validate_port "$PORT"; validate_carrier "$UP"; validate_carrier "$DOWN"
  validate_mux "$MUX"; validate_log "$LOG_LEVEL"; validate_rate "$RATE"; validate_rate "$ETAR"; validate_alpn "$ALPN"
  validate_sni "$SNI"; validate_pin "$PIN"
  [[ -n "$PUBLIC_HOST" ]] || die "$(tr_msg "Vector requires --host Portal address." "Vector 必须指定 --host Portal 地址。" "Vector требует --host.")"
  [[ -n "$VECTOR_SOCKS" && "$VECTOR_SOCKS" != none ]] || die "$(tr_msg "Vector requires local SOCKS listen addr." "Vector 必须指定本地 SOCKS 监听地址。" "Vector требует SOCKS адрес.")"
  validate_socks_endpoint "$VECTOR_SOCKS" 1
  local host query eff_mux
  host="$(format_host "$PUBLIC_HOST")"
  eff_mux="$(carrier_mux_pair "$UP" "$DOWN" "$MUX")"
  query="up=${UP}&down=${DOWN}&mux=${eff_mux}&socks=$(urlencode "$VECTOR_SOCKS")"
  [[ "$ALPN" == "$DEFAULT_ALPN" ]] || query+="&alpn=$(urlencode "$ALPN")"
  [[ "$SNI" == none || -z "$SNI" ]] || query+="&sni=$(urlencode "$SNI")"
  [[ "$PIN" == none || -z "$PIN" ]] || query+="&pin=$(urlencode "$PIN")"
  [[ "$RATE" == 0 ]] || query+="&rate=${RATE}"
  [[ "$ETAR" == 0 ]] || query+="&etar=${ETAR}"
  [[ "$LOG_LEVEL" == "$DEFAULT_LOG" ]] || query+="&log=${LOG_LEVEL}"
  printf 'vector://%s@%s:%s?%s' "$(urlencode "$KEY")" "$host" "$PORT" "$query"
}

detect_public_host() {
  local h=""
  h="$(curl -4fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$h" ]] || h="$(curl -6fsS --max-time 4 https://api64.ipify.org 2>/dev/null || true)"
  printf '%s' "$h"
}

build_share_link() {
  local run_url="$1" r host cup cdown cmux csni cpin tls net link_alpn
  r="$(detect_role_from_url "$run_url" 2>/dev/null || true)"
  [[ "$r" == portal ]] || return 0
  parse_authority "$run_url" || return 1
  host="$PUBLIC_HOST"; [[ -n "$host" ]] || host="$PARSED_HOST"
  [[ -n "$host" ]] || host="$(detect_public_host)"
  [[ -n "$host" ]] || die "$(tr_msg "Cannot detect public IP; pass --host." "无法检测公网 IP，请用 --host 指定。" "Укажите --host.")"
  net="$(query_get "$run_url" net)"; net="${net:-mix}"
  tls="$(query_get "$run_url" tls)"; tls="${tls:-1}"
  link_alpn="$(query_get "$run_url" alpn)"; link_alpn="$(urldecode "${link_alpn:-$DEFAULT_ALPN}")"
  cup="$CLIENT_UP"; cdown="$CLIENT_DOWN"
  [[ "$cup" == auto ]] && cup="$net"
  [[ "$cdown" == auto ]] && cdown="$net"
  validate_carrier "$cup"; validate_carrier "$cdown"
  cmux="$CLIENT_MUX"
  if [[ "$cmux" == auto ]]; then
    if [[ "$cup" == udp && "$cdown" == udp ]]; then cmux=0; else cmux=1; fi
  fi
  validate_mux "$cmux"; cmux="$(carrier_mux_pair "$cup" "$cdown" "$cmux")"
  csni="$CLIENT_SNI"
  if [[ "$csni" == auto ]]; then
    if [[ "$tls" == 2 ]] && ! is_ip_literal "$host"; then csni="$host"; else csni="none"; fi
  fi
  cpin="$CLIENT_PIN"
  local q="up=${cup}&down=${cdown}&mux=${cmux}"
  [[ "$link_alpn" == "$DEFAULT_ALPN" ]] || q+="&alpn=$(urlencode "$link_alpn")"
  [[ "$csni" == none || -z "$csni" ]] || q+="&sni=$(urlencode "$csni")"
  [[ "$cpin" == none || -z "$cpin" ]] || q+="&pin=$(urlencode "$cpin")"
  local name="$NODE_NAME"; [[ -n "$name" ]] || name="Nowhere-${host}"
  printf 'nowhere://%s@%s:%s?%s#%s' "$(urlencode "$PARSED_KEY")" "$(format_host "$host")" "$PARSED_PORT" "$q" "$(urlencode "$name")"
}

# ============================================================
# 版本管理
# ============================================================
version_number_ge() {
  local a="${1%%-*}" b="${2%%-*}" a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<< "$a"
  IFS=. read -r b1 b2 b3 <<< "$b"
  (( 10#${a1:-0} > 10#${b1:-0} ||
     (10#${a1:-0} == 10#${b1:-0} && 10#${a2:-0} > 10#${b2:-0}) ||
     (10#${a1:-0} == 10#${b1:-0} && 10#${a2:-0} == 10#${b2:-0} && 10#${a3:-0} >= 10#${b3:-0}) ))
}

version_supported() {
  [[ "${1:-}" == "$PINNED_NOWHERE_VERSION" ]]
}

# Stable V1 channel: deliberately no remote version picker.
# Nowhere v2.0.0 is wire-incompatible with v1.x and must use a separate manager.
choose_version_interactive() {
  printf '%s\n' "$(tr_msg \
    "Stable channel pinned to Nowhere ${PINNED_NOWHERE_VERSION} (V2 is intentionally unsupported here)." \
    "稳定通道固定为 Nowhere ${PINNED_NOWHERE_VERSION}（此脚本明确不支持 V2）。" \
    "Стабильный канал закреплён на Nowhere ${PINNED_NOWHERE_VERSION} (V2 здесь намеренно не поддерживается).")" >&2
  printf '%s' "$PINNED_NOWHERE_VERSION"
}

resolve_version() {
  validate_version "$VERSION"
  VERSION="$PINNED_NOWHERE_VERSION"
}


# ============================================================
# 依赖安装
# ============================================================
pkg_manager() {
  local c
  for c in apt-get dnf yum apk zypper; do
    command -v "$c" >/dev/null 2>&1 && { printf '%s' "$c"; return 0; }
  done
  return 1
}

install_runtime_deps() {
  local need=0 c
  for c in curl tar python3 sha256sum; do has_cmd "$c" || need=1; done
  [[ "$need" -eq 0 ]] && return 0
  local pm; pm="$(pkg_manager)" || die "$(tr_msg "No supported package manager." "未找到受支持的包管理器。" "Нет пакетного менеджера.")"
  info "$(tr_msg "Installing runtime deps..." "正在安装运行依赖..." "Установка зависимостей...")"
  case "$pm" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates tar python3 coreutils ;;
    dnf|yum) "$pm" install -y curl ca-certificates tar python3 coreutils ;;
    apk) apk add --no-cache curl ca-certificates tar python3 coreutils ;;
    zypper) zypper --non-interactive install curl ca-certificates tar python3 coreutils ;;
  esac
}

install_build_deps() {
  local need=0
  has_cmd git || need=1
  has_cmd cargo || need=1
  if ! has_cmd cc && ! has_cmd gcc && ! has_cmd clang; then need=1; fi
  [[ "$need" -eq 0 ]] && return 0
  local pm; pm="$(pkg_manager)" || die "$(tr_msg "No supported package manager." "未找到受支持的包管理器。" "Нет пакетного менеджера.")"
  info "$(tr_msg "Installing build deps..." "正在安装构建依赖..." "Установка build deps...")"
  case "$pm" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential git curl ca-certificates pkg-config ;;
    dnf|yum) "$pm" install -y gcc gcc-c++ make git curl ca-certificates pkgconf-pkg-config ;;
    apk) apk add --no-cache build-base git curl ca-certificates pkgconf ;;
    zypper) zypper --non-interactive install gcc gcc-c++ make git curl ca-certificates pkg-config ;;
  esac
}

detect_libc() {
  case "$LIBC" in
    gnu|musl) printf '%s' "$LIBC"; return ;;
    auto) ;;
    *) die "$(tr_msg "--libc must be auto|gnu|musl" "--libc 只能是 auto|gnu|musl" "--libc = auto|gnu|musl")" ;;
  esac
  if [[ -f /etc/alpine-release ]] || (has_cmd ldd && ldd --version 2>&1 | grep -qi musl); then
    printf musl
  else
    printf gnu
  fi
}

ensure_rust() {
  local have=""
  if has_cmd rustc && has_cmd cargo; then
    have="$(rustc --version 2>/dev/null | awk '{print $2}')"
    if [[ -n "$have" ]] && version_number_ge "$have" "$MIN_RUSTC"; then
      info "$(tr_msg "Using existing $(rustc --version)" "使用现有 $(rustc --version)" "Используется $(rustc --version)")"
      return 0
    fi
  fi
  local arch libc target tmp expected actual url
  case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) die "$(tr_msg "Unsupported CPU: $(uname -m)" "不支持的 CPU: $(uname -m)" "Неподдерживаемый CPU: $(uname -m)")" ;;
  esac
  libc="$(detect_libc)"; target="${arch}-unknown-linux-${libc}"
  tmp="$(mktemp -d)"; CLEANUP_PATHS+=("$tmp")
  url="https://static.rust-lang.org/rustup/dist/${target}/rustup-init"
  info "$(tr_msg "Installing Rust stable (${target})..." "正在安装 Rust stable (${target})..." "Установка Rust stable (${target})...")"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3 -o "$tmp/rustup-init" "$url"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3 -o "$tmp/rustup-init.sha256" "${url}.sha256"
  expected="$(awk '{print $1}' "$tmp/rustup-init.sha256")"
  actual="$(sha256sum "$tmp/rustup-init" | awk '{print $1}')"
  [[ "${expected,,}" == "${actual,,}" ]] || die "$(tr_msg "rustup-init SHA-256 mismatch." "rustup-init SHA-256 校验失败。" "rustup-init SHA-256 mismatch.")"
  chmod 700 "$tmp/rustup-init"
  RUSTUP_HOME="$RUSTUP_HOME_DIR" CARGO_HOME="$CARGO_HOME_DIR" \
    "$tmp/rustup-init" -y --no-modify-path --profile minimal --default-toolchain stable
  export RUSTUP_HOME="$RUSTUP_HOME_DIR" CARGO_HOME="$CARGO_HOME_DIR" PATH="${CARGO_HOME_DIR}/bin:${PATH}"
  has_cmd cargo || die "$(tr_msg "Rust install failed." "Rust 安装失败。" "Установка Rust не удалась.")"
}

asset_name() {
  local arch libc
  case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) die "$(tr_msg "Unsupported CPU: $(uname -m)" "不支持的 CPU: $(uname -m)" "Неподдерживаемый CPU: $(uname -m)")" ;;
  esac
  libc="$(detect_libc)"
  printf 'nowhere-%s-unknown-linux-%s.tar.gz' "$arch" "$libc"
}

get_release_asset_fields() {
  local asset="$1" tmp
  tmp="$(mktemp)"; CLEANUP_PATHS+=("$tmp")
  local -a curl_args=(
    --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3
    -H 'Accept: application/vnd.github+json'
  )
  [[ -n "$GITHUB_TOKEN" ]] && curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  curl "${curl_args[@]}" \
    "https://api.github.com/repos/${UPSTREAM_REPO}/releases/tags/${VERSION}" -o "$tmp" ||
    die "$(tr_msg "Failed to read Release metadata." "读取 Release 元数据失败。" "Не удалось прочитать метаданные.")"
  python3 -c 'import json,sys
name=sys.argv[2]
with open(sys.argv[1],"r",encoding="utf-8") as f: data=json.load(f)
for a in data.get("assets",[]):
    if a.get("name")==name:
        print(a.get("browser_download_url", ""))
        print(a.get("digest", ""))
        break
' "$tmp" "$asset"
}

safe_extract_tar() {
  local archive="$1" dest="$2" member
  while IFS= read -r member; do
    if [[ "$member" == /* || "$member" == ../* || "$member" == */../* || "$member" == *'/..' ]]; then
      die "$(tr_msg "Unsafe path in tar: $member" "压缩包包含不安全路径: $member" "Небезопасный путь в tar: $member")"
    fi
  done < <(tar -tzf "$archive")
  tar -xzf "$archive" -C "$dest"
}

# ============================================================
# 安装 binary
# ============================================================
install_release() {
  install_runtime_deps; resolve_version
  local asset fields url digest expected tmp archive actual binary bsha release_dir
  asset="$(asset_name)"
  fields="$(get_release_asset_fields "$asset")"
  url="$(printf '%s\n' "$fields" | sed -n '1p')"
  digest="$(printf '%s\n' "$fields" | sed -n '2p')"
  [[ -n "$url" ]] || die "$(tr_msg "Release ${VERSION} has no asset ${asset}." "Release ${VERSION} 找不到资产 ${asset}。" "В релизе ${VERSION} нет ${asset}.")"
  [[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || die "$(tr_msg "GitHub did not publish SHA-256 for ${asset}; refusing." "GitHub 未为 ${asset} 提供 SHA-256；拒绝安装。" "GitHub не опубликовал SHA-256 для ${asset}.")"
  expected="${digest#sha256:}"
  tmp="$(mktemp -d)"; CLEANUP_PATHS+=("$tmp"); archive="$tmp/$asset"
  info "$(tr_msg "Downloading official ${VERSION} / ${asset}..." "正在下载官方 ${VERSION} / ${asset} ..." "Загрузка ${VERSION} / ${asset} ...")"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 10 -o "$archive" "$url"
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] || die "$(tr_msg "SHA-256 mismatch." "SHA-256 校验失败。" "SHA-256 mismatch.")"
  mkdir -p "$tmp/extracted"
  safe_extract_tar "$archive" "$tmp/extracted"
  binary="$(find "$tmp/extracted" -type f -name nowhere -print -quit)"
  [[ -n "$binary" ]] || die "$(tr_msg "No nowhere executable in archive." "压缩包中找不到 nowhere 二进制。" "В архиве нет nowhere.")"
  chmod 755 "$binary"; bsha="$(sha256sum "$binary" | awk '{print $1}')"
  release_dir="${RELEASES_DIR}/${VERSION}-release-${bsha:0:12}"
  install -d -m 755 "$RELEASES_DIR" "$release_dir"
  install -m 755 "$binary" "$release_dir/nowhere"
  cat >"$release_dir/RELEASE-INFO" <<EOF2
repository: https://github.com/${UPSTREAM_REPO}
tag: ${VERSION}
asset: ${asset}
asset_sha256: ${expected}
binary_sha256: ${bsha}
installed_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF2
  NEW_TARGET="$release_dir"
  ln -sfn "$release_dir" "$CURRENT_LINK"
  ln -sfn "$CURRENT_LINK/nowhere" "$BIN_LINK"
  ok "$(tr_msg "Installed verified Nowhere ${VERSION} (${bsha:0:12})" "已安装官方验证版 Nowhere ${VERSION} (${bsha:0:12})" "Установлен Nowhere ${VERSION} (${bsha:0:12})")"
}

ensure_build_swap() {
  [[ "$SWAP_MODE" == off ]] && return 0
  awk 'NR>1 {found=1} END{exit !found}' /proc/swaps 2>/dev/null && return 0
  local mem_kb mem_mb want=0 free_mb
  mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  mem_mb=$(( ${mem_kb:-0} / 1024 ))
  if [[ "$SWAP_MODE" == auto ]]; then
    (( mem_mb >= 2048 )) && return 0
    if (( mem_mb < 1024 )); then want=4096; else want=2048; fi
  elif [[ "$SWAP_MODE" =~ ^[0-9]+$ ]]; then
    want="$SWAP_MODE"
  else
    die "$(tr_msg "--swap must be auto|off|MB" "--swap 只能是 auto|off|MB" "--swap = auto|off|MB")"
  fi
  (( want > 0 )) || return 0
  free_mb="$(df -Pk /var/tmp 2>/dev/null | awk 'NR==2{print int($4/1024)}')"
  (( ${free_mb:-0} > want + 512 )) || die "$(tr_msg "Need ~$((want+512))MB free on /var/tmp for swap." "/var/tmp 空间不足（需要约 $((want+512))MB）。" "Нужно ~$((want+512))MB в /var/tmp.")"
  has_cmd mkswap && has_cmd swapon && has_cmd swapoff || die "$(tr_msg "Missing mkswap/swapon/swapoff." "缺少 mkswap/swapon/swapoff。" "Отсутствует mkswap/swapon/swapoff.")"
  info "$(tr_msg "Creating temporary ${want}MB swapfile..." "正在创建临时 ${want}MB swapfile..." "Создание временного swapfile на ${want}MB...")"
  fallocate -l "${want}M" "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$want" status=none
  chmod 600 "$SWAP_FILE"; mkswap "$SWAP_FILE" >/dev/null; swapon "$SWAP_FILE"; SWAP_CREATED=1
}

install_source() {
  acquire_build_lock
  cleanup_stale_swap
  resolve_version; install_runtime_deps; install_build_deps; ensure_rust; ensure_build_swap
  local tmp bsha release_dir commit
  tmp="$(mktemp -d /var/tmp/nowhere-build.XXXXXX)"
  BUILD_DIR="$tmp"
  [[ "$KEEP_SOURCE" -eq 1 ]] || CLEANUP_PATHS+=("$tmp")
  info "$(tr_msg "Cloning and compiling Nowhere ${VERSION}..." "正在拉取并编译 Nowhere ${VERSION} ..." "Клонирование и компиляция Nowhere ${VERSION} ...")"
  git clone --quiet --depth 1 --branch "$VERSION" "$DEFAULT_REPO_URL" "$tmp/src" ||
    die "$(tr_msg "git clone failed." "git clone 失败。" "git clone не удался.")"
  (
    cd "$tmp/src"
    export RUSTUP_HOME="$RUSTUP_HOME_DIR" CARGO_HOME="$CARGO_HOME_DIR" PATH="${CARGO_HOME_DIR}/bin:${PATH}"
    cargo build --release --locked
  ) || die "$(tr_msg "cargo build failed." "cargo 构建失败。" "cargo build не удался.")"
  [[ -x "$tmp/src/target/release/nowhere" ]] || die "$(tr_msg "Built binary not found." "编译产物未找到。" "Собранный файл не найден.")"
  commit="$(git -C "$tmp/src" rev-parse HEAD)"
  bsha="$(sha256sum "$tmp/src/target/release/nowhere" | awk '{print $1}')"
  release_dir="${RELEASES_DIR}/${VERSION}-source-${commit:0:8}-${bsha:0:12}"
  install -d -m 755 "$RELEASES_DIR" "$release_dir"
  install -m 755 "$tmp/src/target/release/nowhere" "$release_dir/nowhere"
  cat >"$release_dir/BUILD-INFO" <<EOF2
repository: ${DEFAULT_REPO_URL}
tag: ${VERSION}
commit: ${commit}
binary_sha256: ${bsha}
built_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF2
  NEW_TARGET="$release_dir"
  ln -sfn "$release_dir" "$CURRENT_LINK"
  ln -sfn "$CURRENT_LINK/nowhere" "$BIN_LINK"
  ok "$(tr_msg "Installed ${VERSION} (${bsha:0:12})" "已安装自编译版 ${VERSION} (${bsha:0:12})" "Установлена версия ${VERSION} (${bsha:0:12})")"
  cleanup_swap || warn "$(tr_msg "Temporary swap cleanup was incomplete; run clean-build later." "临时 swap 清理未完全成功，稍后可运行 clean-build。" "Очистка swap не завершена; запустите clean-build позже.")"
  release_build_lock
  [[ "$KEEP_SOURCE" -eq 1 ]] && info "$(tr_msg "Source kept at $tmp/src" "源码保留在 $tmp/src" "Исходники сохранены в $tmp/src")"
}

install_binary() {
  install -d -m 755 "$INSTALL_ROOT" "$RELEASES_DIR"
  OLD_TARGET=""
  [[ -L "$CURRENT_LINK" ]] && OLD_TARGET="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
  case "$INSTALL_METHOD" in
    release) install_release ;;
    source) install_source ;;
    *) die "$(tr_msg "--method must be release|source" "--method 只能是 release|source" "--method = release|source")" ;;
  esac
}

# ============================================================
# 配置 / 元数据
# ============================================================
ensure_user() {
  if ! getent group "$RUN_GROUP" >/dev/null 2>&1; then groupadd --system "$RUN_GROUP"; fi
  if ! id "$RUN_USER" >/dev/null 2>&1; then
    useradd --system --gid "$RUN_GROUP" --home-dir /var/lib/nowhere --create-home --shell /usr/sbin/nologin "$RUN_USER"
  fi
  install -d -o "$RUN_USER" -g "$RUN_GROUP" -m 750 /var/lib/nowhere
  install -d -o root -g "$RUN_GROUP" -m 750 "$CONFIG_DIR"
}

meta_get() {
  local k="$1"
  [[ -r "$META_FILE" ]] || return 0
  awk -v k="$k" 'index($0,k"=")==1 {print substr($0,length(k)+2); exit}' "$META_FILE"
}

write_meta() {
  local run_url="$1"
  validate_single_line url "$run_url"
  validate_single_line PUBLIC_HOST "$PUBLIC_HOST"
  validate_single_line NODE_NAME "$NODE_NAME"
  validate_single_line CLIENT_SNI "$CLIENT_SNI"
  validate_single_line CLIENT_PIN "$CLIENT_PIN"
  install -d -o root -g "$RUN_GROUP" -m 750 "$CONFIG_DIR"
  cat >"$META_FILE" <<EOF2
ROLE=${ROLE}
VERSION=${VERSION}
PUBLIC_HOST=${PUBLIC_HOST}
NODE_NAME=${NODE_NAME}
CLIENT_UP=${CLIENT_UP}
CLIENT_DOWN=${CLIENT_DOWN}
CLIENT_MUX=${CLIENT_MUX}
CLIENT_SNI=${CLIENT_SNI}
CLIENT_PIN=${CLIENT_PIN}
EOF2
  chmod 600 "$META_FILE"; chown root:root "$META_FILE"
  printf '%s\n' "$run_url" >"$URL_FILE"
  chown root:"$RUN_GROUP" "$URL_FILE"; chmod 640 "$URL_FILE"
}

load_meta() {
  local v
  [[ -r "$META_FILE" ]] || return 0
  v="$(meta_get ROLE)"; if [[ -n "$v" ]]; then ROLE="$v"; fi
  v="$(meta_get PUBLIC_HOST)"; if [[ -n "$v" ]]; then PUBLIC_HOST="$v"; fi
  v="$(meta_get NODE_NAME)"; if [[ -n "$v" ]]; then NODE_NAME="$v"; fi
  v="$(meta_get CLIENT_UP)"; if [[ -n "$v" ]]; then CLIENT_UP="$v"; fi
  v="$(meta_get CLIENT_DOWN)"; if [[ -n "$v" ]]; then CLIENT_DOWN="$v"; fi
  v="$(meta_get CLIENT_MUX)"; if [[ -n "$v" ]]; then CLIENT_MUX="$v"; fi
  v="$(meta_get CLIENT_SNI)"; if [[ -n "$v" ]]; then CLIENT_SNI="$v"; fi
  v="$(meta_get CLIENT_PIN)"; if [[ -n "$v" ]]; then CLIENT_PIN="$v"; fi
}

import_legacy_config() {
  [[ -s "$URL_FILE" ]] && return 0
  local legacy="${CONFIG_DIR}/nowhere.env" line=""
  [[ -r "$legacy" ]] || return 0
  line="$(grep -m1 '^NOWHERE_PORTAL=' "$legacy" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 0
  line="${line#NOWHERE_PORTAL=}"
  line="${line#\"}"; line="${line%\"}"
  [[ "$line" == portal://* ]] || return 0
  ensure_user
  line="$(migrate_url "$line")"
  printf '%s\n' "$line" >"$URL_FILE"
  chown root:"$RUN_GROUP" "$URL_FILE"; chmod 640 "$URL_FILE"
  warn "$(tr_msg "Imported legacy config from ${legacy}." "已从旧 ${legacy} 导入配置。" "Импортирована старая конфигурация из ${legacy}.")"
}

load_existing_url_into_values() {
  [[ -s "$URL_FILE" ]] || return 0
  local u x
  IFS= read -r u <"$URL_FILE"
  u="$(migrate_url "$u")"
  ROLE="$(detect_role_from_url "$u" 2>/dev/null || printf portal)"
  parse_authority "$u" || return 0
  KEY="$PARSED_KEY"; PORT="$PARSED_PORT"
  if [[ "$ROLE" == portal ]]; then
    LISTEN_HOST="$PARSED_HOST"
    NET="$(query_get "$u" net)"; NET="${NET:-mix}"
    TLS="$(query_get "$u" tls)"; TLS="${TLS:-1}"
    x="$(query_get "$u" crt)"; if [[ -n "$x" ]]; then CERT="$(urldecode "$x")"; fi
    x="$(query_get "$u" key)"; if [[ -n "$x" ]]; then TLS_KEY="$(urldecode "$x")"; fi
    x="$(query_get "$u" dial)"; if [[ -n "$x" ]]; then DIAL="$(urldecode "$x")"; fi
    x="$(query_get "$u" socks)"; if [[ -n "$x" ]]; then OUT_SOCKS="$(urldecode "$x")"; fi
    x="$(query_get "$u" next)"; if [[ -n "$x" ]]; then NEXT="$(urldecode "$x")"; fi
  else
    PUBLIC_HOST="$PARSED_HOST"
    x="$(query_get "$u" socks)"; if [[ -n "$x" ]]; then VECTOR_SOCKS="$(urldecode "$x")"; fi
  fi
  x="$(query_get "$u" alpn)"; if [[ -n "$x" ]]; then ALPN="$(urldecode "$x")"; fi
  x="$(query_get "$u" rate)"; if [[ -n "$x" ]]; then RATE="$x"; fi
  x="$(query_get "$u" etar)"; if [[ -n "$x" ]]; then ETAR="$x"; fi
  x="$(query_get "$u" log)"; if [[ -n "$x" ]]; then LOG_LEVEL="$x"; fi
  x="$(query_get "$u" up)"; if [[ -n "$x" ]]; then UP="$x"; fi
  x="$(query_get "$u" down)"; if [[ -n "$x" ]]; then DOWN="$x"; fi
  x="$(query_get "$u" mux)"; if [[ -n "$x" ]]; then MUX="$x"; fi
  x="$(query_get "$u" sni)"; if [[ -n "$x" ]]; then SNI="$(urldecode "$x")"; fi
  x="$(query_get "$u" pin)"; if [[ -n "$x" ]]; then PIN="$(urldecode "$x")"; fi
}

prepare_tls_files() {
  [[ "$TLS" == 2 ]] || return 0
  [[ -f "$CERT" && -f "$TLS_KEY" ]] || die "$(tr_msg "tls=2 cert/key missing." "tls=2 证书或私钥不存在。" "tls=2: cert/key отсутствует.")"
  ensure_user
  if [[ "$COPY_CERT" -eq 1 ]]; then
    local src_cert="$CERT" src_key="$TLS_KEY"
    install -d -o root -g "$RUN_GROUP" -m 750 "$TLS_DIR"
    if [[ "$(readlink -f "$src_cert")" != "$(readlink -f "$TLS_DIR/fullchain.pem" 2>/dev/null || printf '%s' "$TLS_DIR/fullchain.pem")" ]]; then
      install -o root -g "$RUN_GROUP" -m 640 "$src_cert" "$TLS_DIR/fullchain.pem"
    fi
    if [[ "$(readlink -f "$src_key")" != "$(readlink -f "$TLS_DIR/privkey.pem" 2>/dev/null || printf '%s' "$TLS_DIR/privkey.pem")" ]]; then
      install -o root -g "$RUN_GROUP" -m 640 "$src_key" "$TLS_DIR/privkey.pem"
    fi
    chown root:"$RUN_GROUP" "$TLS_DIR/fullchain.pem" "$TLS_DIR/privkey.pem"
    chmod 640 "$TLS_DIR/fullchain.pem" "$TLS_DIR/privkey.pem"
    CERT="$TLS_DIR/fullchain.pem"; TLS_KEY="$TLS_DIR/privkey.pem"
    ok "$(tr_msg "Cert copied to ${TLS_DIR} (re-copy after renewal)." "证书已复制到 ${TLS_DIR}（续期后需重新复制）。" "Сертификат скопирован в ${TLS_DIR}.")"
  fi
  if has_cmd runuser; then
    runuser -u "$RUN_USER" -- test -r "$CERT" || die "$(tr_msg "Service user cannot read cert; add --copy-cert." "服务用户无法读取证书；请加 --copy-cert。" "Пользователь не может прочитать cert.")"
    runuser -u "$RUN_USER" -- test -r "$TLS_KEY" || die "$(tr_msg "Service user cannot read key; add --copy-cert." "服务用户无法读取私钥；请加 --copy-cert。" "Пользователь не может прочитать key.")"
  fi
}

write_launcher() {
  install -d -m 755 "$(dirname "$LAUNCHER")"
  cat >"$LAUNCHER" <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail
URL_FILE="/etc/nowhere/url.conf"
[[ -r "$URL_FILE" ]] || { echo "Cannot read $URL_FILE" >&2; exit 1; }
IFS= read -r NOWHERE_URL < "$URL_FILE"
[[ -n "$NOWHERE_URL" ]] || { echo "$URL_FILE is empty" >&2; exit 1; }
exec /opt/nowhere/current/nowhere "$NOWHERE_URL"
EOF2
  chmod 755 "$LAUNCHER"; chown root:root "$LAUNCHER"
}

write_unit() {
  local desc="Nowhere Portal"; [[ "$ROLE" == vector ]] && desc="Nowhere Vector"
  cat >"$UNIT_FILE" <<EOF2
[Unit]
Description=${desc}
Documentation=https://github.com/${UPSTREAM_REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
ExecStart=${LAUNCHER}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
UMask=0077
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RuntimeDirectory=nowhere
RuntimeDirectoryMode=0750
StateDirectory=nowhere
StateDirectoryMode=0750

[Install]
WantedBy=multi-user.target
EOF2
  chmod 644 "$UNIT_FILE"; chown root:root "$UNIT_FILE"
  systemctl daemon-reload
}

# ============================================================
# 配置向导
# ============================================================
interactive_config_quick() {
  echo
  info "$(tr_msg "Quick setup: only essential settings are shown; advanced values are kept unchanged." "快速配置：只询问必要参数；高级参数保持原值不动。" "Быстрая настройка: только основные параметры; расширенные значения сохраняются.")"
  ROLE="$(prompt_choice "$(tr_msg 'Role portal/vector' '服务类型 portal/vector' 'Роль portal/vector')" "$ROLE" portal vector)"
  validate_role "$ROLE"
  [[ -n "$KEY" ]] || KEY="$(random_key)"
  prompt_key
  prompt_port
  if [[ "$ROLE" == portal ]]; then
    NET="$(prompt_choice "$(tr_msg 'Listener net mix/tcp/udp' '监听模式 mix/tcp/udp' 'Listener net mix/tcp/udp')" "$NET" mix tcp udp)"
    TLS="$(prompt_choice "$(tr_msg 'TLS 1=self-signed / 2=PEM' 'TLS 1=自签 / 2=证书' 'TLS 1=self / 2=PEM')" "$TLS" 1 2)"
    if [[ "$TLS" == 2 ]]; then
      CERT="$(prompt "$(tr_msg 'Cert path' '证书路径' 'Cert path')" "$CERT")"
      TLS_KEY="$(prompt "$(tr_msg 'Key path' '私钥路径' 'Key path')" "$TLS_KEY")"
      if prompt_yes "$(tr_msg "Copy cert to /etc/nowhere/tls?" "是否复制证书到 /etc/nowhere/tls（推荐）?" "Скопировать cert в /etc/nowhere/tls?")"; then
        COPY_CERT=1
      fi
    fi
    PUBLIC_HOST="$(prompt "$(tr_msg 'Public IP/domain for share link (empty = auto)' '分享链接公网 IP/域名（可留空自动探测）' 'Public IP/domain для share (пусто=auto)')" "$PUBLIC_HOST")"
    NODE_NAME="$(prompt "$(tr_msg 'Node name' '节点名称' 'Имя узла')" "$NODE_NAME")"
  else
    PUBLIC_HOST="$(prompt "$(tr_msg 'Portal host/IP' 'Portal 主机/IP' 'Portal host/IP')" "$PUBLIC_HOST")"
    UP="$(prompt_choice "$(tr_msg 'Up tcp/udp/mix' '上行 tcp/udp/mix' 'Up tcp/udp/mix')" "$UP" tcp udp mix)"
    DOWN="$(prompt_choice "$(tr_msg 'Down tcp/udp/mix' '下行 tcp/udp/mix' 'Down tcp/udp/mix')" "$DOWN" tcp udp mix)"
    VECTOR_SOCKS="$(prompt "$(tr_msg 'Local SOCKS5 listen' '本地 SOCKS5 监听' 'Local SOCKS5')" "$VECTOR_SOCKS")"
  fi
}

interactive_config_advanced() {
  echo
  info "$(tr_msg "Advanced setup (Enter to keep current value)" "高级配置（回车保留当前值）" "Расширенная настройка (Enter = текущее значение)")"
  ROLE="$(prompt_choice "$(tr_msg 'Role portal/vector' '服务类型 portal/vector' 'Роль portal/vector')" "$ROLE" portal vector)"
  validate_role "$ROLE"
  [[ -n "$KEY" ]] || KEY="$(random_key)"
  prompt_key
  prompt_port
  if [[ "$ROLE" == portal ]]; then
    LISTEN_HOST="$(prompt "$(tr_msg 'Listen addr (0.0.0.0/::/empty wildcard; - to clear)' '监听地址（0.0.0.0/::/留空 wildcard；输入 - 清空）' 'Listen addr')" "$LISTEN_HOST")"
    [[ "$LISTEN_HOST" == - ]] && LISTEN_HOST=""
    NET="$(prompt_choice "$(tr_msg 'net mix/tcp/udp' 'net mix/tcp/udp' 'net mix/tcp/udp')" "$NET" mix tcp udp)"
    TLS="$(prompt_choice "$(tr_msg 'TLS 1=self-signed / 2=PEM' 'TLS 1=自签 / 2=证书' 'TLS 1=self 2=PEM')" "$TLS" 1 2)"
    if [[ "$TLS" == 2 ]]; then
      CERT="$(prompt "$(tr_msg 'Cert path' '证书路径' 'Cert path')" "$CERT")"
      TLS_KEY="$(prompt "$(tr_msg 'Key path' '私钥路径' 'Key path')" "$TLS_KEY")"
      if prompt_yes "$(tr_msg "Copy cert to /etc/nowhere/tls?" "是否复制证书到 /etc/nowhere/tls（推荐）?" "Скопировать cert в /etc/nowhere/tls?")"; then
        COPY_CERT=1
      fi
    fi
    local mode="none"
    [[ "$OUT_SOCKS" != none ]] && mode=socks
    [[ "$NEXT" != none ]] && mode=next
    mode="$(prompt_choice "$(tr_msg 'Portal outbound none/socks/next' 'Portal 出站 none/socks/next' 'Исходящий none/socks/next')" "$mode" none socks next)"
    OUT_SOCKS=none; NEXT=none
    case "$mode" in
      none) ;;
      socks) OUT_SOCKS="$(prompt "$(tr_msg 'SOCKS5 endpoint' 'SOCKS5 地址' 'SOCKS5 endpoint')" '')" ;;
      next)
        NEXT="$(prompt "$(tr_msg 'next KEY@HOST:PORT' 'next KEY@HOST:PORT' 'next KEY@HOST:PORT')" '')"
        UP="$(prompt_choice "$(tr_msg 'next up tcp/udp/mix' 'next 上行 tcp/udp/mix' 'next up')" "$UP" tcp udp mix)"
        DOWN="$(prompt_choice "$(tr_msg 'next down tcp/udp/mix' 'next 下行 tcp/udp/mix' 'next down')" "$DOWN" tcp udp mix)"
        MUX="$(prompt_choice "$(tr_msg 'next mux 0/1' 'next mux 0/1' 'next mux')" "$MUX" 0 1)"
        SNI="$(prompt "$(tr_msg 'next SNI or none' 'next SNI 或 none' 'next SNI')" "$SNI")"
        PIN="$(prompt "$(tr_msg 'next pin or none' 'next pin 或 none' 'next pin')" "$PIN")"
        ;;
    esac
    PUBLIC_HOST="$(prompt "$(tr_msg 'Public IP/domain for share link (empty = auto)' '分享链接公网 IP/域名（可留空自动探测）' 'Public IP/domain для share (пусто=auto)')" "$PUBLIC_HOST")"
    NODE_NAME="$(prompt "$(tr_msg 'Node name' '节点名称' 'Имя узла')" "$NODE_NAME")"
    CLIENT_UP="$(prompt_choice "$(tr_msg 'Client up auto/tcp/udp/mix' '客户端 up auto/tcp/udp/mix' 'Client up auto/tcp/udp/mix')" "$CLIENT_UP" auto tcp udp mix)"
    CLIENT_DOWN="$(prompt_choice "$(tr_msg 'Client down auto/tcp/udp/mix' '客户端 down auto/tcp/udp/mix' 'Client down auto/tcp/udp/mix')" "$CLIENT_DOWN" auto tcp udp mix)"
    CLIENT_MUX="$(prompt_choice "$(tr_msg 'Client mux auto/0/1' '客户端 mux auto/0/1' 'Client mux auto/0/1')" "$CLIENT_MUX" auto 0 1)"
  else
    PUBLIC_HOST="$(prompt "$(tr_msg 'Portal host/IP' 'Portal 主机/IP' 'Portal host/IP')" "$PUBLIC_HOST")"
    UP="$(prompt_choice "$(tr_msg 'Up tcp/udp/mix' '上行 tcp/udp/mix' 'Up tcp/udp/mix')" "$UP" tcp udp mix)"
    DOWN="$(prompt_choice "$(tr_msg 'Down tcp/udp/mix' '下行 tcp/udp/mix' 'Down tcp/udp/mix')" "$DOWN" tcp udp mix)"
    MUX="$(prompt_choice "$(tr_msg 'mux 0/1' 'mux 0/1' 'mux 0/1')" "$MUX" 0 1)"
    VECTOR_SOCKS="$(prompt "$(tr_msg 'Local SOCKS5 listen' '本地 SOCKS5 监听' 'Local SOCKS5')" "$VECTOR_SOCKS")"
    SNI="$(prompt "$(tr_msg 'SNI or none' 'SNI 或 none' 'SNI или none')" "$SNI")"
    PIN="$(prompt "$(tr_msg 'pin or none' 'pin 或 none' 'pin или none')" "$PIN")"
  fi
  ALPN="$(prompt "$(tr_msg 'ALPN' 'ALPN' 'ALPN')" "$ALPN")"
  LOG_LEVEL="$(prompt_choice "$(tr_msg 'Log level' '日志级别' 'Log level')" "$LOG_LEVEL" none debug info warn error event)"
}

interactive_config() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  local mode="$CONFIG_MODE"
  case "$mode" in
    ask) mode="$(prompt_choice "$(tr_msg 'Setup mode quick/advanced' '配置模式 quick/advanced（快速/高级）' 'Режим quick/advanced')" quick quick advanced)" ;;
    quick|advanced) ;;
    *) die "$(tr_msg "config-mode must be ask|quick|advanced" "config-mode 只能是 ask|quick|advanced" "config-mode = ask|quick|advanced")" ;;
  esac
  if [[ "$mode" == quick ]]; then interactive_config_quick; else interactive_config_advanced; fi
}

validate_final_config() {
  validate_role "$ROLE"; validate_key "$KEY"; validate_port "$PORT"
  validate_log "$LOG_LEVEL"; validate_rate "$RATE"; validate_rate "$ETAR"; validate_alpn "$ALPN"
  validate_single_line host "$PUBLIC_HOST"; validate_single_line name "$NODE_NAME"
  if [[ "$ROLE" == portal ]]; then
    validate_net "$NET"; validate_tls "$TLS"
    [[ "$OUT_SOCKS" == none || "$NEXT" == none ]] || die "$(tr_msg "socks and next are mutually exclusive." "socks 与 next 互斥。" "socks и next взаимоисключающие.")"
    if [[ "$OUT_SOCKS" != none && -n "$OUT_SOCKS" ]]; then validate_socks_endpoint "$OUT_SOCKS" 0; fi
    if [[ "$NEXT" != none && -n "$NEXT" ]]; then
      validate_next_endpoint "$NEXT"
      validate_carrier "$UP"; validate_carrier "$DOWN"; validate_mux "$MUX"; validate_sni "$SNI"; validate_pin "$PIN"
    fi
    [[ "$CLIENT_UP" != auto ]] && validate_carrier "$CLIENT_UP"
    [[ "$CLIENT_DOWN" != auto ]] && validate_carrier "$CLIENT_DOWN"
    [[ "$CLIENT_MUX" == auto ]] || validate_mux "$CLIENT_MUX"
    [[ "$CLIENT_SNI" == auto ]] || validate_sni "$CLIENT_SNI"
    validate_pin "$CLIENT_PIN"
  else
    validate_carrier "$UP"; validate_carrier "$DOWN"; validate_mux "$MUX"; validate_sni "$SNI"; validate_pin "$PIN"
    [[ -n "$PUBLIC_HOST" ]] || die "$(tr_msg "Vector requires --host." "Vector 需要 --host。" "Vector требует --host.")"
    validate_socks_endpoint "$VECTOR_SOCKS" 1
  fi
}

validate_imported_url() {
  local u="$1" r x keyv socks next up down mux sni pin tls crt keyf
  validate_single_line url "$u"
  validate_percent_encoding "$u"
  r="$(detect_role_from_url "$u")" || die "$(tr_msg "Invalid URL scheme." "URL scheme 无效。" "Неверная схема URL.")"
  parse_authority "$u" || die "$(tr_msg "Cannot parse key@host:port." "无法解析 key@host:port。" "Не удалось разобрать key@host:port.")"
  keyv="$PARSED_KEY"; validate_import_key "$keyv"; validate_port "$PARSED_PORT"

  x="$(query_get "$u" alpn)"; [[ -z "$x" ]] || validate_alpn "$(urldecode "$x")"
  x="$(query_get "$u" rate)"; [[ -z "$x" ]] || validate_rate "$x"
  x="$(query_get "$u" etar)"; [[ -z "$x" ]] || validate_rate "$x"
  x="$(query_get "$u" log)"; [[ -z "$x" ]] || validate_log "$x"

  if [[ "$r" == portal ]]; then
    x="$(query_get "$u" net)"; [[ -z "$x" ]] || validate_net "$x"
    tls="$(query_get "$u" tls)"; tls="${tls:-1}"; validate_tls "$tls"
    if [[ "$tls" == 2 ]]; then
      crt="$(urldecode "$(query_get "$u" crt)")"; keyf="$(urldecode "$(query_get "$u" key)")"
      [[ -n "$crt" && -n "$keyf" && -f "$crt" && -f "$keyf" ]] || die "$(tr_msg "Imported tls=2 URL requires existing crt/key files." "导入的 tls=2 URL 必须指向存在的 crt/key 文件。" "Для импортированного tls=2 нужны существующие crt/key.")"
    fi
    socks="$(urldecode "$(query_get "$u" socks)")"; next="$(urldecode "$(query_get "$u" next)")"
    [[ -z "$socks" || -z "$next" || "$socks" == none || "$next" == none ]] || die "$(tr_msg "Imported Portal URL cannot contain both socks= and next=." "导入的 Portal URL 不能同时包含 socks= 与 next=。" "Portal URL не может содержать socks= и next= одновременно.")"
    [[ -z "$socks" || "$socks" == none ]] || validate_socks_endpoint "$socks" 0
    if [[ -n "$next" && "$next" != none ]]; then
      validate_next_endpoint "$next"
      up="$(query_get "$u" up)"; up="${up:-udp}"; validate_carrier "$up"
      down="$(query_get "$u" down)"; down="${down:-udp}"; validate_carrier "$down"
      mux="$(query_get "$u" mux)"; mux="${mux:-0}"; validate_mux "$mux"
      sni="$(urldecode "$(query_get "$u" sni)")"; validate_sni "${sni:-none}"
      pin="$(urldecode "$(query_get "$u" pin)")"; validate_pin "${pin:-none}"
    fi
  else
    [[ -n "$PARSED_HOST" ]] || die "$(tr_msg "Vector URL must include Portal host." "Vector URL 必须包含 Portal host。" "Vector URL требует Portal host.")"
    up="$(query_get "$u" up)"; up="${up:-udp}"; validate_carrier "$up"
    down="$(query_get "$u" down)"; down="${down:-udp}"; validate_carrier "$down"
    mux="$(query_get "$u" mux)"; mux="${mux:-0}"; validate_mux "$mux"
    socks="$(urldecode "$(query_get "$u" socks)")"
    [[ -n "$socks" && "$socks" != none ]] || die "$(tr_msg "Vector URL must include socks=." "Vector URL 必须包含 socks=。" "Vector URL требует socks=.")"
    validate_socks_endpoint "$socks" 1
    sni="$(urldecode "$(query_get "$u" sni)")"; validate_sni "${sni:-none}"
    pin="$(urldecode "$(query_get "$u" pin)")"; validate_pin "${pin:-none}"
  fi
}

# ============================================================
# 服务操作
# ============================================================
wait_service() {
  local i
  for i in {1..10}; do systemctl is-active --quiet "$SERVICE_NAME" && return 0; sleep 1; done
  return 1
}

rollback_to_old_after_failure() {
  [[ -n "$OLD_TARGET" && -x "$OLD_TARGET/nowhere" ]] || return 1
  warn "$(tr_msg "New release failed to start; rolling back to ${OLD_TARGET}" "新版本启动失败，自动回滚到 ${OLD_TARGET}" "Откат к ${OLD_TARGET}")"
  ln -sfn "$OLD_TARGET" "$CURRENT_LINK"
  ln -sfn "$CURRENT_LINK/nowhere" "$BIN_LINK"
  if systemctl restart "$SERVICE_NAME" && wait_service; then
    return 0
  fi
  warn "$(tr_msg "Rollback target also failed to start." "旧版本回滚后仍未能启动。" "Откатная версия также не запустилась.")"
  return 1
}

ensure_existing_tls_access() {
  [[ -s "$URL_FILE" ]] || return 0
  local u r tls crt keyf
  IFS= read -r u <"$URL_FILE"
  r="$(detect_role_from_url "$u" 2>/dev/null || true)"
  [[ "$r" == portal ]] || return 0
  tls="$(query_get "$u" tls)"; tls="${tls:-1}"
  [[ "$tls" == 2 ]] || return 0
  crt="$(urldecode "$(query_get "$u" crt)")"
  keyf="$(urldecode "$(query_get "$u" key)")"
  [[ -f "$crt" && -f "$keyf" ]] || die "$(tr_msg "Existing tls=2 cert/key missing: $crt / $keyf" "现有 tls=2 证书/私钥不存在: $crt / $keyf" "Существующий tls=2 cert/key отсутствует: $crt / $keyf")"
  CERT="$crt"; TLS_KEY="$keyf"; TLS=2
  if [[ "$COPY_CERT" -eq 1 ]]; then
    prepare_tls_files
    u="$(query_strip "$u" crt)"; u="$(query_strip "$u" key)"
    u="$(query_append "$u" "crt=$(urlencode "$CERT")")"
    u="$(query_append "$u" "key=$(urlencode "$TLS_KEY")")"
    printf '%s\n' "$u" >"$URL_FILE"
    chown root:"$RUN_GROUP" "$URL_FILE"; chmod 640 "$URL_FILE"
  elif has_cmd runuser; then
    runuser -u "$RUN_USER" -- test -r "$crt" || die "$(tr_msg "Non-root service cannot read cert; add --copy-cert." "非 root 服务无法读取证书；请加 --copy-cert。" "Сервис не может прочитать cert; добавьте --copy-cert.")"
    runuser -u "$RUN_USER" -- test -r "$keyf" || die "$(tr_msg "Non-root service cannot read key; add --copy-cert." "非 root 服务无法读取私钥；请加 --copy-cert。" "Сервис не может прочитать key; добавьте --copy-cert.")"
  fi
}

# ============================================================
# 动作
# ============================================================
install_action() {
  require_root; require_systemd; ensure_user
  import_legacy_config; load_meta; apply_cli_overrides
  local had_config=0
  [[ -s "$URL_FILE" ]] && had_config=1
  if [[ "$had_config" -eq 1 && "${#CLI_SET[@]}" -gt 0 ]]; then
    warn "$(tr_msg "Existing config found; install/upgrade only replaces binary. Use 'configure' to change URL." "检测到已有配置；install/upgrade 只更换二进制，不改配置。要改请用 configure。" "Найдена существующая конфигурация; install/upgrade только меняет бинарник. Для смены URL используйте configure.")"
  fi
  if [[ "$ACTION" == upgrade ]]; then
    [[ "$had_config" -eq 1 ]] || die "$(tr_msg "No existing config; run install first." "没有现有配置，请先 install。" "Нет конфигурации, сначала install.")"
  elif [[ "$had_config" -eq 0 ]]; then
    [[ -n "$KEY" ]] || KEY="$(random_key)"
    interactive_config; validate_final_config; prepare_tls_files
    local u
    if [[ "$ROLE" == portal ]]; then u="$(build_portal_url)"; else u="$(build_vector_url)"; fi
    write_meta "$u"
  fi
  [[ "$had_config" -eq 1 ]] && ensure_existing_tls_access
  install_binary
  write_launcher
  if [[ "$had_config" -eq 1 ]]; then
    local u
    IFS= read -r u <"$URL_FILE"
    u="$(migrate_url "$u")"
    printf '%s\n' "$u" >"$URL_FILE"
    chown root:"$RUN_GROUP" "$URL_FILE"; chmod 640 "$URL_FILE"
    ROLE="$(detect_role_from_url "$u" 2>/dev/null || printf portal)"
    # v2.4.2: 从已存 URL 回读真实端口，避免升级时 firewall 提示用错端口
    if parse_authority "$u"; then
      PORT="$PARSED_PORT"
    fi
  fi
  write_unit
  systemctl enable "$SERVICE_NAME" >/dev/null
  if ! systemctl restart "$SERVICE_NAME" || ! wait_service; then
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager >&2 || true
    if rollback_to_old_after_failure; then
      die "$(tr_msg "New release failed; rolled back and old service recovered." "新版本启动失败，已自动回滚且旧服务恢复运行。" "Новая версия не запустилась; откат выполнен и старая служба восстановлена.")"
    fi
    die "$(tr_msg "Nowhere failed to start and automatic rollback could not recover service." "Nowhere 启动失败，自动回滚也未能恢复服务。" "Nowhere не запустился, автоматический откат не восстановил службу.")"
  fi
  ok "$(tr_msg "Nowhere ${VERSION} is active as ${RUN_USER}." "Nowhere ${VERSION} 已作为 ${RUN_USER} 运行。" "Nowhere ${VERSION} запущен от ${RUN_USER}.")"
  if [[ -s "$URL_FILE" ]]; then
    local _u _net
    IFS= read -r _u <"$URL_FILE"
    if [[ "$(detect_role_from_url "$_u" 2>/dev/null || true)" == portal ]]; then
      _net="$(query_get "$_u" net)"; _net="${_net:-mix}"
      case "$_net" in
        mix) warn "$(tr_msg "Open TCP + UDP ${PORT} in firewall." "请在防火墙/安全组同时放行 TCP + UDP ${PORT}。" "Откройте TCP + UDP ${PORT}.")" ;;
        tcp) warn "$(tr_msg "Open TCP ${PORT} in firewall." "请在防火墙放行 TCP ${PORT}。" "Откройте TCP ${PORT}.")" ;;
        udp) warn "$(tr_msg "Open UDP ${PORT} in firewall." "请在防火墙放行 UDP ${PORT}。" "Откройте UDP ${PORT}.")" ;;
      esac
    fi
  fi
  cleanup_old_releases 1
  show_links
}

CONFIG_SNAPSHOT_DIR=""

# v2.5.2: 缺失文件正常跳过；真实复制失败则中止，避免产生不完整快照
snapshot_config_state() {
  CONFIG_SNAPSHOT_DIR="$(mktemp -d)" || die "$(tr_msg "Failed to create config snapshot directory." "无法创建配置快照目录。" "Не удалось создать каталог снимка конфигурации.")"
  CLEANUP_PATHS+=("$CONFIG_SNAPSHOT_DIR")

  if [[ -e "$URL_FILE" ]]; then
    cp -a -- "$URL_FILE" "$CONFIG_SNAPSHOT_DIR/url.conf" ||
      die "$(tr_msg "Failed to snapshot url.conf." "备份 url.conf 失败。" "Не удалось сохранить url.conf.")"
  fi
  if [[ -e "$META_FILE" ]]; then
    cp -a -- "$META_FILE" "$CONFIG_SNAPSHOT_DIR/manager.conf" ||
      die "$(tr_msg "Failed to snapshot manager.conf." "备份 manager.conf 失败。" "Не удалось сохранить manager.conf.")"
  fi
  if [[ -d "$TLS_DIR" ]]; then
    cp -a -- "$TLS_DIR" "$CONFIG_SNAPSHOT_DIR/tls" ||
      die "$(tr_msg "Failed to snapshot TLS directory." "备份 TLS 目录失败。" "Не удалось сохранить каталог TLS.")"
  fi
  return 0
}

# v2.5.2: 空快照保护；恢复过程显式检查复制失败，避免半恢复状态被误判成功
restore_config_state() {
  [[ -n "$CONFIG_SNAPSHOT_DIR" && -d "$CONFIG_SNAPSHOT_DIR" ]] || return 1
  rm -f -- "$URL_FILE" "$META_FILE" || return 1
  rm -rf -- "$TLS_DIR" || return 1
  if [[ -e "$CONFIG_SNAPSHOT_DIR/url.conf" ]]; then
    cp -a -- "$CONFIG_SNAPSHOT_DIR/url.conf" "$URL_FILE" || return 1
  fi
  if [[ -e "$CONFIG_SNAPSHOT_DIR/manager.conf" ]]; then
    cp -a -- "$CONFIG_SNAPSHOT_DIR/manager.conf" "$META_FILE" || return 1
  fi
  if [[ -d "$CONFIG_SNAPSHOT_DIR/tls" ]]; then
    cp -a -- "$CONFIG_SNAPSHOT_DIR/tls" "$TLS_DIR" || return 1
  fi
  if [[ -s "$URL_FILE" ]]; then
    local old_u
    IFS= read -r old_u <"$URL_FILE"
    ROLE="$(detect_role_from_url "$old_u" 2>/dev/null || printf portal)"
    write_launcher
    write_unit
    if [[ -x "$CURRENT_LINK/nowhere" ]]; then
      systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
      wait_service || return 1
    fi
  else
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  return 0
}

configure_action() {
  require_root; require_systemd; ensure_user
  import_legacy_config; load_meta; load_existing_url_into_values; apply_cli_overrides
  snapshot_config_state
  if [[ -n "$IMPORT_URL" ]]; then
    local u raw="$IMPORT_URL" frag=""
    if [[ "$raw" == nowhere://* && "$raw" == *#* ]]; then
      frag="${raw#*#}"; raw="${raw%%#*}"
      [[ -z "$NODE_NAME" ]] && NODE_NAME="$(urldecode "$frag")"
    fi
    u="$(migrate_url "$raw")"
    ROLE="$(detect_role_from_url "$u")" || die "$(tr_msg "Only portal/vector/nowhere URLs." "只支持 portal:// vector:// nowhere://" "Поддерживаются portal/vector/nowhere URL.")"
    if [[ "$IMPORT_URL" == nowhere://* ]] && [[ -z "$(query_get "$u" socks)" ]]; then
      u="$(query_append "$u" "socks=$(urlencode "$VECTOR_SOCKS")")"
    fi
    validate_imported_url "$u"
    # Imported tls=2 must also be readable by the non-root service. --copy-cert
    # canonicalizes it into /etc/nowhere/tls and rewrites the imported URL.
    local imported_tls
    imported_tls="$(query_get "$u" tls)"; imported_tls="${imported_tls:-1}"
    if [[ "$ROLE" == portal && "$imported_tls" == 2 ]]; then
      TLS=2
      CERT="$(urldecode "$(query_get "$u" crt)")"
      TLS_KEY="$(urldecode "$(query_get "$u" key)")"
      prepare_tls_files
      u="$(query_strip "$u" crt)"; u="$(query_strip "$u" key)"
      u="$(query_append "$u" "crt=$(urlencode "$CERT")")"
      u="$(query_append "$u" "key=$(urlencode "$TLS_KEY")")"
    fi
    printf '%s\n' "$u" >"$URL_FILE"
    chown root:"$RUN_GROUP" "$URL_FILE"; chmod 640 "$URL_FILE"
    write_meta "$u"; write_launcher; write_unit
    systemctl enable "$SERVICE_NAME" >/dev/null
    if ! systemctl restart "$SERVICE_NAME" || ! wait_service; then
      journalctl -u "$SERVICE_NAME" -n 60 --no-pager >&2 || true
      if restore_config_state; then
        die "$(tr_msg "Imported config failed; previous config was restored." "导入配置启动失败，已恢复之前的配置。" "Импорт не запустился; предыдущая конфигурация восстановлена.")"
      fi
      die "$(tr_msg "Imported config failed and previous service could not be recovered." "导入配置启动失败，且旧服务也未能恢复。" "Импорт не запустился, восстановить старую службу не удалось.")"
    fi
    ok "$(tr_msg "Config imported and active." "配置已导入并生效。" "Конфигурация импортирована.")"
    return
  fi
  [[ -n "$KEY" ]] || KEY="$(random_key)"
  interactive_config; validate_final_config; prepare_tls_files
  local u
  if [[ "$ROLE" == portal ]]; then u="$(build_portal_url)"; else u="$(build_vector_url)"; fi
  write_meta "$u"; write_launcher; write_unit
  systemctl enable "$SERVICE_NAME" >/dev/null
  if [[ -x "$CURRENT_LINK/nowhere" ]]; then
    if ! systemctl restart "$SERVICE_NAME" || ! wait_service; then
      journalctl -u "$SERVICE_NAME" -n 60 --no-pager >&2 || true
      if restore_config_state; then
        die "$(tr_msg "New config failed; previous config was restored." "新配置启动失败，已恢复之前的配置。" "Новая конфигурация не запустилась; предыдущая восстановлена.")"
      fi
      die "$(tr_msg "New config failed and previous service could not be recovered." "新配置启动失败，旧服务也未能恢复。" "Новая конфигурация не запустилась, восстановить старую службу не удалось.")"
    fi
  fi
  ok "$(tr_msg "Config saved." "配置已保存。" "Конфигурация сохранена.")"
}

current_version() {
  if [[ -x "$BIN_LINK" ]]; then
    "$BIN_LINK" --version 2>/dev/null | head -n1 || true
  else
    printf '%s' "$(tr_msg "not installed" "未安装" "не установлено")"
  fi
}

show_status() {
  require_root; require_systemd
  import_legacy_config
  local svc_state svc_pid svc_uptime svc_mem target version port port_state portal
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    svc_state="${C_GREEN}● running${C_NC}"
  else
    svc_state="${C_RED}● stopped${C_NC}"
  fi
  svc_pid="$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null || echo 0)"
  if [[ "$svc_pid" != "0" && -n "$svc_pid" ]]; then
    svc_uptime="$(ps -o etime= -p "$svc_pid" 2>/dev/null | tr -d ' ' || echo N/A)"
    svc_mem="$(ps -o rss= -p "$svc_pid" 2>/dev/null | awk '{printf "%.1f MB", $1/1024}' || echo N/A)"
  else
    svc_uptime="N/A"; svc_mem="N/A"
  fi
  target="$(readlink "$CURRENT_LINK" 2>/dev/null || echo 'not installed')"
  version="$(basename "$target" 2>/dev/null || echo N/A)"
  port="$PORT"
  local port_label="Port"
  if [[ -s "$URL_FILE" ]]; then
    local u socks_value; IFS= read -r u <"$URL_FILE"
    ROLE="$(detect_role_from_url "$u" 2>/dev/null || printf portal)"
    if [[ "$ROLE" == portal ]]; then
      if parse_authority "$u"; then port="$PARSED_PORT"; fi
    else
      socks_value="$(urldecode "$(query_get "$u" socks)")"
      port="$(extract_endpoint_port "$socks_value" 2>/dev/null || printf '?')"
      port_label="SOCKS"
    fi
  fi
  if [[ "$port" =~ ^[0-9]+$ ]] && has_cmd ss && ss -lntup 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then
    port_state="${C_GREEN}● listening${C_NC}"
  else
    port_state="${C_RED}● not listening${C_NC}"
  fi
  printf '\033[1;36m┌──────────────────────────────────────────────────┐\033[0m\n'
  printf '\033[1;36m│\033[0m  \033[1;32mNowhere Service Status\033[0m                        \033[1;36m│\033[0m\n'
  printf '\033[1;36m├──────────────────────────────────────────────────┤\033[0m\n'
  printf '\033[1;36m│\033[0m  %-14s %-32b \033[1;36m│\033[0m\n' "Service:" "$svc_state"
  printf '\033[1;36m│\033[0m  %-14s %-32s \033[1;36m│\033[0m\n' "Version:" "${version:0:32}"
  printf '\033[1;36m│\033[0m  %-14s %-32s \033[1;36m│\033[0m\n' "Role:"    "$ROLE"
  printf '\033[1;36m│\033[0m  %-14s %-32s \033[1;36m│\033[0m\n' "PID:"     "$svc_pid"
  printf '\033[1;36m│\033[0m  %-14s %-32s \033[1;36m│\033[0m\n' "Uptime:"  "$svc_uptime"
  printf '\033[1;36m│\033[0m  %-14s %-32s \033[1;36m│\033[0m\n' "Memory:"  "$svc_mem"
  printf '\033[1;36m│\033[0m  %-14s %-32b \033[1;36m│\033[0m\n' "${port_label} ${port}:" "$port_state"
  printf '\033[1;36m└──────────────────────────────────────────────────┘\033[0m\n'
  printf '\n\033[1;33m%s\033[0m\n' "$(tr_msg "Recent logs:" "最近日志:" "Последние логи:")"
  journalctl -u "$SERVICE_NAME" -n 8 --no-pager --output=short-iso 2>/dev/null || true
}

show_links() {
  require_root; import_legacy_config
  [[ -s "$URL_FILE" ]] || die "$(tr_msg "No config." "没有配置。" "Нет конфигурации.")"
  load_meta
  apply_cli_overrides  # after load_meta so CLI flags (--host/--name/--client-*) win
  local u share
  IFS= read -r u <"$URL_FILE"
  u="$(migrate_url "$u")"
  echo
  printf '%b%s%b\n  %s\n' "$C_CYAN" "$(tr_msg "Run URL (server config, keep secret):" "运行 URL（服务端配置，请保密）:" "Run URL (секрет):")" "$C_NC" "$u"
  if [[ "$(detect_role_from_url "$u" 2>/dev/null || true)" == portal ]]; then
    share="$(build_share_link "$u")"
    echo
    printf '%b%s%b\n  %s\n' "$C_GREEN" "$(tr_msg "Anywhere 2.0 share link:" "Anywhere 2.0 分享链接:")" "$C_NC" "$share"
    local tls; tls="$(query_get "$u" tls)"; tls="${tls:-1}"
    if [[ "$tls" == 1 ]]; then
      warn "$(tr_msg "tls=1 self-signed; client must trust or pin." "tls=1 自签证书；客户端需信任或 pin。" "tls=1 self-signed; клиент должен доверять или pin.")"
    fi
  fi
}

fingerprint() {
  require_root; require_systemd
  import_legacy_config
  [[ -s "$URL_FILE" ]] || die "$(tr_msg "No config." "没有配置。" "Нет конфигурации.")"
  local u tls fp line host port
  IFS= read -r u <"$URL_FILE"
  tls="$(query_get "$u" tls)"; tls="${tls:-1}"
  [[ "$tls" == 1 ]] || { info "$(tr_msg "Not tls=1; use CA/SNI or pin." "当前不是 tls=1；tls=2 使用 CA/SNI 或 pin。" "Не tls=1; используйте CA/SNI или pin.")"; return; }
  line="$(journalctl -u "$SERVICE_NAME" -n 400 --no-pager 2>/dev/null | grep -Eai 'CERT_SHA256\||fingerprint|sha-?256' | tail -n1 || true)"
  # Prefer the colon-separated form (the Nowhere log format) before falling
  # back to a bare hex string, which may match an unrelated hash in the line.
  fp="$(printf '%s\n' "$line" | grep -Eaio '([A-Fa-f0-9]{2}:){31}[A-Fa-f0-9]{2}' | tail -n1 || true)"
  [[ -n "$fp" ]] || fp="$(printf '%s\n' "$line" | grep -Eao '[A-Fa-f0-9]{64}' | tail -n1 || true)"
  if [[ -n "$fp" ]]; then
    echo "$fp"
    warn "$(tr_msg "tls=1 fingerprint changes on restart." "tls=1 证书通常重启后会变化。" "Отпечаток tls=1 меняется при перезапуске.")"
    return
  fi
  parse_authority "$u" || die "$(tr_msg "Cannot parse config." "无法解析配置。" "Не удалось разобрать конфигурацию.")"
  host="$PARSED_HOST"; port="$PARSED_PORT"
  [[ -n "$host" && "$host" != 0.0.0.0 && "$host" != :: ]] || host=127.0.0.1
  if has_cmd openssl && has_cmd timeout && [[ "$(query_get "$u" net)" != udp ]]; then
    fp="$(timeout 8 openssl s_client -connect "$(format_host "$host"):${port}" -servername localhost </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//' || true)"
    if [[ -n "$fp" ]]; then echo "$fp"; return 0; fi
  fi
  die "$(tr_msg "Cannot get fingerprint; check journalctl -u nowhere -n 100." "暂时无法取得 fingerprint；请查看 journalctl -u nowhere -n 100。" "Не удалось получить отпечаток.")"
}

cleanup_old_releases() {
  require_root
  validate_keep_releases "$KEEP_RELEASES"
  local quiet="${1:-0}"
  [[ "$KEEP_RELEASES" -gt 0 ]] || { [[ "$quiet" == 1 ]] || info "$(tr_msg "Automatic release cleanup is disabled." "旧版本自动清理已关闭。" "Автоочистка релизов отключена.")"; return 0; }
  [[ -d "$RELEASES_DIR" ]] || return 0
  local current="" previous="" d kept=0 removed=0
  current="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
  previous="$OLD_TARGET"
  if [[ -n "$current" && -d "$current" ]]; then kept=1; fi
  if [[ -n "$previous" && -d "$previous" && "$previous" != "$current" ]] && (( kept < KEEP_RELEASES )); then
    kept=$((kept + 1))
  else
    previous=""
  fi
  while IFS= read -r d; do
    [[ -n "$d" && -d "$d" ]] || continue
    [[ "$d" == "$current" || "$d" == "$previous" ]] && continue
    if (( kept < KEEP_RELEASES )); then
      kept=$((kept + 1))
      continue
    fi
    rm -rf -- "$d"
    removed=$((removed + 1))
  done < <(ls -1dt "$RELEASES_DIR"/* 2>/dev/null || true)
  if (( removed > 0 )); then
    ok "$(tr_msg "Removed ${removed} old release(s); keeping up to ${KEEP_RELEASES}." "已清理 ${removed} 个旧版本；最多保留 ${KEEP_RELEASES} 个。" "Удалено старых релизов: ${removed}; сохранено до ${KEEP_RELEASES}.")"
  elif [[ "$quiet" != 1 ]]; then
    info "$(tr_msg "No old releases need cleanup (keep=${KEEP_RELEASES})." "无需清理旧版本（保留数=${KEEP_RELEASES}）。" "Старые релизы не требуют очистки (keep=${KEEP_RELEASES}).")"
  fi
}

doctor_action() {
  require_root; require_systemd
  import_legacy_config
  local pass=0 warning=0 fail=0 u="" r="" port="" net="" socks="" tls="" crt="" keyf="" perm=""
  local D_OK D_WARN D_FAIL
  D_OK="$(tr_msg 'PASS' '通过' 'OK')"; D_WARN="$(tr_msg 'WARN' '警告' 'WARN')"; D_FAIL="$(tr_msg 'FAIL' '失败' 'FAIL')"
  doctor_pass() { pass=$((pass + 1)); printf '%b[%s]%b %s\n' "$C_GREEN" "$D_OK" "$C_NC" "$*"; }
  doctor_warn() { warning=$((warning + 1)); printf '%b[%s]%b %s\n' "$C_YELLOW" "$D_WARN" "$C_NC" "$*"; }
  doctor_fail() { fail=$((fail + 1)); printf '%b[%s]%b %s\n' "$C_RED" "$D_FAIL" "$C_NC" "$*"; }

  printf '\n%b%s%b\n' "$C_CYAN" "$(tr_msg 'Nowhere health check' 'Nowhere 健康检查' 'Проверка Nowhere')" "$C_NC"

  if id "$RUN_USER" >/dev/null 2>&1; then doctor_pass "$(tr_msg "Service user exists: ${RUN_USER}" "服务用户存在: ${RUN_USER}" "Пользователь службы существует: ${RUN_USER}")"; else doctor_fail "$(tr_msg "Missing service user: ${RUN_USER}" "缺少服务用户: ${RUN_USER}" "Нет пользователя: ${RUN_USER}")"; fi
  if [[ -x "$CURRENT_LINK/nowhere" && -x "$BIN_LINK" ]]; then doctor_pass "$(tr_msg 'Binary and current symlink are valid.' '二进制与 current 软链接正常。' 'Бинарник и current-ссылка исправны.')"; else doctor_fail "$(tr_msg 'Binary/current symlink is missing or broken.' '二进制/current 软链接缺失或损坏。' 'Бинарник/current-ссылка отсутствует или повреждена.')"; fi
  if [[ -x "$LAUNCHER" && -f "$UNIT_FILE" ]]; then doctor_pass "$(tr_msg 'Launcher and systemd unit exist.' 'Launcher 与 systemd unit 存在。' 'Launcher и systemd unit существуют.')"; else doctor_fail "$(tr_msg 'Launcher or systemd unit is missing.' 'Launcher 或 systemd unit 缺失。' 'Launcher или systemd unit отсутствует.')"; fi

  if [[ -s "$URL_FILE" ]]; then
    IFS= read -r u <"$URL_FILE"
    if ( validate_imported_url "$u" ) >/dev/null 2>&1; then doctor_pass "$(tr_msg 'Configuration URL passed validation.' '配置 URL 校验通过。' 'URL конфигурации прошёл проверку.')"; else doctor_fail "$(tr_msg 'Configuration URL is invalid; run configure.' '配置 URL 无效，请运行 configure 修复。' 'URL конфигурации некорректен; запустите configure.')"; fi
    r="$(detect_role_from_url "$u" 2>/dev/null || true)"
  else
    doctor_fail "$(tr_msg "Missing configuration: ${URL_FILE}" "缺少配置文件: ${URL_FILE}" "Нет конфигурации: ${URL_FILE}")"
  fi

  if [[ -f "$URL_FILE" ]]; then
    perm="$(stat -c '%a %U:%G' "$URL_FILE" 2>/dev/null || true)"
    if [[ "$perm" == "640 root:${RUN_GROUP}" ]]; then doctor_pass "$(tr_msg "Config permissions are ${perm}." "配置权限正常: ${perm}。" "Права конфига: ${perm}.")"; else doctor_warn "$(tr_msg "Config permissions are ${perm:-unknown}; expected 640 root:${RUN_GROUP}." "配置权限为 ${perm:-未知}；建议 640 root:${RUN_GROUP}。" "Права конфига ${perm:-?}; ожидается 640 root:${RUN_GROUP}.")"; fi
  fi

  if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then doctor_pass "$(tr_msg 'Service is enabled at boot.' '服务已设置开机启动。' 'Автозапуск службы включён.')"; else doctor_warn "$(tr_msg 'Service is not enabled at boot.' '服务未设置开机启动。' 'Автозапуск службы выключен.')"; fi
  if systemctl is-active --quiet "$SERVICE_NAME"; then doctor_pass "$(tr_msg 'Service is active.' '服务正在运行。' 'Служба активна.')"; else doctor_fail "$(tr_msg 'Service is not active.' '服务未运行。' 'Служба не активна.')"; fi

  if [[ -n "$u" && "$r" == portal ]] && parse_authority "$u"; then
    port="$PARSED_PORT"; net="$(query_get "$u" net)"; net="${net:-mix}"
    if has_cmd ss; then
      if [[ "$net" == tcp || "$net" == mix ]]; then
        if ss -lnt 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then doctor_pass "TCP ${port} $(tr_msg 'is listening.' '正在监听。' 'слушается.')"; else doctor_fail "TCP ${port} $(tr_msg 'is not listening.' '未监听。' 'не слушается.')"; fi
      fi
      if [[ "$net" == udp || "$net" == mix ]]; then
        if ss -lnu 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then doctor_pass "UDP ${port} $(tr_msg 'is listening.' '正在监听。' 'слушается.')"; else doctor_fail "UDP ${port} $(tr_msg 'is not listening.' '未监听。' 'не слушается.')"; fi
      fi
    else
      doctor_warn "$(tr_msg 'ss is unavailable; skipped listen-port check.' '缺少 ss，跳过端口监听检查。' 'Нет ss; проверка порта пропущена.')"
    fi
    tls="$(query_get "$u" tls)"; tls="${tls:-1}"
    if [[ "$tls" == 2 ]]; then
      crt="$(urldecode "$(query_get "$u" crt)")"; keyf="$(urldecode "$(query_get "$u" key)")"
      if [[ -f "$crt" && -f "$keyf" ]]; then doctor_pass "$(tr_msg 'TLS certificate/key files exist.' 'TLS 证书与私钥文件存在。' 'TLS cert/key существуют.')"; else doctor_fail "$(tr_msg 'TLS certificate/key file is missing.' 'TLS 证书或私钥文件缺失。' 'TLS cert/key отсутствует.')"; fi
      if has_cmd runuser && runuser -u "$RUN_USER" -- test -r "$crt" 2>/dev/null && runuser -u "$RUN_USER" -- test -r "$keyf" 2>/dev/null; then doctor_pass "$(tr_msg 'Service user can read TLS files.' '服务用户可读取 TLS 文件。' 'Пользователь службы читает TLS-файлы.')"; else doctor_fail "$(tr_msg 'Service user cannot read TLS cert/key.' '服务用户无法读取 TLS 证书/私钥。' 'Пользователь службы не может читать TLS cert/key.')"; fi
    fi
  elif [[ -n "$u" && "$r" == vector ]]; then
    socks="$(urldecode "$(query_get "$u" socks)")"; port="$(extract_endpoint_port "$socks" 2>/dev/null || true)"
    if [[ "$port" =~ ^[0-9]+$ ]] && has_cmd ss; then
      if ss -lnt 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then doctor_pass "SOCKS TCP ${port} $(tr_msg 'is listening.' '正在监听。' 'слушается.')"; else doctor_fail "SOCKS TCP ${port} $(tr_msg 'is not listening.' '未监听。' 'не слушается.')"; fi
    fi
  fi

  if [[ -e "$SWAP_FILE" && "$BUILD_LOCK_HELD" -eq 0 ]]; then doctor_warn "$(tr_msg "Stale build swap may exist: ${SWAP_FILE}" "可能存在残留构建 swap: ${SWAP_FILE}" "Возможен устаревший swap: ${SWAP_FILE}")"; else doctor_pass "$(tr_msg 'No obvious stale build swap.' '未发现明显残留构建 swap。' 'Явного устаревшего build swap нет.')"; fi
  if [[ -d "$BUILD_LOCK_DIR" ]]; then doctor_warn "$(tr_msg "Build lock exists: ${BUILD_LOCK_DIR}" "存在构建锁: ${BUILD_LOCK_DIR}" "Есть build lock: ${BUILD_LOCK_DIR}")"; else doctor_pass "$(tr_msg 'No stale build lock.' '未发现残留构建锁。' 'Устаревшего build lock нет.')"; fi

  printf '\n%s\n' "$(tr_msg "Result: ${pass} passed, ${warning} warning(s), ${fail} failed." "结果：${pass} 项通过，${warning} 项警告，${fail} 项失败。" "Итог: ${pass} OK, ${warning} WARN, ${fail} FAIL.")"
  if (( fail > 0 )); then
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager --output=short-iso 2>/dev/null || true
    return 1
  fi
  return 0
}

rollback_action() {
  require_root; require_systemd
  [[ -d "$RELEASES_DIR" ]] || die "$(tr_msg "No releases." "没有历史版本。" "Нет релизов.")"
  local current candidates=() d target=""
  current="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
  while IFS= read -r d; do
    if [[ -d "$d" && -x "$d/nowhere" && "$d" != "$current" ]]; then candidates+=("$d"); fi
  done < <(ls -1dt "$RELEASES_DIR"/* 2>/dev/null || true)
  [[ "${#candidates[@]}" -gt 0 ]] || die "$(tr_msg "No valid rollback target." "没有有效的可回滚版本。" "Нет корректной цели отката.")"
  target="${candidates[0]}"
  info "$(tr_msg "Rollback to: $target" "回滚到: $target" "Откат к: $target")"
  ln -sfn "$target" "$CURRENT_LINK"
  ln -sfn "$CURRENT_LINK/nowhere" "$BIN_LINK"
  if systemctl restart "$SERVICE_NAME" && wait_service; then
    ok "$(tr_msg "Rolled back." "回滚完成。" "Откат выполнен.")"
    return 0
  fi
  warn "$(tr_msg "Rollback target failed; restoring original release." "目标回滚版本启动失败，正在恢复原版本。" "Цель отката не запустилась; восстанавливается исходная версия.")"
  if [[ -n "$current" && -x "$current/nowhere" ]]; then
    ln -sfn "$current" "$CURRENT_LINK"
    ln -sfn "$CURRENT_LINK/nowhere" "$BIN_LINK"
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
    wait_service || warn "$(tr_msg "Original release also failed to recover." "原版本也未能恢复运行。" "Исходная версия также не восстановилась.")"
  fi
  die "$(tr_msg "Rollback failed; original release was restored when possible." "回滚失败；已尽可能恢复原版本。" "Откат не удался; исходная версия восстановлена, если возможно.")"
}

prepare_tls_action() {
  require_root; ensure_user
  [[ -f "$CERT" && -f "$TLS_KEY" ]] || die "$(tr_msg "prepare-tls requires --cert and --tls-key." "prepare-tls 需要 --cert 与 --tls-key。" "prepare-tls требует --cert и --tls-key.")"
  TLS=2; COPY_CERT=1
  prepare_tls_files
  ok "$(tr_msg "Prepared ${CERT} and ${TLS_KEY}" "证书权限已准备完成: ${CERT} / ${TLS_KEY}" "Сертификаты подготовлены: ${CERT} / ${TLS_KEY}")"
}

uninstall_action() {
  require_root; require_systemd
  if [[ "$ASSUME_YES" -ne 1 ]]; then
    prompt_confirm "$(tr_msg "Confirm uninstall?" "确认卸载 Nowhere?" "Подтвердить удаление?")" || return 0
  fi
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE" "$LAUNCHER" "$BIN_LINK"
  rm -rf "$INSTALL_ROOT"
  systemctl daemon-reload
  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$CONFIG_DIR"
    ok "$(tr_msg "Removed binary, service, and config." "已卸载并清除配置。" "Удалено полностью.")"
  else
    warn "$(tr_msg "Kept ${CONFIG_DIR} (contains keys); use --purge to fully remove." "已保留 ${CONFIG_DIR}（含密钥）；使用 --purge 彻底删除。" "Сохранён ${CONFIG_DIR}; используйте --purge.")"
  fi
}

clean_build() {
  require_root
  acquire_build_lock
  cleanup_stale_swap
  rm -rf -- "$SRC_DIR"
  # Remove abandoned mktemp source trees left by SIGKILL/power loss.
  find /var/tmp -maxdepth 1 -type d -name 'nowhere-build.*' -exec rm -rf -- {} + 2>/dev/null || true
  cleanup_swap
  release_build_lock
  ok "$(tr_msg "Cleaned build cache and swap." "已清理构建缓存与临时 swap。" "Кэш сборки и swap очищены.")"
}

# ============================================================
# 语言选择 & 自更新
# ============================================================
choose_initial_language() {
  clear
  printf '\033[1;36m====================================================\033[0m\n'
  printf '\033[1;32m      Nowhere Unified Management Script (v%s)        \033[0m\n' "$SCRIPT_VERSION"
  printf '\033[1;36m====================================================\033[0m\n'
  printf ' [1] English\n'
  printf ' [2] 简体中文 (Simplified Chinese)\n'
  printf ' [3] Русский (Russian)\n'
  printf '%s\n' "----------------------------------------------------"
  local ch
  read -rp "Please select language / 请选择语言 / Выберите язык [1-3] (Default: 2): " ch </dev/tty || ch=""
  case "${ch:-2}" in
    1) LANG_CODE="en" ;;
    3) LANG_CODE="ru" ;;
    *) LANG_CODE="zh" ;;
  esac
}

self_update() {
  require_command curl
  local tmp remote_version self backup staging
  tmp="$(mktemp)"; CLEANUP_PATHS+=("$tmp")
  info "$(tr_msg "Checking for script updates..." "正在检查脚本更新..." "Проверка обновлений...")"
  if ! curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 --max-time 15 -o "$tmp" "$SELF_UPDATE_URL"; then
    warn "$(tr_msg "Failed to download script from ${SELF_UPDATE_URL}." "下载脚本失败: ${SELF_UPDATE_URL}" "Не удалось скачать скрипт: ${SELF_UPDATE_URL}")"
    return 1
  fi
  if ! bash -n "$tmp"; then
    warn "$(tr_msg "Downloaded script has syntax errors; aborting." "下载的脚本语法错误，已中止。" "Скачанный скрипт содержит ошибки синтаксиса.")"
    return 1
  fi
  remote_version="$(grep -oE '^readonly SCRIPT_VERSION="[^"]+"' "$tmp" | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  [[ "$remote_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || { warn "$(tr_msg "Downloaded script has no valid SCRIPT_VERSION; refusing update." "下载脚本缺少有效 SCRIPT_VERSION，拒绝更新。" "В загруженном скрипте нет корректного SCRIPT_VERSION.")"; return 1; }
  grep -q 'NodePassProject/Nowhere' "$tmp" || { warn "$(tr_msg "Downloaded script does not target NodePassProject/Nowhere; refusing update." "下载脚本目标不是 NodePassProject/Nowhere，拒绝更新。" "Скрипт не предназначен для NodePassProject/Nowhere.")"; return 1; }
  grep -q '^readonly SCRIPT_CHANNEL="v1-stable"$' "$tmp" || { warn "$(tr_msg "Downloaded script is not the V1 stable channel; refusing cross-generation self-update." "下载脚本不是 V1 稳定通道，拒绝跨代自更新。" "Загруженный скрипт не относится к стабильному каналу V1; межпоколенное обновление отклонено.")"; return 1; }
  grep -q '^readonly PINNED_NOWHERE_VERSION="v1.8.3"$' "$tmp" || { warn "$(tr_msg "Downloaded script does not pin Nowhere v1.8.3; refusing update." "下载脚本未固定 Nowhere v1.8.3，拒绝更新。" "Загруженный скрипт не закрепляет Nowhere v1.8.3; обновление отклонено.")"; return 1; }
  if [[ "$remote_version" == "$SCRIPT_VERSION" ]]; then
    info "$(tr_msg "Already up to date (v${SCRIPT_VERSION})." "已是最新版本 (v${SCRIPT_VERSION})。" "Уже последняя версия (v${SCRIPT_VERSION}).")"
    return 0
  fi
  self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  [[ -f "$self" ]] || { warn "$(tr_msg "Cannot locate own script." "无法定位当前脚本文件。" "Не удалось найти файл скрипта.")"; return 1; }
  info "$(tr_msg "Update available: v${SCRIPT_VERSION} -> v${remote_version:-unknown}" "发现更新: v${SCRIPT_VERSION} -> v${remote_version:-未知}" "Доступно обновление: v${SCRIPT_VERSION} -> v${remote_version:-?}")"
  prompt_confirm "$(tr_msg "Apply update?" "是否应用更新?" "Применить обновление?")" || { info "$(tr_msg "Cancelled." "已取消。" "Отменено.")"; return 0; }
  backup="${self}.bak.$(date +%s)"
  cp "$self" "$backup"
  # Stage beside the target and rename into place: writing in place (install
  # truncates the same inode) can corrupt the copy of this script that bash is
  # still executing before it reaches `exit 0`.
  staging="${self}.upgrade.$$"
  if ! { cp "$tmp" "$staging" && chmod 755 "$staging" && mv -f "$staging" "$self"; }; then
    rm -f "$staging"
    warn "$(tr_msg "Failed to install updated script; original kept. Backup: ${backup}" "安装更新脚本失败，原脚本保留。备份: ${backup}" "Ошибка установки. Резерв: ${backup}")"
    return 1
  fi
  rm -f "$tmp"
  info "$(tr_msg "Update applied (backup: ${backup}). Please re-run." "更新完成（备份: ${backup}），请重新运行脚本。" "Обновление применено (резерв: ${backup}). Перезапустите скрипт.")"
  exit 0
}

# ============================================================
# 主菜单
# ============================================================
interactive_menu() {
  require_root; require_systemd
  if [[ "$LANG_CODE" == "ask" ]]; then choose_initial_language; fi
  while true; do
    clear
    printf '\033[1;36m====================================================\033[0m\n'
    printf '\033[1;32m      Nowhere Unified Management Script (v%s)        \033[0m\n' "$SCRIPT_VERSION"
    printf '\033[1;36m====================================================\033[0m\n'
    printf ' [1] %s\n' "$(tr_msg "Install prebuilt (Recommended)" "安装官方预编译版本（推荐）" "Установить релиз (рекомендуется)")"
    printf ' [2] %s\n' "$(tr_msg "Compile from source" "本地源码编译安装" "Компилировать из исходников")"
    printf ' [3] %s\n' "$(tr_msg "Configure / Import URL" "修改/导入配置" "Настроить/Импорт URL")"
    printf '%s\n' "----------------------------------------------------"
    printf ' [4] %s\n' "$(tr_msg "View service status" "查看服务运行状态" "Статус службы")"
    printf ' [5] %s\n' "$(tr_msg "Show connection links" "显示连接链接" "Показать ссылки")"
    printf ' [6] %s\n' "$(tr_msg "View live logs" "查看实时日志" "Логи")"
    printf ' [7] %s\n' "$(tr_msg "Restart service" "重启服务" "Перезапустить")"
    printf ' [8] %s\n' "$(tr_msg "Launch TUI monitor" "启动 TUI 监控" "Запустить TUI")"
    printf ' [9] %s\n' "$(tr_msg "Show tls=1 fingerprint" "查看 tls=1 证书指纹" "Отпечаток tls=1")"
    printf ' [10] %s\n' "$(tr_msg "Rollback to previous release" "回滚至上一版本" "Откат")"
    printf ' [11] %s\n' "$(tr_msg "Clean build cache" "清理构建缓存" "Очистить кэш")"
    printf ' [12] %s\n' "$(tr_msg "Health check / Doctor" "健康检查 / Doctor" "Проверка / Doctor")"
    printf ' [13] %s\n' "$(tr_msg "Clean old releases" "清理旧版本" "Очистить старые релизы")"
    printf ' [14] %s\n' "$(tr_msg "Uninstall Nowhere" "卸载 Nowhere" "Удалить Nowhere")"
    printf '%s\n' "----------------------------------------------------"
    printf ' [15] %s\n' "$(tr_msg "Update script itself" "脚本自更新" "Обновить скрипт")"
    printf ' [16] %s\n' "$(tr_msg "Switch language (Current: $LANG_CODE)" "切换语言 (当前: $LANG_CODE)" "Сменить язык ($LANG_CODE)")"
    printf ' [0] %s\n' "$(tr_msg "Exit" "退出" "Выход")"
    printf '\033[1;36m====================================================\033[0m\n'
    local choice
    read -rp "$(tr_msg "Choice [0-16]: " "请输入选项序号 [0-16]: " "Выбор [0-16]: ")" choice </dev/tty || exit 0
    case "$choice" in
      1|2)
        ACTION="install"
        if [[ "$choice" == "2" ]]; then INSTALL_METHOD="source"; else INSTALL_METHOD="release"; fi
        VERSION="$(choose_version_interactive "$VERSION")"
        validate_version "$VERSION"
        install_action
        ;;
      3) configure_action ;;
      4) show_status ;;
      5) show_links ;;
      6) info "$(tr_msg 'Press Ctrl+C to stop.' '按 Ctrl+C 退出。' 'Ctrl+C для выхода.')"; journalctl -u "$SERVICE_NAME" -f || true ;;
      7)
        if systemctl restart "$SERVICE_NAME"; then
          ok "$(tr_msg "Restarted." "已重启。" "Перезапущено.")"
        else
          warn "$(tr_msg "Restart failed; check journalctl -u nowhere -n 50." "重启失败；请查看 journalctl -u nowhere -n 50。" "Перезапуск не удался: journalctl -u nowhere -n 50.")"
        fi
        ;;
      8)
        if [[ ! -x "$BIN_LINK" ]]; then
          warn "$(tr_msg "Nowhere not installed." "未安装 Nowhere。" "Nowhere не установлен.")"
        else
          "$BIN_LINK" tui || true
        fi
        ;;
      9) fingerprint ;;
      10) rollback_action ;;
      11) clean_build ;;
      12) doctor_action || true ;;
      13) cleanup_old_releases ;;
      14)
        if prompt_confirm "$(tr_msg "Also delete config/keys?" "是否一并删除配置和密钥?" "Удалить также конфиг/ключи?")"; then PURGE=1; fi
        uninstall_action
        ;;
      15) self_update || true ;;
      16) choose_initial_language ;;
      0) exit 0 ;;
      *) warn "$(tr_msg 'Invalid choice.' '无效选择。' 'Неверный выбор.')"; sleep 1; continue ;;
    esac
    echo
    read -rp "$(tr_msg "Press Enter to return to menu..." "按回车键返回菜单..." "Enter для возврата в меню...")" _ </dev/tty || true
  done
}

usage() {
  cat <<EOF2
Nowhere Unified Management Script v${SCRIPT_VERSION}
Channel: ${SCRIPT_CHANNEL}
Pinned Nowhere core: ${PINNED_NOWHERE_VERSION}
NOTE: Nowhere v2.x is wire-incompatible with v1.x and is intentionally unsupported by this script.

Usage:
  sudo bash nowhere-v1.sh                                  (Interactive menu)
  sudo bash nowhere-v1.sh install [options]                (Install + configure)
  sudo bash nowhere-v1.sh upgrade [options]                (Upgrade binary, keep config)
  sudo bash nowhere-v1.sh configure [options]              (Modify / import URL)
  sudo bash nowhere-v1.sh status | link | logs | restart
  sudo bash nowhere-v1.sh fingerprint                      (tls=1 SHA-256)
  sudo bash nowhere-v1.sh tui
  sudo bash nowhere-v1.sh rollback
  sudo bash nowhere-v1.sh doctor                            (Health diagnostics)
  sudo bash nowhere-v1.sh clean-releases [--keep-releases N]
  sudo bash nowhere-v1.sh prepare-tls --cert FILE --tls-key FILE
  sudo bash nowhere-v1.sh uninstall [--purge]
  sudo bash nowhere-v1.sh self-update

Options:
  -y, --yes                    Non-interactive
  --method release|source      Default: release
  --version v1.8.3              Pinned stable core; all other versions rejected
  --libc auto|gnu|musl         Release libc
  --type portal|vector         Service role, default: portal
  --url URI                    Import portal:// / vector:// / nowhere://
  --key KEY                    Shared key (16-255 chars)
  --port PORT                  1-65535, default: 2077
  --listen-host HOST           Portal listen address
  --host HOST                  Public IP/domain for share link
  --name NAME                  Node display name
  --net mix|tcp|udp            Portal listener, default: mix
  --tls 1|2                    1=self-signed, 2=PEM, default: 1
  --cert FILE --tls-key FILE   TLS 2 cert/key
  --copy-cert                  Copy tls=2 cert into /etc/nowhere/tls
  --alpn VALUE                 Default: now/1
  --rate Mbps --etar Mbps      Bidirectional rate limit
  --dial auto|IP               Portal outbound source
  --log LEVEL                  none|debug|info|warn|error|event
  --socks ENDPOINT             Portal outbound SOCKS5 (mutually exclusive with --next)
  --next KEY@HOST:PORT         Portal native chained upstream
  --up tcp|udp|mix             Vector / next upstream
  --down tcp|udp|mix           Vector / next downstream
  --mux 0|1                    TLS Mux
  --sni NAME|none              Vector / next SNI
  --pin SHA256|none            Vector / next cert pin
  --vector-socks ADDR          Default: 127.0.0.1:1080
  --client-up tcp|udp|mix|auto Client share link upstream
  --client-down ...            Client share link downstream
  --client-mux 0|1|auto        Share link mux
  --client-sni NAME|none|auto  Share link SNI
  --client-pin SHA256|none     Share link pin
  --swap auto|off|MB           Source compile temp swap
  --keep-source                Keep source tree after compile
  --keep-releases N            Keep current + newest backups; default: 3, 0=off
  --config-mode MODE           ask|quick|advanced (interactive config)
  --quick                      Shortcut for --config-mode quick
  --advanced                   Shortcut for --config-mode advanced
  --github-token TOKEN         GitHub PAT (rate limit bypass)
  --purge                      Uninstall also deletes config

Environment:
  GITHUB_TOKEN                 GitHub PAT for API rate limit
  NOWHERE_SELF_URL             Override self-update source URL
  NOWHERE_KEEP_RELEASES        Auto cleanup retention (default: 3)
  NOWHERE_CONFIG_MODE          ask|quick|advanced
EOF2
}

# ============================================================
# CLI 参数
# ============================================================
set_cli() {
  local name="$1" value="$2"
  CLI_SET["$name"]=1; CLI_VAL["$name"]="$value"
  printf -v "$name" '%s' "$value"
}

apply_cli_overrides() {
  local name
  for name in "${!CLI_SET[@]}"; do printf -v "$name" '%s' "${CLI_VAL[$name]}"; done
}

parse_args() {
  if [[ $# -gt 0 && "$1" != -* ]]; then ACTION="$1"; shift; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) ASSUME_YES=1; shift ;;
      --method) INSTALL_METHOD="${2:?missing --method}"; shift 2 ;;
      --version) VERSION="${2:?missing --version}"; validate_version "$VERSION"; shift 2 ;;
      --libc) LIBC="${2:?missing --libc}"; shift 2 ;;
      --type) set_cli ROLE "${2:?missing --type}"; shift 2 ;;
      --url) IMPORT_URL="${2:?missing --url}"; shift 2 ;;
      --key) set_cli KEY "${2:?missing --key}"; shift 2 ;;
      --port) set_cli PORT "${2:?missing --port}"; shift 2 ;;
      --listen-host) set_cli LISTEN_HOST "${2:?missing --listen-host}"; shift 2 ;;
      --host|--public-host) set_cli PUBLIC_HOST "${2:?missing --host}"; shift 2 ;;
      --name) set_cli NODE_NAME "${2:?missing --name}"; shift 2 ;;
      --net) set_cli NET "${2:?missing --net}"; shift 2 ;;
      --tls) set_cli TLS "${2:?missing --tls}"; shift 2 ;;
      --cert|--crt) set_cli CERT "${2:?missing --cert}"; shift 2 ;;
      --tls-key) set_cli TLS_KEY "${2:?missing --tls-key}"; shift 2 ;;
      --copy-cert) COPY_CERT=1; shift ;;
      --alpn) set_cli ALPN "${2:?missing --alpn}"; shift 2 ;;
      --rate) set_cli RATE "${2:?missing --rate}"; shift 2 ;;
      --etar) set_cli ETAR "${2:?missing --etar}"; shift 2 ;;
      --dial) set_cli DIAL "${2:?missing --dial}"; shift 2 ;;
      --log) set_cli LOG_LEVEL "${2:?missing --log}"; shift 2 ;;
      --socks) set_cli OUT_SOCKS "${2:?missing --socks}"; shift 2 ;;
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
      --swap) SWAP_MODE="${2:?missing --swap}"; shift 2 ;;
      --keep-source) KEEP_SOURCE=1; shift ;;
      --keep-releases)
        KEEP_RELEASES="${2:?missing --keep-releases}"
        validate_keep_releases "$KEEP_RELEASES"
        shift 2
        ;;
      --config-mode)
        CONFIG_MODE="${2:?missing --config-mode}"
        validate_config_mode "$CONFIG_MODE"
        shift 2
        ;;
      --quick) CONFIG_MODE=quick; shift ;;
      --advanced) CONFIG_MODE=advanced; shift ;;
      --github-token) GITHUB_TOKEN="${2:?missing --github-token}"; shift 2 ;;
      --purge) PURGE=1; shift ;;
      -h|--help) ACTION=help; shift ;;
      *) die "$(tr_msg "Unknown option: $1" "未知参数: $1" "Неизвестный параметр: $1")" ;;
    esac
  done
}

# ============================================================
# 主入口
# ============================================================
main() {
  parse_args "$@"
  validate_keep_releases "$KEEP_RELEASES"
  validate_config_mode "$CONFIG_MODE"
  if [[ "$LANG_CODE" == "ask" && "$ACTION" != menu ]]; then resolve_language "auto"; fi
  case "$ACTION" in
    menu) interactive_menu ;;
    install) install_action ;;
    upgrade|update) ACTION=upgrade; install_action ;;
    configure|config) configure_action ;;
    status) show_status ;;
    link|links|client-link) show_links ;;
    logs|log) require_root; require_systemd; journalctl -u "$SERVICE_NAME" -f ;;
    start|stop|restart) require_root; require_systemd; systemctl "$ACTION" "$SERVICE_NAME" ;;
    tui) require_root; [[ -x "$BIN_LINK" ]] || die "$(tr_msg "Not installed." "未安装 Nowhere。" "Nowhere не установлен.")"; "$BIN_LINK" tui ;;
    fingerprint|sha256|sha-256) fingerprint ;;
    rollback) rollback_action ;;
    doctor|check|diagnose) doctor_action ;;
    clean-releases|prune-releases) require_root; cleanup_old_releases ;;
    prepare-tls) prepare_tls_action ;;
    clean-build) clean_build ;;
    self-update) self_update ;;
    uninstall|remove) uninstall_action ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi