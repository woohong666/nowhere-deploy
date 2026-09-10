#!/usr/bin/env bash
#
# Nowhere Unified Management Script (Prebuilt Release & Source Compile)
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 woohong666
#
set -Eeuo pipefail
umask 077

readonly SCRIPT_VERSION="2.1.0"
readonly UPSTREAM_REPO="NodePassProject/Nowhere"
readonly DEFAULT_REPO_URL="https://github.com/NodePassProject/Nowhere.git"
readonly DEFAULT_VERSION="v1.8.3"
readonly MIN_RUSTC="1.85.0"

readonly SERVICE_NAME="nowhere"
readonly RUN_USER="nowhere"
readonly RUN_GROUP="nowhere"
readonly INSTALL_ROOT="/opt/nowhere"
readonly CURRENT_LINK="${INSTALL_ROOT}/current"
readonly BIN_LINK="/usr/local/bin/nowhere"
readonly CONFIG_DIR="/etc/nowhere"
readonly CONFIG_FILE="${CONFIG_DIR}/nowhere.env"
readonly UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

readonly SRC_DIR="/var/tmp/nowhere-build"
readonly SWAP_FILE="/swapfile-nowhere"
readonly RUSTUP_HOME_DIR="/usr/local/rustup"
readonly CARGO_HOME_DIR="/usr/local/cargo"

LANG_CODE="${NOWHERE_LANG:-ask}"

INSTALL_METHOD="release"
ACTION=""
VERSION="${NOWHERE_VERSION:-$DEFAULT_VERSION}"
REPO_URL="${NOWHERE_GIT_URL:-$DEFAULT_REPO_URL}"
COMMIT="${NOWHERE_COMMIT:-}"
PORT="${NOWHERE_PORT:-2077}"
KEY="${NOWHERE_KEY:-}"
NET="${NOWHERE_NET:-mix}"
TLS="${NOWHERE_TLS:-2}"
CERT="${NOWHERE_CERT:-}"
TLS_KEY="${NOWHERE_TLS_KEY:-}"
LISTEN_HOST="${NOWHERE_LISTEN_HOST:-}"
CLIENT_LINK_HOST="${NOWHERE_CLIENT_HOST:-}"
CLIENT_LINK_NAME="${NOWHERE_CLIENT_NAME:-}"
LIBC="${NOWHERE_LIBC:-auto}"
JOBS="${NOWHERE_JOBS:-}"
SWAP_MODE="${NOWHERE_SWAP:-auto}"
KEEP_SOURCE="${NOWHERE_KEEP_SOURCE:-0}"
INSTALL_DEPS="${NOWHERE_INSTALL_DEPS:-1}"
INSTALL_RUST="${NOWHERE_INSTALL_RUST:-1}"
TRUST_RUSTUP_SHA="${NOWHERE_RUSTUP_SHA:-}"
PURGE=0

SWAP_CREATED=0
CLEANUP_PATHS=("")

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

info() { printf '\033[1;34m[Nowhere]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$(tr_msg Warn 警告 Предупреждение)" "$*" >&2; }
die()  { printf '\033[1;31m[%s]\033[0m %s\n' "$(tr_msg Error 错误 Ошибка)" "$*" >&2; exit 1; }

cleanup_all() {
  local p
  if (( ${#CLEANUP_PATHS[@]} > 0 )); then
    for p in "${CLEANUP_PATHS[@]}"; do
      [[ -n "$p" ]] && rm -rf "$p"
    done
  fi
  cleanup_swap
}
trap cleanup_all EXIT

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "$(tr_msg "Run this command as root: sudo bash $0" "请以 root 权限运行此命令: sudo bash $0" "Запустите команду от root: sudo bash $0")"
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "$(tr_msg "systemctl is required. This script supports systemd Linux only." "缺少 systemctl，本脚本仅支持 systemd Linux。" "Требуется systemctl. Поддерживается только systemd Linux.")"
  [[ -d /run/systemd/system ]] || die "$(tr_msg "systemd is not running on this host." "systemd 未在当前主机上运行。" "systemd не запущен на этом хосте.")"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$(tr_msg "Missing required command: $1" "缺少必要系统命令: $1" "Отсутствует необходимая утилита: $1")"
}

validate_version() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] ||
    die "$(tr_msg "Invalid version tag: $1" "版本号格式不合法: $1" "Неверный тег версии: $1")"
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "$(tr_msg "Port must be an integer." "端口必须是纯数字。" "Порт должен быть числом.")"
  (( 1024 <= 10#$1 && 10#$1 <= 65535 )) ||
    die "$(tr_msg "Port must be between 1024 and 65535 for non-root service." "非 root 服务端口必须在 1024-65535 之间。" "Порт должен быть в диапазоне 1024-65535.")"
}

validate_key() {
  [[ -n "$1" ]] || die "$(tr_msg "A shared key is required." "必须提供共享密钥。" "Необходим секретный ключ.")"
  [[ "$1" =~ ^[A-Za-z0-9._~-]{16,255}$ ]] ||
    die "$(tr_msg "Key must be 16-255 characters using A-Z, a-z, 0-9, '.', '_', '~', or '-'." "密钥必须为 16-255 位字符，仅允许字母、数字及 . _ ~ -" "Ключ должен быть длиной 16-255 символов.")"
}

validate_no_space() {
  [[ "$2" != *[[:space:]]* ]] || die "$(tr_msg "$1 must not contain whitespace: $2" "$1 路径不得包含空格: $2" "$1 не должен содержать пробелов: $2")"
}

validate_config() {
  validate_version "$VERSION"
  validate_port "$PORT"
  [[ "$NET" == "mix" || "$NET" == "tcp" || "$NET" == "udp" ]] ||
    die "$(tr_msg "--net must be mix, tcp, or udp." "--net 必须为 mix, tcp 或 udp。" "--net должен быть mix, tcp или udp.")"
  [[ "$TLS" == "1" || "$TLS" == "2" ]] || die "$(tr_msg "--tls must be 1 or 2." "--tls 模式必须为 1 或 2。" "--tls должен быть 1 или 2.")"
  [[ "$INSTALL_METHOD" == "release" || "$INSTALL_METHOD" == "source" ]] ||
    die "$(tr_msg "--method must be release or source." "--method 必须为 release 或 source。" "--method должен быть release или source.")"
  case "$LIBC" in
    auto|gnu|musl) ;;
    *) die "$(tr_msg "--libc must be auto, gnu, or musl." "--libc 必须为 auto, gnu 或 musl。" "--libc должен быть auto, gnu или musl.")" ;;
  esac
  [[ "$SWAP_MODE" == "auto" || "$SWAP_MODE" == "off" || "$SWAP_MODE" =~ ^[0-9]+$ ]] ||
    die "$(tr_msg "--swap must be auto, off, or a size in MB." "--swap 必须为 auto, off 或数字（MB）。" "--swap должен быть auto, off или размер в МБ.")"
  if [[ -n "$COMMIT" && ! "$COMMIT" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    die "$(tr_msg "--commit must be a git commit hash (7-40 hex characters)." "--commit 必须是 git 提交哈希（7-40 位十六进制）。" "--commit должен быть git хеш (7-40 hex символов).")"
  fi
  if [[ "$TLS" == "2" ]]; then
    [[ -n "$CERT" && -n "$TLS_KEY" ]] || die "$(tr_msg "--tls 2 requires --cert and --tls-key." "TLS 2 模式必须指定 --cert 与 --tls-key。" "--tls 2 требует --cert и --tls-key.")"
    [[ -f "$CERT" ]] || die "$(tr_msg "Certificate not found: $CERT" "证书文件未找到: $CERT" "Сертификат не найден: $CERT")"
    [[ -f "$TLS_KEY" ]] || die "$(tr_msg "Private key not found: $TLS_KEY" "私钥文件未找到: $TLS_KEY" "Ключ не найден: $TLS_KEY")"
    validate_no_space "--cert" "$CERT"
    validate_no_space "--tls-key" "$TLS_KEY"
  fi
}

urlencode() {
  local s="$1" out="" c i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9.~_-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

env_quote() {
  local value="${1//$'\n'/}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

stored_portal() {
  [[ -r "$CONFIG_FILE" ]] || return 0
  awk -F'"' '/^NOWHERE_PORTAL=/ { print $2; exit }' "$CONFIG_FILE"
}

build_portal() {
  local host="${LISTEN_HOST}"
  local query="tls=${TLS}"
  [[ "$NET" == "mix" ]] || query="${query}&net=${NET}"
  if [[ "$TLS" == "2" ]]; then
    query="${query}&crt=$(urlencode "$CERT")&key=$(urlencode "$TLS_KEY")"
  fi
  printf 'portal://%s@%s:%s?%s' "$KEY" "$host" "$PORT" "$query"
}

parse_query_param() {
  local query="$1" name="$2"
  [[ "$query" =~ (^|&)"$name"=([^&]*) ]] && printf '%s' "${BASH_REMATCH[2]}" || true
}

detect_public_ip() {
  local ip
  ip="$(curl -fsSL --max-time 5 --ipv4 https://ifconfig.me 2>/dev/null || true)"
  [[ -n "$ip" ]] && printf '%s' "$ip" || return 1
}

is_ip_literal() {
  local h="$1"
  [[ "$h" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && return 0
  [[ "$h" == \[*\] ]] && return 0
  return 1
}

# Derive the client-facing nowhere:// share URI from a server portal:// URI.
# Portal-only parameters (tls/crt/key/net/dial/log) are deliberately dropped;
# the client only needs key, host, port, carrier strategy and node name.
build_nowhere_link() {
  local portal="$1" public_host="${2:-}" node_name="${3:-}"

  local rest="${portal#portal://}"
  if [[ "$rest" == "$portal" ]]; then
    warn "$(tr_msg "Not a portal:// URI: ${portal}" "不是 portal:// 格式: ${portal}" "Это не portal:// URI: ${portal}")"
    return 1
  fi

  local query=""
  if [[ "$rest" == *\?* ]]; then
    query="${rest#*\?}"
    rest="${rest%%\?*}"
  fi

  if [[ ! "$rest" =~ ^([^@]+)@(.*):([0-9]+)$ ]]; then
    warn "$(tr_msg "Cannot parse portal authority: ${rest}" "无法解析 portal 地址: ${rest}" "Не удалось разобрать адрес portal: ${rest}")"
    return 1
  fi
  local key="${BASH_REMATCH[1]}"
  local conf_host="${BASH_REMATCH[2]}"
  local port="${BASH_REMATCH[3]}"

  local tls net
  tls="$(parse_query_param "$query" "tls")"
  net="$(parse_query_param "$query" "net")"
  [[ -n "$net" ]] || net="mix"

  # Host precedence: --host > host baked into the config > detected public IP.
  local host="$public_host"
  if [[ -z "$host" ]]; then
    host="$conf_host"
  fi
  if [[ -z "$host" ]]; then
    host="$(detect_public_ip)" || {
      warn "$(tr_msg "Could not detect public IP; pass --host <ip-or-domain>." "无法检测公网 IP，请用 --host <IP或域名> 指定。" "Не удалось определить публичный IP; укажите --host <ip-или-домен>.")"
      return 1
    }
  fi

  local up down mux_param=""
  case "$net" in
    tcp) up="tcp"; down="tcp"; mux_param="&mux=1" ;;
    udp) up="udp"; down="udp" ;;
    *)   up="mix"; down="mix" ;;
  esac

  # SNI only matters when a real certificate is served for a domain name.
  local sni=""
  if [[ "$tls" == "2" ]] && ! is_ip_literal "$host"; then
    sni="&sni=${host}"
  fi

  [[ -n "$node_name" ]] || node_name="Nowhere-${host}"

  printf 'nowhere://%s@%s:%s?up=%s&down=%s%s%s#%s\n' \
    "$key" "$host" "$port" "$up" "$down" "$mux_param" "$sni" "$(urlencode "$node_name")"

  if [[ "$tls" == "1" ]]; then
    warn "$(tr_msg "TLS mode 1 uses a self-signed certificate; the client must trust or pin its fingerprint." "TLS 模式 1 使用自签名证书，客户端需信任或固定其指纹。" "Режим TLS 1 использует самоподписанный сертификат; клиент должен доверять отпечатку.")"
  fi
}

version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

mem_total_mb() {
  local mb
  mb="$(awk '/^MemTotal:/ { printf "%d", $2/1024 }' /proc/meminfo 2>/dev/null || true)"
  printf '%s' "${mb:-0}"
}

free_disk_mb() {
  local mb
  mb="$(df -Pk "$1" 2>/dev/null | awk 'NR==2 { printf "%d", $4/1024 }' || true)"
  printf '%s' "${mb:-0}"
}

detect_target() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'x86_64-unknown-linux-gnu' ;;
    aarch64|arm64) printf 'aarch64-unknown-linux-gnu' ;;
    *) die "$(tr_msg "Unsupported CPU architecture: $(uname -m)" "不支持的 CPU 架构: $(uname -m)" "Неподдерживаемая архитектура CPU: $(uname -m)")" ;;
  esac
}

asset_name() {
  local arch libc
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) die "$(tr_msg "Unsupported CPU architecture: $(uname -m)" "不支持的 CPU 架构: $(uname -m)" "Неподдерживаемая архитектура CPU: $(uname -m)")" ;;
  esac
  libc="gnu"
  if [[ "$LIBC" == "musl" ]]; then
    libc="musl"
  elif [[ "$LIBC" == "auto" ]] && command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
    libc="musl"
  fi
  printf 'nowhere-%s-unknown-linux-%s.tar.gz' "$arch" "$libc"
}

fetch_asset_digest() {
  local asset="$1" api_json digest
  api_json="$(curl --fail --silent --show-error --location --proto '=https' \
    --tlsv1.2 --retry 3 --connect-timeout 10 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${UPSTREAM_REPO}/releases/tags/${VERSION}")" ||
    die "$(tr_msg "Could not read official GitHub Release metadata." "无法读取官方 GitHub Release 元数据。" "Не удалось прочитать метаданные GitHub Release.")"
  digest="$(printf '%s' "$api_json" | python3 -c '
import json, sys
asset_name = sys.argv[1]
data = json.load(sys.stdin)
for asset in data.get("assets", []):
    if asset.get("name") == asset_name:
        print(asset.get("digest") or "")
        break
' "$asset")"
  [[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] ||
    die "$(tr_msg "GitHub did not publish a SHA-256 digest for ${asset}. Refusing to install." "GitHub 未为 ${asset} 提供 SHA-256 校验和，已拒绝安装。" "GitHub не предоставил SHA-256 для ${asset}. Отказ в установке.")"
  printf '%s' "${digest#sha256:}"
}

download_verified_release() {
  local asset="$1" expected="$2" tmpdir="$3" archive="$tmpdir/$asset" actual
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --retry 3 --connect-timeout 10 \
    -o "$archive" \
    "https://github.com/${UPSTREAM_REPO}/releases/download/${VERSION}/${asset}" ||
    die "$(tr_msg "Could not download official Release ${VERSION}." "下载官方 Release ${VERSION} 失败。" "Не удалось скачать релиз ${VERSION}.")"
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] ||
    die "$(tr_msg "SHA-256 mismatch for ${asset}." "文件 SHA-256 校验不匹配 (${asset})。" "Несовпадение SHA-256 для ${asset}.")"
  printf '%s' "$archive"
}

install_verified_binary() {
  local asset tmpdir archive release_dir binary expected binary_sha
  asset="$(asset_name)"
  info "$(tr_msg "Resolving published digest for ${asset}..." "正在检索官方发布的 ${asset} 校验和..." "Получение контрольной суммы для ${asset}...")"
  expected="$(fetch_asset_digest "$asset")"
  tmpdir="$(mktemp -d)"
  CLEANUP_PATHS+=("$tmpdir")

  info "$(tr_msg "Downloading official Release ${VERSION}..." "正在下载官方 Release ${VERSION}..." "Загрузка официального релиза ${VERSION}...")"
  archive="$(download_verified_release "$asset" "$expected" "$tmpdir")"
  mkdir -p "$tmpdir/extracted"
  tar --extract --gzip --file "$archive" --directory "$tmpdir/extracted"
  binary="$(find "$tmpdir/extracted" -type f -name nowhere -perm -u+x -print -quit)"
  [[ -n "$binary" ]] || die "$(tr_msg "Release archive does not contain nowhere executable." "解压归档中未发现可执行文件 nowhere。" "Архив не содержит исполняемого файла nowhere.")"

  binary_sha="$(sha256sum "$binary" | awk '{print $1}')"
  release_dir="${INSTALL_ROOT}/releases/${VERSION}-prebuilt-${binary_sha:0:12}"
  install -d -m 755 "${INSTALL_ROOT}/releases" "$release_dir"
  install -m 755 "$binary" "${release_dir}/nowhere"
  ln -sfn "$release_dir" "$CURRENT_LINK"
  ln -sfn "${CURRENT_LINK}/nowhere" "$BIN_LINK"
  cat >"${release_dir}/RELEASE-INFO" <<EOF
repository:   https://github.com/${UPSTREAM_REPO}
tag:          ${VERSION}
asset:        ${asset}
source:       official prebuilt Release
downloaded_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
asset_sha256: ${expected}
binary_sha256: ${binary_sha}
EOF
  info "$(tr_msg "Installed verified Nowhere ${VERSION} (sha256: ${binary_sha:0:12})" "已成功安装官方验证版 Nowhere ${VERSION} (sha256: ${binary_sha:0:12})" "Установлен проверенный Nowhere ${VERSION} (sha256: ${binary_sha:0:12})")"
}

pkg_manager() {
  local c
  for c in apt-get dnf yum apk zypper; do
    command -v "$c" >/dev/null 2>&1 && { printf '%s' "$c"; return 0; }
  done
  return 1
}

pkg_install() {
  local mgr; mgr="$(pkg_manager)" || die "$(tr_msg "No supported package manager found." "未找到受支持的包管理器。" "Поддерживаемый менеджер пакетов не найден.")"
  case "$mgr" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential git curl ca-certificates ;;
    dnf) dnf install -y gcc gcc-c++ make git curl ca-certificates ;;
    yum) yum install -y gcc gcc-c++ make git curl ca-certificates ;;
    apk) apk add --no-cache build-base git curl ca-certificates ;;
    zypper) zypper --non-interactive install gcc gcc-c++ make git curl ca-certificates ;;
  esac
}

ensure_build_deps() {
  local need=0
  command -v git >/dev/null 2>&1 || need=1
  command -v curl >/dev/null 2>&1 || need=1
  command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 || need=1

  if [[ "$need" -eq 0 ]]; then return 0; fi
  if [[ "$INSTALL_DEPS" -ne 1 ]]; then
    die "$(tr_msg "Missing build dependencies (git, curl, C compiler)." "缺少构建依赖（git, curl, C 编译器）。" "Отсутствуют зависимости сборки (git, curl, C compiler).")"
  fi
  info "$(tr_msg "Installing build dependencies..." "正在安装构建工具链依赖..." "Установка зависимостей сборки...")"
  pkg_install || die "$(tr_msg "Could not install build dependencies." "安装系统构建依赖失败。" "Не удалось установить зависимости сборки.")"
}

use_existing_rustc() {
  command -v rustc >/dev/null 2>&1 || return 1
  command -v cargo >/dev/null 2>&1 || return 1
  local raw
  raw="$(rustc --version 2>/dev/null | awk '{print $2}')"
  [[ -n "$raw" ]] || return 1
  version_ge "$raw" "$MIN_RUSTC"
}

activate_rust_env() {
  export RUSTUP_HOME="$RUSTUP_HOME_DIR"
  export CARGO_HOME="$CARGO_HOME_DIR"
  export PATH="${CARGO_HOME_DIR}/bin:${PATH}"
}

ensure_rust() {
  if use_existing_rustc; then
    info "$(tr_msg "Using existing $(rustc --version)" "使用现有 $(rustc --version)" "Используется $(rustc --version)")"
    return 0
  fi
  if [[ "$INSTALL_RUST" -ne 1 ]]; then
    die "$(tr_msg "Rust ${MIN_RUSTC}+ is required." "需要 Rust ${MIN_RUSTC}+ 环境。" "Требуется Rust ${MIN_RUSTC}+.")"
  fi
  activate_rust_env
  if [[ -x "${CARGO_HOME_DIR}/bin/cargo" ]] && use_existing_rustc; then
    return 0
  fi

  local target url sha_url tmp expected actual
  target="$(detect_target)"
  url="https://static.rust-lang.org/rustup/dist/${target}/rustup-init"
  sha_url="${url}.sha256"

  info "$(tr_msg "Installing Rust toolchain (${target})..." "正在安装 Rust 工具链 (${target})..." "Установка тулчейна Rust (${target})...")"
  tmp="$(mktemp -d)"
  CLEANUP_PATHS+=("$tmp")

  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --retry 3 --connect-timeout 10 -o "${tmp}/rustup-init" "$url"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --retry 3 --connect-timeout 10 -o "${tmp}/rustup-init.sha256" "$sha_url"

  expected="$(awk '{print $1}' "${tmp}/rustup-init.sha256")"
  actual="$(sha256sum "${tmp}/rustup-init" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] || die "$(tr_msg "rustup-init SHA-256 mismatch." "rustup-init SHA-256 校验和不匹配。" "Несовпадение SHA-256 для rustup-init.")"

  if [[ -n "$TRUST_RUSTUP_SHA" && "${TRUST_RUSTUP_SHA,,}" != "${actual,,}" ]]; then
    die "$(tr_msg "rustup-init does not match --trust-rustup-sha." "rustup-init 与 --trust-rustup-sha 指定值不符。" "rustup-init не соответствует значению --trust-rustup-sha.")"
  fi

  chmod 700 "${tmp}/rustup-init"
  "${tmp}/rustup-init" -y --no-modify-path --profile minimal --default-toolchain stable
  rm -rf "$tmp"
  activate_rust_env
}

cleanup_swap() {
  if [[ "$SWAP_CREATED" -ne 1 ]]; then return 0; fi
  SWAP_CREATED=0
  swapoff "$SWAP_FILE" 2>/dev/null || true
  rm -f "$SWAP_FILE"
}

has_swap() {
  [[ "$(awk 'NR>1' /proc/swaps 2>/dev/null | wc -l)" -gt 0 ]]
}

ensure_swap() {
  if [[ "$SWAP_MODE" == "off" ]] || has_swap; then return 0; fi
  local mem want_mb=0
  mem="$(mem_total_mb)"
  if [[ "$SWAP_MODE" == "auto" ]]; then
    if (( mem >= 2048 )); then return 0; fi
    want_mb=2048
    if (( mem < 1024 )); then want_mb=4096; fi
  elif [[ "$SWAP_MODE" =~ ^[0-9]+$ ]]; then
    want_mb="$SWAP_MODE"
  fi

  local avail
  avail="$(free_disk_mb /)"
  (( avail > want_mb + 1024 )) || die "$(tr_msg "Need ~$((want_mb + 1024))MB free on / for swap." "根目录可用空间不足，无法创建 $((want_mb))MB swap。" "Недостаточно места на / для создания swap.")"

  info "$(tr_msg "Creating temporary ${want_mb}MB swapfile..." "正在为编译创建临时 ${want_mb}MB swapfile..." "Создание временного swapfile на ${want_mb}MB...")"
  fallocate -l "${want_mb}M" "$SWAP_FILE" 2>/dev/null ||
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$want_mb" status=none
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE" >/dev/null
  swapon "$SWAP_FILE"
  SWAP_CREATED=1
}

fetch_source() {
  local ref="${COMMIT:-$VERSION}"
  if [[ -d "${SRC_DIR}/.git" ]]; then
    info "$(tr_msg "Reusing source tree in ${SRC_DIR}." "复用 ${SRC_DIR} 中的源码目录。" "Повторное использование исходников в ${SRC_DIR}.")"
    git -C "$SRC_DIR" remote set-url origin "$REPO_URL"
    git -C "$SRC_DIR" fetch --tags --force origin
  else
    rm -rf "$SRC_DIR"
    git clone --quiet "$REPO_URL" "$SRC_DIR"
  fi
  git -C "$SRC_DIR" checkout --force "$ref" >/dev/null 2>&1
  BUILD_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
  info "$(tr_msg "Source ready: ${ref} @ ${BUILD_COMMIT:0:8}" "源码就绪: ${ref} @ ${BUILD_COMMIT:0:8}" "Исходники готовы: ${ref} @ ${BUILD_COMMIT:0:8}")"
}

check_disk_space() {
  local avail_src avail_toolchain
  avail_src="$(free_disk_mb "$(dirname "$SRC_DIR")")"
  (( avail_src >= 5120 )) || die "$(tr_msg "Need at least 5GB free under $(dirname "$SRC_DIR")." "构建目录分区需至少 5GB 空闲空间。" "Требуется минимум 5 ГБ места для сборки.")"
  avail_toolchain="$(free_disk_mb /)"
  (( avail_toolchain >= 2048 )) || die "$(tr_msg "Need at least 2GB free on /." "根目录需要至少 2GB 空闲空间。" "Требуется минимум 2 ГБ свободного места на /.")"
}

build_nowhere() {
  local -a cargo_args=(build --release --locked)
  [[ -z "$JOBS" ]] || cargo_args+=(--jobs "$JOBS")
  info "$(tr_msg "Compiling Nowhere (Fat-LTO, this may take 20-60 mins on 1-core VPS)..." "开始编译 Nowhere（开启了全程序优化 Fat-LTO，单核机器预计 20-60 分钟）..." "Компиляция Nowhere (Fat-LTO, может занять 20-60 мин)...")"
  (
    cd "$SRC_DIR"
    export RUSTUP_HOME="$RUSTUP_HOME_DIR"
    export CARGO_HOME="$CARGO_HOME_DIR"
    export PATH="${CARGO_HOME_DIR}/bin:${PATH}"
    cargo "${cargo_args[@]}"
  ) || die "$(tr_msg "cargo build failed." "cargo 构建失败。" "Ошибка выполнения cargo build.")"

  BUILT_BIN="${SRC_DIR}/target/release/nowhere"
  [[ -f "$BUILT_BIN" && -x "$BUILT_BIN" ]] || die "$(tr_msg "Built binary is missing or not executable." "编译产物不存在或不可执行。" "Исполняемый файл не найден.")"
}

stage_release_from_source() {
  local rustc_version binary_sha release_dir
  binary_sha="$(sha256sum "$BUILT_BIN" | awk '{print $1}')"
  release_dir="${INSTALL_ROOT}/releases/${VERSION}-source-${BUILD_COMMIT:0:8}-${binary_sha:0:12}"
  install -d -m 755 "${INSTALL_ROOT}/releases" "$release_dir"
  install -m 755 "$BUILT_BIN" "${release_dir}/nowhere"

  rustc_version="$(RUSTUP_HOME="$RUSTUP_HOME_DIR" CARGO_HOME="$CARGO_HOME_DIR" \
    PATH="${CARGO_HOME_DIR}/bin:${PATH}" rustc --version 2>/dev/null || printf 'unknown')"

  cat >"${release_dir}/BUILD-INFO" <<EOF
repository:   ${REPO_URL}
tag:          ${VERSION}
commit:       ${BUILD_COMMIT}
built_at:     $(date -u '+%Y-%m-%dT%H:%M:%SZ')
built_on:     $(uname -m) $(uname -s)
toolchain:    ${rustc_version}
cargo:        cargo build --release --locked
binary_sha256: ${binary_sha}
EOF
  chmod 644 "${release_dir}/BUILD-INFO"
  ln -sfn "$release_dir" "$CURRENT_LINK"
  ln -sfn "${CURRENT_LINK}/nowhere" "$BIN_LINK"
  info "$(tr_msg "Installed release ${VERSION} (sha256: ${binary_sha:0:12})" "已成功安装自编译版 ${VERSION} (sha256: ${binary_sha:0:12})" "Установлена версия из исходников ${VERSION} (sha256: ${binary_sha:0:12})")"
}

ensure_user() {
  if ! getent group "$RUN_GROUP" >/dev/null 2>&1; then groupadd --system "$RUN_GROUP"; fi
  if ! id "$RUN_USER" >/dev/null 2>&1; then
    useradd --system --gid "$RUN_GROUP" --home-dir /var/lib/nowhere --create-home --shell /usr/sbin/nologin "$RUN_USER"
  fi
  install -d -o "$RUN_USER" -g "$RUN_GROUP" -m 750 /var/lib/nowhere
}

check_certificate_access() {
  [[ "$TLS" == "2" ]] || return 0
  [[ -n "$CERT" && -n "$TLS_KEY" ]] || return 0
  command -v runuser >/dev/null 2>&1 || return 0
  runuser -u "$RUN_USER" -- test -r "$CERT" ||
    die "$(tr_msg "Service user ${RUN_USER} cannot read cert: ${CERT}. Run prepare-tls first." "服务用户 ${RUN_USER} 无法读取证书: ${CERT}，请先运行 prepare-tls。" "Пользователь ${RUN_USER} не может прочитать сертификат: ${CERT}.")"
  runuser -u "$RUN_USER" -- test -r "$TLS_KEY" ||
    die "$(tr_msg "Service user ${RUN_USER} cannot read private key: ${TLS_KEY}. Run prepare-tls first." "服务用户 ${RUN_USER} 无法读取私钥: ${TLS_KEY}，请先运行 prepare-tls。" "Пользователь ${RUN_USER} не может прочитать ключ: ${TLS_KEY}.")"
}

prepare_tls() {
  require_root
  [[ -n "$CERT" && -n "$TLS_KEY" ]] || die "$(tr_msg "prepare-tls requires --cert and --tls-key." "prepare-tls 需要指定 --cert 与 --tls-key。" "prepare-tls требует --cert и --tls-key.")"
  [[ -f "$CERT" ]] || die "$(tr_msg "Certificate not found: $CERT" "证书未找到: $CERT" "Сертификат не найден: $CERT")"
  [[ -f "$TLS_KEY" ]] || die "$(tr_msg "Private key not found: $TLS_KEY" "私钥未找到: $TLS_KEY" "Ключ не найден: $TLS_KEY")"
  ensure_user
  install -d -o root -g "$RUN_GROUP" -m 750 "${CONFIG_DIR}/tls"
  install -o root -g "$RUN_GROUP" -m 640 "$CERT" "${CONFIG_DIR}/tls/fullchain.pem"
  install -o root -g "$RUN_GROUP" -m 640 "$TLS_KEY" "${CONFIG_DIR}/tls/privkey.pem"
  info "$(tr_msg "Certificate copied. Use these paths:" "证书权限设置完成，请使用以下复制路径:" "Сертификат скопирован. Используйте пути:")"
  printf '%s\n' "    --cert ${CONFIG_DIR}/tls/fullchain.pem \\"
  printf '%s\n' "    --tls-key ${CONFIG_DIR}/tls/privkey.pem"
}

check_port_available() {
  [[ -f "$CONFIG_FILE" ]] && return 0
  command -v ss >/dev/null 2>&1 || return 0
  if ss -lntup 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]"; then
    die "$(tr_msg "Port ${PORT} is already in use." "端口 ${PORT} 已被占用，请更换端口或停止冲突服务。" "Порт ${PORT} уже используется.")"
  fi
}

write_config() {
  local portal; portal="$(build_portal)"
  install -d -o root -g "$RUN_GROUP" -m 750 "$CONFIG_DIR"
  cat >"$CONFIG_FILE" <<EOF
NOWHERE_PORTAL=$(env_quote "$portal")
NOWHERE_VERSION_VALUE=$(env_quote "$VERSION")
EOF
  chown root:root "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

write_unit() {
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Nowhere Portal
Documentation=https://github.com/${UPSTREAM_REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
EnvironmentFile=${CONFIG_FILE}
ExecStart=${CURRENT_LINK}/nowhere \${NOWHERE_PORTAL}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
CapabilityBoundingSet=
AmbientCapabilities=
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
StateDirectory=nowhere

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$UNIT_FILE"
  systemctl daemon-reload
}

wait_for_service() {
  local attempt
  for attempt in {1..10}; do
    systemctl is-active --quiet "$SERVICE_NAME" && return 0
    sleep 1
  done
  return 1
}

install_or_upgrade() {
  require_root
  require_systemd
  validate_version "$VERSION"
  require_command curl
  require_command systemctl

  # python3, sha256sum, and tar are only needed for the release installation method
  if [[ "$INSTALL_METHOD" == "release" ]]; then
    require_command python3
    require_command sha256sum
    require_command tar
  fi

  local fresh=0
  [[ -f "$CONFIG_FILE" ]] || fresh=1
  if [[ "$ACTION" == "install" && "$fresh" -eq 1 ]]; then
    validate_config
    validate_key "$KEY"
    check_port_available
  elif [[ "$ACTION" == "upgrade" && "$fresh" -eq 1 ]]; then
    die "$(tr_msg "No existing configuration. Run install first." "未找到现有配置，请先运行安装。" "Конфигурация не найдена. Сначала выполните установку.")"
  fi

  ensure_user
  check_certificate_access

  local old_target=""
  [[ -L "$CURRENT_LINK" ]] && old_target="$(readlink "$CURRENT_LINK")"

  if [[ "$INSTALL_METHOD" == "source" ]]; then
    ensure_build_deps
    ensure_rust
    ensure_swap
    check_disk_space
    fetch_source
    build_nowhere
    stage_release_from_source
    cleanup_swap
    if [[ "$KEEP_SOURCE" -ne 1 ]]; then rm -rf "$SRC_DIR"; fi
  else
    install_verified_binary
  fi

  if [[ "$fresh" -eq 1 ]]; then write_config; fi
  write_unit
  systemctl enable "$SERVICE_NAME" >/dev/null
  systemctl restart "$SERVICE_NAME" 2>/dev/null || systemctl start "$SERVICE_NAME"

  if ! wait_for_service; then
    warn "$(tr_msg "Nowhere failed to become active; logs:" "Nowhere 服务启动失败，最近日志如下:" "Сбой запуска Nowhere, логи:")"
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager >&2 || true
    if [[ -n "$old_target" ]]; then
      ln -sfn "$old_target" "$CURRENT_LINK"
      systemctl restart "$SERVICE_NAME" || true
      die "$(tr_msg "Rolled back to ${old_target}." "升级失败，已自动回滚至 ${old_target}。" "Откат к предыдущей версии ${old_target}.")"
    fi
    die "$(tr_msg "Installation failed." "安装失败。" "Сбой установки.")"
  fi

  info "$(tr_msg "Nowhere ${VERSION} is active as ${RUN_USER}." "Nowhere ${VERSION} 已成功作为 ${RUN_USER} 运行。" "Nowhere ${VERSION} успешно запущен от пользователя ${RUN_USER}.")"
  info "$(tr_msg "Remember to open ${PORT}/${NET} in your firewall." "请记得在 VPS 防火墙/安全组放行 ${PORT}/${NET} 端口。" "Откройте порт ${PORT}/${NET} в брандмауэре.")"
  local portal; portal="$(stored_portal)"
  if [[ -n "$portal" ]]; then
    printf '\n\033[1;32m%s\033[0m\n' "$(tr_msg "Client Link (Keep Secret):" "客户端连接链接（请妥善保管）:" "Клиентская ссылка (секретно):")"
    printf '    \033[4;36m%s\033[0m\n\n' "$portal"
  fi
}

rollback() {
  require_root
  require_systemd
  local current previous
  current="$(readlink "$CURRENT_LINK" 2>/dev/null || true)"
  [[ -n "$current" ]] || die "$(tr_msg "No current Nowhere release found." "未找到当前安装版本。" "Текущая версия не найдена.")"
  previous="$(find "${INSTALL_ROOT}/releases" -mindepth 1 -maxdepth 1 -type d \
    ! -path "$current" -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {sub(/^[^ ]+ /, ""); print}')"
  [[ -n "$previous" ]] || die "$(tr_msg "No previous release available for rollback." "没有可供回滚的旧版本。" "Нет предыдущей версии для отката.")"
  ln -sfn "$previous" "$CURRENT_LINK"
  systemctl restart "$SERVICE_NAME"
  wait_for_service || die "$(tr_msg "Rollback failed to activate." "回滚版本激活失败。" "Сбой отката.")"
  info "$(tr_msg "Rolled back to ${previous}." "已成功回滚至: ${previous}" "Откат выполнен к: ${previous}")"
}

show_status() {
  require_root
  require_systemd
  systemctl --no-pager --full status "$SERVICE_NAME" || true
  printf '\n\033[1;33mCurrent Target:\033[0m '
  readlink "$CURRENT_LINK" 2>/dev/null || printf 'not installed\n'
}

show_link() {
  require_root
  [[ -f "$CONFIG_FILE" ]] || die "$(tr_msg "No config found at ${CONFIG_FILE}." "未找到配置文件: ${CONFIG_FILE}" "Конфигурационный файл не найден.")"
  local portal; portal="$(stored_portal)"
  [[ -n "$portal" ]] || die "$(tr_msg "NOWHERE_PORTAL missing." "配置中缺少 NOWHERE_PORTAL。" "В файле конфигурации отсутствует NOWHERE_PORTAL.")"
  info "$(tr_msg "Server configuration (internal use, not for client import):" "服务端配置（内部使用，不用于客户端导入）:" "Конфигурация сервера (внутреннее использование):")"
  printf '%s\n' "$portal"
}

show_client_link() {
  require_root
  [[ -f "$CONFIG_FILE" ]] || die "$(tr_msg "No config found at ${CONFIG_FILE}." "未找到配置文件: ${CONFIG_FILE}" "Конфигурационный файл не найден.")"
  local portal; portal="$(stored_portal)"
  [[ -n "$portal" ]] || die "$(tr_msg "NOWHERE_PORTAL missing." "配置中缺少 NOWHERE_PORTAL。" "В файле конфигурации отсутствует NOWHERE_PORTAL.")"

  local public_host="${CLIENT_LINK_HOST:-}"
  local node_name="${CLIENT_LINK_NAME:-}"

  info "$(tr_msg "Client share link (for Anywhere 2.0):" "客户端分享链接（用于 Anywhere 2.0）:" "Клиентская ссылка (для Anywhere 2.0):")"
  build_nowhere_link "$portal" "$public_host" "$node_name"
}

uninstall() {
  require_root
  require_systemd
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE" "$BIN_LINK"
  systemctl daemon-reload
  rm -rf "$INSTALL_ROOT"
  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$CONFIG_DIR" /var/lib/nowhere
    info "$(tr_msg "Removed binary, service, and state." "已彻底移除 Nowhere 核心、服务、配置及运行状态。" "Удалены бинарники, служба и конфигурации.")"
  else
    info "$(tr_msg "Removed service; kept config." "已卸载程序并停用服务，保留了配置目录 ${CONFIG_DIR}。" "Служба удалена; конфигурация сохранена.")"
  fi
}

clean_build() {
  require_root
  rm -rf "$SRC_DIR" "$SWAP_FILE"
  info "$(tr_msg "Cleaned build cache and swap." "已清理源码编译缓存与临时 swap。" "Очищен кэш сборки и swap.")"
}

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
  read -rp "Please select language / 请选择语言 / Выберите язык [1-3] (Default: 2): " ch
  case "${ch:-2}" in
    1) LANG_CODE="en" ;;
    3) LANG_CODE="ru" ;;
    *) LANG_CODE="zh" ;;
  esac
}

interactive_menu() {
  require_root
  if [[ "$LANG_CODE" == "ask" ]]; then
    choose_initial_language
  fi
  clear
  printf '\033[1;36m====================================================\033[0m\n'
  printf '\033[1;32m      Nowhere Unified Management Script (v%s)        \033[0m\n' "$SCRIPT_VERSION"
  printf '\033[1;36m====================================================\033[0m\n'
  printf ' [1] %s\n' "$(tr_msg "Install official prebuilt binary (Recommended, ~1 min)" "安装官方预编译版本（推荐，约 1 分钟）" "Установка официального релиза (Рекомендуется, ~1 мин)")"
  printf ' [2] %s\n' "$(tr_msg "Compile and install from source (~20-60 mins)" "本地源码编译安装（全程序优化，约 20-60 分钟）" "Компиляция из исходников (~20-60 мин)")"
  printf ' [3] %s\n' "$(tr_msg "Prepare TLS certificates (Let's Encrypt / PEM)" "配置/复制 TLS 证书 (Let's Encrypt / PEM)" "Подготовка TLS сертификатов (PEM)")"
  printf '%s\n' "----------------------------------------------------"
  printf ' [4] %s\n' "$(tr_msg "View service status" "查看服务运行状态" "Проверить статус службы")"
  printf ' [5] %s\n' "$(tr_msg "Show server portal:// link" "查看服务端配置链接 (portal://)" "Показать portal:// сервера")"
  printf ' [6] %s\n' "$(tr_msg "Generate client nowhere:// link" "生成客户端连接链接 (nowhere://)" "Сгенерировать клиентскую ссылку")"
  printf ' [7] %s\n' "$(tr_msg "View live service logs" "跟踪实时服务日志" "Просмотр логов в реальном времени")"
  printf ' [8] %s\n' "$(tr_msg "Restart service" "重启 Nowhere 服务" "Перезапустить службу")"
  printf ' [9] %s\n' "$(tr_msg "Rollback to previous release" "回滚至上一版本" "Откат к предыдущей версии")"
  printf ' [10] %s\n' "$(tr_msg "Clean compilation build cache" "清理源码构建缓存与 Swap" "Очистить кэш сборки")"
  printf ' [11] %s\n' "$(tr_msg "Uninstall Nowhere" "卸载 Nowhere" "Удалить Nowhere")"
  printf '%s\n' "----------------------------------------------------"
  printf ' [12] %s\n' "$(tr_msg "Switch Language / 切换语言 (Current: $LANG_CODE)" "切换语言 / Switch Language (当前: $LANG_CODE)" "Сменить язык (Current: $LANG_CODE)")"
  printf ' [0] %s\n' "$(tr_msg "Exit" "退出" "Выход")"
  printf '\033[1;36m====================================================\033[0m\n'

  local choice
  read -rp "$(tr_msg "Please enter your choice [0-12]: " "请输入选项序号 [0-12]: " "Введите номер действия [0-12]: ")" choice
  case "$choice" in
    1|2)
      ACTION="install"
      [[ "$choice" == "2" ]] && INSTALL_METHOD="source" || INSTALL_METHOD="release"
      
      read -rp "$(tr_msg "Enter listen port (Default: 2077): " "请输入监听端口 (默认 2077): " "Введите порт (по умолчанию 2077): ")" input_port
      PORT="${input_port:-2077}"
      
      local def_key
      def_key="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 24 || true)"
      read -rp "$(tr_msg "Enter Portal key (Default: auto-generated): " "请输入共享密钥 (回车使用随机生成: $def_key): " "Введите ключ (по умолчанию: $def_key): ")" input_key
      KEY="${input_key:-$def_key}"

      read -rp "$(tr_msg "Network mode (mix/tcp/udp, Default: mix): " "网络协议模式 (mix/tcp/udp，默认 mix): " "Режим сети (mix/tcp/udp, по умолчанию mix): ")" input_net
      NET="${input_net:-mix}"

      printf '\n%s\n' "$(tr_msg "TLS Mode: 1 = Self-signed (Quick test), 2 = Custom PEM cert (Production)" "TLS 模式: 1 = 临时自签名 (快速测试), 2 = 自定义证书文件 (生产推荐)" "Режим TLS: 1 = самоподписанный, 2 = PEM сертификаты")"
      read -rp "$(tr_msg "Select TLS mode [1/2] (Default: 2): " "请选择 TLS 模式 [1/2] (默认 2): " "Выберите TLS [1/2] (по умолчанию 2): ")" input_tls
      TLS="${input_tls:-2}"

      if [[ "$TLS" == "2" ]]; then
        read -rp "$(tr_msg "Cert path (e.g. /etc/nowhere/tls/fullchain.pem): " "证书全链 fullchain.pem 完整路径: " "Путь к fullchain.pem: ")" CERT
        read -rp "$(tr_msg "Private key path (e.g. /etc/nowhere/tls/privkey.pem): " "私钥 privkey.pem 完整路径: " "Путь к privkey.pem: ")" TLS_KEY
      fi

      install_or_upgrade
      ;;
    3)
      read -rp "$(tr_msg "Original fullchain.pem path: " "原始证书路径 (如 /etc/letsencrypt/live/domain/fullchain.pem): " "Путь к исходному fullchain.pem: ")" CERT
      read -rp "$(tr_msg "Original privkey.pem path: " "原始私钥路径 (如 /etc/letsencrypt/live/domain/privkey.pem): " "Путь к исходному privkey.pem: ")" TLS_KEY
      prepare_tls
      ;;
    4) show_status ;;
    5) show_link ;;
    6) show_client_link ;;
    7) journalctl -u "$SERVICE_NAME" -f ;;
    8) systemctl restart "$SERVICE_NAME"; info "$(tr_msg "Service restarted." "服务已成功重启。" "Служба перезапущена.")" ;;
    9) rollback ;;
    10) clean_build ;;
    11)
      read -rp "$(tr_msg "Also delete configuration and keys? [y/N]: " "是否一并删除所有配置和密钥? [y/N]: " "Удалить также конфигурации и ключи? [y/N]: ")" purge_ans
      [[ "$purge_ans" =~ ^[yY]$ ]] && PURGE=1
      uninstall
      ;;
    12)
      choose_initial_language
      interactive_menu
      ;;
    0) exit 0 ;;
    *) warn "$(tr_msg "Invalid choice." "无效选择。" "Неверный выбор.")"; sleep 1; interactive_menu ;;
  esac
}

usage() {
  cat <<EOF
Nowhere Unified Management Script v${SCRIPT_VERSION}

Usage:
  sudo bash nowhere.sh                                  (Launch Interactive Menu)
  sudo bash nowhere.sh install --method release [args]  (Download official prebuilt)
  sudo bash nowhere.sh install --method source [args]   (Compile locally)
  sudo bash nowhere.sh upgrade [--method release|source] [--version v1.8.3]
  sudo bash nowhere.sh rollback
  sudo bash nowhere.sh status | link | logs | restart
  sudo bash nowhere.sh client-link [--host IP] [--name NAME]
  sudo bash nowhere.sh prepare-tls --cert /path/to/crt --tls-key /path/to/key
  sudo bash nowhere.sh uninstall [--purge]

Link formats:
  link                Server-side portal:// URI from the config (NOT importable)
  client-link         Client-side nowhere:// link, built from stored portal config.
                      Use this one for Anywhere 2.0.

Options:
  --method MODE       release (prebuilt binary) or source (compile); default: release
  --key KEY           Portal shared key (16-255 alphanumeric chars)
  --port PORT         Listen port (>= 1024, default: 2077)
  --net MODE          mix, tcp, or udp (default: mix)
  --tls MODE          1 (self-signed) or 2 (PEM certificate, default: 2)
  --cert PATH         Certificate chain path (required for TLS 2)
  --tls-key PATH      Private key path (required for TLS 2)
  --host IP_OR_DOMAIN Public IP / domain for client-link (auto-detected if omitted)
  --name NAME         Node display name in nowhere:// link (default: Nowhere-<host>)
  --version TAG       Upstream git tag (default: ${DEFAULT_VERSION})
  --libc MODE         gnu, musl, or auto (for release mode; default: auto)
  --swap MODE         auto, off, or size in MB (for source compile; default: auto)
  --jobs N            Parallel cargo jobs (for source compile)
  --lang en|zh|ru     Force interface language
  --purge             Delete configurations on uninstall
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --method) INSTALL_METHOD="${2:?}"; shift 2 ;;
      --lang) LANG_CODE="${2:?}"; resolve_language "$LANG_CODE"; shift 2 ;;
      --version) VERSION="${2:?}"; shift 2 ;;
      --libc) LIBC="${2:?}"; shift 2 ;;
      --key) KEY="${2:?}"; shift 2 ;;
      --port) PORT="${2:?}"; shift 2 ;;
      --net) NET="${2:?}"; shift 2 ;;
      --tls) TLS="${2:?}"; shift 2 ;;
      --cert|--crt) CERT="${2:?}"; shift 2 ;;
      --tls-key) TLS_KEY="${2:?}"; shift 2 ;;
      --listen-host) LISTEN_HOST="${2:?}"; shift 2 ;;
      --host) CLIENT_LINK_HOST="${2:?}"; shift 2 ;;
      --name) CLIENT_LINK_NAME="${2:?}"; shift 2 ;;
      --commit) COMMIT="${2:?}"; shift 2 ;;
      --git-url) REPO_URL="${2:?}"; shift 2 ;;
      --jobs) JOBS="${2:?}"; shift 2 ;;
      --swap) SWAP_MODE="${2:?}"; shift 2 ;;
      --trust-rustup-sha) TRUST_RUSTUP_SHA="${2:?}"; shift 2 ;;
      --keep-source) KEEP_SOURCE=1; shift ;;
      --no-install-deps) INSTALL_DEPS=0; shift ;;
      --no-install-rust) INSTALL_RUST=0; shift ;;
      --purge) PURGE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "$(tr_msg "Unknown option: $1" "未知选项: $1" "Неизвестный параметр: $1")" ;;
    esac
  done
}

if [[ $# -eq 0 ]]; then
  interactive_menu
  exit 0
fi

ACTION="$1"
shift
parse_args "$@"

if [[ "$LANG_CODE" == "ask" ]]; then
  resolve_language "auto"
fi

case "$ACTION" in
  install|upgrade) install_or_upgrade ;;
  rollback) rollback ;;
  status) show_status ;;
  link) show_link ;;
  client-link) show_client_link ;;
  prepare-tls) prepare_tls ;;
  logs) require_root; journalctl -u "$SERVICE_NAME" -f ;;
  restart) require_root; require_systemd; systemctl restart "$SERVICE_NAME" ;;
  clean-build) clean_build ;;
  uninstall|remove) uninstall ;;
  menu) interactive_menu ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac