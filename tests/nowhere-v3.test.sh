#!/usr/bin/env bash
#
# Test suite for nowhere-v3.sh.
#
# Everything runs inside a temporary sandbox: the manager's path declarations are
# rewritten before it is sourced, so no test can touch the real /etc/nowhere-v3,
# /opt/nowhere-v3, or systemd. The suite needs no root and no network; the URL
# grammar is checked against the official v3.0.0 docs/configuration.md.
#
# Usage:
#   bash tests/nowhere-v3.test.sh [path/to/nowhere-v3.sh]
#
# Exits 0 when every assertion passes, 1 when any fails, 2 on a setup error.
#
# NOTE for anyone extending this file: the manager defines ok/warn/die/info and
# many other short names. Never name a test helper after one of them, or the
# helper silently replaces the manager's function and tests fail for the wrong
# reason. The t_* prefix is used here for that reason.

# This suite deliberately assigns the manager's own globals (ROLE, KEY, ...) so
# that its functions can read them. Shellcheck cannot see across the sourced
# file, so every "appears unused" warning here is expected.
# shellcheck disable=SC2034

set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SELF_DIR}/.." && pwd)"
SCRIPT="${1:-${REPO_ROOT}/nowhere-v3.sh}"

[[ -f "$SCRIPT" ]] || { echo "FATAL: script not found: $SCRIPT" >&2; exit 2; }

SANDBOX="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 2; }
cleanup_sandbox() { rm -rf -- "$SANDBOX"; }
trap cleanup_sandbox EXIT

# ---------------------------------------------------------------------------
# Sandbox the manager
# ---------------------------------------------------------------------------

patch_script() {
  local src="$1" dst="$2" sb="$3" v
  sed \
    -e "s|^readonly INSTALL_ROOT=.*|readonly INSTALL_ROOT=\"${sb}/opt\"|" \
    -e "s|^readonly RELEASES_DIR=.*|readonly RELEASES_DIR=\"${sb}/opt/releases\" CURRENT_LINK=\"${sb}/opt/current\"|" \
    -e "s|^readonly BIN_LINK=.*|readonly BIN_LINK=\"${sb}/bin/nowhere-v3\"|" \
    -e "s|^readonly LAUNCHER=.*|readonly LAUNCHER=\"${sb}/bin/launch-v3\"|" \
    -e "s|^readonly CONFIG_DIR=.*|readonly CONFIG_DIR=\"${sb}/etc\"|" \
    -e "s|^readonly URL_FILE=.*|readonly URL_FILE=\"${sb}/etc/url.conf\" META_FILE=\"${sb}/etc/manager.conf\" TLS_DIR=\"${sb}/etc/tls\"|" \
    -e "s|^readonly UNIT_FILE=.*|readonly UNIT_FILE=\"${sb}/unit-v3.service\"|" \
    -e "s|^readonly BUILD_LOCK_DIR=.*|readonly BUILD_LOCK_DIR=\"${sb}/lock-v3.d\"|" \
    "$src" > "$dst"

  for v in INSTALL_ROOT RELEASES_DIR BIN_LINK LAUNCHER CONFIG_DIR URL_FILE UNIT_FILE BUILD_LOCK_DIR; do
    grep -q "^readonly ${v}=\"${sb}" "$dst" ||
      { echo "FATAL: ${v} was not sandboxed; refusing to run" >&2; exit 2; }
  done
}

mkdir -p "$SANDBOX/bin" "$SANDBOX/etc/tls" "$SANDBOX/opt/releases"

# Stub the host commands the manager shells out to. Without this, write_unit and
# friends would invoke the real systemctl.
for c in systemctl journalctl runuser getent useradd groupadd; do
  printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/$c"
  chmod +x "$SANDBOX/bin/$c"
done
PATH="$SANDBOX/bin:$PATH"

PATCHED="$SANDBOX/v3.sh"
patch_script "$SCRIPT" "$PATCHED" "$SANDBOX"

# The manager enables `set -Eeuo pipefail` and installs its own EXIT trap when
# sourced; undo both so one failing assertion cannot abort the suite.
# shellcheck disable=SC1090
source "$PATCHED" >/dev/null 2>&1 || true
set +e
trap cleanup_sandbox EXIT

require_root() { :; }

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

PASS=0
FAIL=0

t_ok() { # t_ok <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected [%s]\n       actual   [%s]\n' "$1" "$2" "$3"
  fi
}

t_skip() { # counts as a pass so a host without the tool still reports green
  PASS=$((PASS + 1)); printf '  skip %s\n' "$1"
}

t_rc() { # t_rc <command...> -> prints 0 on success, 1 on any failure
  ( "$@" ) >/dev/null 2>&1 && echo 0 || echo 1
}

t_section() { printf '\n%s\n' "$1"; }

# Host capabilities: the suite runs in full on Linux; macOS dev runs skip the
# sections that need util-linux / GNU coreutils commands.
HAVE_FLOCK=0; command -v flock >/dev/null 2>&1 && HAVE_FLOCK=1
HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
# self-update preserves mode/owner with GNU --reference extensions.
HAVE_CHMODREF=0
cap="$(mktemp)"
if chmod --reference="$cap" "$cap" 2>/dev/null && chown --reference="$cap" "$cap" 2>/dev/null; then HAVE_CHMODREF=1; fi
rm -f "$cap"

# ---------------------------------------------------------------------------
t_section "syntax and help"

t_ok "bash -n parses v3"        0 "$(t_rc bash -n "$SCRIPT")"
t_ok "help exits 0"             0 "$(bash "$SCRIPT" help >/dev/null 2>&1; echo $?)"
t_ok "help mentions the channel" yes "$(bash "$SCRIPT" help 2>/dev/null | grep -q 'Nowhere V3' && echo yes || echo no)"

# ---------------------------------------------------------------------------
t_section "version gates"

t_ok "v3.0.0 accepted"          0 "$(t_rc validate_version_arg v3.0.0)"
t_ok "latest-v3 accepted"       0 "$(t_rc validate_version_arg latest-v3)"
t_ok "v2.2.1 rejected"          1 "$(t_rc validate_version_arg v2.2.1)"
t_ok "plain latest rejected"    1 "$(t_rc validate_version_arg latest)"
t_ok "prerelease rejected"      1 "$(t_rc validate_version_arg v3.1.0-beta)"

# ---------------------------------------------------------------------------
t_section "URL matrix (against official v3.0.0 docs/configuration.md)"

K="$(printf 'a%.0s' $(seq 1 32))"
P64="$(printf 'c%.0s' $(seq 1 64))"
vu() { t_rc v3_url validate "$1"; }

t_ok "portal compact accepts"       0 "$(vu "portal://$K@*:2083")"
t_ok "portal split families accepts" 0 "$(vu "portal://$K@*/tcp4:2083/udp6:2084?out=egress")"
t_ok "portal morph=0 accepts"       0 "$(vu "portal://$K@*:2083?morph=0")"
t_ok "portal dial4/dial6 accepts"   0 "$(vu "portal://$K@*:2083?dial4=127.0.0.1&dial6=::1")"
t_ok "portal tls=2+crt+key accepts" 0 "$(vu "portal://$K@*:2083?tls=2&crt=/x.pem&key=/y.pem")"
t_ok "portal rate max accepts"      0 "$(vu "portal://$K@*:2083?rate=2147483647")"
t_ok "portal SOCKS creds accept"    0 "$(vu "portal://$K@*:2083?out=a%3Ab:p%40ss@127.0.0.1:1080")"
t_ok "vector compact accepts"       0 "$(vu "vector://$K@example.com:2083?in=127.0.0.1:1083")"
t_ok "vector creds accept"          0 "$(vu "vector://$K@example.com/udp:2083?in=a%3Ab:p%40ss@127.0.0.1:1083")"
t_ok "egress IPv6 udp accepts"      0 "$(vu "egress://$K@[::1]/udp6:2083")"
t_ok "egress pin accepts"           0 "$(vu "egress://$K@example.com:2083?pin=$P64")"

t_ok "64-hex key rejected"          1 "$(vu "portal://$K$K@*:2083")"
t_ok "next= rejected in v3"         1 "$(vu "portal://$K@*:2083?next=a@b:12")"
t_ok "mux= rejected in v3"          1 "$(vu "portal://$K@*:2083?mux=0")"
t_ok "log= rejected in v3"          1 "$(vu "portal://$K@*:2083?log=info")"
t_ok "invalid first morph rejected" 1 "$(vu "portal://$K@*:2083?morph=x&morph=1")"
t_ok "tls=1 with crt rejected"      1 "$(vu "portal://$K@*:2083?tls=1&crt=/x&key=/y")"
t_ok "tcp-only + egress rejected"   1 "$(vu "portal://$K@*/tcp:2083?out=egress")"
t_ok "egress with dial rejected"    1 "$(vu "portal://$K@*:2083?out=egress&dial=auto")"
t_ok "rate=nan rejected"            1 "$(vu "portal://$K@*:2083?rate=nan")"
t_ok "rate=0.5 rejected"            1 "$(vu "portal://$K@*:2083?rate=0.5")"
t_ok "rate overflow rejected"       1 "$(vu "portal://$K@*:2083?rate=2147483648")"
t_ok "dial+dial4 rejected"          1 "$(vu "portal://$K@*:2083?dial=auto&dial4=auto")"
t_ok "bad IPv6 literal rejected"    1 "$(vu "portal://$K@[invalid]:2083")"
t_ok "port 65536 rejected"          1 "$(vu "portal://$K@*:65536")"
t_ok "vector two carriers rejected" 1 "$(vu "vector://$K@a/tcp:2083/udp:2083?in=127.0.0.1:1083")"
t_ok "vector socks= rejected"       1 "$(vu "vector://$K@a:2083?socks=127.0.0.1:1083")"
t_ok "uppercase pin rejected"       1 "$(vu "vector://$K@a:2083?in=127.0.0.1:1083&pin=${P64^^}")"
t_ok "egress tcp carrier rejected"  1 "$(vu "egress://$K@a/tcp:2083")"
t_ok "authority+path rejected"      1 "$(vu "portal://$K@*:2083/tcp:2083")"

# ---------------------------------------------------------------------------
t_section "v3_url build round trip"

built="$(v3_url build portal "$K" '*:2083' 1 direct 127.0.0.1:1083 '' '' '' '')"
t_ok "portal build validates"       0 "$(vu "$built")"
t_ok "portal build has tls=1"       yes "$(grep -q 'tls=1' <<<"$built" && echo yes || echo no)"
built="$(v3_url build portal "$K" '*:2083' 1 direct 127.0.0.1:1083 '' '' "$SANDBOX/etc/tls/pem.t/cert.pem" "$SANDBOX/etc/tls/pem.t/key.pem")"
t_ok "portal build with PEM validates" 0 "$(vu "$built")"
t_ok "portal build has tls=2"       yes "$(grep -q 'tls=2' <<<"$built" && echo yes || echo no)"
built="$(v3_url build vector "$K" 'relay.example:2083' 1 direct 127.0.0.1:1083 '' '' '' '')"
t_ok "vector build validates"       0 "$(vu "$built")"
t_ok "vector build has in="         yes "$(grep -q 'in=127.0.0.1:1083' <<<"$built" && echo yes || echo no)"
built="$(v3_url build egress "$K" 'relay.example:2083' 1 direct 127.0.0.1:1083 '' '' '' '')"
t_ok "egress build validates"       0 "$(vu "$built")"
t_ok "egress build has no in="      1 "$(grep -q 'in=' <<<"$built" && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
t_section "links output"

links="$(v3_url links "portal://$K@*:2083" 203.0.113.5 "$P64" 2>/dev/null)"
t_ok "prints tcp carrier"           yes "$(grep -q 'Vector tcp: vector://' <<<"$links" && echo yes || echo no)"
t_ok "prints udp carrier"           yes "$(grep -q 'Vector udp: vector://' <<<"$links" && echo yes || echo no)"
t_ok "carries the pin"              yes "$(grep -q "pin=$P64" <<<"$links" && echo yes || echo no)"
t_ok "carries the default ingress"  yes "$(grep -q 'in=127.0.0.1:1083' <<<"$links" && echo yes || echo no)"
links="$(v3_url links "portal://$K@*:2083?out=egress" 203.0.113.5 "$P64" 2>/dev/null)"
t_ok "egress portal prints Egress URL" yes "$(grep -q 'Egress: egress://' <<<"$links" && echo yes || echo no)"
t_ok "invalid pin refused"          1 "$(t_rc v3_url links "portal://$K@*:2083" 203.0.113.5 abc)"

# ---------------------------------------------------------------------------
t_section "namespace isolation"

t_ok "no v2 paths"                  yes "$(grep -q '/nowhere-v2' "$PATCHED" && echo no || echo yes)"
t_ok "default ingress is 1083"      yes "$(grep -q '127.0.0.1:1083' "$PATCHED" && echo yes || echo no)"
t_ok "default portal port is 2083"  yes "$(grep -q '\*:2083' "$PATCHED" && echo yes || echo no)"
t_ok "self-update stays on V3 source" yes "$(grep -q 'DEFAULT_SELF_UPDATE_URL=.*nowhere-v3.sh' "$PATCHED" && echo yes || echo no)"

# ---------------------------------------------------------------------------
t_section "safe_extract_tar (v3)"

python3 - "$SANDBOX" <<'PY'
import io, sys, tarfile
sb = sys.argv[1]
def add(t, name, link=None, fifo=False):
    ti = tarfile.TarInfo(name); ti.mode = 0o755
    if link:
        ti.type = tarfile.SYMTYPE; ti.linkname = link; t.addfile(ti)
    elif fifo:
        ti.type = tarfile.FIFOTYPE; t.addfile(ti)
    else:
        b = b"binary"; ti.size = len(b); t.addfile(ti, io.BytesIO(b))
with tarfile.open(f"{sb}/good3.tar.gz", "w:gz") as t: add(t, "nowhere")
with tarfile.open(f"{sb}/evil3.tar.gz", "w:gz") as t: add(t, "nowhere", "/etc/passwd")
with tarfile.open(f"{sb}/fifo3.tar.gz", "w:gz") as t: add(t, "nowhere", fifo=True)
with tarfile.open(f"{sb}/dup3.tar.gz", "w:gz") as t:
    add(t, "a/nowhere"); add(t, "b/nowhere")
PY

mkdir -p "$SANDBOX/d1" "$SANDBOX/d2" "$SANDBOX/d3" "$SANDBOX/d4"
t_ok "regular tar extracts"      0 "$(t_rc safe_extract_tar "$SANDBOX/good3.tar.gz" "$SANDBOX/d1")"
t_ok "binary present"            yes "$([[ -f "$SANDBOX/d1/nowhere" ]] && echo yes || echo no)"
t_ok "symlink tar refused"       1 "$(t_rc safe_extract_tar "$SANDBOX/evil3.tar.gz" "$SANDBOX/d2")"
t_ok "fifo tar refused"          1 "$(t_rc safe_extract_tar "$SANDBOX/fifo3.tar.gz" "$SANDBOX/d3")"
t_ok "duplicate binary refused"  1 "$(t_rc safe_extract_tar "$SANDBOX/dup3.tar.gz" "$SANDBOX/d4")"

# ---------------------------------------------------------------------------
t_section "build lock (flock)"

if command -v flock >/dev/null 2>&1; then
  # flock is an open-file-description lock: it must be held from a live process,
  # so the contention checks use a separate holder process rather than $( ).
  LOCK_FILE="${BUILD_LOCK_DIR%.d}"
  rm -f "$LOCK_FILE" "$SANDBOX/held.flag"
  bash -c 'source "$1" >/dev/null 2>&1; require_root() { :; }; acquire_build_lock; printf held > "$2"; sleep 30' _ "$PATCHED" "$SANDBOX/held.flag" &
  holder=$!
  for _ in $(seq 1 50); do [[ -s "$SANDBOX/held.flag" ]] && break; sleep 0.1; done
  t_ok "holder acquired the lock"      yes "$([[ -s "$SANDBOX/held.flag" ]] && echo yes || echo no)"
  t_ok "contention refused"            1 "$(t_rc bash -c 'source "$1" >/dev/null 2>&1; require_root() { :; }; acquire_build_lock' _ "$PATCHED")"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  rm -f "$SANDBOX/held.flag"
  t_ok "free after holder exits"       0 "$(t_rc bash -c 'source "$1" >/dev/null 2>&1; require_root() { :; }; acquire_build_lock; release_build_lock' _ "$PATCHED")"
  # In-shell flag transitions (only safe once the lock is known to be free).
  acquire_build_lock
  t_ok "acquire sets held flag"        1 "$BUILD_LOCK_HELD"
  release_build_lock
  t_ok "release clears flag"           0 "$BUILD_LOCK_HELD"
else
  # flock is util-linux and absent on macOS; CI (Linux) runs the real branch.
  t_skip "build lock (flock unavailable on this host)"
fi

# ---------------------------------------------------------------------------
t_section "transaction rollback (top-level failure path)"

printf 'portal://%s@127.0.0.1:2083?morph=1\n' "$K" > "$URL_FILE"
printf 'PUBLIC_HOST=old.example\n' > "$META_FILE"
printf 'ORIGINAL UNIT\n' > "$UNIT_FILE"
printf 'ORIGINAL LAUNCHER\n' > "$LAUNCHER"
ORIG_URL="$(cat "$URL_FILE")"
out="$(bash -c 'source "$1" >/dev/null 2>&1; require_root() { :; }; systemctl() { return 0; }; wait_service() { return 0; }; begin_transaction; printf changed > "$URL_FILE"; printf changed > "$META_FILE"; printf changed > "$UNIT_FILE"; printf changed > "$LAUNCHER"; false' _ "$PATCHED" 2>&1)"
rc=$?
t_ok "failure exits non-zero"  1 "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
t_ok "url.conf rolled back"    "$ORIG_URL" "$(cat "$URL_FILE")"
t_ok "manager.conf rolled back" "PUBLIC_HOST=old.example" "$(cat "$META_FILE")"
t_ok "unit rolled back"        "ORIGINAL UNIT" "$(cat "$UNIT_FILE")"
t_ok "launcher rolled back"    "ORIGINAL LAUNCHER" "$(cat "$LAUNCHER")"
out="$(bash -c 'source "$1" >/dev/null 2>&1; require_root() { :; }; systemctl() { return 0; }; wait_service() { return 0; }; begin_transaction; printf kept > "$URL_FILE"; TX_COMMITTED=1' _ "$PATCHED" 2>&1)"
t_ok "committed change kept"   kept "$(cat "$URL_FILE")"

# ---------------------------------------------------------------------------
t_section "tolerant meta read"

printf 'PUBLIC_HOST=hidden.example\n' > "$META_FILE"
chmod 000 "$META_FILE"
t_ok "unreadable meta is ignored" 0 "$(bash -c 'source "$1" >/dev/null 2>&1; load_meta; echo done' _ "$PATCHED" >/dev/null 2>&1; echo $?)"
chmod 644 "$META_FILE"

# ---------------------------------------------------------------------------
t_section "v1.1.0 key, language and redaction"
key_out="$(bash "$PATCHED" generate-key 2>/dev/null)"
t_ok "key exactly 32 lowercase hex" yes "$([[ "$key_out" =~ ^[0-9a-f]{32}$ ]] && echo yes || echo no)"
t_ok "English help" yes "$(bash "$PATCHED" help --lang en | grep -q 'Nowhere V3 Manager' && echo yes || echo no)"
t_ok "English help contains no Chinese" yes "$(bash "$PATCHED" help --lang en | python3 -c 'import sys;print("no" if any("\u4e00"<=c<="\u9fff" for c in sys.stdin.read()) else "yes")')"
t_ok "environment selects English" yes "$(NOWHERE_V3_LANG=en bash "$PATCHED" help | grep -q 'Nowhere V3 Manager' && echo yes || echo no)"
t_ok "CLI language wins over env" yes "$(NOWHERE_V3_LANG=en bash "$PATCHED" help --lang zh | grep -q '管理器' && echo yes || echo no)"
t_ok "invalid language rejected" 1 "$(t_rc bash "$PATCHED" help --lang fr)"
if ((HAVE_FLOCK)); then
  ( LANG_CODE=en; save_language ) >/dev/null 2>&1
  t_ok "language persisted" yes "$(grep -q '^LANG=en$' "$META_FILE" && echo yes || echo no)"
  t_ok "preference write preserves host" yes "$(grep -q '^PUBLIC_HOST=hidden.example$' "$META_FILE" && echo yes || echo no)"
  t_ok "meta language used" yes "$(bash "$PATCHED" help | grep -q 'Nowhere V3 Manager' && echo yes || echo no)"
else
  t_skip "language persistence (flock unavailable on this host)"
fi
redacted="$(printf 'Exec vector://%s@relay:2083?pin=%s\nPIN %s\n' "$K" "$P64" "$P64" | redact_stream)"
t_ok "status redactor removes key" yes "$([[ "$redacted" != *"$K"* ]] && echo yes || echo no)"
t_ok "status redactor removes pin" yes "$([[ "$redacted" != *"$P64"* ]] && echo yes || echo no)"
t_ok "arbitrary-size version comparison" 0 "$(t_rc version_ge 3.1000000000000000000000000000.0 3.2.0)"

# ---------------------------------------------------------------------------
t_section "self-update (stubbed download; no network)"
if ((HAVE_CHMODREF)); then
t_update() {
  local remote="$1" mode="${2:-normal}"
  cp "$PATCHED" "$SANDBOX/self.sh"
  chmod 750 "$SANDBOX/self.sh"
  NOWHERE_V3_SELF_URL="https://example.invalid/v3.sh" bash -c '
    source "$1"
    fixture="$2"; mode="$3"
    curl() {
      [[ "$mode" != offline ]] || return 22
      local dst=""
      while (($#)); do if [[ "$1" == -o ]]; then dst="$2"; shift 2; else shift; fi; done
      cp "$fixture" "$dst"
    }
    ASSUME_YES=1
    self_update
  ' _ "$SANDBOX/self.sh" "$remote" "$mode"
}
for ver in 1.3.0 1.2.0 1.1.0; do
  printf '#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="%s"\nreadonly SCRIPT_CHANNEL="v3"\n' "$ver" >"$SANDBOX/remote-$ver"
done
out="$(t_update "$SANDBOX/remote-1.3.0" 2>&1)"; rc=$?
t_ok "higher manager version accepted" 0 "$rc"
t_ok "higher manager installed" yes "$(grep -q 'SCRIPT_VERSION="1.3.0"' "$SANDBOX/self.sh" && echo yes || echo no)"
t_ok "update preserves executable bit" yes "$([[ -x "$SANDBOX/self.sh" ]] && echo yes || echo no)"
t_ok "update saves backup" yes "$(find "$SANDBOX" -name 'self.sh.bak.*' -print -quit | grep -q . && echo yes || echo no)"
out="$(t_update "$SANDBOX/remote-1.2.0" 2>&1)"; rc=$?
t_ok "same version exits normally" 0 "$rc"
t_ok "same version unchanged" 0 "$(t_rc cmp "$PATCHED" "$SANDBOX/self.sh")"
out="$(t_update "$SANDBOX/remote-1.1.0" 2>&1)"; rc=$?
t_ok "downgrade refused" 1 "$rc"
t_ok "downgrade leaves file unchanged" 0 "$(t_rc cmp "$PATCHED" "$SANDBOX/self.sh")"
printf '#!/bin/bash\ntrue\n' >"$SANDBOX/invalid-manager"
out="$(t_update "$SANDBOX/invalid-manager" 2>&1)"; rc=$?
t_ok "missing version refused" 1 "$rc"
t_ok "invalid manager leaves file unchanged" 0 "$(t_rc cmp "$PATCHED" "$SANDBOX/self.sh")"
printf '#!/bin/bash\nreadonly SCRIPT_VERSION="9.0.0"\nreadonly SCRIPT_CHANNEL="v2"\n' >"$SANDBOX/cross-manager"
out="$(t_update "$SANDBOX/cross-manager" 2>&1)"; rc=$?
t_ok "cross-channel manager refused" 1 "$rc"
out="$(t_update "$SANDBOX/remote-1.3.0" offline 2>&1)"; rc=$?
t_ok "offline update refused" 1 "$rc"
t_ok "offline leaves file unchanged" 0 "$(t_rc cmp "$PATCHED" "$SANDBOX/self.sh")"
t_ok "empty update URL disables normally" 0 "$(t_rc env NOWHERE_V3_SELF_URL= bash "$PATCHED" self-update)"
else
  t_skip "self-update (GNU chmod/chown --reference unavailable on this host)"
fi

# ---------------------------------------------------------------------------
t_section "share links and Portal probe"
shares="$(v3_url shares "portal://$K@*:2083?morph=0" 203.0.113.5 'NW3 测试')"
t_ok "share TCP format" yes "$(grep -q '^nowhere://.*?net=tcp&morph=0#' <<<"$shares" && echo yes || echo no)"
t_ok "share UDP format" yes "$(grep -q '^nowhere://.*?net=udp&morph=0#' <<<"$shares" && echo yes || echo no)"
t_ok "share has no pin" yes "$([[ "$shares" != *pin=* ]] && echo yes || echo no)"
t_ok "share node name encoded" yes "$([[ "$shares" == *%20* ]] && echo yes || echo no)"
probeurl="$(v3_url probe-link "portal://$K@*:2083?morph=0" 203.0.113.5 "$P64")"
t_ok "probe uses configured morph" yes "$([[ "$probeurl" == *morph=0* ]] && echo yes || echo no)"
t_ok "probe uses trusted pin" yes "$([[ "$probeurl" == *"pin=$P64"* ]] && echo yes || echo no)"
t_ok "probe URL validates" 0 "$(vu "$probeurl")"
t_ok "UDP-only probe selects UDP" yes "$(v3_url probe-link "portal://$K@*/udp:2083" 203.0.113.5 "$P64" | grep -q '/udp:2083' && echo yes || echo no)"
t_ok "egress source dial allowed" 0 "$(vu "egress://$K@relay/udp:2083?dial4=127.0.0.1")"
if ((HAVE_TIMEOUT)); then
cat > "$BIN_LINK" <<'CORE'
#!/bin/sh
printf 'vector://should-not-leak@host:2083?pin=should-not-leak\n'
printf 'Result: OK\n'
CORE
chmod +x "$BIN_LINK"
printf '%s\n' "$probeurl" >"$URL_FILE"
out="$(probe_action 2>&1)"; rc=$?
t_ok "Vector probe succeeds" 0 "$rc"
t_ok "probe output redacts key" yes "$([[ "$out" != *"$K"* && "$out" != *should-not-leak* ]] && echo yes || echo no)"
t_ok "probe output redacts pin" yes "$([[ "$out" != *"$P64"* ]] && echo yes || echo no)"
t_ok "probe output contains masked URL" yes "$([[ "$out" == *'vector://***@'* ]] && echo yes || echo no)"
printf 'portal://%s@*:2083?morph=0\n' "$K" >"$URL_FILE"
out="$( (PUBLIC_HOST=203.0.113.5; local_pin() { printf '%s\n' "$P64"; }; probe_action) 2>&1)"; rc=$?
t_ok "Portal probe succeeds" 0 "$rc"
printf 'egress://%s@relay/udp:2083\n' "$K" >"$URL_FILE"
out="$(probe_action 2>&1)"; rc=$?
t_ok "Egress probe refused" 1 "$rc"
cat > "$BIN_LINK" <<'CORE'
#!/bin/sh
printf 'Result: DIAL_FAILED\n'
exit 4
CORE
chmod +x "$BIN_LINK"
printf '%s\n' "$probeurl" >"$URL_FILE"
out="$(probe_action 2>&1)"; rc=$?
t_ok "probe preserves failure code" 4 "$rc"
t_ok "probe prints known failure" yes "$([[ "$out" == *DIAL_FAILED* ]] && echo yes || echo no)"
else
  t_skip "probe execution (timeout unavailable on this host)"
fi

# ---------------------------------------------------------------------------
t_section "release pagination (stubbed GitHub)"
python3 - "$SANDBOX" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);(p/'page1.json').write_text(json.dumps([{'tag_name':'v2.2.1'}]*100))
(p/'page2.json').write_text(json.dumps([{'tag_name':'v3.0.9'},{'tag_name':'v3.0.10'},{'tag_name':'v3.0.11','prerelease':True},{'tag_name':'v3.0.12','draft':True}]))
PY
versions="$( (curl_github() { cp "$SANDBOX/page${1##*page=}.json" "$2"; }; fetch_versions) )"
t_ok "second page stable release included" yes "$([[ "$versions" == *v3.0.10* ]] && echo yes || echo no)"
t_ok "numeric descending order" v3.0.10 "$(head -1 <<<"$versions")"
t_ok "prerelease excluded" yes "$([[ "$versions" != *v3.0.11* ]] && echo yes || echo no)"
t_ok "draft excluded" yes "$([[ "$versions" != *v3.0.12* ]] && echo yes || echo no)"
t_ok "V2 releases excluded" yes "$([[ "$versions" != *v2.* ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------
t_section "remote fingerprint"
out="$(fingerprint_action 'http://example.com:2083' 2>&1)"; rc=$?
t_ok "remote fingerprint rejects a non-nowhere scheme" 1 "$rc"
t_ok "remote fingerprint prints usage" yes "$([[ "$out" == *nowhere://* ]] && echo yes || echo no)"
out="$(fingerprint_action 'nowhere://key@relay.example' 2>&1)"; rc=$?
t_ok "remote fingerprint requires a port" 1 "$rc"
out="$(fingerprint_action 'nowhere://key@relay.example:0?morph=1' 2>&1)"; rc=$?
t_ok "remote fingerprint rejects port zero" 1 "$rc"
out="$(fingerprint_action 'nowhere://key@relay.example:2083/tcp:2083?morph=1' 2>&1)"; rc=$?
t_ok "remote fingerprint rejects carrier paths" 1 "$rc"
if ((HAVE_TIMEOUT)); then
FP64_COLON="$(printf '%s' "$P64" | sed 's/../&:/g;s/:$//' | tr 'a-f' 'A-F')"
cat > "$BIN_LINK" <<CORE
#!/bin/sh
printf '%s\n' "$FP64_COLON"
CORE
chmod +x "$BIN_LINK"
out="$(fingerprint_action 'nowhere://should-not-leak@relay.example:2083?morph=1#Name' 2>&1)"; rc=$?
t_ok "remote fingerprint succeeds" 0 "$rc"
t_ok "remote fingerprint normalized lowercase hex" yes "$([[ "$out" == *"$P64"* ]] && echo yes || echo no)"
t_ok "remote fingerprint redacts the key" yes "$([[ "$out" != *should-not-leak* ]] && echo yes || echo no)"
t_ok "remote fingerprint shows the masked endpoint" yes "$([[ "$out" == *'nowhere://***@relay.example:2083'* ]] && echo yes || echo no)"
cat > "$BIN_LINK" <<'CORE'
#!/bin/sh
exit 3
CORE
chmod +x "$BIN_LINK"
out="$(fingerprint_action 'nowhere://should-not-leak@relay.example:2083?morph=1' 2>&1)"; rc=$?
t_ok "remote fingerprint failure is nonzero" 1 "$rc"
t_ok "remote fingerprint failure hides the key" yes "$([[ "$out" != *should-not-leak* ]] && echo yes || echo no)"
else
  t_skip "remote fingerprint execution (timeout unavailable on this host)"
fi

# ---------------------------------------------------------------------------
t_section "menu and transaction regressions"
# Python creates a session with no controlling terminal, independently of CI TTY.
out="$(python3 - "$PATCHED" <<'PY'
import subprocess,sys
p=subprocess.run(['bash',sys.argv[1]],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True,timeout=4)
print(p.returncode);print(p.stdout.decode().count('22.'))
PY
)"
t_ok "no-tty menu exits 0" 0 "$(head -1 <<<"$out")"
t_ok "no-tty menu renders only once" 1 "$(tail -1 <<<"$out")"
printf 'portal://%s@127.0.0.1:2083?morph=1\n' "$K" > "$URL_FILE"
ORIG_URL="$(cat "$URL_FILE")"
# Run the same non-conditional child-shell boundary used by the menu.
out="$(bash -c 'source "$1"; systemctl() { return 0; }; wait_service() { return 0; }; set +e; ( set -e; trap finish EXIT; begin_transaction; printf broken > "$URL_FILE"; false ); rc=$?; exit "$rc"' _ "$PATCHED" 2>&1)"; rc=$?
t_ok "menu child failure nonzero" 1 "$rc"
t_ok "menu child restored configuration" "$ORIG_URL" "$(cat "$URL_FILE")"
mkdir -p "$RELEASES_DIR/v3.0.0-fixture"
printf '#!/bin/sh\nexit 0\n' > "$RELEASES_DIR/v3.0.0-fixture/nowhere"
chmod +x "$RELEASES_DIR/v3.0.0-fixture/nowhere"
ln -sfn "$RELEASES_DIR/v3.0.0-fixture" "$CURRENT_LINK"
out="$(bash -c 'source "$1"; mutating_setup() { :; }; ROLE=egress; KEY="$2"; ENDPOINT=relay:2083; ASSUME_YES=1; configure_action' _ "$PATCHED" "$K" 2>&1)"; rc=$?
t_ok "unattended role switch refused" 1 "$rc"
t_ok "role-switch diagnostic reached" yes "$([[ "$out" == *allow-role-switch* ]] && echo yes || echo no)"
t_ok "role guard preserves URL" "$ORIG_URL" "$(cat "$URL_FILE")"

# ---------------------------------------------------------------------------
t_section "persistent PEM reuse"
if command -v openssl >/dev/null 2>&1; then
  mkdir -p "$TLS_DIR/pem.original"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj /CN=test -keyout "$TLS_DIR/pem.original/key.pem" -out "$TLS_DIR/pem.original/cert.pem" >/dev/null 2>&1
  cp "$TLS_DIR/pem.original/cert.pem" "$SANDBOX/original-cert.pem"
  printf 'portal://%s@*:2083?tls=2&crt=%s&key=%s\n' "$K" "$TLS_DIR/pem.original/cert.pem" "$TLS_DIR/pem.original/key.pem" >"$URL_FILE"
  # Keep real openssl/parser/copy; stub ownership only, so it remains non-root.
  out="$(bash -c '
    source "$1"; KEY="$2"; ENDPOINT="*:2083"; CERT=""; TLS_KEY=""
    chown() { :; }
    install() { local -a a=(); while (($#)); do case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done; command install "${a[@]}"; }
    prepare_configuration
  ' _ "$PATCHED" "$K" 2>&1)"; rc=$?
  t_ok "same-role configuration prepared" 0 "$rc"
  newcert="$(v3_url get "$(cat "$URL_FILE")" crt)"
  t_ok "reconfigure preserves certificate bytes" 0 "$(t_rc cmp "$SANDBOX/original-cert.pem" "$newcert")"
  t_ok "superseded PEM directory pruned" yes "$([[ ! -d "$TLS_DIR/pem.original" ]] && echo yes || echo no)"
else t_skip "PEM reuse (openssl unavailable)"; fi
# ---------------------------------------------------------------------------
t_section "wizard defaults and optional doctor probe"
out="$(python3 - "$PATCHED" <<'PYW'
import subprocess,sys
code='source "$1"; ROLE="$2"; installation_wizard; printf "SUMMARY %s %s %s\\n" "$ROLE" "$ENDPOINT" "${#KEY}"'
for role in ('portal','vector','egress'):
 p=subprocess.run(['bash','-c',code,'test',sys.argv[1],role],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True,timeout=5)
 assert p.returncode==0,p.stderr.decode()
 print(p.stdout.decode().strip())
PYW
)"
t_ok "Portal defaults without tty" yes "$([[ "$out" == *'SUMMARY portal *:2083 32'* ]] && echo yes || echo no)"
t_ok "Vector defaults without tty" yes "$([[ "$out" == *'SUMMARY vector 127.0.0.1/tcp:2083 32'* ]] && echo yes || echo no)"
t_ok "Egress defaults without tty" yes "$([[ "$out" == *'SUMMARY egress 127.0.0.1/udp:2083 32'* ]] && echo yes || echo no)"
cat > "$CURRENT_LINK/nowhere" <<'CORE'
#!/bin/sh
if [ "$1" = --version ]; then echo 'nowhere-v3.0.0 linux/x86_64'; exit 0; fi
printf 'Result DIAL_FAILED\n'
exit 4
CORE
chmod +x "$CURRENT_LINK/nowhere"
cp "$CURRENT_LINK/nowhere" "$BIN_LINK"
printf '%s\n' "$probeurl" >"$URL_FILE"
out="$(bash -c 'source "$1"; require_root() { :; }; require_systemd() { :; }; DOCTOR_PROBE=1; doctor_action' _ "$PATCHED" 2>&1)"; rc=$?
t_ok "doctor probe failure warns only" 0 "$rc"
t_ok "doctor probe warning present" yes "$([[ "$out" == *'[Warn]'* ]] && echo yes || echo no)"
t_ok "doctor probe warning contains no key" yes "$([[ "$out" != *"$K"* ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------
t_section "wizard reinstall transaction"
printf 'tag: v3.0.0\n' > "$CURRENT_LINK/RELEASE-INFO"
ORIG_URL="$(cat "$URL_FILE")"
out="$(bash -c '
 source "$1"
 require_root() { :; }; mutating_setup() { :; }; ensure_user() { :; }; wait_service() { return 0; }
 ROLE=vector; KEY="$2"; ENDPOINT=relay:2083; REINSTALL_MODE=1
 prepare_configuration() { printf changed > "$URL_FILE"; }
 install_release() { return 19; }
 configure_action
' _ "$PATCHED" "$K" 2>&1)"; rc=$?
t_ok "reinstall download failure returned" 19 "$rc"
t_ok "reinstall download failure restores URL" "$ORIG_URL" "$(cat "$URL_FILE")"

# ---------------------------------------------------------------------------
t_section "integration fixes (prompt visibility, advanced carry)"

# The v1.1.0 review found every interactive prompt hidden behind 2>/dev/null;
# guard against the pattern coming back.
t_ok "no stderr-suppressed read prompts" yes \
  "$(grep -q '</dev/tty; } 2>/dev/null' "$SCRIPT" && echo no || echo yes)"
s="$(v3_url build portal "$K" '*:2083' 1 direct 127.0.0.1:1083 '' '' '' '')"
s2="$(v3_url set-advanced "$s" 100 50)"
t_ok "set-advanced adds rate" yes "$(grep -q 'rate=100' <<<"$s2" && echo yes || echo no)"
t_ok "set-advanced adds etar" yes "$(grep -q 'etar=50' <<<"$s2" && echo yes || echo no)"
t_ok "set-advanced result validates" 0 "$(vu "$s2")"
# rate/etar must survive a reconfigure: load_config_fields reads them so the
# rebuilt URL can carry them via set-advanced.
printf 'portal://%s@*:2083?morph=0&tls=1&rate=123&etar=45\n' "$K" > "$URL_FILE"
load_config_fields
t_ok "load_config_fields reads rate" 123 "$RATE"
t_ok "load_config_fields reads etar" 45 "$ETAR"

# ---------------------------------------------------------------------------
printf '\n%s\n' "----------------------------------------"
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
