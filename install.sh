#!/usr/bin/env bash
#
# Nowhere compile-from-source installer for systemd Linux.
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 woohong666
#
# Design rule: this script never installs a prebuilt Nowhere binary. The only
# binary it trusts is the one it compiles on this machine from a pinned git tag,
# so the produced artifact can be traced back to source you can read.
#
set -Eeuo pipefail
umask 077

readonly SCRIPT_VERSION="1.0.0"
readonly DEFAULT_REPO_URL="https://github.com/NodePassProject/Nowhere.git"
readonly DEFAULT_VERSION="v1.8.3"
readonly MIN_RUSTC="1.85.0" # edition 2024 => rustc >= 1.85

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

ACTION="${1:-help}"
[[ $# -eq 0 ]] || shift

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
JOBS="${NOWHERE_JOBS:-}"
SWAP_MODE="${NOWHERE_SWAP:-auto}"
KEEP_SOURCE="${NOWHERE_KEEP_SOURCE:-0}"
INSTALL_DEPS="${NOWHERE_INSTALL_DEPS:-1}"
INSTALL_RUST="${NOWHERE_INSTALL_RUST:-1}"
TRUST_RUSTUP_SHA="${NOWHERE_RUSTUP_SHA:-}"
PURGE=0

SWAP_CREATED=0
CLEANUP_PATHS=()

info() { printf '\033[1;34m[Nowhere]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[Warn]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[Error]\033[0m %s\n' "$*" >&2; exit 1; }

# Runs on every exit path, including die(), so a failed build never leaves a
# temporary swapfile or a mktemp directory behind.
cleanup_all() {
  local p
  if (( ${#CLEANUP_PATHS[@]} > 0 )); then
    for p in "${CLEANUP_PATHS[@]}"; do
      if [[ -n "$p" ]]; then
        rm -rf "$p"
      fi
    done
  fi
  cleanup_swap
}
trap cleanup_all EXIT

usage() {
  cat <<'EOF'
Compile Nowhere from source and run it as a systemd service.

Usage:
  sudo bash install.sh install --key KEY [--port 2077] --tls 2 \
    --cert /path/fullchain.pem --tls-key /path/privkey.pem
  sudo bash install.sh upgrade [--version v1.8.3] [--commit SHA]
  sudo bash install.sh rollback
  sudo bash install.sh status
  sudo bash install.sh link
  sudo bash install.sh logs
  sudo bash install.sh restart
  sudo bash install.sh clean-build
  sudo bash install.sh uninstall [--purge]

TLS helper:
  sudo bash install.sh prepare-tls --cert /path/fullchain.pem --tls-key /path/privkey.pem
                      Copy the certificate where the service user can read it
                      (Let's Encrypt private keys are root-only by default).

Build options:
  --version TAG       Git tag to build; default: v1.8.3
  --commit SHA        Pin an exact commit instead of a tag (full clone, slower)
  --git-url URL       Clone from this URL instead of the upstream repository
  --jobs N            Limit parallel rustc jobs (use 1 on a tiny VPS)
  --swap auto|off|MB  Temporary swap for the build; default: auto
  --keep-source       Keep the build tree and its cargo cache after success
                      ("install.sh clean-build" removes it later)
  --no-install-deps   Never run the package manager; fail instead
  --no-install-rust   Never install Rust; fail if the toolchain is too old
  --trust-rustup-sha HEX
                      Require this SHA-256 for the downloaded rustup-init

Service options:
  --key KEY           Portal shared key; required for a first install
  --port PORT         Listen port; must be >= 1024
  --net MODE          mix, tcp, or udp; default: mix
  --tls MODE          1 for an ephemeral self-signed cert, 2 for PEM files
  --cert PATH         PEM certificate chain; required when --tls 2
  --tls-key PATH      PEM private key; required when --tls 2
  --listen-host HOST  Bind host; empty means Nowhere's wildcard default
  --purge             Also remove /etc/nowhere and /var/lib/nowhere on uninstall

Trust boundary:
  This script removes every "download the official binary" path. It clones the
  upstream git repository and compiles it here, so the installed binary comes
  from source you can audit. It cannot vet the source itself, the crates.io
  packages Cargo downloads, or the Rust toolchain; pin --commit and
  --trust-rustup-sha when you need those answers to be reproducible.
EOF
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run this command as root, for example: sudo bash $0 $ACTION"
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl is required. This script supports systemd Linux only."
  [[ -d /run/systemd/system ]] || die "systemd is not running on this host."
}

# ---------------------------------------------------------------- validation

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

# systemd splits ExecStart on whitespace, so a path with a space would silently
# truncate the portal URI.
validate_no_space() {
  [[ "$2" != *[[:space:]]* ]] || die "$1 must not contain whitespace: $2"
}

validate_config() {
  validate_version "$VERSION"
  validate_port "$PORT"
  [[ "$NET" == "mix" || "$NET" == "tcp" || "$NET" == "udp" ]] ||
    die "--net must be mix, tcp, or udp."
  [[ "$TLS" == "1" || "$TLS" == "2" ]] || die "--tls must be 1 or 2."
  if [[ "$TLS" == "2" ]]; then
    [[ -n "$CERT" && -n "$TLS_KEY" ]] || die "--tls 2 requires --cert and --tls-key."
    [[ -f "$CERT" ]] || die "Certificate not found: $CERT"
    [[ -f "$TLS_KEY" ]] || die "Private key not found: $TLS_KEY"
    validate_no_space "--cert" "$CERT"
    validate_no_space "--tls-key" "$TLS_KEY"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) VERSION="${2:?missing value for --version}"; shift 2 ;;
      --commit) COMMIT="${2:?missing value for --commit}"; shift 2 ;;
      --git-url) REPO_URL="${2:?missing value for --git-url}"; shift 2 ;;
      --jobs) JOBS="${2:?missing value for --jobs}"; shift 2 ;;
      --swap) SWAP_MODE="${2:?missing value for --swap}"; shift 2 ;;
      --key) KEY="${2:?missing value for --key}"; shift 2 ;;
      --port) PORT="${2:?missing value for --port}"; shift 2 ;;
      --net) NET="${2:?missing value for --net}"; shift 2 ;;
      --tls) TLS="${2:?missing value for --tls}"; shift 2 ;;
      --cert|--crt) CERT="${2:?missing value for --cert}"; shift 2 ;;
      --tls-key) TLS_KEY="${2:?missing value for --tls-key}"; shift 2 ;;
      --listen-host) LISTEN_HOST="${2:?missing value for --listen-host}"; shift 2 ;;
      --trust-rustup-sha) TRUST_RUSTUP_SHA="${2:?missing value for --trust-rustup-sha}"; shift 2 ;;
      --keep-source) KEEP_SOURCE=1; shift ;;
      --no-install-deps) INSTALL_DEPS=0; shift ;;
      --no-install-rust) INSTALL_RUST=0; shift ;;
      --purge) PURGE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

# ---------------------------------------------------------------- small utils

# sort -V is GNU coreutils; every supported target has it.
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# Pure-bash percent-encoding; avoids depending on python3 on the target host.
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

# Both of these must always print a number: the callers use the result inside
# (( )), where an empty expansion is a syntax error rather than a false test.
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
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

# ------------------------------------------------------------ dependencies

pkg_manager() {
  local c
  for c in apt-get dnf yum apk zypper; do
    command -v "$c" >/dev/null 2>&1 && { printf '%s' "$c"; return 0; }
  done
  return 1
}

pkg_install() {
  local mgr; mgr="$(pkg_manager)" || die "No supported package manager found; install a C toolchain and git manually."
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

  if [[ "$need" -eq 0 ]]; then
    return 0
  fi
  if [[ "$INSTALL_DEPS" -ne 1 ]]; then
    die "Missing build dependencies (need git, curl and a C compiler). Re-run without --no-install-deps, or install them yourself."
  fi
  info "Installing build dependencies (git, curl, C toolchain)..."
  pkg_install || die "Could not install build dependencies automatically; install git, curl and a C toolchain, then retry."
  command -v git >/dev/null 2>&1 || die "git is still missing after the package install."
  command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 ||
    die "No C compiler is available after the package install."
}

# ---------------------------------------------------------------- rust

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
    info "Using existing $(rustc --version)"
    return 0
  fi

  if command -v rustc >/dev/null 2>&1; then
    warn "rustc $(rustc --version | awk '{print $2}') is older than ${MIN_RUSTC} (edition 2024); installing a current stable toolchain."
  fi

  if [[ "$INSTALL_RUST" -ne 1 ]]; then
    die "Rust ${MIN_RUSTC}+ is required. Install it yourself or drop --no-install-rust."
  fi

  activate_rust_env
  if [[ -x "${CARGO_HOME_DIR}/bin/cargo" ]] && use_existing_rustc; then
    info "Using existing $(rustc --version)"
    return 0
  fi

  local target url sha_url tmp expected actual
  target="$(detect_target)"
  url="https://static.rust-lang.org/rustup/dist/${target}/rustup-init"
  sha_url="${url}.sha256"

  info "Installing the Rust toolchain into ${CARGO_HOME_DIR} (rustup-init for ${target})..."
  tmp="$(mktemp -d)"
  CLEANUP_PATHS+=("$tmp")

  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --retry 3 --connect-timeout 10 -o "${tmp}/rustup-init" "$url" ||
    die "Could not download rustup-init from ${url}"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --retry 3 --connect-timeout 10 -o "${tmp}/rustup-init.sha256" "$sha_url" ||
    die "Could not download ${sha_url}"

  expected="$(awk '{print $1}' "${tmp}/rustup-init.sha256")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "Could not parse a SHA-256 from rustup-init.sha256."
  actual="$(sha256sum "${tmp}/rustup-init" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] ||
    die "rustup-init SHA-256 mismatch. Expected ${expected}, got ${actual}."

  if [[ -n "$TRUST_RUSTUP_SHA" && "${TRUST_RUSTUP_SHA,,}" != "${actual,,}" ]]; then
    die "rustup-init does not match --trust-rustup-sha. Expected ${TRUST_RUSTUP_SHA}, got ${actual}."
  fi
  info "rustup-init verified: sha256 ${actual} (source: static.rust-lang.org)"

  chmod 700 "${tmp}/rustup-init"
  "${tmp}/rustup-init" -y --no-modify-path --profile minimal --default-toolchain stable ||
    die "rustup-init failed."
  rm -rf "$tmp"

  activate_rust_env
  use_existing_rustc || die "Rust is still older than ${MIN_RUSTC} after the rustup install."
  info "Installed $(rustc --version)"
}

# ---------------------------------------------------------------- swap

cleanup_swap() {
  if [[ "$SWAP_CREATED" -ne 1 ]]; then
    return 0
  fi
  SWAP_CREATED=0
  swapoff "$SWAP_FILE" 2>/dev/null || true
  rm -f "$SWAP_FILE"
  info "Removed temporary swap ${SWAP_FILE}."
}

has_swap() {
  [[ "$(awk 'NR>1' /proc/swaps 2>/dev/null | wc -l)" -gt 0 ]]
}

ensure_swap() {
  if [[ "$SWAP_MODE" == "off" ]]; then
    info "Temporary swap disabled (--swap off)."
    return 0
  fi
  if has_swap; then
    info "System already has swap enabled; not adding any."
    return 0
  fi

  local mem want_mb=0
  mem="$(mem_total_mb)"
  if [[ "$SWAP_MODE" == "auto" ]]; then
    if (( mem >= 2048 )); then
      info "RAM ${mem}MB is enough for a fat-LTO build; no swap needed."
      return 0
    fi
    want_mb=2048
    if (( mem < 1024 )); then
      want_mb=4096
    fi
  elif [[ "$SWAP_MODE" =~ ^[0-9]+$ ]]; then
    want_mb="$SWAP_MODE"
  else
    die "--swap must be auto, off, or a size in MB."
  fi

  local avail
  avail="$(free_disk_mb /)"
  (( avail > want_mb + 1024 )) ||
    die "Need ~$((want_mb + 1024))MB free on / to create a ${want_mb}MB swapfile; only ${avail}MB available."

  info "Creating a temporary ${want_mb}MB swapfile for the build (RAM: ${mem}MB)..."
  fallocate -l "${want_mb}M" "$SWAP_FILE" 2>/dev/null ||
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$want_mb" status=none ||
    die "Could not create ${SWAP_FILE}."
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE" >/dev/null
  swapon "$SWAP_FILE" || die "Could not enable swap on ${SWAP_FILE}."
  SWAP_CREATED=1
  info "Swap enabled; it is removed automatically when this run finishes."
}

# ---------------------------------------------------------------- source

fetch_source() {
  command -v git >/dev/null 2>&1 || die "git is required to fetch the source."

  local ref="${COMMIT:-$VERSION}"

  if [[ -d "${SRC_DIR}/.git" ]]; then
    info "Reusing the source tree in ${SRC_DIR}."
    git -C "$SRC_DIR" remote set-url origin "$REPO_URL"
    if [[ -n "$COMMIT" ]]; then
      # A pinned commit may be unreachable from a shallow clone.
      git -C "$SRC_DIR" fetch --tags --force origin || die "git fetch failed."
    else
      git -C "$SRC_DIR" fetch --tags --force --depth 1 origin "$VERSION" || die "git fetch failed."
    fi
  else
    rm -rf "$SRC_DIR"
    if [[ -n "$COMMIT" ]]; then
      git clone --quiet "$REPO_URL" "$SRC_DIR" || die "git clone failed."
    else
      git clone --quiet --depth 1 --branch "$VERSION" --single-branch "$REPO_URL" "$SRC_DIR" ||
        { rm -rf "$SRC_DIR"; git clone --quiet "$REPO_URL" "$SRC_DIR"; } ||
        die "git clone failed."
    fi
  fi

  git -C "$SRC_DIR" checkout --force "$ref" >/dev/null 2>&1 ||
    die "Could not check out ${ref} from ${REPO_URL}."

  BUILD_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
  [[ "$BUILD_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "Could not resolve a commit for ${ref}."
  info "Source ready: ${ref} @ ${BUILD_COMMIT}"
}

check_disk_space() {
  local avail_src avail_toolchain
  avail_src="$(free_disk_mb "$(dirname "$SRC_DIR")")"
  (( avail_src >= 5120 )) ||
    die "Building needs roughly 5GB free under $(dirname "$SRC_DIR"); only ${avail_src}MB available. Free space first, or run 'install.sh clean-build' afterwards to reclaim the build tree."
  # The Rust toolchain (~600MB) and the cargo registry sources (~1GB) live on /.
  avail_toolchain="$(free_disk_mb /)"
  (( avail_toolchain >= 2048 )) ||
    die "Need at least 2GB free on / for the Rust toolchain and cargo registry; only ${avail_toolchain}MB available."
}

# ---------------------------------------------------------------- build

build_nowhere() {
  local -a cargo_args=(build --release --locked)
  [[ -z "$JOBS" ]] || cargo_args+=(--jobs "$JOBS")

  info "Compiling: cargo ${cargo_args[*]}"
  info "This is a fat-LTO release build (lto=\"fat\", codegen-units=1). On a 1-2 core VPS expect 20-60 minutes."
  (
    cd "$SRC_DIR"
    export RUSTUP_HOME="$RUSTUP_HOME_DIR"
    export CARGO_HOME="$CARGO_HOME_DIR"
    export PATH="${CARGO_HOME_DIR}/bin:${PATH}"
    cargo "${cargo_args[@]}"
  ) || die "cargo build failed. The source tree is kept at ${SRC_DIR} so a retry resumes from the cargo cache."

  BUILT_BIN="${SRC_DIR}/target/release/nowhere"
  [[ -f "$BUILT_BIN" && -x "$BUILT_BIN" ]] ||
    die "Build finished but ${BUILT_BIN} is missing or not executable."
  info "Built binary: $("$BUILT_BIN" --version 2>/dev/null | head -n1 || printf 'nowhere (version flag unavailable)')"
}

# ---------------------------------------------------------------- install

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

# Refuse to claim a port that something else already owns. Skipped when our own
# service is the thing listening.
check_port_available() {
  [[ -f "$CONFIG_FILE" ]] && return 0
  command -v ss >/dev/null 2>&1 || return 0
  if ss -lntup 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]"; then
    die "Port ${PORT} is already in use. Pick another --port or stop the conflicting service."
  fi
}

stage_release() {
  local release_dir="${INSTALL_ROOT}/releases/${VERSION}"
  install -d -m 755 "${INSTALL_ROOT}/releases" "$release_dir"
  install -m 755 "$BUILT_BIN" "${release_dir}/nowhere"

  local rustc_version binary_sha
  rustc_version="$(RUSTUP_HOME="$RUSTUP_HOME_DIR" CARGO_HOME="$CARGO_HOME_DIR" \
    PATH="${CARGO_HOME_DIR}/bin:${PATH}" rustc --version 2>/dev/null || printf 'unknown')"
  binary_sha="$(sha256sum "${release_dir}/nowhere" | awk '{print $1}')"

  cat >"${release_dir}/BUILD-INFO" <<EOF
repository:   ${REPO_URL}
tag:          ${VERSION}
commit:       ${BUILD_COMMIT}
built_at:     $(date -u '+%Y-%m-%dT%H:%M:%SZ')
built_on:     $(uname -m) $(uname -s) $(uname -r)
toolchain:    ${rustc_version}
cargo:        cargo build --release --locked
binary_sha256: ${binary_sha}
EOF
  chmod 644 "${release_dir}/BUILD-INFO"

  ln -sfn "$release_dir" "$CURRENT_LINK"
  ln -sfn "${CURRENT_LINK}/nowhere" "$BIN_LINK"

  info "Installed release ${VERSION} (binary sha256 ${binary_sha})"
  info "Build provenance recorded in ${release_dir}/BUILD-INFO"
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

env_quote() {
  local value="${1//$'\n'/}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

# Read the portal URI back out of the config file as data. Sourcing it would
# execute whatever a previous edit left in there, and on upgrade the KEY/CERT
# variables are unset, so build_portal would emit a link with an empty key.
stored_portal() {
  [[ -r "$CONFIG_FILE" ]] || return 0
  awk -F'"' '/^NOWHERE_PORTAL=/ { print $2; exit }' "$CONFIG_FILE"
}

write_unit() {
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Nowhere Portal
Documentation=https://github.com/NodePassProject/Nowhere
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

install_or_upgrade() {
  require_root
  require_systemd

  # Validate every cheap thing before spending an hour on a build.
  validate_version "$VERSION"
  if [[ -n "$COMMIT" && ! "$COMMIT" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    die "--commit must be a git object name (7-40 hex characters)."
  fi
  if [[ "$ACTION" == "install" && ! -f "$CONFIG_FILE" ]]; then
    validate_config
    validate_key "$KEY"
  fi
  [[ "$SWAP_MODE" == "auto" || "$SWAP_MODE" == "off" || "$SWAP_MODE" =~ ^[0-9]+$ ]] ||
    die "--swap must be auto, off, or a size in MB."

  local fresh=0
  [[ -f "$CONFIG_FILE" ]] || fresh=1
  if [[ "$ACTION" == "upgrade" && "$fresh" -eq 1 ]]; then
    die "No existing configuration. Run install first."
  fi
  if [[ "$ACTION" == "install" ]]; then
    check_port_available
  fi

  ensure_build_deps
  ensure_rust
  ensure_swap
  check_disk_space
  ensure_user
  check_certificate_access

  local old_target=""
  [[ -L "$CURRENT_LINK" ]] && old_target="$(readlink "$CURRENT_LINK")"

  fetch_source
  build_nowhere
  stage_release

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

  cleanup_swap
  if [[ "$KEEP_SOURCE" -eq 1 ]]; then
    info "Build tree kept at ${SRC_DIR} ($(du -sh "$SRC_DIR" 2>/dev/null | awk '{print $1}'))."
  else
    rm -rf "$SRC_DIR"
    info "Removed the build tree ${SRC_DIR}; the installed binary is unaffected."
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

clean_build() {
  require_root
  [[ -d "$SRC_DIR" ]] || { info "No build tree at ${SRC_DIR}."; return 0; }
  rm -rf "$SRC_DIR"
  rm -f "$SWAP_FILE"
  info "Removed ${SRC_DIR} and any leftover build swapfile."
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
  clean-build) clean_build ;;
  uninstall|remove) uninstall ;;
  version) printf '%s\n' "$SCRIPT_VERSION" ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
