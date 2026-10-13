#!/usr/bin/env bash
# Nowhere V3 isolated manager v1.0.1
# Deployment helpers derived from woohong666's Nowhere V2 manager.
# v1.0.1 integration fixes: reuse the existing staged PEM on reconfigure so the
#   client pin stays stable; guard role switches in configure; tolerate an
#   unreadable manager.conf for `validate`; prune superseded PEM directories.
# Copyright (C) 2026 woohong666
# SPDX-License-Identifier: GPL-3.0-only
set -Eeuo pipefail
umask 077
readonly SCRIPT_VERSION="1.0.1"
readonly SCRIPT_CHANNEL="v3"
readonly DEFAULT_CORE_VERSION="v3.0.0"
readonly UPSTREAM_REPO="NodePassProject/Nowhere"
readonly SERVICE_NAME="nowhere-v3" RUN_USER="nowhere-v3" RUN_GROUP="nowhere-v3"
readonly INSTALL_ROOT="/opt/nowhere-v3"
readonly RELEASES_DIR="$INSTALL_ROOT/releases" CURRENT_LINK="$INSTALL_ROOT/current"
readonly BIN_LINK="/usr/local/bin/nowhere-v3"
readonly LAUNCHER="/usr/local/libexec/nowhere-v3-launch"
readonly CONFIG_DIR="/etc/nowhere-v3"
readonly URL_FILE="$CONFIG_DIR/url.conf" META_FILE="$CONFIG_DIR/manager.conf" TLS_DIR="$CONFIG_DIR/tls"
readonly UNIT_FILE="/etc/systemd/system/nowhere-v3.service"
readonly BUILD_LOCK_DIR="/run/nowhere-v3-build.lock.d"
LANG_CODE=zh
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

prompt_confirm() { local a; read -r -p "$1 [y/N]: " a </dev/tty || a=""; [[ "$a" =~ ^[Yy] ]]; }

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
  flock -n "$BUILD_LOCK_FD" || die "另一个 V3 管理操作正在运行"
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
    curl_github "https://api.github.com/repos/${UPSTREAM_REPO}/releases?per_page=100&page=${page}" "$tmp" || die "无法获取官方发布列表"
    found="$(python3 - "$tmp" <<'PY'
import json,re,sys
r=json.load(open(sys.argv[1])); assert isinstance(r,list)
c=[(tuple(map(int,x['tag_name'][1:].split('.'))),x['tag_name']) for x in r if re.fullmatch(r'v3\.\d+\.\d+',x.get('tag_name','')) and not x.get('draft') and not x.get('prerelease')]
print(max(c)[1] if c else '')
print(len(r))
PY
)" || die "发布元数据无效"
    count="${found##*$'\n'}"; found="${found%%$'\n'*}"
    if [[ -n "$found" ]] && { [[ -z "$best" ]] || version_ge "$found" "$best"; }; then best="$found"; fi
    if ((count<100)); then
      [[ -n "$best" ]] || die "未找到稳定 V3 版本"
      VERSION="$best"; return 0
    fi
  done
  die "发布列表超过扫描上限，请显式指定稳定版标签"
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
  python3 - "$json" "$VERSION" <<'PYMETA' || die "发布标签不是匹配的稳定正式版"
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

validate_version_arg() {
  [[ "$1" == latest-v3 || "$1" =~ ^v3\.[0-9]+\.[0-9]+$ ]] || die "仅支持稳定 V3 标签或 latest-v3；拒绝 V2"
}
# A fail-closed manager validator. Upstream ignores unknown keys; this manager
# rejects them so accidentally importing an NW2 URL cannot silently change routing.
v3_url() {
  python3 - "$@" <<'PY'
import sys,re,urllib.parse as U,ipaddress,json
op=sys.argv[1]
def fail(m): raise SystemExit(m)
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
    key=U.unquote(u.username or '',errors='strict')
    if not re.fullmatch(r'[0-9a-f]{32}',key):fail('NW3 key must be exactly 32 lowercase hex characters')
    ep=u.netloc.rsplit('@',1)[-1]+u.path
    h,entries=endpoint(ep,role)
    rawq={}
    for pair in u.query.split('&') if u.query else []:
        k,_,v=pair.partition('=');k=U.unquote(k,errors='strict');rawq.setdefault(k,v)
    q={k:U.unquote(v,errors='strict') for k,v in rawq.items()}
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
    if op=='validate':print('V3 configuration OK')
    elif op=='get':
        k=sys.argv[3];print({'role':role,'endpoint':ep,'shared_key':key}.get(k,q.get(k,'')))
    elif op=='rewrite-pem':
        rawq.update(tls='2',crt=U.quote(sys.argv[3],safe=''),key=U.quote(sys.argv[4],safe=''))
        print(f'{role}://{key}@{ep}?'+ '&'.join(U.quote(k,safe='')+'='+v for k,v in rawq.items()))
    elif op=='links':
        if role!='portal':fail('Links require Portal')
        public,pin=sys.argv[3:]
        if ':' in public and not public.startswith('['):public='['+public+']'
        host(public)
        if not re.fullmatch(r'[0-9a-f]{64}',pin):fail('Verified local certificate pin required')
        for typ,fam,p in entries:
            # Let public DNS choose a family unless it is an explicit IP.
            query=U.urlencode({'morph':q.get('morph','1'),'pin':pin})
            print(f'Vector {typ}: vector://{key}@{public}/{typ}:{p}?{query}&in=127.0.0.1:1083')
            if typ=='udp' and q.get('out')=='egress':print(f'Egress: egress://{key}@{public}/udp:{p}?{query}')
    elif op=='ports':
        for typ,fam,p in entries:print(f'{typ.upper()} {p} (family {fam or "auto"})')
PY
}

read_url() { [[ -s "$URL_FILE" ]] || die "尚未配置 V3"; head -n 1 "$URL_FILE"; }
load_meta() {
  [[ -r "$META_FILE" ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      PUBLIC_HOST) PUBLIC_HOST="$v" ;;
      MEMORY_PROFILE) validate_memory_profile "$v"; MEMORY_PROFILE="$v" ;;
      MORPH_PRELUDE) validate_morph_prelude "$v"; MORPH_PRELUDE="$v" ;;
    esac
  done <"$META_FILE"
}
write_meta() {
  printf 'SCRIPT_CHANNEL=v3\nSCRIPT_VERSION=%s\nCORE_VERSION=%s\nPUBLIC_HOST=%s\nMEMORY_PROFILE=%s\nMORPH_PRELUDE=%s\n' "$SCRIPT_VERSION" "$VERSION" "$PUBLIC_HOST" "$MEMORY_PROFILE" "$MORPH_PRELUDE" >"$META_FILE"
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
    warn "操作未完成，恢复之前的 V3 配置、服务定义和二进制链接"
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
      systemctl restart "$SERVICE_NAME" && wait_service 12 || warn "服务恢复失败，请检查日志"
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
  [[ -f "$cert" && -f "$key" ]] || die "证书或私钥不存在"
  d="$(mktemp -d "$TLS_DIR/pem.XXXXXX")"; chmod 750 "$d"; chown root:"$RUN_GROUP" "$d"
  install -m 640 -o root -g "$RUN_GROUP" "$cert" "$d/cert.pem"
  install -m 640 -o root -g "$RUN_GROUP" "$key" "$d/key.pem"
  openssl x509 -in "$d/cert.pem" -noout -checkend 0 >/dev/null || die "证书无效或已过期"
  cp="$(openssl x509 -in "$d/cert.pem" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum)"
  kp="$(openssl pkey -in "$d/key.pem" -passin pass: -pubout -outform DER | sha256sum)"
  [[ "$cp" == "$kp" ]] || die "证书与私钥不匹配（仅支持无口令服务私钥）"
  CERT="$d/cert.pem"; TLS_KEY="$d/key.pem"
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
      warn "导入的 tls=1 使用临时证书；重启后需要更新客户端 pin"
    fi
  else
    [[ -n "$KEY" ]] || { [[ "$ROLE" == portal ]] && KEY="$(python3 -c 'import secrets;print(secrets.token_hex(16))')"; }
    [[ -n "$ENDPOINT" ]] || { [[ "$ROLE" == portal ]] && ENDPOINT='*:2083'; }
    [[ -n "$KEY" && -n "$ENDPOINT" ]] || die "Vector/Egress 必须提供 --key 和 --endpoint"
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
activate() {
  write_launcher; write_unit
  systemctl enable "$SERVICE_NAME" >/dev/null
  systemctl restart "$SERVICE_NAME"
  wait_service 12 || die "V3 未持续运行，触发恢复；请检查 journalctl -u nowhere-v3"
  TX_COMMITTED=1
}
mutating_setup() {
  require_root; require_systemd; install_runtime_deps; acquire_build_lock
}
install_action() {
  mutating_setup
  if [[ "$ACTION" == upgrade ]]; then [[ -s "$URL_FILE" ]] || die "upgrade 需要已有 V3 配置"; fi
  if [[ -s "$URL_FILE" && ( -n "$URL_INPUT" || -n "$KEY" || -n "$ENDPOINT" || -n "$CERT" || "$ROLE" != portal || "$OUT" != direct || "$MORPH" != 1 ) ]]; then
    die "已有 V3 配置；install/upgrade 仅更新二进制。修改配置请单独使用 configure"
  fi
  begin_transaction; ensure_user
  if [[ -s "$URL_FILE" ]]; then load_meta; v3_url validate "$(read_url)" >/dev/null
  else prepare_configuration; fi
  install_release
  local actual
  actual="$("$CURRENT_LINK/nowhere" --version)"
  [[ "$actual" == "nowhere-${VERSION} "* ]] || die "下载二进制版本与所选标签不符"
  write_meta; activate
  cleanup_old_releases 1
  ok "V3 ${VERSION} 服务已启动；尚需客户端端到端验收"
}
configure_action() {
  mutating_setup; [[ -x "$CURRENT_LINK/nowhere" ]] || die "请先 install"
  [[ -n "$URL_INPUT" || ( -n "$KEY" && -n "$ENDPOINT" ) ]] || die "configure 必须明确提供 --url 或 --key 与 --endpoint"
  if [[ -s "$URL_FILE" ]]; then
    local current_role new_role
    current_role="$(v3_url get "$(head -n 1 "$URL_FILE")" role)"
    if [[ -n "$URL_INPUT" ]]; then new_role="$(v3_url get "$URL_INPUT" role)"; else new_role="$ROLE"; fi
    if [[ "$new_role" != "$current_role" ]]; then
      if [[ "$ALLOW_ROLE_SWITCH" == 1 ]]; then
        warn "角色从 ${current_role} 切换为 ${new_role}：原配置将被覆盖"
      elif [[ "$ASSUME_YES" == 1 ]]; then
        die "角色将从 ${current_role} 切换为 ${new_role}；确认请显式加 --allow-role-switch"
      else
        prompt_confirm "角色将从 ${current_role} 切换为 ${new_role}，原配置会被覆盖，继续？" || die "已取消角色切换"
      fi
    fi
  fi
  begin_transaction; ensure_user
  VERSION="$(sed -n 's/^tag: //p' "$CURRENT_LINK/RELEASE-INFO")"
  prepare_configuration; write_meta; activate
  ok "V3 配置已应用"
}
local_pin() {
  local u tls cert fp
  u="$(read_url)"
  [[ "$(v3_url get "$u" role)" == portal ]] || die "仅 Portal 支持本机 PEM 指纹"
  tls="$(v3_url get "$u" tls)"
  [[ "$tls" == 2 ]] || die "tls=1 不导出可能过期的链接；请提供持久 PEM，或自行核验当前证书指纹"
  cert="$(v3_url get "$u" crt)"
  fp="$(openssl x509 -in "$cert" -noout -fingerprint -sha256)"
  fp="${fp#*=}"; fp="${fp//:/}"; fp="${fp,,}"
  [[ "$fp" =~ ^[0-9a-f]{64}$ ]] || die "指纹读取失败"
  printf '%s\n' "$fp"
}
show_links() {
  require_root
  local requested="$PUBLIC_HOST"
  load_meta
  [[ -z "$requested" ]] || PUBLIC_HOST="$requested"
  [[ -n "$PUBLIC_HOST" ]] || die "请用 --public-host 指定公网地址"
  v3_url links "$(read_url)" "$PUBLIC_HOST" "$(local_pin)"
  warn "以上是 NW3 原生角色 URL；不能导入仅支持 NW2 的客户端"
}
rollback_action() {
  mutating_setup
  local d target=''
  begin_transaction
  while IFS= read -r d; do
    [[ "$d" == "$OLD_TARGET" || ! -x "$d/nowhere" ]] && continue
    target="$d"; break
  done < <(ls -1dt "$RELEASES_DIR"/v3.* 2>/dev/null || true)
  [[ -n "$target" ]] || die "没有可回滚的 V3 版本"
  ln -sfn "$target" "$CURRENT_LINK"
  VERSION="$(sed -n 's/^tag: //p' "$target/RELEASE-INFO")"
  validate_version_arg "$VERSION"; load_meta; write_meta; activate
  ok "V3 二进制已回滚；配置不跨版本转换"
}
backup_action() {
  require_root; acquire_build_lock
  local out="${BACKUP_PATH:-/root/nowhere-v3-backup-$(date +%Y%m%d-%H%M%S).tar.gz}"
  [[ -d "$CONFIG_DIR" ]] || die "没有 V3 配置"
  [[ ! -e "$out" ]] || die "备份目标已存在，拒绝覆盖"
  case "$(realpath -m "$out")" in "$CONFIG_DIR"/*) die "备份必须位于配置目录之外" ;; esac
  tar -czf "$out" -C /etc nowhere-v3
  chmod 600 "$out"; ok "已备份到 $out（包含密钥，请妥善保管）"
}
uninstall_action() {
  mutating_setup
  if [[ "$ASSUME_YES" != 1 ]]; then
    local answer
    read -r -p '确认卸载 V3？输入 REMOVE-V3: ' answer
    [[ "$answer" == REMOVE-V3 ]] || return 0
  fi
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE" "$LAUNCHER" "$BIN_LINK"
  rm -rf "$INSTALL_ROOT"
  if [[ "$PURGE" == 1 ]]; then rm -rf "$CONFIG_DIR"; fi
  systemctl daemon-reload
  ok "V3 已卸载；默认保留配置，V2 不受影响"
}
doctor_action() {
  require_root; require_systemd
  v3_url validate "$(read_url)"
  [[ -x "$CURRENT_LINK/nowhere" ]] || die "V3 二进制缺失"
  "$CURRENT_LINK/nowhere" --version
  systemctl is-active --quiet "$SERVICE_NAME" || die "V3 服务未运行"
  local u; u="$(read_url)"
  if [[ "$(v3_url get "$u" tls)" == 2 ]]; then
    runuser -u "$RUN_USER" -- test -r "$(v3_url get "$u" crt)" || die "服务账户不能读取证书"
    runuser -u "$RUN_USER" -- test -r "$(v3_url get "$u" key)" || die "服务账户不能读取私钥"
  fi
  ok "基础检查通过；不代表 Egress 在线或目标可达，请另做 probe"
}
usage() {
  cat <<EOF
Nowhere V3 管理器 ${SCRIPT_VERSION}（通道 ${SCRIPT_CHANNEL}；仅 Linux + systemd，Bash >=4.3）
默认固定 v3.0.0；--version latest-v3 可显式更新到最新稳定 V3。
独立服务/账户 nowhere-v3；/etc/nowhere-v3；/opt/nowhere-v3。
默认 Portal 2083，Vector SOCKS 1083；不修改 V2，不自动开放防火墙。

用法：sudo bash nowhere-v3.sh ACTION [选项]
  install       安装官方 SHA-256 校验预编译版；新 Portal 自动生成持久 PEM
  upgrade       更新已有 V3（二进制），默认 v3.0.0
  configure     明确重配；提供 --url，或 --key 与 --endpoint
  validate      只校验 --url，不需要 root，不安装依赖
  status        systemd 状态
  telemetry     V3 原生只读统计（取代旧 TUI）
  links         导出原生 Vector/Egress URL，需要 --public-host
  fingerprint   持久 PEM 的 SHA-256 指纹
  doctor        基础配置、进程和证书可读性检查
  logs | start | stop | restart
  rollback | backup [路径] | check-updates | uninstall [--purge]

参数：
 --version v3.0.0|latest-v3  --libc auto|gnu|musl  --keep-releases 0..20
 --role portal|vector|egress  --key 32位小写十六进制  --endpoint HOST:PORT
 --url '完整原生 V3 URL'     --url-file FILE（避免将 URL 留在 shell 历史）
 --public-host HOST          --morph 0|1（默认1）
 --out direct|egress|HOST:PORT  --in HOST:PORT（默认127.0.0.1:1083）
 --pin 64位小写十六进制     --sni DNS名
 --cert PEM --tls-key PEM（自动复制；不提供时新 Portal 生成持久自签 PEM）
 --memory-profile memory|balanced|throughput --morph-prelude low7|full8
 -y / --yes（确认卸载）
 --allow-role-switch          configure 时允许角色切换（默认要求确认或拒绝）

高级 rate/etar、dial/dial4/dial6、SOCKS凭证通过 --url-file 配置。
不接受旧 socks/next/up/down/mux/log 参数；不做 V2 配置自动转换。
首次接入前核验客户端明确支持 NW3，并通过可信渠道传递 pin。
EOF
}
menu() {
  local c
  printf 'Nowhere V3 独立管理器\n1) 新建 Portal（2083）\n2) 更新 V3\n3) 状态\n4) 连接链接\n5) 日志\n6) 健康检查\n7) 最新版本\n0) 退出\n'
  read -r -p '选择: ' c || return 0
  case "$c" in
    1) read -r -p '公网 IP/域名: ' PUBLIC_HOST; ACTION=install; install_action ;;
    2) ACTION=upgrade; VERSION=latest-v3; install_action ;;
    3) systemctl status "$SERVICE_NAME" --no-pager ;;
    4) show_links ;;
    5) journalctl -u "$SERVICE_NAME" -f ;;
    6) doctor_action ;;
    7) VERSION=latest-v3; resolve_version; printf '%s\n' "$VERSION" ;;
    0) return 0 ;;
    *) die "无效选项" ;;
  esac
}
main() {
  load_meta
  (($#==0)) || { ACTION="$1"; shift; }
  while (($#)); do
    case "$1" in
      --version) VERSION="${2:?}"; shift 2 ;;
      --role|--type) ROLE="${2:?}"; shift 2 ;;
      --key) KEY="${2:?}"; shift 2 ;;
      --endpoint) ENDPOINT="${2:?}"; shift 2 ;;
      --url) URL_INPUT="${2:?}"; shift 2 ;;
      --url-file) URL_INPUT="$(cat -- "${2:?}")"; shift 2 ;;
      --public-host) PUBLIC_HOST="${2:?}"; shift 2 ;;
      --morph) MORPH="${2:?}"; shift 2 ;;
      --out) OUT="${2:?}"; shift 2 ;;
      --in) INGRESS="${2:?}"; shift 2 ;;
      --pin) PIN="${2:?}"; shift 2 ;;
      --sni) SNI="${2:?}"; shift 2 ;;
      --cert) CERT="${2:?}"; shift 2 ;;
      --tls-key) TLS_KEY="${2:?}"; shift 2 ;;
      --memory-profile) MEMORY_PROFILE="${2:?}"; shift 2 ;;
      --morph-prelude) MORPH_PRELUDE="${2:?}"; shift 2 ;;
      --libc) LIBC="${2:?}"; shift 2 ;;
      --keep-releases) KEEP_RELEASES="${2:?}"; shift 2 ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      --purge) PURGE=1; shift ;;
      --allow-role-switch) ALLOW_ROLE_SWITCH=1; shift ;;
      *) if [[ "$ACTION" == backup && "$1" != -* && -z "${BACKUP_PATH:-}" ]]; then BACKUP_PATH="$1"; shift; else die "未知参数"; fi ;;
    esac
  done
  validate_version_arg "$VERSION"; validate_keep_releases "$KEEP_RELEASES"
  validate_memory_profile "$MEMORY_PROFILE"; validate_morph_prelude "$MORPH_PRELUDE"
  [[ "$ROLE" == portal || "$ROLE" == vector || "$ROLE" == egress ]] || die "无效角色"
  [[ "$PUBLIC_HOST" != *$'\n'* && "$PUBLIC_HOST" != *$'\r'* ]] || die "公网地址包含换行"
  case "$ACTION" in
    menu) menu ;;
    help|-h|--help) usage ;;
    validate) [[ -n "$URL_INPUT" ]] || die "需要 --url 或 --url-file"; v3_url validate "$URL_INPUT" ;;
    install|upgrade) install_action ;;
    configure) configure_action ;;
    links) show_links ;;
    fingerprint) require_root; local_pin ;;
    status) systemctl status "$SERVICE_NAME" --no-pager ;;
    telemetry) require_root; runuser -u "$RUN_USER" -- env TMPDIR=/run/nowhere-v3 "$BIN_LINK" status ;;
    logs) require_root; journalctl -u "$SERVICE_NAME" -f ;;
    start|stop|restart) mutating_setup; systemctl "$ACTION" "$SERVICE_NAME" ;;
    doctor) doctor_action ;;
    rollback) rollback_action ;;
    backup) backup_action ;;
    check-updates) VERSION=latest-v3; resolve_version; printf '%s\n' "$VERSION" ;;
    uninstall) uninstall_action ;;
    *) usage; exit 1 ;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
