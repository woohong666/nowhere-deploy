#!/usr/bin/env bash
#
# Nowhere installer for systemd Linux: downloads the official prebuilt Release.
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 woohong666
#
# Trust boundary: this script never compiles anything and never pipes remote
# content to bash, but it does trust the binary published by the upstream
# project. Before installing, it asks the GitHub API for the SHA-256 digest of
# the asset and refuses to continue when no digest is published. Use
# install-source.sh instead if you do not want to trust that binary at all.
#
set -Eeuo pipefail
umask 077

readonly SCRIPT_VERSION="1.1.0"
readonly REPO="NodePassProject/Nowhere"
readonly DEFAULT_VERSION="v1.8.3"
readonly SERVICE_NAME="nowhere"
readonly RUN_USER="nowhere"
readonly RUN_GROUP="nowhere"
readonly INSTALL_ROOT="/opt/nowhere"
readonly CURRENT_LINK="${INSTALL_ROOT}/current"
readonly BIN_LINK="/usr/local/bin/nowhere"
readonly CONFIG_DIR="/etc/nowhere"
readonly CONFIG_FILE="${CONFIG_DIR}/nowhere.env"
readonly UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly SCRIPT_NAME="${0##*/}"

LANG_CODE="${NOWHERE_LANG:-auto}"

ACTION="${1:-help}"
[[ $# -eq 0 ]] || shift

VERSION="${NOWHERE_VERSION:-$DEFAULT_VERSION}"
PORT="${NOWHERE_PORT:-2077}"
KEY="${NOWHERE_KEY:-}"
NET="${NOWHERE_NET:-mix}"
TLS="${NOWHERE_TLS:-2}"
CERT="${NOWHERE_CERT:-}"
TLS_KEY="${NOWHERE_TLS_KEY:-}"
LISTEN_HOST="${NOWHERE_LISTEN_HOST:-}"
LIBC="${NOWHERE_LIBC:-auto}"
PURGE=0

# Seeded with an empty string on purpose: expanding an empty array under
# `set -u` is an "unbound variable" error on bash < 4.4 (CentOS 7 ships 4.2).
# The loop in cleanup_all skips empty entries, so this sentinel is inert.
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
    *) printf '\033[1;31m[Error]\033[0m Unsupported language: %s (use auto, en, zh, or ru).\n' "$requested" >&2; exit 1 ;;
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
die() { printf '\033[1;31m[%s]\033[0m %s\n' "$(tr_msg Error 错误 Ошибка)" "$*" >&2; exit 1; }

# Runs on every exit path, including die(), so a failed run never leaves a
# mktemp directory behind.
cleanup_all() {
  local p
  if (( ${#CLEANUP_PATHS[@]} > 0 )); then
    for p in "${CLEANUP_PATHS[@]}"; do
      if [[ -n "$p" ]]; then
        rm -rf "$p"
      fi
    done
  fi
}
trap cleanup_all EXIT

resolve_language "$LANG_CODE"

usage() {
  cat <<'EOF'
Install the official prebuilt Nowhere Release and run it as a systemd service.

Usage:
  sudo bash install.sh install --key KEY --port 2077 \
    --tls 2 --cert /path/fullchain.pem --tls-key /path/privkey.pem
  sudo bash install.sh upgrade [--version v1.8.3]
  sudo bash install.sh rollback
  sudo bash install.sh status
  sudo bash install.sh link
  sudo bash install.sh logs
  sudo bash install.sh restart
  sudo bash install.sh uninstall [--purge]

TLS helper:
  sudo bash install.sh prepare-tls --cert /path/fullchain.pem --tls-key /path/privkey.pem
                      Copy the certificate where the service user can read it
                      (Let's Encrypt private keys are root-only by default).

Options:
  --version TAG       Exact official Release tag; default: v1.8.3
  --libc MODE         gnu, musl, or auto (detect); default: auto
  --key KEY           Portal shared key; required for first install
  --port PORT         Listen port; must be >= 1024 (the service runs unprivileged)
  --net MODE          mix, tcp, or udp; default: mix
  --tls MODE          1 for ephemeral self-signed, 2 for PEM files; default: 2
  --cert PATH         PEM certificate chain; required when --tls 2
  --tls-key PATH      PEM private key; required when --tls 2
  --listen-host HOST  Bind host; empty means the Nowhere wildcard default
  --purge             Remove /etc/nowhere and /var/lib/nowhere on uninstall
  -h, --help          Show this help

The installer refuses to install a release when GitHub does not publish a
SHA-256 digest for the selected asset, and never pipes remote content to bash.
On Debian/Ubuntu whose glibc is older than the official GNU build, pass
--libc musl to use the official static musl asset.

This script downloads a binary. If you would rather compile from source on this
machine, use install-source.sh instead.
EOF
}

# ---------------------------------------------------------------- validation

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run this command as root, for example: sudo bash $0 $ACTION"
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl is required. This script supports systemd Linux only."
  [[ -d /run/systemd/system ]] || die "systemd is not running on this host."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

validate_version() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] ||
    die "Invalid version tag: $1"
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "Port must be an integer."
  (( 1024 <= 10#$1 && 10#$1 <= 65535 )) ||
    die "Port must be between 1024 and 65535 for the non-root service."
}

validate_key() {
  [[ -n "$1" ]] || die "A shared key is required for the first install."
  [[ "$1" =~ ^[A-Za-z0-9._~-]{16,255}$ ]] ||
    die "Key must be 16-255 characters using A-Z, a-z, 0-9, '.', '_', '~', or '-'."
}

validate_config() {
  validate_version "$VERSION"
  validate_port "$PORT"
  [[ "$NET" == "mix" || "$NET" == "tcp" || "$NET" == "udp" ]] ||
    die "--net must be mix, tcp, or udp."
  [[ "$TLS" == "1" || "$TLS" == "2" ]] || die "--tls must be 1 or 2."
  case "$LIBC" in
    auto|gnu|musl) ;;
    *) die "--libc must be auto, gnu, or musl." ;;
  esac
  if [[ "$TLS" == "2" ]]; then
    [[ -n "$CERT" && -n "$TLS_KEY" ]] || die "--tls 2 requires --cert and --tls-key."
    [[ -f "$CERT" ]] || die "Certificate not found: $CERT"
    [[ -f "$TLS_KEY" ]] || die "Private key not found: $TLS_KEY"
  fi
}

# ---------------------------------------------------------------- small utils

# Pure-bash percent-encoding, so the portal URL does not depend on python3.
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

# Read the portal URI back out of the config file as data. On upgrade the
# KEY/CERT variables are unset, so build_portal would emit an empty-key link.
stored_portal() {
  [[ -r "$CONFIG_FILE" ]] || return 0
  awk -F'"' '/^NOWHERE_PORTAL=/ { print $2; exit }' "$CONFIG_FILE"
}

build_portal() {
  local host="${LISTEN_HOST}"
  # If LISTEN_HOST is empty, use a placeholder that makes the malformed URL obvious
  [[ -z "$host" ]] && host="<YOUR-SERVER-IP-OR-DOMAIN>"
  local query="tls=${TLS}"
  [[ "$NET" == "mix" ]] || query="${query}&net=${NET}"
  if [[ "$TLS" == "2" ]]; then
    query="${query}&crt=$(urlencode "$CERT")&key=$(urlencode "$TLS_KEY")"
  fi
  printf 'portal://%s@%s:%s?%s' "$KEY" "$host" "$PORT" "$query"
}

asset_name() {
  local arch libc
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
  libc="gnu"
  if [[ "$LIBC" == "musl" ]]; then
    libc="musl"
  elif [[ "$LIBC" == "auto" ]] && command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
    libc="musl"
  fi
  printf 'nowhere-%s-unknown-linux-%s.tar.gz' "$arch" "$libc"
}

# ---------------------------------------------------------------- release

# Ask the GitHub API for the digest it publishes for this asset. This is the
# only integrity check available for a prebuilt binary, so a missing digest is
# treated as a hard failure rather than a warning.
fetch_asset_digest() {
  local asset="$1" api_json digest
  api_json="$(curl --fail --silent --show-error --location --proto '=https' \
    --tlsv1.2 --retry 3 --connect-timeout 10 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${REPO}/releases/tags/${VERSION}")" ||
    die "Could not read the official GitHub Release metadata."
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
    die "GitHub did not publish a SHA-256 digest for ${asset}. Refusing to install."
  printf '%s' "${digest#sha256:}"
}

download_verified_release() {
  local asset="$1" expected="$2" tmpdir="$3" archive="$tmpdir/$asset" actual
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --retry 3 --connect-timeout 10 \
    -o "$archive" \
    "https://github.com/${REPO}/releases/download/${VERSION}/${asset}" ||
    die "Could not download official Release ${VERSION}."
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] ||
    die "SHA-256 mismatch for ${asset}. Expected ${expected}, got ${actual}."
  printf '%s' "$archive"
}

install_verified_binary() {
  local asset tmpdir archive release_dir binary expected
  asset="$(asset_name)"
  info "Resolving the published digest for ${asset}..."
  expected="$(fetch_asset_digest "$asset")"
  tmpdir="$(mktemp -d)"
  CLEANUP_PATHS+=("$tmpdir")

  info "Downloading official Release ${VERSION}..."
  archive="$(download_verified_release "$asset" "$expected" "$tmpdir")"
  mkdir -p "$tmpdir/extracted"
  tar --extract --gzip --file "$archive" --directory "$tmpdir/extracted"
  binary="$(find "$tmpdir/extracted" -type f -name nowhere -perm -u+x -print -quit)"
  [[ -n "$binary" ]] || die "Release archive does not contain an executable named nowhere."

  local binary_sha
  binary_sha="$(sha256sum "$binary" | awk '{print $1}')"
  release_dir="${INSTALL_ROOT}/releases/${VERSION}-prebuilt-${binary_sha:0:12}"
  install -d -m 755 "${INSTALL_ROOT}/releases" "$release_dir"
  install -m 755 "$binary" "${release_dir}/nowhere"
  ln -sfn "$release_dir" "$CURRENT_LINK"
  ln -sfn "${CURRENT_LINK}/nowhere" "$BIN_LINK"
  cat >"${release_dir}/RELEASE-INFO" <<EOF
repository:   https://github.com/${REPO}
tag:          ${VERSION}
asset:        ${asset}
source:       official prebuilt Release (not compiled locally)
downloaded_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
asset_sha256: ${expected}
binary_sha256: ${binary_sha}
EOF
  info "Installed verified Nowhere ${VERSION} (${asset}, sha256 ${binary_sha})"
}

# ---------------------------------------------------------------- service

ensure_user() {
  if ! getent group "$RUN_GROUP" >/dev/null 2>&1; then
    groupadd --system "$RUN_GROUP"
  fi
  if ! id "$RUN_USER" >/dev/null 2>&1; then
    useradd --system --gid "$RUN_GROUP" --home-dir /var/lib/nowhere \
      --create-home --shell /usr/sbin/nologin "$RUN_USER"
  fi
  install -d -o "$RUN_USER" -g "$RUN_GROUP" -m 750 /var/lib/nowhere
}

check_certificate_access() {
  [[ "$TLS" == "2" ]] || return 0
  # On upgrade the paths live in the existing config, not in the flags, so there
  # is nothing to test here; systemd will use the paths it already has.
  [[ -n "$CERT" && -n "$TLS_KEY" ]] || return 0
  command -v runuser >/dev/null 2>&1 || {
    warn "runuser is unavailable; certificate readability will be checked by systemd at startup."
    return 0
  }
  runuser -u "$RUN_USER" -- test -r "$CERT" ||
    die "Service user ${RUN_USER} cannot read certificate: ${CERT}
       Copy it with 'install.sh prepare-tls --cert ... --tls-key ...' and use the paths it prints."
  runuser -u "$RUN_USER" -- test -r "$TLS_KEY" ||
    die "Service user ${RUN_USER} cannot read private key: ${TLS_KEY}
       Copy it with 'install.sh prepare-tls --cert ... --tls-key ...' and use the paths it prints."
}

# Let's Encrypt keeps privkey.pem at 600 root:root under a 700 directory, so the
# service user cannot read it. Copy both files into a group-readable location
# rather than loosening the permissions of the originals.
prepare_tls() {
  require_root
  [[ -n "$CERT" && -n "$TLS_KEY" ]] || die "prepare-tls requires --cert and --tls-key."
  [[ -f "$CERT" ]] || die "Certificate not found: $CERT"
  [[ -f "$TLS_KEY" ]] || die "Private key not found: $TLS_KEY"
  ensure_user
  install -d -o root -g "$RUN_GROUP" -m 750 "${CONFIG_DIR}/tls"
  install -o root -g "$RUN_GROUP" -m 640 "$CERT" "${CONFIG_DIR}/tls/fullchain.pem"
  install -o root -g "$RUN_GROUP" -m 640 "$TLS_KEY" "${CONFIG_DIR}/tls/privkey.pem"
  info "Certificate copied for the ${RUN_USER} user. Use these paths for install/upgrade:"
  printf '    --cert %s \\\n    --tls-key %s\n' "${CONFIG_DIR}/tls/fullchain.pem" "${CONFIG_DIR}/tls/privkey.pem"
  warn "Originals were not modified. Re-run prepare-tls after every renewal, or call it from certbot's deploy hook."
}

write_config() {
  local portal
  portal="$(build_portal)"
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
Documentation=https://github.com/${REPO}
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
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    systemctl is-active --quiet "$SERVICE_NAME" && return 0
    sleep 1
  done
  return 1
}

# ---------------------------------------------------------------- actions

check_port_available() {
  [[ -f "$CONFIG_FILE" ]] && return 0
  command -v ss >/dev/null 2>&1 || return 0
  if ss -lntup 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]"; then
    die "Port ${PORT} is already in use. Pick another --port or stop the conflicting service."
  fi
}

install_or_upgrade() {
  require_root
  require_systemd
  # Validate before using VERSION in filesystem paths and network URLs.
  validate_version "$VERSION"
  require_command curl
  require_command python3
  require_command sha256sum
  require_command tar
  require_command systemctl

  local fresh=0
  [[ -f "$CONFIG_FILE" ]] || fresh=1
  if [[ "$ACTION" == "install" && "$fresh" -eq 1 ]]; then
    validate_config
    validate_key "$KEY"
    check_port_available
  elif [[ "$ACTION" == "upgrade" && "$fresh" -eq 1 ]]; then
    die "No existing configuration. Run install first."
  fi

  ensure_user
  check_certificate_access

  local old_target=""
  [[ -L "$CURRENT_LINK" ]] && old_target="$(readlink "$CURRENT_LINK")"

  install_verified_binary

  if [[ "$fresh" -eq 1 ]]; then
    write_config
  fi
  write_unit
  systemctl enable "$SERVICE_NAME" >/dev/null
  systemctl restart "$SERVICE_NAME" 2>/dev/null || systemctl start "$SERVICE_NAME"

  if ! wait_for_service; then
    warn "Nowhere failed to become active; showing recent logs."
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager >&2 || true
    if [[ -n "$old_target" ]]; then
      ln -sfn "$old_target" "$CURRENT_LINK"
      systemctl restart "$SERVICE_NAME" || true
      die "Upgrade rolled back to ${old_target}."
    fi
    die "Initial installation failed."
  fi

  info "Nowhere ${VERSION} is active as ${RUN_USER}."
  info "Open ${PORT}/${NET} in the VPS firewall/security group."
  if [[ "$TLS" == "1" ]]; then
    warn "TLS 1 uses an ephemeral self-signed certificate. Use TLS 2 with a managed certificate in production."
  fi
  local portal
  portal="$(stored_portal)"
  if [[ -n "$portal" ]]; then
    info "Client link (keep it secret):"
    printf '    %s\n\n' "$portal"
  else
    warn "Could not read NOWHERE_PORTAL from ${CONFIG_FILE}; run 'install.sh link' to inspect it."
  fi
}

rollback() {
  require_root
  require_systemd
  local current previous
  current="$(readlink "$CURRENT_LINK" 2>/dev/null || true)"
  [[ -n "$current" ]] || die "No current Nowhere release found."
  previous="$(find "${INSTALL_ROOT}/releases" -mindepth 1 -maxdepth 1 -type d \
    ! -path "$current" -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {sub(/^[^ ]+ /, ""); print}')"
  [[ -n "$previous" ]] || die "No previous release is available for rollback."
  ln -sfn "$previous" "$CURRENT_LINK"
  systemctl restart "$SERVICE_NAME"
  wait_for_service || die "Rollback target did not become active."
  info "Rolled back to ${previous}."
}

show_status() {
  require_root
  require_systemd
  systemctl --no-pager --full status "$SERVICE_NAME" || true
  printf '\nCurrent binary: '
  readlink "$CURRENT_LINK" 2>/dev/null || printf 'not installed\n'
}

show_link() {
  require_root
  [[ -f "$CONFIG_FILE" ]] || die "No configuration found at ${CONFIG_FILE}."
  local portal
  portal="$(stored_portal)"
  [[ -n "$portal" ]] || die "NOWHERE_PORTAL is missing from ${CONFIG_FILE}."
  printf '%s\n' "$portal"
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
    info "Removed Nowhere binary, service, configuration, and state."
  else
    info "Removed binary and service; kept ${CONFIG_DIR} and /var/lib/nowhere."
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lang) LANG_CODE="${2:?missing value for --lang}"; resolve_language "$LANG_CODE"; shift 2 ;;
      --version) VERSION="${2:?missing value for --version}"; shift 2 ;;
      --libc) LIBC="${2:?missing value for --libc}"; shift 2 ;;
      --key) KEY="${2:?missing value for --key}"; shift 2 ;;
      --port) PORT="${2:?missing value for --port}"; shift 2 ;;
      --net) NET="${2:?missing value for --net}"; shift 2 ;;
      --tls) TLS="${2:?missing value for --tls}"; shift 2 ;;
      --cert|--crt) CERT="${2:?missing value for --cert}"; shift 2 ;;
      --tls-key) TLS_KEY="${2:?missing value for --tls-key}"; shift 2 ;;
      --listen-host) LISTEN_HOST="${2:?missing value for --listen-host}"; shift 2 ;;
      --purge) PURGE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

parse_args "$@"

case "$ACTION" in
  install|upgrade) install_or_upgrade ;;
  rollback) rollback ;;
  status) show_status ;;
  link) show_link ;;
  prepare-tls) prepare_tls ;;
  logs) require_root; journalctl -u "$SERVICE_NAME" -f ;;
  restart) require_root; require_systemd; systemctl restart "$SERVICE_NAME" ;;
  uninstall|remove) uninstall ;;
  version) printf '%s\n' "$SCRIPT_VERSION" ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
