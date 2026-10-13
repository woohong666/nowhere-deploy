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
t_ok "no self-update URL"           yes "$(grep -q 'DEFAULT_SELF_UPDATE_URL' "$PATCHED" && echo no || echo yes)"

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
  LOCK_FILE="${BUILD_LOCK_DIR%.d}"
  rm -f "$LOCK_FILE"; BUILD_LOCK_HELD=0
  t_ok "free lock is acquirable"      0 "$(t_rc acquire_build_lock)"
  t_ok "flag set after acquire"       1 "$BUILD_LOCK_HELD"
  t_ok "contention refused"           1 "$(t_rc bash -c 'source "$1" >/dev/null 2>&1; require_root() { :; }; acquire_build_lock' _ "$PATCHED")"
  release_build_lock
  t_ok "flag cleared after release"   0 "$BUILD_LOCK_HELD"
  t_ok "reacquirable after release"   0 "$(t_rc bash -c 'source "$1" >/dev/null 2>&1; require_root() { :; }; acquire_build_lock' _ "$PATCHED")"
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
printf '\n%s\n' "----------------------------------------"
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
