#!/usr/bin/env bash
# Nowhere V3 isolated manager v1.3.1
# Deployment helpers derived from woohong666's Nowhere V2 manager.
# v1.3.1: isolated ACME state/plugin, explicit LE CA, early certificate rollback,
#   serialized renewal, stable renewal paths and CA-verified native links.
# v1.3.0: Let's Encrypt certificate automation (`cert` action): pinned acme.sh
#   from a GitHub release tarball, Cloudflare DNS-01 (token read hidden) or
#   HTTP-01, files staged under /etc/nowhere-v3/tls/le.<domain>/, url.conf
#   rewritten in a transaction, daily systemd renewal timer.
# v1.2.0: remote certificate fingerprint (`fingerprint nowhere://...`) for
#   out-of-band verification before pinning; shared fingerprint normalization.
# v1.1.0: bilingual operations menu/wizards, channel-safe self-update, versions,
#   generate-key, redacted probe, share links/optional QR and language persistence.
# v1.0.1 integration fixes: reuse the existing staged PEM on reconfigure so the
#   client pin stays stable; guard role switches in configure; tolerate an
#   unreadable manager.conf for `validate`; prune superseded PEM directories.
# Copyright (C) 2026 woohong666
# SPDX-License-Identifier: GPL-3.0-only
set -Eeuo pipefail
umask 077
readonly SCRIPT_VERSION="1.3.1"
readonly SCRIPT_CHANNEL="v3"
readonly DEFAULT_CORE_VERSION="v3.0.0"
readonly UPSTREAM_REPO="NodePassProject/Nowhere"
readonly SERVICE_NAME="nowhere-v3" RUN_USER="nowhere-v3" RUN_GROUP="nowhere-v3"
readonly INSTALL_ROOT="/opt/nowhere-v3"
readonly RELEASES_DIR="$INSTALL_ROOT/releases" CURRENT_LINK="$INSTALL_ROOT/current"
readonly BIN_LINK="/usr/local/bin/nowhere-v3"
readonly SHORTCUT_PATH="/usr/local/bin/nh"
readonly ACME_VERSION="3.1.6"
readonly LAUNCHER="/usr/local/libexec/nowhere-v3-launch"
readonly CONFIG_DIR="/etc/nowhere-v3"
# Dedicated ACME state is covered by config backups and transaction rollback.
readonly ACME_HOME="$CONFIG_DIR/acme"
readonly URL_FILE="$CONFIG_DIR/url.conf" META_FILE="$CONFIG_DIR/manager.conf" TLS_DIR="$CONFIG_DIR/tls"
readonly UNIT_FILE="/etc/systemd/system/nowhere-v3.service"
readonly BUILD_LOCK_DIR="/run/nowhere-v3-build.lock.d"
LANG_CODE="${NOWHERE_V3_LANG:-zh}"
C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_NC=''
BUILD_LOCK_HELD=0
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
VERSION="${NOWHERE_V3_VERSION:-$DEFAULT_CORE_VERSION}"
LIBC=auto
KEEP_RELEASES=3
OLD_TARGET=''
MEMORY_PROFILE=throughput
MORPH_PRELUDE=full8
PUBLIC_HOST=''
ROLE=portal
KEY=''
ENDPOINT=''
MORPH=1
OUT=direct
INGRESS=127.0.0.1:1083
PIN=''
SNI=''
CERT=''
TLS_KEY=''
URL_INPUT=''
ACTION=menu
ASSUME_YES=0
PURGE=0
ALLOW_ROLE_SWITCH=0
readonly DEFAULT_SELF_UPDATE_URL="https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v3.sh"
readonly SELF_UPDATE_URL="${NOWHERE_V3_SELF_URL-$DEFAULT_SELF_UPDATE_URL}"
MANAGER_FILE="${BASH_SOURCE[0]}"
NODE_NAME=Nowhere-V3
DIAL='' DIAL4='' DIAL6='' RATE='' ETAR=''
PROBE_TARGET=example.com:443
FINGERPRINT_URL=''
CERT_DOMAIN='' CERT_EMAIL='' CF_TOKEN='' CF_TOKEN_FILE=''
CERT_HTTP=0 CERT_FORCE=0
DOCTOR_PROBE=0
LANG_SET=0
WIZARD_REQUESTED=0
REINSTALL_MODE=0
ROLE_SET=0
TX_DIR=''
TX_COMMITTED=0
TX_ACTIVE=0
TX_ENABLED=0
TX_STARTED=0
declare -a CLEANUP_PATHS=()
info() { printf '%b[Nowhere V3]%b %s\n' "$C_BLUE" "$C_NC" "$*"; }

ok()   { printf '%b[OK]%b %s\n' "$C_GREEN" "$C_NC" "$*"; }

warn() { printf '%b[Warn]%b %s\n' "$C_YELLOW" "$C_NC" "$*" >&2; }

die()  { printf '%b[Error]%b %s\n' "$C_RED" "$C_NC" "$*" >&2; exit 1; }

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

prompt_confirm() {
  local a hint input="${NOWHERE_V3_PROMPT_TTY:-/dev/tty}"
  hint="$(tr_msg '[y/N]' '[y/N]（y=是 n=否）')"
  read -r -p "$1 $hint: " a <"$input" || a=""
  [[ "$a" =~ ^([Yy]([Ee][Ss])?|是)$ ]]
}

release_build_lock() {
  if [[ "$BUILD_LOCK_HELD" -eq 1 ]]; then
    flock -u "$BUILD_LOCK_FD" || true
    exec {BUILD_LOCK_FD}>&-
    BUILD_LOCK_HELD=0
  fi
}

acquire_build_lock() {
  [[ "$BUILD_LOCK_HELD" -eq 1 ]] && return 0
  require_root; require_command flock
  exec {BUILD_LOCK_FD}>"${BUILD_LOCK_DIR%.d}"
  flock -n "$BUILD_LOCK_FD" || die "$(tr_msg "Another V3 management operation is running" "另一个 V3 管理操作正在运行")"
  BUILD_LOCK_HELD=1
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

validate_keep_releases() { [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1>=0 && 10#$1<=20)) || die "$(tr_msg "keep-releases must be 0-20" "keep-releases 必须为 0-20")"; }

is_valid_memory_profile() { [[ "$1" == memory || "$1" == balanced || "$1" == throughput ]]; }

is_valid_morph_prelude() { [[ "$1" == low7 || "$1" == full8 ]]; }

validate_memory_profile() { is_valid_memory_profile "$1" || die "$(tr_msg "memory-profile must be memory|balanced|throughput" "memory-profile 必须为 memory|balanced|throughput")"; }

validate_morph_prelude() { is_valid_morph_prelude "$1" || die "$(tr_msg "morph-prelude must be low7|full8" "morph-prelude 必须为 low7|full8")"; }

curl_github() {
  local url="$1" out="$2"; shift 2
  local -a args=(--fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --connect-timeout 10 -H 'Accept: application/vnd.github+json')
  [[ -n "$GITHUB_TOKEN" ]] && args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  curl "${args[@]}" "$@" "$url" -o "$out"
}

resolve_version() {
  validate_version_arg "$VERSION"
  [[ "$VERSION" == latest-v3 ]] || return 0
  install_runtime_deps
  local tmp page found best="" count
  tmp="$(mktemp)"; CLEANUP_PATHS+=("$tmp")
  for ((page=1;page<=20;page++)); do
    curl_github "https://api.github.com/repos/${UPSTREAM_REPO}/releases?per_page=100&page=${page}" "$tmp" || die "$(tr_msg "Cannot fetch the official release list" "无法获取官方发布列表")"
    found="$(python3 - "$tmp" <<'PY'
import json,re,sys
r=json.load(open(sys.argv[1])); assert isinstance(r,list)
c=[(tuple(map(int,x['tag_name'][1:].split('.'))),x['tag_name']) for x in r if re.fullmatch(r'v3\.\d+\.\d+',x.get('tag_name','')) and not x.get('draft') and not x.get('prerelease')]
print(max(c)[1] if c else '')
print(len(r))
PY
)" || die "$(tr_msg "Invalid release metadata" "发布元数据无效")"
    count="${found##*$'\n'}"; found="${found%%$'\n'*}"
    if [[ -n "$found" ]] && { [[ -z "$best" ]] || version_ge "$found" "$best"; }; then best="$found"; fi
    if ((count<100)); then
      [[ -n "$best" ]] || die "$(tr_msg "No stable V3 release found" "未找到稳定 V3 版本")"
      VERSION="$best"; return 0
    fi
  done
  die "$(tr_msg "Release scan limit reached; specify a stable tag" "发布列表超过扫描上限，请显式指定稳定版标签")"
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
    members=t.getmembers(); seen=set()
    for m in members:
        p=pathlib.PurePosixPath(m.name)
        if str(p) in seen: raise SystemExit('Duplicate archive member')
        seen.add(str(p))
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
manager_channel: v3
EOF2
  ln -sfn "$release_dir" "$CURRENT_LINK"; ln -sfn "$CURRENT_LINK/nowhere" "$BIN_LINK"
  ok "$(tr_msg "Installed Nowhere ${VERSION} (${bsha:0:12})" "已安装 Nowhere ${VERSION} (${bsha:0:12})")"
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
[[ -r "\$URL_FILE" ]] || { echo 'missing V3 config' >&2; exit 1; }
IFS= read -r URL <"\$URL_FILE"
[[ -n "\$URL" ]] || { echo 'empty V3 config' >&2; exit 1; }
exec "\$BIN" "\$URL"
EOF2
  chmod 755 "$LAUNCHER"
}

write_unit() {
  cat >"$UNIT_FILE" <<EOF2
[Unit]
Description=Nowhere V3 (${SERVICE_NAME})
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
Environment=TMPDIR=/run/nowhere-v3
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
RuntimeDirectory=nowhere-v3
RuntimeDirectoryMode=0750

[Install]
WantedBy=multi-user.target
EOF2
  chmod 644 "$UNIT_FILE"
  systemctl daemon-reload
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
  ((removed>0)) && ok "$(tr_msg "Removed ${removed} old V3 release(s)" "已清理 ${removed} 个旧 V3 Release")" || [[ "$quiet" == 1 ]] || info "$(tr_msg "No old V3 releases need cleanup" "没有需要清理的旧 V3 Release")"
}

version_ge() {
  python3 - "$1" "$2" <<'PY'
import re,sys
v=[x.removeprefix('v') if hasattr(x,'removeprefix') else x.lstrip('v') for x in sys.argv[1:]]
if not all(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',x) for x in v):sys.exit(1)
sys.exit(0 if tuple(map(int,v[0].split('.'))) >= tuple(map(int,v[1].split('.'))) else 1)
PY
}

validate_version_arg() {
  [[ "$1" == latest-v3 || "$1" =~ ^v3\.[0-9]+\.[0-9]+$ ]] || die "$(tr_msg "Only stable V3 tags or latest-v3 are supported; V2 is refused" "仅支持稳定 V3 标签或 latest-v3；拒绝 V2")"
}
# A fail-closed manager validator. Upstream ignores unknown keys; this manager
# rejects them so accidentally importing an NW2 URL cannot silently change routing.
v3_url() {
  NOWHERE_MANAGER_LANG="$LANG_CODE" python3 - "$@" <<'PY'
import sys,re,urllib.parse as U,ipaddress,os
op=sys.argv[1]
MESSAGES={'Invalid IPv6': 'IPv6地址无效', 'Invalid host': '主机地址无效', 'Invalid port': '端口无效', 'Invalid carrier path': '载波路径无效', 'Invalid endpoint': '端点无效', 'Duplicate or missing carrier': '载波重复或缺失', 'V3 client must select one carrier': 'V3客户端必须选择单一载波', 'Egress requires QUIC/udp': 'Egress必须使用QUIC/udp', 'Address family conflict': '地址族冲突', 'SOCKS credentials must encode reserved characters': 'SOCKS凭据中的保留字符必须编码', 'Invalid SOCKS credentials': 'SOCKS凭据无效', 'SOCKS requires HOST:PORT': 'SOCKS必须使用HOST:PORT', 'Whitespace/control in URL': 'URL含空白或控制字符', 'Invalid percent encoding': '百分号编码无效', 'Invalid URL': 'URL无效', 'Invalid role URL': '角色URL无效', 'NW3 key must be exactly 32 lowercase hex characters': 'NW3密钥必须为32位小写十六进制', 'Unsupported V3 option; old NW2 and unknown parameters are refused': '不支持的V3参数；拒绝NW2及未知参数', 'Invalid morph': 'Morph无效', 'Rate must be an integer in 0..2147483647': '速率必须为0..2147483647整数', 'Conflicting source bindings': '出站源地址参数冲突', 'Invalid source IP': '出站源IP无效', 'Invalid source family': '出站源地址族无效', 'Invalid TLS mode': 'TLS模式无效', 'PEM paths required': '必须提供PEM路径', 'PEM paths must be absolute': 'PEM路径必须为绝对路径', 'PEM paths require tls=2': 'PEM路径要求tls=2', 'Egress output requires QUIC and forbids dial options': 'Portal的egress出口要求QUIC且禁止dial参数', 'Pin must be 64 lowercase hex characters': 'pin必须为64位小写十六进制', 'Invalid SNI': 'SNI无效', 'Vector requires in=': 'Vector必须指定in=', 'Links require Portal': '链接操作要求Portal角色', 'Verified local certificate pin required': '必须取得可信的本机证书pin', 'Fingerprint inspection requires a TCP listener or persistent PEM': '指纹探测需要TCP监听或持久PEM证书', 'V3 configuration OK': 'V3配置校验通过'}
def msg(m):return MESSAGES.get(m,m) if os.environ.get('NOWHERE_MANAGER_LANG')=='zh' else m
def fail(m): raise SystemExit(msg(m))
def host(h,wild=False):
    if h=='*' and wild:return
    if h.startswith('[') and h.endswith(']'):
        try:ipaddress.IPv6Address(h[1:-1]);return
        except ValueError:fail('Invalid IPv6')
    if not h or not re.fullmatch(r'[A-Za-z0-9._-]+',h):fail('Invalid host')
def port(p):
    if not re.fullmatch(r'[0-9]{1,5}',p) or not 1<=int(p)<=65535:fail('Invalid port')
    return int(p)
def endpoint(ep,role):
    entries=[]
    if '/' in ep:
        h,*parts=ep.split('/')
        for part in parts:
            m=re.fullmatch(r'(tcp|udp)([46]?):([0-9]+)',part)
            if not m:fail('Invalid carrier path')
            typ,fam,p=m.groups();entries.append((typ,int(fam or 0),port(p)))
    else:
        m=re.fullmatch(r'(\[[^\]]+\]|[^:]+):([0-9]+)',ep)
        if not m:fail('Invalid endpoint')
        h,p=m.groups();p=port(p)
        entries=[('tcp',0,p),('udp',0,p)] if role=='portal' else [('udp' if role=='egress' else 'tcp',0,p)]
    host(h,role=='portal')
    if not entries or len(entries)>2 or len({x[0] for x in entries})!=len(entries):fail('Duplicate or missing carrier')
    if role!='portal' and len(entries)!=1:fail('V3 client must select one carrier')
    if role=='egress' and entries[0][0]!='udp':fail('Egress requires QUIC/udp')
    try:ip=ipaddress.ip_address(h.strip('[]'))
    except ValueError:ip=None
    for _,fam,_ in entries:
        if ip and fam and fam!=ip.version:fail('Address family conflict')
    return h,entries
def socks(raw):
    if '@' in raw:
        auth,addr=raw.rsplit('@',1)
        if auth.count(':')!=1 or '@' in auth:fail('SOCKS credentials must encode reserved characters')
        for v in auth.split(':'):
            if not 1<=len(U.unquote(v).encode())<=255:fail('Invalid SOCKS credentials')
    else:addr=raw
    endpoint(addr,'vector')
    if '/' in addr:fail('SOCKS requires HOST:PORT')
def validate(raw):
    if any(ord(c)<33 or ord(c)==127 for c in raw):fail('Whitespace/control in URL')
    if re.search(r'%(?![0-9a-fA-F]{2})',raw):fail('Invalid percent encoding')
    try:u=U.urlsplit(raw)
    except ValueError:fail('Invalid URL')
    role=u.scheme
    if role not in ('portal','vector','egress') or u.fragment or u.password is not None:fail('Invalid role URL')
    try:key=U.unquote(u.username or '',errors='strict')
    except UnicodeError:fail('Invalid percent encoding')
    if not re.fullmatch(r'[0-9a-f]{32}',key):fail('NW3 key must be exactly 32 lowercase hex characters')
    ep=u.netloc.rsplit('@',1)[-1]+u.path
    h,entries=endpoint(ep,role)
    rawq={}
    for pair in u.query.split('&') if u.query else []:
        k,_,v=pair.partition('=')
        try:k=U.unquote(k,errors='strict')
        except UnicodeError:fail('Invalid percent encoding')
        rawq.setdefault(k,v)
    try:q={k:U.unquote(v,errors='strict') for k,v in rawq.items()}
    except UnicodeError:fail('Invalid percent encoding')
    common={'morph','rate','etar'}
    allowed=common|({'out','tls','crt','key','dial','dial4','dial6'} if role=='portal' else {'in','sni','pin'} if role=='vector' else {'sni','pin','dial','dial4','dial6'})
    if set(q)-allowed:fail('Unsupported V3 option; old NW2 and unknown parameters are refused')
    if q.get('morph','1') not in ('0','1'):fail('Invalid morph')
    for k in ('rate','etar'):
        v=q.get(k,'0')
        if not re.fullmatch(r'[0-9]{1,10}',v) or int(v)>2147483647:fail('Rate must be an integer in 0..2147483647')
    if 'dial' in q and ('dial4' in q or 'dial6' in q):fail('Conflicting source bindings')
    for k in ('dial','dial4','dial6'):
        if k in q and q[k]!='auto':
            try:a=ipaddress.ip_address(q[k])
            except ValueError:fail('Invalid source IP')
            if '%' in q[k] or (k=='dial4' and a.version!=4) or (k=='dial6' and (a.version!=6 or a.ipv4_mapped)):fail('Invalid source family')
    if role=='portal':
        tls=q.get('tls','1')
        if tls not in ('1','2'):fail('Invalid TLS mode')
        if tls=='2':
            if not q.get('crt') or not q.get('key'):fail('PEM paths required')
            if not q['crt'].startswith('/') or not q['key'].startswith('/'):fail('PEM paths must be absolute')
        elif 'crt' in q or 'key' in q:fail('PEM paths require tls=2')
        out=q.get('out','direct')
        if out=='egress':
            if not any(e[0]=='udp' for e in entries) or set(q)&{'dial','dial4','dial6'}:fail('Egress output requires QUIC and forbids dial options')
        elif out!='direct':socks(rawq['out'])
    else:
        if q.get('pin','none') not in ('','none') and not re.fullmatch(r'[0-9a-f]{64}',q['pin']):fail('Pin must be 64 lowercase hex characters')
        if q.get('sni','none') not in ('','none') and not re.fullmatch(r'[A-Za-z0-9.-]+',q['sni']):fail('Invalid SNI')
        if role=='vector':
            if not q.get('in'):fail('Vector requires in=')
            socks(rawq['in'])
    return role,key,ep,h,entries,q,rawq
if op=='build':
    role,key,ep,morph,out,ingress,pin,sni,crt,pk=sys.argv[2:]
    pairs=[('morph',morph)]
    if role=='portal':
        # out uses raw SOCKS delimiter syntax, handled separately below.
        pairs += [('tls','2'),('crt',crt),('key',pk)] if crt else [('tls','1')]
    else:
        if pin:pairs.append(('pin',pin))
        if sni:pairs.append(('sni',sni))
    raw=f'{role}://{key}@{ep}?'+U.urlencode(pairs,quote_via=U.quote)
    raw+='&out='+out if role=='portal' else '&in='+ingress if role=='vector' else ''
    validate(raw);print(raw)
else:
    raw=sys.argv[2]
    role,key,ep,h,entries,q,rawq=validate(raw)
    if op=='validate':print(msg('V3 configuration OK'))
    elif op=='get':
        k=sys.argv[3];print({'role':role,'endpoint':ep,'shared_key':key}.get(k,q.get(k,'')))
    elif op=='rewrite-pem':
        rawq.update(tls='2',crt=U.quote(sys.argv[3],safe=''),key=U.quote(sys.argv[4],safe=''))
        print(f'{role}://{key}@{ep}?'+ '&'.join(U.quote(k,safe='')+'='+v for k,v in rawq.items()))
    elif op=='redact':
        print(f'{role}://***@{ep}')
    elif op=='set-dial':
        for k,v in zip(('dial','dial4','dial6'),sys.argv[3:]):
            if v:rawq[k]=U.quote(v,safe='')
        result=f'{role}://{key}@{ep}?'+ '&'.join(U.quote(k,safe='')+'='+v for k,v in rawq.items())
        validate(result);print(result)
    elif op=='set-advanced':
        for k,v in zip(('rate','etar'),sys.argv[3:]):
            if v:rawq[k]=U.quote(v,safe='')
        result=f'{role}://{key}@{ep}?'+ '&'.join(U.quote(k,safe='')+'='+v for k,v in rawq.items())
        validate(result);print(result)
    elif op=='fingerprint-link':
        if role!='portal':fail('Links require Portal')
        tcp=next((x for x in entries if x[0]=='tcp'),None)
        if not tcp:fail('Fingerprint inspection requires a TCP listener or persistent PEM')
        local=h
        if h in ('*','0.0.0.0','[::]'):local='[::1]' if tcp[1]==6 or h=='[::]' else '127.0.0.1'
        print(f'nowhere://{key}@{local}:{tcp[2]}?morph='+q.get('morph','1'))
    elif op=='probe-link':
        if role!='portal':fail('Links require Portal')
        public,pin=sys.argv[3:]
        if ':' in public and not public.startswith('['):public='['+public+']'
        host(public)
        if not re.fullmatch(r'[0-9a-f]{64}',pin):fail('Verified local certificate pin required')
        typ,_,p=next((x for x in entries if x[0]=='tcp'),entries[0])
        print(f'vector://{key}@{public}/{typ}:{p}?morph='+q.get('morph','1')+'&pin='+pin+'&in=127.0.0.1:1083')
    elif op=='shares':
        if role!='portal':fail('Links require Portal')
        public,name=sys.argv[3:]
        if ':' in public and not public.startswith('['):public='['+public+']'
        host(public)
        for typ,_,p in entries:
            print(f'nowhere://{key}@{public}:{p}?net={typ}&morph='+q.get('morph','1')+'#'+U.quote(name,safe=''))
    elif op=='links':
        if role!='portal':fail('Links require Portal')
        public,pin=sys.argv[3:]
        if ':' in public and not public.startswith('['):public='['+public+']'
        host(public)
        if pin and not re.fullmatch(r'[0-9a-f]{64}',pin):fail('Verified local certificate pin required')
        for typ,fam,p in entries:
            # Let public DNS choose a family unless it is an explicit IP.
            params={'morph':q.get('morph','1')}
            if pin:params['pin']=pin
            query=U.urlencode(params)
            print(f'Vector {typ}: vector://{key}@{public}/{typ}:{p}?{query}&in=127.0.0.1:1083')
            if typ=='udp' and q.get('out')=='egress':print(f'Egress: egress://{key}@{public}/udp:{p}?{query}')
    elif op=='ports':
        for typ,fam,p in entries:print(f'{typ.upper()} {p} (family {fam or "auto"})')
PY
}

read_url() { [[ -s "$URL_FILE" ]] || die "$(tr_msg "V3 is not configured" "尚未配置 V3")"; head -n 1 "$URL_FILE"; }
load_meta() {
  [[ -r "$META_FILE" ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      PUBLIC_HOST) PUBLIC_HOST="$v" ;;
      LANG) [[ "$v" != zh && "$v" != en ]] || LANG_CODE="$v" ;;
      NODE_NAME) NODE_NAME="$v" ;;
      MEMORY_PROFILE) validate_memory_profile "$v"; MEMORY_PROFILE="$v" ;;
      MORPH_PRELUDE) validate_morph_prelude "$v"; MORPH_PRELUDE="$v" ;;
    esac
  done <"$META_FILE"
}
write_meta() {
  printf 'SCRIPT_CHANNEL=v3\nSCRIPT_VERSION=%s\nCORE_VERSION=%s\nPUBLIC_HOST=%s\nMEMORY_PROFILE=%s\nMORPH_PRELUDE=%s\nLANG=%s\nNODE_NAME=%s\n' "$SCRIPT_VERSION" "$VERSION" "$PUBLIC_HOST" "$MEMORY_PROFILE" "$MORPH_PRELUDE" "$LANG_CODE" "$NODE_NAME" >"$META_FILE"
  chown root:"$RUN_GROUP" "$META_FILE"; chmod 640 "$META_FILE"
}
# Save everything needed for service/config/binary recovery before mutation.
begin_transaction() {
  [[ -n "$TX_DIR" ]] && return 0
  TX_DIR="$(mktemp -d)"; CLEANUP_PATHS+=("$TX_DIR")
  systemctl is-active --quiet "$SERVICE_NAME" && TX_ACTIVE=1 || true
  systemctl is-enabled --quiet "$SERVICE_NAME" && TX_ENABLED=1 || true
  OLD_TARGET="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
  [[ ! -d "$CONFIG_DIR" ]] || cp -a "$CONFIG_DIR" "$TX_DIR/config"
  [[ ! -f "$UNIT_FILE" ]] || cp -a "$UNIT_FILE" "$TX_DIR/unit"
  [[ ! -f "$LAUNCHER" ]] || cp -a "$LAUNCHER" "$TX_DIR/launcher"
  TX_STARTED=1
}
finish() {
  local rc=$? p
  trap - EXIT
  set +e
  if [[ "$TX_STARTED" == 1 && "$TX_COMMITTED" == 0 ]]; then
    warn "$(tr_msg "Operation failed; restoring previous V3 config, service files and binary links" "操作未完成，恢复之前的 V3 配置、服务定义和二进制链接")"
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
    rm -rf "$CONFIG_DIR"
    [[ ! -d "$TX_DIR/config" ]] || cp -a "$TX_DIR/config" "$CONFIG_DIR"
    rm -f "$UNIT_FILE" "$LAUNCHER"
    [[ ! -f "$TX_DIR/unit" ]] || cp -a "$TX_DIR/unit" "$UNIT_FILE"
    [[ ! -f "$TX_DIR/launcher" ]] || cp -a "$TX_DIR/launcher" "$LAUNCHER"
    if [[ -n "$OLD_TARGET" && -x "$OLD_TARGET/nowhere" ]]; then
      ln -sfn "$OLD_TARGET" "$CURRENT_LINK"; ln -sfn "$CURRENT_LINK/nowhere" "$BIN_LINK"
    else rm -f "$CURRENT_LINK" "$BIN_LINK"; fi
    systemctl daemon-reload
    if [[ "$TX_ENABLED" == 1 ]]; then systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    else systemctl disable "$SERVICE_NAME" >/dev/null 2>&1; fi
    if [[ "$TX_ACTIVE" == 1 ]]; then
      systemctl restart "$SERVICE_NAME" && wait_service 12 || warn "$(tr_msg "Service recovery failed; inspect the logs" "服务恢复失败，请检查日志")"
    fi
  fi
  for p in "${CLEANUP_PATHS[@]}"; do [[ -z "$p" ]] || rm -rf -- "$p"; done
  release_build_lock
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stage_pem() {
  local cert="$1" key="$2" cp kp d
  [[ -f "$cert" && -f "$key" ]] || die "$(tr_msg "Certificate or private key does not exist" "证书或私钥不存在")"
  d="$(mktemp -d "$TLS_DIR/pem.XXXXXX")"; chmod 750 "$d"; chown root:"$RUN_GROUP" "$d"
  install -m 640 -o root -g "$RUN_GROUP" "$cert" "$d/cert.pem"
  install -m 640 -o root -g "$RUN_GROUP" "$key" "$d/key.pem"
  openssl x509 -in "$d/cert.pem" -noout -checkend 0 >/dev/null || die "$(tr_msg "Certificate invalid or expired" "证书无效或已过期")"
  cp="$(openssl x509 -in "$d/cert.pem" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum)"
  kp="$(openssl pkey -in "$d/key.pem" -passin pass: -pubout -outform DER 2>/dev/null | sha256sum)"
  [[ "$cp" == "$kp" ]] || die "$(tr_msg "Certificate and key mismatch; only unencrypted service keys are supported" "证书与私钥不匹配（仅支持无口令服务私钥）")"
  if [[ "$cert" == "$TLS_DIR"/le.*/fullchain.pem && "$key" == "${cert%/*}/key.pem" && "${cert#"$TLS_DIR"/le.}" != */*/* ]]; then
    rm -rf -- "$d"
    CERT="$cert"; TLS_KEY="$key"
  else
    CERT="$d/cert.pem"; TLS_KEY="$d/key.pem"
  fi
}
prepare_configuration() {
  local u crt pk
  if [[ -n "$URL_INPUT" ]]; then
    u="$URL_INPUT"; v3_url validate "$u" >/dev/null
    ROLE="$(v3_url get "$u" role)"
    if [[ "$ROLE" == portal && "$(v3_url get "$u" tls)" == 2 ]]; then
      crt="$(v3_url get "$u" crt)"; pk="$(v3_url get "$u" key)"
      stage_pem "$crt" "$pk"
      u="$(v3_url rewrite-pem "$u" "$CERT" "$TLS_KEY")"
    elif [[ "$ROLE" == portal ]]; then
      warn "$(tr_msg "Imported tls=1 uses a temporary certificate; update client pins after restart" "导入的 tls=1 使用临时证书；重启后需要更新客户端 pin")"
    fi
  else
    [[ -n "$KEY" ]] || { [[ "$ROLE" == portal ]] && KEY="$(python3 -c 'import secrets;print(secrets.token_hex(16))')"; }
    [[ -n "$ENDPOINT" ]] || { [[ "$ROLE" == portal ]] && ENDPOINT='*:2083'; }
    [[ -n "$KEY" && -n "$ENDPOINT" ]] || die "$(tr_msg "Vector/Egress require --key and --endpoint" "Vector/Egress 必须提供 --key 和 --endpoint")"
    if [[ "$ROLE" == portal ]]; then
      if [[ -z "$CERT" && -z "$TLS_KEY" && -s "$URL_FILE" ]]; then
        # Reuse the existing staged PEM: a reconfigure must not silently rotate
        # the certificate (and with it every client's pin). Pass --cert/--tls-key
        # explicitly to rotate.
        local ex="" ex_crt="" ex_key=""
        ex="$(head -n 1 "$URL_FILE")"
        if [[ "$(v3_url get "$ex" role)" == portal && "$(v3_url get "$ex" tls)" == 2 ]]; then
          ex_crt="$(v3_url get "$ex" crt)"; ex_key="$(v3_url get "$ex" key)"
          if [[ -f "$ex_crt" && -f "$ex_key" ]]; then CERT="$ex_crt"; TLS_KEY="$ex_key"; fi
        fi
      fi
      if [[ -n "$CERT" || -n "$TLS_KEY" ]]; then stage_pem "$CERT" "$TLS_KEY"
      else
        # Persistent self-signed PEM: pin remains stable across restarts/upgrades.
        local tmp
        tmp="$(mktemp -d)"; CLEANUP_PATHS+=("$tmp")
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj /CN=nowhere-v3 -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1
        stage_pem "$tmp/cert.pem" "$tmp/key.pem"
      fi
    fi
    u="$(v3_url build "$ROLE" "$KEY" "$ENDPOINT" "$MORPH" "$OUT" "$INGRESS" "$PIN" "$SNI" "$CERT" "$TLS_KEY")"
    u="$(v3_url set-dial "$u" "$DIAL" "$DIAL4" "$DIAL6")"
    u="$(v3_url set-advanced "$u" "$RATE" "$ETAR")"
  fi
  v3_url validate "$u" >/dev/null
  printf '%s\n' "$u" >"$URL_FILE.new"
  chown root:"$RUN_GROUP" "$URL_FILE.new"; chmod 640 "$URL_FILE.new"
  mv -f "$URL_FILE.new" "$URL_FILE"
  # Drop staged PEM directories that the current configuration no longer references.
  local keep_dir=""
  if [[ "$ROLE" == portal && "$(v3_url get "$u" tls)" == 2 ]]; then keep_dir="$(dirname "$(v3_url get "$u" crt)")"; fi
  if [[ "$keep_dir" == "$TLS_DIR"/pem.* ]]; then
    find "$TLS_DIR" -maxdepth 1 -type d -name 'pem.*' ! -path "$keep_dir" -exec rm -rf -- {} + 2>/dev/null || true
  fi
}
install_shortcut() {
  local self target content
  target="$SHORTCUT_PATH"
  self="$(readlink -f -- "$MANAGER_FILE" 2>/dev/null || true)"
  [[ -n "$self" && -f "$self" ]] || self="$MANAGER_FILE"
  [[ -f "$self" ]] || return 0
  content="#!/usr/bin/env bash
# nowhere-v3-shortcut: opens the Nowhere V3 manager; delete this file to remove it.
exec bash $(printf '%q' "$self") \"\$@\""
  if [[ -L "$target" ]]; then
    warn "$(tr_msg "Shortcut path is a symlink; leaving it unchanged" "快捷命令路径是软链接，保留原状")"
    return 0
  fi
  if [[ -e "$target" ]]; then
    if ! grep -qs 'nowhere-v3-shortcut' "$target"; then
      warn "$(tr_msg "Shortcut not created: $target already exists and is not owned by this manager" "未创建快捷命令：$target 已存在且不属于本管理器")"
      return 0
    fi
    if [[ "$(cat "$target" 2>/dev/null)" == "$content" ]]; then return 0; fi
  fi
  if ! printf '%s\n' "$content" >"$target" 2>/dev/null; then
    warn "$(tr_msg "Could not write the shortcut: $target" "快捷命令写入失败：$target")"
    return 0
  fi
  chmod 755 "$target" 2>/dev/null || true
  info "$(tr_msg "Shortcut ready: nh - open this menu (arguments pass through, e.g. nh status)" "快捷命令已就绪：nh——打开本菜单（参数透传，如 nh status）")"
}
activate() {
  write_launcher; write_unit
  systemctl enable "$SERVICE_NAME" >/dev/null
  systemctl restart "$SERVICE_NAME"
  wait_service 12 || die "$(tr_msg "V3 did not stay active; restoring state. Check journalctl -u nowhere-v3" "V3 未持续运行，触发恢复；请检查 journalctl -u nowhere-v3")"
  TX_COMMITTED=1
  install_shortcut
}
mutating_setup() {
  require_root; require_systemd; install_runtime_deps; acquire_build_lock
}
install_action() {
  mutating_setup
  if [[ "$ACTION" == upgrade ]]; then [[ -s "$URL_FILE" ]] || die "$(tr_msg "upgrade requires existing V3 configuration" "upgrade 需要已有 V3 配置")"; fi
  if [[ -s "$URL_FILE" && ( -n "$URL_INPUT" || -n "$KEY" || -n "$ENDPOINT" || -n "$CERT" || "$ROLE" != portal || "$OUT" != direct || "$MORPH" != 1 ) ]]; then
    die "$(tr_msg "Existing V3 config: install/upgrade only updates the binary. Use configure to change configuration" "已有 V3 配置；install/upgrade 仅更新二进制。修改配置请单独使用 configure")"
  fi
  begin_transaction; ensure_user
  if [[ -s "$URL_FILE" ]]; then v3_url validate "$(read_url)" >/dev/null
  else prepare_configuration; fi
  install_release
  local actual
  actual="$("$CURRENT_LINK/nowhere" --version)"
  [[ "$actual" == "nowhere-${VERSION} "* ]] || die "$(tr_msg "Downloaded binary version does not match the selected tag" "下载二进制版本与所选标签不符")"
  write_meta; activate
  cleanup_old_releases 1
  ok "$(tr_msg "V3 ${VERSION} is active; client end-to-end acceptance is still required" "V3 ${VERSION} 服务已启动；尚需客户端端到端验收")"
}
configure_action() {
  mutating_setup; [[ -x "$CURRENT_LINK/nowhere" ]] || die "$(tr_msg "Run install first" "请先 install")"
  [[ -n "$URL_INPUT" || ( -n "$KEY" && -n "$ENDPOINT" ) ]] || die "$(tr_msg "configure requires --url or both --key and --endpoint" "configure 必须明确提供 --url 或 --key 与 --endpoint")"
  if [[ -s "$URL_FILE" ]]; then
    local current_role new_role
    current_role="$(v3_url get "$(head -n 1 "$URL_FILE")" role)"
    if [[ -n "$URL_INPUT" ]]; then new_role="$(v3_url get "$URL_INPUT" role)"; else new_role="$ROLE"; fi
    if [[ "$new_role" != "$current_role" ]]; then
      if [[ "$ALLOW_ROLE_SWITCH" == 1 ]]; then
        warn "$(tr_msg "Switching role ${current_role} to ${new_role}: existing config will be replaced" "角色从 ${current_role} 切换为 ${new_role}：原配置将被覆盖")"
      elif [[ "$ASSUME_YES" == 1 ]]; then
        die "$(tr_msg "Role changes from ${current_role} to ${new_role}; explicitly add --allow-role-switch to confirm" "角色将从 ${current_role} 切换为 ${new_role}；确认请显式加 --allow-role-switch")"
      else
        prompt_confirm "$(tr_msg "Role changes from ${current_role} to ${new_role}, replacing existing config. Continue?" "角色将从 ${current_role} 切换为 ${new_role}，原配置会被覆盖，继续？")" || die "$(tr_msg "Role switch cancelled" "已取消角色切换")"
      fi
    fi
  fi
  begin_transaction; ensure_user
  VERSION="$(sed -n 's/^tag: //p' "$CURRENT_LINK/RELEASE-INFO")"
  prepare_configuration
  if [[ "$REINSTALL_MODE" == 1 ]]; then
    install_release
    local actual
    actual="$("$CURRENT_LINK/nowhere" --version)"
    [[ "$actual" == "nowhere-${VERSION} "* ]] || die "$(tr_msg 'Downloaded binary version does not match the selected tag' '下载二进制版本与所选标签不符')"
  fi
  write_meta; activate
  ok "$(tr_msg "V3 configuration applied" "V3 配置已应用")"
}
normalize_fingerprint() {
  printf '%s' "$1" | tr -d '[:space:]:' | tr 'A-F' 'a-f'
}
local_pin() {
  local u tls cert fp link
  u="$(read_url)"
  [[ "$(v3_url get "$u" role)" == portal ]] || die "$(tr_msg "Fingerprint is a Portal operation" "仅 Portal 支持本机证书指纹")"
  tls="$(v3_url get "$u" tls)"
  if [[ "$tls" == 2 ]]; then
    cert="$(v3_url get "$u" crt)"
    fp="$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null)" || die "$(tr_msg "Cannot read certificate fingerprint" "指纹读取失败")"
    fp="$(normalize_fingerprint "${fp#*=}")"
  else
    [[ -x "$BIN_LINK" ]] || die "$(tr_msg "V3 binary missing" "V3 二进制缺失")"
    link="$(v3_url fingerprint-link "$u")"
    fp="$(timeout 12 "$BIN_LINK" fingerprint "$link" 2>/dev/null)" || die "$(tr_msg "Cannot inspect the live local certificate" "无法探测本机正在使用的证书")"
    fp="$(normalize_fingerprint "$fp")"
  fi
  [[ "$fp" =~ ^[0-9a-f]{64}$ ]] || die "$(tr_msg "Cannot read certificate fingerprint" "指纹读取失败")"
  printf '%s\n' "$fp"
}
remote_fingerprint() {
  local url="$1" endpoint port redacted fp
  [[ "$url" == nowhere://*@* ]] || die "$(tr_msg "Usage: fingerprint [nowhere://KEY@HOST:PORT?morph=0|1]" "用法：fingerprint [nowhere://KEY@HOST:PORT?morph=0|1]")"
  [[ "$url" != *[$' \t\r\n']* ]] || die "$(tr_msg "URL contains whitespace or control characters" "URL含空白或控制字符")"
  endpoint="${url#*@}"; endpoint="${endpoint%%[?#]*}"
  [[ "$endpoint" != :* && "$endpoint" != */* ]] || die "$(tr_msg "Usage: fingerprint [nowhere://KEY@HOST:PORT?morph=0|1]" "用法：fingerprint [nowhere://KEY@HOST:PORT?morph=0|1]")"
  [[ "$endpoint" =~ :([0-9]{1,5})$ ]] || die "$(tr_msg "Usage: fingerprint [nowhere://KEY@HOST:PORT?morph=0|1]" "用法：fingerprint [nowhere://KEY@HOST:PORT?morph=0|1]")"
  port="${BASH_REMATCH[1]}"; port="$((10#$port))"
  (( port >= 1 && port <= 65535 )) || die "$(tr_msg "Invalid port in the link" "链接中的端口无效")"
  [[ -x "$BIN_LINK" ]] || die "$(tr_msg "V3 binary missing" "V3 二进制缺失")"
  redacted="nowhere://***@${endpoint}"
  info "$(tr_msg "Inspecting the remote certificate over TCP/TLS (link redacted): ${redacted}" "正在通过 TCP/TLS 探测远端证书（链接已打码）：${redacted}")"
  fp="$(timeout 12 "$BIN_LINK" fingerprint "$url" 2>/dev/null)" || die "$(tr_msg "Remote fingerprint failed: check host/port reachability, a TCP/TLS listener, and that morph matches the Portal" "远端指纹探测失败：请检查地址/端口可达性、TCP/TLS 监听与 morph 是否与 Portal 一致")"
  fp="$(normalize_fingerprint "$fp")"
  [[ "$fp" =~ ^[0-9a-f]{64}$ ]] || die "$(tr_msg "Cannot read certificate fingerprint" "指纹读取失败")"
  printf '%s\n' "$fp"
  warn "$(tr_msg "Compare it through a trusted channel before using it as a pin or a client trust entry." "请先通过可信渠道核对该值，再配置为 pin 或加入客户端信任列表。")"
}
fingerprint_action() {
  local url="${1:-}"
  [[ -n "$url" ]] || { local_pin; return 0; }
  remote_fingerprint "$url"
}
validate_cert_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] || die "$(tr_msg "Invalid domain name: $1" "域名无效：$1")"
}
ensure_acme() {
  [[ -x "$ACME_HOME/acme.sh" && -r "$ACME_HOME/dnsapi/dns_cf.sh" ]] && return 0
  local tmp src url
  url="https://github.com/acmesh-official/acme.sh/archive/refs/tags/${ACME_VERSION}.tar.gz"
  tmp="$(mktemp -d)"; CLEANUP_PATHS+=("$tmp")
  info "$(tr_msg "Installing acme.sh ${ACME_VERSION} (pinned release tarball)" "正在安装 acme.sh ${ACME_VERSION}（固定版本 tarball）")"
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 --connect-timeout 10 --max-time 120 -o "$tmp/acme.tar.gz" "$url" || die "$(tr_msg 'acme.sh download failed' 'acme.sh 下载失败')"
  tar -xzf "$tmp/acme.tar.gz" -C "$tmp" || die "$(tr_msg 'acme.sh archive extraction failed' 'acme.sh 解压失败')"
  src="$(find "$tmp" -maxdepth 2 -type f -name acme.sh | head -n 1)"
  [[ -n "$src" ]] || die "$(tr_msg 'acme.sh not found in the archive' '压缩包中未找到 acme.sh')"
  install -d -m 700 "$ACME_HOME"
  [[ -r "$(dirname "$src")/dnsapi/dns_cf.sh" ]] || die "$(tr_msg "acme.sh archive lacks dns_cf plugin" "acme.sh 压缩包缺少 dns_cf 插件")"
  install -m 700 "$src" "$ACME_HOME/acme.sh"
  install -d -m 700 "$ACME_HOME/dnsapi"
  install -m 600 "$(dirname "$src")/dnsapi/dns_cf.sh" "$ACME_HOME/dnsapi/dns_cf.sh"
  ok "$(tr_msg "acme.sh ${ACME_VERSION} installed under $ACME_HOME" "acme.sh ${ACME_VERSION} 已安装到 $ACME_HOME")"
}
write_cert_timer() {
  local svc="${UNIT_FILE%.service}-cert-renew.service" tmr="${UNIT_FILE%.service}-cert-renew.timer"
  cat >"$svc" <<EOF
[Unit]
Description=Renew Nowhere V3 TLS certificate (acme.sh --cron)
Documentation=https://github.com/acmesh-official/acme.sh
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/flock -n -E 0 ${BUILD_LOCK_DIR%.d} ${ACME_HOME}/acme.sh --cron --home ${ACME_HOME}
EOF
  cat >"$tmr" <<EOF
[Unit]
Description=Daily Nowhere V3 certificate renewal check

[Timer]
OnCalendar=daily
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now "$tmr" >/dev/null 2>&1 || warn "$(tr_msg 'Could not enable the renewal timer; enable nowhere-v3-cert-renew.timer manually' '续期定时器启用失败；请稍后手动 systemctl enable nowhere-v3-cert-renew.timer')"
}
cert_action() {
  mutating_setup
  local u role domain token mode crt key dir rc=0
  u="$(read_url)"
  role="$(v3_url get "$u" role)"
  [[ "$role" == portal ]] || die "$(tr_msg "Certificate issuance is a Portal operation" "证书申请仅适用于 Portal 角色")"
  domain="${CERT_DOMAIN:-$PUBLIC_HOST}"
  if [[ -z "$domain" && -t 0 ]]; then
    read -r -p "$(tr_msg 'Domain for the certificate: ' '证书域名：')" domain </dev/tty || domain=""
  fi
  [[ -n "$domain" ]] || die "$(tr_msg "Pass --domain (PUBLIC_HOST is empty or not a domain)" "请用 --domain 指定域名（当前 PUBLIC_HOST 为空或不是域名）")"
  validate_cert_domain "$domain"
  if [[ "$CERT_HTTP" != 1 && -z "$CF_TOKEN" && -z "$CF_TOKEN_FILE" && -t 0 ]]; then
    mode="$(prompt_choice "$(tr_msg 'Validation: 1=Cloudflare DNS-01 (needs token) 2=HTTP-01 (needs port 80)' '验证方式：1=Cloudflare DNS-01（需Token）2=HTTP-01（需80端口）')" 1 1 2)"
    [[ "$mode" == 1 ]] || CERT_HTTP=1
  fi
  if [[ "$CERT_HTTP" == 1 ]]; then
    info "$(tr_msg "Using HTTP-01 standalone; port 80 must be reachable from the internet" "使用 HTTP-01 standalone；80 端口需从公网可达")"
  else
    token="${CF_TOKEN:-}"
    if [[ -z "$token" && -n "$CF_TOKEN_FILE" ]]; then
      [[ -r "$CF_TOKEN_FILE" ]] || die "$(tr_msg "Cannot read token file: $CF_TOKEN_FILE" "无法读取 Token 文件：$CF_TOKEN_FILE")"
      token="$(tr -d ' \t\r\n' <"$CF_TOKEN_FILE")"
    fi
    if [[ -z "$token" && -t 0 ]]; then
      read -r -s -p "$(tr_msg 'Cloudflare API Token (hidden input, Zone.DNS Edit scope): ' 'Cloudflare API Token（输入不回显，需该域 Zone.DNS 编辑权限）：')" token </dev/tty || token=""
      printf '\n' >&2
    fi
    [[ -n "$token" ]] || die "$(tr_msg "Missing Cloudflare API Token: pass --cf-token-file or run interactively" "缺少 Cloudflare API Token：请传 --cf-token-file 或交互运行")"
  fi
  begin_transaction
  ensure_acme
  if [[ -n "$CERT_EMAIL" ]]; then
    "$ACME_HOME/acme.sh" --home "$ACME_HOME" --server letsencrypt --register-account -m "$CERT_EMAIL" >/dev/null 2>&1 || warn "$(tr_msg 'Account email registration failed; continuing without it' '邮箱注册未成功；将继续申请（可不带邮箱）')"
  fi
  dir="$TLS_DIR/le.${domain}"
  crt="$dir/fullchain.pem"; key="$dir/key.pem"
  install -d -m 750 "$dir" 2>/dev/null || mkdir -p "$dir"
  chown root:"$RUN_GROUP" "$dir" 2>/dev/null || true
  info "$(tr_msg "Requesting a Let's Encrypt certificate for ${domain} ..." "正在为 ${domain} 申请 Let's Encrypt 证书 ...")"
  local -a issue_args=(--issue --server letsencrypt)
  if [[ "$CERT_HTTP" == 1 ]]; then issue_args+=(--standalone); else issue_args+=(--dns dns_cf); fi
  issue_args+=(-d "$domain")
  [[ "$CERT_FORCE" == 1 ]] && issue_args+=(--force)
  set +e
  if [[ "$CERT_HTTP" == 1 ]]; then
    "$ACME_HOME/acme.sh" --home "$ACME_HOME" "${issue_args[@]}" >/dev/null 2>&1; rc=$?
  else
    CF_Token="$token" "$ACME_HOME/acme.sh" --home "$ACME_HOME" "${issue_args[@]}" >/dev/null 2>&1; rc=$?
  fi
  set -e
  case "$rc" in
    0|2) ;;
    *) die "$(tr_msg "Certificate issuance failed (acme.sh exit $rc): check the token scope / the domain being on Cloudflare, or port 80 for --http" "证书申请失败（acme.sh 退出码 $rc）：请检查 Token 权限/域名是否在 Cloudflare，或 --http 模式的 80 端口")" ;;
  esac
  "$ACME_HOME/acme.sh" --home "$ACME_HOME" --install-cert -d "$domain" \
    --fullchain-file "$crt" --key-file "$key" \
    --reloadcmd "systemctl try-restart $SERVICE_NAME" >/dev/null 2>&1 || die "$(tr_msg 'Failed to install the certificate files' '证书文件安装失败')"
  chown root:"$RUN_GROUP" "$crt" "$key" 2>/dev/null || true
  chmod 640 "$crt" "$key"
  chmod 600 "$ACME_HOME/account.conf" 2>/dev/null || true
  u="$(v3_url rewrite-pem "$u" "$crt" "$key")"
  printf '%s\n' "$u" >"$URL_FILE.new"
  chown root:"$RUN_GROUP" "$URL_FILE.new" 2>/dev/null || true
  chmod 640 "$URL_FILE.new"
  mv -f "$URL_FILE.new" "$URL_FILE"
  systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || die "$(tr_msg 'Service restart failed after the certificate switch' '切换证书后服务重启失败')"
  wait_service 12 || die "$(tr_msg "V3 did not stay active after the certificate switch" "切换证书后 V3 未持续运行")"
  TX_COMMITTED=1
  write_cert_timer
  ok "$(tr_msg "Certificate installed: $crt" "证书已安装：$crt")"
  info "$(tr_msg 'Automatic renewal: systemd timer nowhere-v3-cert-renew (check with systemctl list-timers)' '自动续期：systemd 定时器 nowhere-v3-cert-renew（systemctl list-timers 可查）')"
  warn "$(tr_msg 'Clients that pinned the old self-signed certificate must re-import links or update their trust entry' '此前 pin 过旧自签证书的客户端需要重新导入链接或更新信任项')"
}
ensure_qrencode() {
  has_cmd qrencode && return 0
  if has_cmd apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qrencode >/dev/null 2>&1 || true
  elif has_cmd dnf; then dnf install -y -q qrencode >/dev/null 2>&1 || true
  elif has_cmd yum; then yum install -y -q qrencode >/dev/null 2>&1 || true
  elif has_cmd apk; then apk add --no-cache -q qrencode >/dev/null 2>&1 || true
  fi
  has_cmd qrencode || { warn "$(tr_msg 'qrencode is unavailable; QR output skipped (install it and rerun links)' 'qrencode 不可用，已跳过二维码（安装后重跑 links 即可显示）')"; return 1; }
  info "$(tr_msg 'qrencode installed for QR output' 'qrencode 已自动安装（用于显示二维码）')"
}
certificate_trusted_for_host() {
  local cert="$1" host="${2#[}"; host="${host%]}"
  [[ -r "$cert" && -n "$host" ]] || return 1
  local -a verify=(-purpose sslserver -untrusted "$cert")
  if python3 -c 'import ipaddress,sys;ipaddress.ip_address(sys.argv[1])' "$host" 2>/dev/null; then
    verify+=(-verify_ip "$host")
  else
    verify+=(-verify_hostname "$host")
  fi
  openssl verify "${verify[@]}" "$cert" >/dev/null 2>&1
}
show_links() {
  require_root
  [[ -n "$PUBLIC_HOST" ]] || die "$(tr_msg "Set --public-host first" "请用 --public-host 指定公网地址")"
  local u pin shares line
  u="$(read_url)"; pin="$(local_pin)"
  if [[ "$(v3_url get "$u" tls)" == 2 ]] && certificate_trusted_for_host "$(v3_url get "$u" crt)" "$PUBLIC_HOST"; then
    # Normal CA/hostname verification survives automated certificate renewal.
    pin=""
  fi
  v3_url links "$u" "$PUBLIC_HOST" "$pin"
  shares="$(v3_url shares "$u" "$PUBLIC_HOST" "$NODE_NAME")"
  printf '%s\n' "$(tr_msg 'Generic share links (Anywhere etc.):' '通用分享链接（Anywhere 等客户端）：')"
  printf '%s\n' "$shares"
  warn "$(tr_msg "If the tcp/udp variants share one port, import only ONE link - they differ only in the carrier." "若 tcp/udp 两条共用同一端口，任选一条导入即可——两者仅 carrier 参数不同。")"
  warn "$(tr_msg "Links contain a shared key; do not disclose them. NW3 clients only." "链接含密钥勿外传；仅供支持 NW3 的客户端使用。")"
  warn "$(tr_msg "Share links cannot carry pin. For self-signed certificates, add the SHA-256 from fingerprint to the client's trust list." "通用分享链接不能携带 pin；自签证书请将 fingerprint 的 SHA-256 添加到客户端信任列表。")"
  if ensure_qrencode; then
    while IFS= read -r line; do qrencode -t ANSIUTF8 "$line" || warn "$(tr_msg "QR rendering failed" "二维码显示失败")"; done <<<"$shares"
  fi
}
rollback_action() {
  mutating_setup
  local d target=''
  begin_transaction
  while IFS= read -r d; do
    [[ "$d" == "$OLD_TARGET" || ! -x "$d/nowhere" ]] && continue
    target="$d"; break
  done < <(ls -1dt "$RELEASES_DIR"/v3.* 2>/dev/null || true)
  [[ -n "$target" ]] || die "$(tr_msg "No previous V3 release is available" "没有可回滚的 V3 版本")"
  ln -sfn "$target" "$CURRENT_LINK"
  VERSION="$(sed -n 's/^tag: //p' "$target/RELEASE-INFO")"
  validate_version_arg "$VERSION"; write_meta; activate
  ok "$(tr_msg "V3 binary rolled back; config is not converted across versions" "V3 二进制已回滚；配置不跨版本转换")"
}
backup_action() {
  require_root; acquire_build_lock
  local out="${BACKUP_PATH:-/root/nowhere-v3-backup-$(date +%Y%m%d-%H%M%S).tar.gz}"
  [[ -d "$CONFIG_DIR" ]] || die "$(tr_msg "No V3 configuration" "没有 V3 配置")"
  [[ ! -e "$out" ]] || die "$(tr_msg "Backup target exists; refusing overwrite" "备份目标已存在，拒绝覆盖")"
  case "$(realpath -m "$out")" in "$CONFIG_DIR"/*) die "$(tr_msg "Backup must be outside the config directory" "备份必须位于配置目录之外")" ;; esac
  tar -czf "$out" -C "$(dirname "$CONFIG_DIR")" "$(basename "$CONFIG_DIR")"
  chmod 600 "$out"; ok "$(tr_msg "Backup saved to $out (contains keys; keep it private)" "已备份到 $out（包含密钥，请妥善保管）")"
}
uninstall_action() {
  mutating_setup
  if [[ "$ASSUME_YES" != 1 ]]; then
    local answer
    read -r -p "$(tr_msg 'Confirm V3 removal: type REMOVE-V3: ' '确认卸载V3？输入REMOVE-V3：')" answer || return 0
    [[ "$answer" == REMOVE-V3 ]] || return 0
  fi
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable --now "${UNIT_FILE%.service}-cert-renew.timer" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE" "$LAUNCHER" "$BIN_LINK"
  rm -f "${UNIT_FILE%.service}-cert-renew.service" "${UNIT_FILE%.service}-cert-renew.timer"
  rm -rf "$INSTALL_ROOT"
  if [[ "$PURGE" == 1 ]]; then
    rm -rf "$CONFIG_DIR"
    if [[ -f "$SHORTCUT_PATH" ]] && grep -qs 'nowhere-v3-shortcut' "$SHORTCUT_PATH"; then rm -f "$SHORTCUT_PATH"; fi
  fi
  systemctl daemon-reload
  ok "$(tr_msg "V3 removed; configuration is retained unless --purge was used; V2 is unaffected" "V3 已卸载；默认保留配置，V2 不受影响")"
}
doctor_action() {
  require_root; require_systemd
  v3_url validate "$(read_url)"
  [[ -x "$CURRENT_LINK/nowhere" ]] || die "$(tr_msg "V3 binary missing" "V3 二进制缺失")"
  "$CURRENT_LINK/nowhere" --version
  systemctl is-active --quiet "$SERVICE_NAME" || die "$(tr_msg "V3 service is not active" "V3 服务未运行")"
  local u; u="$(read_url)"
  if [[ "$(v3_url get "$u" tls)" == 2 ]]; then
    runuser -u "$RUN_USER" -- test -r "$(v3_url get "$u" crt)" || die "$(tr_msg "Service account cannot read the certificate" "服务账户不能读取证书")"
    runuser -u "$RUN_USER" -- test -r "$(v3_url get "$u" key)" || die "$(tr_msg "Service account cannot read the private key" "服务账户不能读取私钥")"
  fi
  if [[ "$DOCTOR_PROBE" == 1 ]]; then
    local probe_rc
    set +e
    ( set -e; trap finish EXIT; probe_action )
    probe_rc=$?
    set -e
    [[ "$probe_rc" == 0 ]] || warn "$(tr_msg 'Optional probe failed; base doctor checks passed' '可选probe失败；基础doctor检查已通过')"
  fi
  ok "$(tr_msg "Basic checks passed; this does not prove Egress online or target reachability; run probe separately" "基础检查通过；不代表 Egress 在线或目标可达，请另做 probe")"
}

# Operator prompts always go to stderr/tty; captured defaults never include secrets.
prompt_value() {
  local label="$1" default="${2:-}" value secret="${3:-0}"
  if [[ "$secret" == 1 ]]; then
    if ! read -r -s -p "$label [$(tr_msg 'Enter keeps/generates a value' '回车保留或自动生成')]: " value </dev/tty; then value="$default"; else printf '\n' >&2; fi
  else
    if ! read -r -p "$label [$default]: " value </dev/tty; then value="$default"; fi
  fi
  printf '%s' "${value:-$default}"
}
prompt_choice() {
  local label="$1" default="$2" value allowed entry n input="${NOWHERE_V3_PROMPT_TTY:-/dev/tty}"
  shift 2
  local -a opts=("$@"); n=${#opts[@]}
  while true; do
    if ! read -r -p "$label [$default]: " value <"$input"; then
      for allowed in "${opts[@]}"; do [[ "$default" != "$allowed" ]] || { printf '%s' "$default"; return 0; }; done
      die "$(tr_msg 'No terminal and no valid default' '无终端且没有合法默认值')"
    fi
    value="${value:-$default}"
    for allowed in "${opts[@]}"; do [[ "$value" != "$allowed" ]] || { printf '%s' "$value"; return 0; }; done
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      entry=$((10#$value))
      if (( entry >= 1 && entry <= n )); then printf '%s' "${opts[entry - 1]}"; return 0; fi
    fi
    warn "$(tr_msg "Invalid choice; enter 1-$n or one of: $*" "无效选项；请输入1-$n的编号，或原值：$*")"
  done
}
generate_key() { python3 -c 'import secrets;print(secrets.token_hex(16))'; }
prompt_shared_key() {
  local value fallback="${KEY:-}"
  [[ -n "$fallback" ]] || fallback="$(generate_key)"
  while true; do
    if ! read -r -s -p "$(tr_msg 'Shared key (Enter keeps/generates one)' '共享密钥（回车保留或自动生成）'): " value </dev/tty; then
      [[ "$fallback" =~ ^[0-9a-f]{32}$ ]] || die "$(tr_msg 'No terminal and no valid shared key' '无终端且没有合法共享密钥')"
      KEY="$fallback"; return 0
    fi
    printf '\n' >&2; value="${value:-$fallback}"
    if [[ "$value" =~ ^[0-9a-f]{32}$ ]]; then KEY="$value"; return 0; fi
    warn "$(tr_msg 'Shared key must be exactly 32 lowercase hex characters' '共享密钥必须为32位小写十六进制')"
  done
}
load_config_fields() {
  local u
  u="$(read_url)"
  ROLE="$(v3_url get "$u" role)"; KEY="$(v3_url get "$u" shared_key)"
  ENDPOINT="$(v3_url get "$u" endpoint)"; MORPH="$(v3_url get "$u" morph)"; MORPH="${MORPH:-1}"
  OUT="$(v3_url get "$u" out)"; OUT="${OUT:-direct}"
  INGRESS="$(v3_url get "$u" in)"; INGRESS="${INGRESS:-127.0.0.1:1083}"
  PIN="$(v3_url get "$u" pin)"; SNI="$(v3_url get "$u" sni)"
  DIAL="$(v3_url get "$u" dial)"; DIAL4="$(v3_url get "$u" dial4)"; DIAL6="$(v3_url get "$u" dial6)"
  # Advanced limits are configured through --url-file; carry them across a
  # wizard/CLI reconfigure instead of silently dropping them from the rebuilt URL.
  RATE="$(v3_url get "$u" rate)"; ETAR="$(v3_url get "$u" etar)"
}
installation_wizard() {
  local preset port udp tlsmode exitmode carrier remote previous_role="$ROLE"
  [[ -n "$URL_INPUT" ]] && return 0
  ROLE="$(prompt_choice "$(tr_msg 'Role: 1=portal 2=vector 3=egress' '角色：1=portal 2=vector 3=egress')" "$ROLE" portal vector egress)"
  if [[ "$ROLE" != "$previous_role" ]]; then ENDPOINT=''; DIAL=''; DIAL4=''; DIAL6=''; PIN=''; SNI=''; CERT=''; TLS_KEY=''; OUT=direct; fi
  prompt_shared_key
  if [[ "$ROLE" == portal ]]; then
    preset=both; [[ -z "$ENDPOINT" ]] || preset=manual
    preset="$(prompt_choice "$(tr_msg 'Listener preset: 1=both (shared port) 2=tcp (TCP only) 3=udp (UDP only) 4=split (separate ports) 5=manual' '监听预设：1=both（共用端口）2=tcp（仅TCP）3=udp（仅UDP）4=split（分端口）5=manual（手动）')" "$preset" both tcp udp split manual)"
    if [[ "$preset" == manual ]]; then
      ENDPOINT="$(prompt_value "$(tr_msg 'Listen endpoint' '监听端点')" "${ENDPOINT:-*:2083}")"
    else
      port="$(prompt_value "$(tr_msg 'Primary port' '主端口')" 2083)"
      case "$preset" in
        both) ENDPOINT="*:$port" ;;
        tcp|udp) ENDPOINT="*/$preset:$port" ;;
        split) udp="$(prompt_value "$(tr_msg 'UDP port' 'UDP端口')" 2084)"; ENDPOINT="*/tcp:$port/udp:$udp" ;;
      esac
    fi
    tlsmode="$(prompt_choice "$(tr_msg 'TLS mode: 1=managed (persistent PEM) 2=supplied (own PEM)' 'TLS 模式：1=managed（持久PEM）2=supplied（自备PEM）')" managed managed supplied)"
    if [[ "$tlsmode" == supplied ]]; then
      CERT="$(prompt_value "$(tr_msg 'Certificate PEM path' '证书PEM路径')" "$CERT")"
      TLS_KEY="$(prompt_value "$(tr_msg 'Private key PEM path' '私钥PEM路径')" "$TLS_KEY")"
      [[ -n "$CERT" && -n "$TLS_KEY" ]] || die "$(tr_msg 'Certificate and private key are required' '必须提供证书与私钥')"
    fi
    exitmode="$OUT"; [[ "$exitmode" == direct || "$exitmode" == egress ]] || exitmode=socks
    exitmode="$(prompt_choice "$(tr_msg 'Output: 1=direct 2=socks (upstream SOCKS) 3=egress (remote exit)' '出口：1=direct（直连）2=socks（上游SOCKS）3=egress（远程出口）')" "$exitmode" direct socks egress)"
    if [[ "$exitmode" == socks ]]; then
      OUT="$(prompt_value "$(tr_msg 'SOCKS upstream (input hidden)' 'SOCKS上游（隐藏输入）')" "${OUT/direct/127.0.0.1:1080}" 1)"
    else OUT="$exitmode"; fi
    if [[ "$OUT" == egress ]]; then DIAL='' DIAL4='' DIAL6=''; fi
    PUBLIC_HOST="$(prompt_value "$(tr_msg 'Public host for links' '链接使用的公网地址')" "$PUBLIC_HOST")"
  else
    remote="$(prompt_value "$(tr_msg 'Portal host (bracket IPv6)' 'Portal地址（IPv6加方括号）')" 127.0.0.1)"
    port="$(prompt_value "$(tr_msg 'Portal port' 'Portal端口')" 2083)"
    if [[ "$ROLE" == vector ]]; then
      carrier="$(prompt_choice "$(tr_msg 'Carrier: 1=tcp 2=udp' '载波：1=tcp 2=udp')" tcp tcp udp)"
      INGRESS="$(prompt_value "$(tr_msg 'Local SOCKS ingress (input hidden)' '本地SOCKS入口（隐藏输入）')" "$INGRESS" 1)"
    else carrier=udp; fi
    ENDPOINT="$(prompt_value "$(tr_msg 'Portal endpoint' 'Portal端点')" "${ENDPOINT:-$remote/$carrier:$port}")"
    SNI="$(prompt_value SNI "$SNI")"
    PIN="$(prompt_value "$(tr_msg 'Trusted SHA-256 pin; empty uses system CA' '可信SHA-256 pin；空值使用系统CA')" "$PIN" 1)"
    if [[ "$ROLE" == egress ]]; then
      DIAL="$(prompt_value "$(tr_msg 'Source dial (blank omits)' '出站源dial（空值省略）')" "$DIAL")"
      if [[ -z "$DIAL" ]]; then
        DIAL4="$(prompt_value "$(tr_msg 'IPv4 source dial4 (blank omits)' 'IPv4出站源dial4（空值省略）')" "$DIAL4")"
        DIAL6="$(prompt_value "$(tr_msg 'IPv6 source dial6 (blank omits)' 'IPv6出站源dial6（空值省略）')" "$DIAL6")"
      else DIAL4='' DIAL6=''; fi
    fi
    warn "$(tr_msg 'Clients must use the Portal shared key and trust its certificate; generated client defaults alone cannot connect to an existing Portal.' '客户端必须与Portal使用相同密钥并信任其证书；客户端自动生成的默认密钥不能直接连接已有Portal。')"
  fi
  MORPH="$(prompt_choice "$(tr_msg 'Morph (must match peers; 0=off 1=on)' 'Morph（必须与对端一致；0=关 1=开）')" "$MORPH" 0 1)"
}

save_language() {
  require_root; acquire_build_lock
  [[ "$LANG_CODE" == zh || "$LANG_CODE" == en ]] || die 'LANG: zh|en'
  local tmp
  install -d -m 750 "$CONFIG_DIR"
  tmp="$(mktemp "$CONFIG_DIR/.language.XXXXXX")"; CLEANUP_PATHS+=("$tmp")
  if [[ -f "$META_FILE" ]]; then
    awk -v lang="$LANG_CODE" '/^LANG=/ {next} {print} END {print "LANG=" lang}' "$META_FILE" >"$tmp"
    chmod --reference="$META_FILE" "$tmp"; chown --reference="$META_FILE" "$tmp"
  else printf 'LANG=%s\n' "$LANG_CODE" >"$tmp"; chmod 600 "$tmp"; fi
  mv -f "$tmp" "$META_FILE"
}

fetch_versions() {
  local tmp page count tag
  local -a tags=()
  require_command curl; require_command python3
  tmp="$(mktemp)"; CLEANUP_PATHS+=("$tmp")
  for ((page=1;page<=20;page++)); do
    curl_github "https://api.github.com/repos/${UPSTREAM_REPO}/releases?per_page=100&page=$page" "$tmp" || die "$(tr_msg 'Cannot fetch releases' '无法获取发布列表')"
    count="$(python3 - "$tmp" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));assert isinstance(r,list);print(len(r))
PY
)" || die "$(tr_msg 'Invalid release metadata' '发布元数据无效')"
    while IFS= read -r tag; do [[ -z "$tag" ]] || tags+=("$tag"); done < <(python3 - "$tmp" <<'PY'
import json,re,sys
for r in json.load(open(sys.argv[1])):
    t=r.get('tag_name','')
    if re.fullmatch(r'v3\.\d+\.\d+',t) and not r.get('draft') and not r.get('prerelease'): print(t)
PY
)
    if ((count<100)); then
      ((${#tags[@]}>0)) || die "$(tr_msg 'No stable V3 release found' '未找到稳定V3版本')"
      printf '%s\n' "${tags[@]}" | python3 -c 'import sys;print("\n".join(sorted(set(sys.stdin.read().split()),key=lambda v:tuple(map(int,v[1:].split("."))),reverse=True)))'
      return 0
    fi
  done
  die "$(tr_msg 'Release scan limit reached; specify a stable tag' '发布扫描达到上限，请指定稳定标签')"
}
versions_action() { fetch_versions; }
select_version_install() {
  local listed choice i=0
  local -a available=()
  listed="$(fetch_versions)"
  while IFS= read -r choice; do available+=("$choice"); done <<<"$listed"
  for choice in "${available[@]}"; do i=$((i+1)); printf '%d) %s\n' "$i" "$choice"; done
  choice="$(prompt_value "$(tr_msg 'Version number from list' '版本列表序号')" 1)"
  [[ "$choice" =~ ^[0-9]{1,4}$ ]] && ((10#$choice>=1 && 10#$choice<=${#available[@]})) || die "$(tr_msg 'Invalid selection' '选择无效')"
  VERSION="${available[$((10#$choice-1))]}"; ACTION=install
  if [[ ! -s "$URL_FILE" ]]; then installation_wizard; fi
  install_action
}
self_update() {
  [[ -n "$SELF_UPDATE_URL" ]] || { info "$(tr_msg 'Self-update is disabled (NOWHERE_V3_SELF_URL is empty).' '自更新已禁用（NOWHERE_V3_SELF_URL为空）。')"; return 0; }
  require_command curl; require_command python3
  local tmp remote_ver remote_channel self staging backup
  tmp="$(mktemp)"; CLEANUP_PATHS+=("$tmp")
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 --connect-timeout 10 --max-time 30 -o "$tmp" "$SELF_UPDATE_URL" 2>/dev/null || die "$(tr_msg 'Manager download failed; local file unchanged' '管理脚本下载失败，本地文件未改变')"
  bash -n "$tmp" 2>/dev/null || die "$(tr_msg 'Downloaded manager has syntax errors' '下载的管理脚本存在语法错误')"
  remote_ver="$(sed -n 's/^readonly SCRIPT_VERSION="\([0-9][0-9.]*\)"$/\1/p' "$tmp")"
  remote_channel="$(sed -n 's/^readonly SCRIPT_CHANNEL="\([^"]*\)"$/\1/p' "$tmp")"
  [[ "$remote_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$remote_channel" == v3 ]] || die "$(tr_msg 'Invalid manager version or channel' '管理脚本版本或通道无效')"
  version_ge "$remote_ver" "$SCRIPT_VERSION" || die "$(tr_msg 'Refusing manager downgrade' '拒绝降级管理脚本')"
  [[ "$remote_ver" != "$SCRIPT_VERSION" ]] || { info "$(tr_msg 'Manager already up to date' '管理脚本已是最新')"; install_shortcut; return 0; }
  [[ "$ASSUME_YES" == 1 ]] || prompt_confirm "$(tr_msg "Update manager $SCRIPT_VERSION -> $remote_ver?" "更新管理脚本 $SCRIPT_VERSION -> $remote_ver？")" || return 0
  self="$(readlink -f "$MANAGER_FILE")"
  [[ -f "$self" && -w "$self" && -w "$(dirname "$self")" ]] || die "$(tr_msg 'Manager file/directory is not writable' '管理脚本或目录不可写')"
  staging="$(mktemp "${self}.update.XXXXXX")"; CLEANUP_PATHS+=("$staging")
  backup="$(mktemp "${self}.bak.XXXXXX")"
  cp -p -- "$self" "$backup"
  cp -- "$tmp" "$staging"; chmod --reference="$self" "$staging"; chown --reference="$self" "$staging"
  mv -f -- "$staging" "$self"
  ok "$(tr_msg "Manager updated; backup: $backup. Restart the manager to load it." "管理脚本已更新；备份：$backup。重新启动管理器后生效。")"
  install_shortcut
}

status_panel() {
  local active enabled core role='-' ep='-' morph='-' u
  active="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"; active="${active:-unknown}"
  enabled="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)"; enabled="${enabled:-unknown}"
  core='-'
  [[ ! -r "$CURRENT_LINK/RELEASE-INFO" ]] || core="$(sed -n 's/^tag: //p' "$CURRENT_LINK/RELEASE-INFO")"
  if [[ -r "$URL_FILE" ]]; then
    u="$(read_url)"
    if v3_url validate "$u" >/dev/null 2>&1; then
      role="$(v3_url get "$u" role)"; ep="$(v3_url get "$u" endpoint)"; morph="$(v3_url get "$u" morph)"; morph="${morph:-1}"
    fi
  fi
  printf 'Nowhere V3 %s | %s | Core %s\n' "$SCRIPT_VERSION" "$SCRIPT_CHANNEL" "$core"
  printf '%s: %s / %s\nRole: %s | Endpoint: %s | Morph: %s\n' "$(tr_msg 'Service active/enabled' '服务运行/开机启动')" "$active" "$enabled" "$role" "$ep" "$morph"
}
redact_stream() {
  python3 -c '
import re,sys
for line in sys.stdin:
 line=re.sub(r"(?:portal|vector|egress|nowhere)://[^\s]+", "[URL REDACTED]", line)
 line=re.sub(r"(?i)\b[0-9a-f]{32,64}\b", "***", line)
 print(line,end="",flush=True)
'
}
show_status() {
  status_panel
  # systemctl status includes the process command line; redact it before display.
  systemctl status "$SERVICE_NAME" --no-pager --lines=0 2>&1 | redact_stream || true
}
telemetry_action() {
  require_root
  runuser -u "$RUN_USER" -- env TMPDIR=/run/nowhere-v3 "$BIN_LINK" status 2>&1 | redact_stream
}
probe_action() {
  require_root
  local u role link pin output rc result
  [[ -x "$BIN_LINK" ]] || die "$(tr_msg 'V3 binary missing' 'V3二进制缺失')"
  # Restrict target to a host:port without any credential/query component.
  python3 - "$PROBE_TARGET" <<'PY' >/dev/null 2>&1 || die "$(tr_msg 'Probe target must be HOST:PORT' '探测目标必须是HOST:PORT')"
import sys,re
s=sys.argv[1];m=re.fullmatch(r'(?:\[[0-9a-fA-F:]+\]|[A-Za-z0-9._-]+):([0-9]{1,5})',s)
assert m and 1<=int(m[1])<=65535
PY
  u="$(read_url)"; role="$(v3_url get "$u" role)"
  case "$role" in
    portal)
      [[ -n "$PUBLIC_HOST" ]] || die "$(tr_msg 'Set --public-host before probing a Portal' '探测Portal前请先设置--public-host')"
      pin="$(local_pin)"; link="$(v3_url probe-link "$u" "$PUBLIC_HOST" "$pin")" ;;
    vector) link="$u" ;;
    egress) die "$(tr_msg 'Probe requires a Vector or Portal; Egress is unsupported' 'probe需从Vector或Portal发起，不支持Egress角色')" ;;
  esac
  printf '%s\n' "$(v3_url redact "$link")"
  if output="$(timeout 30 "$BIN_LINK" probe "$link" "$PROBE_TARGET" 2>&1)"; then rc=0; else rc=$?; fi
  # Accept only an enumerated result word; never echo untrusted core diagnostics.
  result="$(printf '%s' "$output" | python3 -c '
import re,sys
s=sys.stdin.read();m=re.search(r"(?im)^\s*Result\s*[:=]?\s*(OK|READY|DIAL_FAILED|TRANSPORT_FAILED|AUTH_FAILED|AUTHENTICATION_FAILED|CLEANUP_FAILED|INVALID_REQUEST|FLOW_LIMIT|TIMEOUT|BUSY|UNAVAILABLE|EGRESS_OFFLINE|INTERNAL_ERROR)\b",s)
print(m[1] if m else "")')"
  if [[ "$rc" == 0 ]]; then printf 'Result OK\n'; else printf 'Result %s\n' "${result:-FAILED}"; fi
  return "$rc"
}
usage() {
  if [[ "$LANG_CODE" == zh ]]; then
    cat <<EOF
Nowhere V3 管理器 ${SCRIPT_VERSION}（通道 ${SCRIPT_CHANNEL}；Linux + systemd，Bash >=4.3）
默认固定 v3.0.0；--version latest-v3 为显式跟进。默认Portal 2083 / SOCKS 1083。
独立账户/服务 nowhere-v3；配置 /etc/nowhere-v3；程序 /opt/nowhere-v3。
不修改V1/V2，不自动开放防火墙。新Portal使用持久PEM；同角色配置复用证书。
用法：sudo bash nowhere-v3.sh [ACTION] [选项]（已是 root 可省略 sudo）；无参数进入循环菜单。

 install                 安装官方校验版；交互向导 / --yes 自动部署
 upgrade                 仅升级二进制（默认固定版本）
 configure               修改配置；无配置参数时进入向导
 validate                只校验 --url/--url-file，无需root
 versions / check-updates 列出所有稳定V3（不足10个列出现有全部）/最新版本
 self-update             只更新管理脚本；NOWHERE_V3_SELF_URL为空时禁用
 generate-key            输出一行32位小写hex，不附加文字
 probe [HOST:PORT]        TCP Flow探测，默认example.com:443，URL打码
 links / fingerprint     原生+通用链接 / 证书SHA-256（秘密输出；fingerprint 无参数=本机，带 nowhere:// 链接=远端 TCP/TLS）
 status / telemetry      状态面板 / 只读统计
 doctor [--probe [目标]]  基础检查；可选探测失败仅警告
 logs / start / stop / restart / clean-releases
 backup [路径] / rollback / uninstall [--purge] / language
 cert [--domain 域名] [--cf-token-file 文件] [--http] 申请/续期LE证书（仅Portal；默认CF DNS-01）

 --role portal|vector|egress --key KEY --endpoint HOST:PORT或carrier路径
 --url 'V3 URL' --url-file FILE（避免密钥写入shell历史）
 --public-host HOST --name NAME --morph 0|1（默认1）
 --out direct|egress|SOCKS地址 --in SOCKS入口（默认127.0.0.1:1083）
 --pin 64位小写hex --sni DNS --cert PEM --tls-key PEM
 --dial IP|auto --dial4 IP|auto --dial6 IP|auto（前者与后两者互斥）
 --memory-profile memory|balanced|throughput --morph-prelude low7|full8
 --version v3.x.y|latest-v3 --libc auto|gnu|musl --keep-releases 0..20
 --lang zh|en（CLI > NOWHERE_V3_LANG > manager.conf > 中文）
 --yes / -y；--wizard；--allow-role-switch（明确允许角色切换）

language --lang zh|en 保存语言；修改类命令的显式--lang也保存。
help/validate/generate-key/self-update只读或独立操作，不修改服务偏好。
高级rate/etar使用--url-file；不接受NW2 socks/next/up/down/mux/log。
安装/重配或自更新成功后生成快捷命令 nh（打开本菜单；参数透传，如 nh status）。
向导选项可用编号（1/2/3）选择；确认提示支持 y/n（是/否）。
Egress使用QUIC；Portal out=egress要求UDP且禁止dial*；Egress自身可使用dial*。
EOF
  else
    cat <<EOF
Nowhere V3 Manager ${SCRIPT_VERSION} (channel ${SCRIPT_CHANNEL}; Linux + systemd, Bash >=4.3)
Pinned core v3.0.0; --version latest-v3 explicitly follows releases. Portal 2083 / SOCKS 1083.
Dedicated account/service nowhere-v3; config /etc/nowhere-v3; binaries /opt/nowhere-v3.
No V1/V2 changes or firewall edits. New Portals use persistent PEM; same-role configure reuses it.
Usage: sudo bash nowhere-v3.sh [ACTION] [options] (omit sudo when already root); no arguments opens the looping menu.

 install                 Verified official binary; wizard / --yes unattended
 upgrade                 Binary-only upgrade (pinned default)
 configure               Configure; opens wizard without configuration arguments
 validate                Validate --url/--url-file; no root needed
 versions / check-updates All stable V3 tags (all available if fewer than 10) / latest
 self-update             Manager only; empty NOWHERE_V3_SELF_URL disables it
 generate-key            Exactly one line of 32 lowercase hex characters
 probe [HOST:PORT]        TCP Flow probe; default example.com:443; URL redacted
 links / fingerprint     Native+share links / certificate SHA-256 (secret output; fingerprint: no arg=local, nowhere:// link=remote TCP/TLS)
 status / telemetry      Status panel / read-only statistics
 doctor [--probe [target]] Basic checks; optional probe failure is a warning
 logs / start / stop / restart / clean-releases
 backup [path] / rollback / uninstall [--purge] / language
 cert [--domain D] [--cf-token-file F] [--http] Issue/renew a LE certificate (Portal only; default CF DNS-01)

 --role portal|vector|egress --key KEY --endpoint HOST:PORT or carrier path
 --url 'V3 URL' --url-file FILE (avoids shared keys in shell history)
 --public-host HOST --name NAME --morph 0|1 (default 1)
 --out direct|egress|SOCKS-address --in SOCKS-ingress (default 127.0.0.1:1083)
 --pin 64-lowercase-hex --sni DNS --cert PEM --tls-key PEM
 --dial IP|auto --dial4 IP|auto --dial6 IP|auto (dial excludes dial4/dial6)
 --memory-profile memory|balanced|throughput --morph-prelude low7|full8
 --version v3.x.y|latest-v3 --libc auto|gnu|musl --keep-releases 0..20
 --lang zh|en (CLI > NOWHERE_V3_LANG > manager.conf > Chinese)
 --yes / -y; --wizard; --allow-role-switch (explicit role-switch consent)

language --lang zh|en persists the language; explicit --lang on mutations is saved too.
help/validate/generate-key/self-update do not change service preferences.
Advanced rate/etar: use --url-file. NW2 socks/next/up/down/mux/log are rejected.
Install, configure or self-update create the shortcut nh (opens this menu; arguments pass through, e.g. nh status).
Wizard choices accept numbers (1/2/3); confirmations accept y/n (yes/no).
Egress uses QUIC. Portal out=egress requires UDP and forbids dial*; Egress itself allows dial*.
EOF
  fi
}
menu_install() {
  local requested="$1"
  ACTION=install
  if [[ -s "$URL_FILE" ]]; then
    if prompt_confirm "$(tr_msg 'Existing instance: reconfigure with the wizard? No updates only the binary.' '已有实例：使用向导重配？否将仅重装二进制。')"; then
      load_config_fields; ROLE="$requested"; ENDPOINT=''; installation_wizard; REINSTALL_MODE=1; configure_action
    else install_action; fi
  else ROLE="$requested"; installation_wizard; install_action; fi
}
menu() {
  local choice rc
  while true; do
    status_panel
    printf '%s\n' "$(tr_msg '--- Install / configuration ---' '--- 安装与配置 ---')"
    printf '%s\n' \
      "1. $(tr_msg 'Install/reinstall Portal (wizard)' '安装/重装Portal（向导）')" \
      "2. $(tr_msg 'Install/reinstall Vector (wizard)' '安装/重装Vector（向导）')" \
      "3. $(tr_msg 'Install/reinstall Egress (wizard)' '安装/重装Egress（向导）')" \
      "4. $(tr_msg 'Configure instance' '修改配置')" \
      "5. $(tr_msg 'Select a stable version to install' '指定稳定版本安装')" \
      "6. $(tr_msg 'Upgrade binary: pinned/latest-v3' '升级二进制：固定/latest-v3')" \
      "$(tr_msg '--- Service / diagnostics ---' '--- 服务与诊断 ---')" \
      "7. $(tr_msg 'Start service' '启动服务')" "8. $(tr_msg 'Stop service' '停止服务')" "9. $(tr_msg 'Restart service' '重启服务')" \
      "10. $(tr_msg 'Status and telemetry' '状态与统计')" "11. $(tr_msg 'Client links' '客户端链接')" \
      "12. $(tr_msg 'Certificate fingerprint' '证书指纹')" "13. $(tr_msg 'Generate shared key' '生成共享密钥')" \
      "14. $(tr_msg 'TCP Flow probe' 'TCP Flow探测')" "15. $(tr_msg 'Live logs' '实时日志')" \
      "$(tr_msg '--- Maintenance ---' '--- 维护 ---')" \
      "16. $(tr_msg 'Health checks' '健康检查')" "17. $(tr_msg 'Prune old releases' '清理旧Release')" \
      "18. $(tr_msg 'Backup configuration' '备份配置')" "19. $(tr_msg 'Rollback binary' '回滚二进制')" \
      "20. $(tr_msg 'Uninstall (config retained by default)' '卸载（默认保留配置）')" \
      "21. $(tr_msg 'Change and save language' '切换并保存语言')" "22. $(tr_msg 'Update manager script' '更新管理脚本')" \
      "$(tr_msg '--- Certificate ---' '--- 证书 ---')" \
      "23. $(tr_msg 'Issue/renew a Let'\''s Encrypt certificate' '申请/续期 TLS 证书（Let'\''s Encrypt）')" \
      "0/q. $(tr_msg 'Exit' '退出')"
    if ! read -r -p "$(tr_msg 'Choice [0-23]: ' '请输入选项 [0-23]：')" choice </dev/tty; then return 0; fi
    [[ "$choice" != 0 && "$choice" != q ]] || return 0
    set +e
    (
      set -Eeuo pipefail
      trap finish EXIT
      case "$choice" in
        1) menu_install portal ;; 2) menu_install vector ;; 3) menu_install egress ;;
        4) load_config_fields; installation_wizard; configure_action ;;
        5) select_version_install ;;
        6) VERSION="$(prompt_choice "$(tr_msg "Core version: 1=$DEFAULT_CORE_VERSION 2=latest-v3" "内核版本：1=$DEFAULT_CORE_VERSION 2=latest-v3")" "$DEFAULT_CORE_VERSION" "$DEFAULT_CORE_VERSION" latest-v3)"; ACTION=upgrade; install_action ;;
        7|8|9) mutating_setup; case "$choice" in 7) systemctl start "$SERVICE_NAME" ;; 8) systemctl stop "$SERVICE_NAME" ;; 9) systemctl restart "$SERVICE_NAME" ;; esac ;;
        10) show_status; telemetry_action ;;
        11) show_links ;; 12) require_root; local_pin; info "$(tr_msg 'Remote: fingerprint nowhere://KEY@HOST:PORT?morph=0|1' '远端：fingerprint nowhere://KEY@HOST:PORT?morph=0|1')" ;; 13) generate_key ;;
        14) PROBE_TARGET="$(prompt_value "$(tr_msg 'Probe target' '探测目标')" "$PROBE_TARGET")"; probe_action ;;
        15) require_root; journalctl -u "$SERVICE_NAME" -f 2>&1 | redact_stream ;;
        16) doctor_action ;; 17) cleanup_old_releases ;; 18) backup_action ;; 19) rollback_action ;;
        20) PURGE=0; if prompt_confirm "$(tr_msg 'Also delete configuration and keys?' '同时删除配置和密钥？')"; then PURGE=1; fi; uninstall_action ;;
        21) LANG_CODE="$(prompt_choice "$(tr_msg 'Language: 1=zh 2=en' '语言：1=zh 2=en')" "$LANG_CODE" zh en)"; save_language ;;
        22) self_update ;;
        23) cert_action ;;
        *) warn "$(tr_msg 'Invalid choice; enter 0-23 or q' '无效选项；请输入 0-23 或 q')" ;;
      esac
    )
    rc=$?
    set -e
    if [[ "$rc" == 0 && "$choice" =~ ^([1-6]|21)$ ]]; then load_meta; fi
    [[ "$rc" == 0 ]] || warn "$(tr_msg "Operation failed (exit $rc); see message above" "操作失败（退出码$rc），请查看上方提示")"
    if ! read -r -p "$(tr_msg 'Press Enter to return...' '按回车返回…')" choice </dev/tty; then return 0; fi
  done
}
main() {
  load_meta
  LANG_CODE="${NOWHERE_V3_LANG:-$LANG_CODE}"
  if (($#)) && [[ "$1" != --* && "$1" != -h ]]; then ACTION="$1"; shift; fi
  # A reconfigure must keep existing settings that the caller did not override:
  # load them before parsing so explicit CLI arguments below still win. Runs as
  # root against a valid existing config only, so a non-root call still reaches
  # the clean require-root error in the action itself.
  if [[ "$ACTION" == configure && "$(id -u)" -eq 0 && -s "$URL_FILE" ]]; then
    if v3_url validate "$(head -n 1 "$URL_FILE")" >/dev/null 2>&1; then load_config_fields; fi
  fi
  while (($#)); do
    case "$1" in
      --version) VERSION="${2:?}"; shift 2 ;;
      --role|--type) ROLE="${2:?}"; ROLE_SET=1; shift 2 ;;
      --key) KEY="${2:?}"; shift 2 ;;
      --endpoint) ENDPOINT="${2:?}"; shift 2 ;;
      --url) URL_INPUT="${2:?}"; shift 2 ;;
      --url-file) URL_INPUT="$(cat -- "${2:?}")"; shift 2 ;;
      --public-host) PUBLIC_HOST="${2:?}"; shift 2 ;;
      --name) NODE_NAME="${2:?}"; shift 2 ;;
      --morph) MORPH="${2:?}"; shift 2 ;;
      --out) OUT="${2:?}"; shift 2 ;;
      --in) INGRESS="${2:?}"; shift 2 ;;
      --pin) PIN="${2:?}"; shift 2 ;;
      --sni) SNI="${2:?}"; shift 2 ;;
      --cert) CERT="${2:?}"; shift 2 ;;
      --tls-key) TLS_KEY="${2:?}"; shift 2 ;;
      --dial) DIAL="${2:?}"; shift 2 ;;
      --dial4) DIAL4="${2:?}"; shift 2 ;;
      --dial6) DIAL6="${2:?}"; shift 2 ;;
      --memory-profile) MEMORY_PROFILE="${2:?}"; shift 2 ;;
      --morph-prelude) MORPH_PRELUDE="${2:?}"; shift 2 ;;
      --libc) LIBC="${2:?}"; shift 2 ;;
      --keep-releases) KEEP_RELEASES="${2:?}"; shift 2 ;;
      --lang) LANG_CODE="${2:?}"; LANG_SET=1; shift 2 ;;
      --domain) CERT_DOMAIN="${2:?}"; shift 2 ;;
      --cf-token-file) CF_TOKEN_FILE="${2:?}"; shift 2 ;;
      --email) CERT_EMAIL="${2:?}"; shift 2 ;;
      --http) CERT_HTTP=1; shift ;;
      --force) CERT_FORCE=1; shift ;;
      --probe) DOCTOR_PROBE=1; shift; if (($#)) && [[ "$1" != -* ]]; then PROBE_TARGET="$1"; shift; fi ;;
      --wizard) WIZARD_REQUESTED=1; shift ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      --purge) PURGE=1; shift ;;
      --allow-role-switch) ALLOW_ROLE_SWITCH=1; shift ;;
      -h|--help) ACTION=help; shift ;;
      *)
        if [[ "$ACTION" == backup && "$1" != -* && -z "${BACKUP_PATH:-}" ]]; then BACKUP_PATH="$1"; shift
        elif [[ "$ACTION" == probe && "$1" != -* ]]; then PROBE_TARGET="$1"; shift
        elif [[ "$ACTION" == fingerprint && "$1" != -* && -z "$FINGERPRINT_URL" ]]; then FINGERPRINT_URL="$1"; shift
        else die "$(tr_msg 'Unknown option' '未知参数')"; fi ;;
    esac
  done
  [[ "$LANG_CODE" == zh || "$LANG_CODE" == en ]] || die 'LANG: zh|en'
  validate_version_arg "$VERSION"; validate_keep_releases "$KEEP_RELEASES"
  validate_memory_profile "$MEMORY_PROFILE"; validate_morph_prelude "$MORPH_PRELUDE"
  [[ "$ROLE" == portal || "$ROLE" == vector || "$ROLE" == egress ]] || die "$(tr_msg 'Invalid role' '无效角色')"
  [[ "$PUBLIC_HOST$NODE_NAME" != *$'\n'* && "$PUBLIC_HOST$NODE_NAME" != *$'\r'* ]] || die "$(tr_msg 'Host/name contains a newline' '地址或名称包含换行')"
  case "$ACTION" in
    menu) menu ;;
    help) usage ;;
    validate) [[ -n "$URL_INPUT" ]] || die "$(tr_msg 'Provide --url or --url-file' '需要--url或--url-file')"; v3_url validate "$URL_INPUT" ;;
    generate-key) generate_key ;;
    install)
      if [[ "$ASSUME_YES" != 1 && ! -s "$URL_FILE" && -z "$URL_INPUT" && ( -z "$KEY" || "$WIZARD_REQUESTED" == 1 ) ]]; then installation_wizard; fi
      install_action ;;
    upgrade) install_action ;;
    configure)
      if [[ -z "$URL_INPUT" && -z "$KEY" && -z "$ENDPOINT" ]]; then
        [[ "$ASSUME_YES" != 1 ]] || die "$(tr_msg 'Unattended configure requires explicit configuration' '非交互configure需要明确配置')"
        local requested="$ROLE"
        load_config_fields; [[ "$ROLE_SET" != 1 ]] || ROLE="$requested"
        installation_wizard
      fi
      configure_action ;;
    links) show_links ;;
    fingerprint) require_root; fingerprint_action "${FINGERPRINT_URL:-}" ;;
    status) show_status ;;
    telemetry) telemetry_action ;;
    logs) require_root; journalctl -u "$SERVICE_NAME" -f 2>&1 | redact_stream ;;
    start|stop|restart) mutating_setup; systemctl "$ACTION" "$SERVICE_NAME" ;;
    doctor) doctor_action ;;
    probe) probe_action ;;
    rollback) rollback_action ;;
    backup) backup_action ;;
    cert) cert_action ;;
    clean-releases) cleanup_old_releases ;;
    versions) versions_action ;;
    check-updates) VERSION=latest-v3; resolve_version; printf '%s\n' "$VERSION" ;;
    self-update) self_update ;;
    language) save_language ;;
    uninstall) uninstall_action ;;
    *) usage; exit 1 ;;
  esac
  if [[ "$LANG_SET" == 1 && "$ACTION" =~ ^(install|upgrade|configure|start|stop|restart|rollback)$ ]]; then save_language; fi
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
