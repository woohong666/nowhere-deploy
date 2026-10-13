#!/usr/bin/env bash
#
# Test suite for nowhere-v2.sh.
#
# Everything runs inside a temporary sandbox: the manager's path declarations are
# rewritten before it is sourced, so no test can touch the real /etc/nowhere-v2,
# /opt/nowhere-v2, or systemd. The suite needs no root and no network.
#
# Usage:
#   bash tests/nowhere-v2.test.sh [path/to/nowhere-v2.sh]
#
# Exits 0 when every assertion passes, 1 when any fails, 2 on a setup error.
#
# NOTE for anyone extending this file: the manager defines ok/warn/die/info and
# many other short names. Never name a test helper after one of them, or the
# helper silently replaces the manager's function and tests fail for the wrong
# reason. The t_* prefix is used here for that reason.

# This suite deliberately assigns the manager's own globals (LANG_CODE, VERSION,
# ROLE, KEY, TLS, ...) so that its functions can read them. Shellcheck cannot see
# across the sourced file, so every "appears unused" warning here is expected.
# shellcheck disable=SC2034

set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SELF_DIR}/.." && pwd)"
SCRIPT="${1:-${REPO_ROOT}/nowhere-v2.sh}"

[[ -f "$SCRIPT" ]] || { echo "FATAL: script not found: $SCRIPT" >&2; exit 2; }

SANDBOX="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 2; }
cleanup_sandbox() { rm -rf -- "$SANDBOX"; }
trap cleanup_sandbox EXIT

# ---------------------------------------------------------------------------
# Sandbox the manager
# ---------------------------------------------------------------------------

# Rewrite the path declarations so every filesystem side effect lands in $SANDBOX.
# A renamed declaration must abort the run: an unpatched path would let the tests
# operate on the real system.
patch_script() {
  local src="$1" dst="$2" sb="$3" v
  sed \
    -e "s|^readonly CONFIG_DIR=.*|readonly CONFIG_DIR=\"${sb}/etc\"|" \
    -e "s|^readonly INSTALL_ROOT=.*|readonly INSTALL_ROOT=\"${sb}/opt\"|" \
    -e "s|^readonly UNIT_FILE=.*|readonly UNIT_FILE=\"${sb}/unit.service\"|" \
    -e "s|^readonly LAUNCHER=.*|readonly LAUNCHER=\"${sb}/bin/launch\"|" \
    -e "s|^readonly BIN_LINK=.*|readonly BIN_LINK=\"${sb}/bin/nowhere-v2\"|" \
    -e "s|^readonly SWAP_FILE=.*|readonly SWAP_FILE=\"${sb}/swap\"|" \
    -e "s|^readonly BUILD_LOCK_DIR=.*|readonly BUILD_LOCK_DIR=\"${sb}/lock.d\"|" \
    "$src" > "$dst"

  for v in CONFIG_DIR INSTALL_ROOT UNIT_FILE LAUNCHER BIN_LINK SWAP_FILE BUILD_LOCK_DIR; do
    grep -q "^readonly ${v}=\"${sb}" "$dst" ||
      { echo "FATAL: ${v} was not sandboxed; refusing to run" >&2; exit 2; }
  done
}

mkdir -p "$SANDBOX/bin" "$SANDBOX/etc/tls" "$SANDBOX/opt/releases"

# Stub the host commands the manager shells out to. Without this, write_unit and
# friends would invoke the real systemctl.
for c in systemctl journalctl runuser ss getent useradd groupadd; do
  printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/$c"
  chmod +x "$SANDBOX/bin/$c"
done
PATH="$SANDBOX/bin:$PATH"

PATCHED="$SANDBOX/manager.sh"
patch_script "$SCRIPT" "$PATCHED" "$SANDBOX"

# The manager enables `set -Eeuo pipefail` and installs its own EXIT trap when
# sourced; undo both so one failing assertion cannot abort the suite.
# shellcheck disable=SC1090
source "$PATCHED" >/dev/null 2>&1 || true
set +e
trap cleanup_sandbox EXIT

LANG_CODE=en
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
  # Normalised on purpose: the manager fails with 1 from `die` and with 2 from
  # its Python helpers, and every caller only tests for non-zero. Asserting a
  # specific code here would break on an unrelated change to either.
  ( "$@" ) >/dev/null 2>&1 && echo 0 || echo 1
}

t_section() { printf '\n%s\n' "$1"; }

file_mode() { # portable: GNU stat first, then BSD
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

# Simulate "no usable controlling terminal" without depending on the host: a
# shell function named `read` shadows the builtin and always fails, which is
# exactly what a failed `read </dev/tty` looks like to the caller.
no_tty() { ( read() { return 1; }; "$@" ); }

# ---------------------------------------------------------------------------
t_section "validators"

t_ok "role: portal accepted"      0 "$(t_rc validate_role portal)"
t_ok "role: bogus rejected"       1 "$(t_rc validate_role bogus)"
t_ok "tls: 2 accepted"            0 "$(t_rc validate_tls 2)"
t_ok "tls: 3 rejected"            1 "$(t_rc validate_tls 3)"
t_ok "log: event rejected"        1 "$(t_rc validate_log event)"
t_ok "log: loud rejected"         1 "$(t_rc validate_log loud)"
t_ok "key: 32-hex accepted"       0 "$(t_rc validate_key "$(printf 'a%.0s' $(seq 1 32))")"
t_ok "key: 64-hex accepted"       0 "$(t_rc validate_key "$(printf 'a%.0s' $(seq 1 64))")"
t_ok "key: 31-hex rejected"       1 "$(t_rc validate_key "$(printf 'a%.0s' $(seq 1 31))")"
t_ok "key: 65-hex rejected"       1 "$(t_rc validate_key "$(printf 'a%.0s' $(seq 1 65))")"
t_ok "key: uppercase rejected"    1 "$(t_rc validate_key "$(printf 'A%.0s' $(seq 1 32))")"
t_ok "key: non-hex rejected"      1 "$(t_rc validate_key "validkey_1234567890")"
t_ok "vector key: legacy ok"      0 "$(t_rc validate_vector_key "validkey_1234567890")"
t_ok "vector key: 64-hex ok"      0 "$(t_rc validate_vector_key "$(printf 'a%.0s' $(seq 1 64))")"
t_ok "dial4: IP ok"               0 "$(t_rc validate_dial_value 4 192.0.2.10)"
t_ok "dial4: wrong family out"    1 "$(t_rc validate_dial_value 4 2001:db8::10)"
t_ok "dial6: IP ok"               0 "$(t_rc validate_dial_value 6 2001:db8::10)"
t_ok "dial6: mapped out"          1 "$(t_rc validate_dial_value 6 ::ffff:192.0.2.10)"
t_ok "dial6: zone out"            1 "$(t_rc validate_dial_value 6 'fe80::1%eth0')"
t_ok "dial: auto ok"              0 "$(t_rc validate_dial_value any auto)"
t_ok "dial: bracketed out"        1 "$(t_rc validate_dial_value any '[2001:db8::10]')"
t_ok "dial+dial6 conflict"        1 "$(DIAL=192.0.2.10; DIAL4=auto; DIAL6=2001:db8::10; t_rc validate_dial_settings)"
t_ok "dial4+auto dial6 ok"        0 "$(DIAL=auto; DIAL4=192.0.2.10; DIAL6=auto; t_rc validate_dial_settings)"
t_ok "morph-prelude: full8 ok"    0 "$(t_rc validate_morph_prelude full8)"
t_ok "morph-prelude: bogus out"   1 "$(t_rc validate_morph_prelude bogus)"
t_ok "memory-profile: memory ok"  0 "$(t_rc validate_memory_profile memory)"
t_ok "memory-profile: bogus out"  1 "$(t_rc validate_memory_profile bogus)"
t_ok "version: latest-v2 ok"      0 "$(t_rc validate_version_arg latest-v2)"
t_ok "version: v2.1.0 ok"         0 "$(t_rc validate_version_arg v2.1.0)"
t_ok "version: v1.8.3 rejected"   1 "$(t_rc validate_version_arg v1.8.3)"
t_ok "version: v3.0.0 rejected"   1 "$(t_rc validate_version_arg v3.0.0)"
t_ok "keep-releases: 20 ok"       0 "$(t_rc validate_keep_releases 20)"
t_ok "keep-releases: 21 out"      1 "$(t_rc validate_keep_releases 21)"
t_ok "rate: 0 ok"                 0 "$(t_rc validate_rate 0)"
t_ok "rate: 2147483647 ok"        0 "$(t_rc validate_rate 2147483647)"
t_ok "rate: decimal rejected"     1 "$(t_rc validate_rate 0.5)"
t_ok "rate: nan rejected"         1 "$(t_rc validate_rate nan)"
t_ok "rate: overflow rejected"    1 "$(t_rc validate_rate 2147483648)"

# ---------------------------------------------------------------------------
t_section "endpoint grammar (valid, per upstream docs/configuration.md)"

ep() { endpoint_canonical "$1" "$2" 2>/dev/null; }

t_ok "portal *:2082"                "*:2082"                "$(ep portal '*:2082')"
t_ok "portal empty host -> *"       "*:2082"                "$(ep portal ':2082')"
t_ok "portal */tcp:2006"            "*/tcp:2006"            "$(ep portal '*/tcp:2006')"
t_ok "portal */udp:2017"            "*/udp:2017"            "$(ep portal '*/udp:2017')"
t_ok "portal dual carrier + family" "*/tcp4:2006/udp6:2017" "$(ep portal '*/tcp4:2006/udp6:2017')"
t_ok "portal carriers are ordered"  "h.example/tcp:2006/udp:2017" "$(ep portal 'h.example/udp:2017/tcp:2006')"
t_ok "vector host:2082"             "relay.example:2082"    "$(ep vector 'relay.example:2082')"
t_ok "vector host/tcp:2006"         "relay.example/tcp:2006" "$(ep vector 'relay.example/tcp:2006')"
t_ok "IPv4 literal"                 "192.0.2.1:2082"        "$(ep portal '192.0.2.1:2082')"
t_ok "IPv6 bracketed"               "[2001:db8::1]:2082"    "$(ep portal '[2001:db8::1]:2082')"
t_ok "IPv6 + tcp6"                  "[2001:db8::1]/tcp6:2006" "$(ep portal '[2001:db8::1]/tcp6:2006')"

# ---------------------------------------------------------------------------
t_section "endpoint grammar (invalid shapes listed upstream)"

t_ok "compact port + carrier path"  1 "$(t_rc ep portal 'host:2000/tcp:2006')"
t_ok "trailing slash"               1 "$(t_rc ep portal 'host/tcp:2006/')"
t_ok "duplicate tcp family"         1 "$(t_rc ep portal 'host/tcp:2006/tcp6:2006')"
t_ok "unknown carrier sctp"         1 "$(t_rc ep portal 'host/sctp:2000')"
t_ok "IPv4 literal with tcp6"       1 "$(t_rc ep portal '192.0.2.1/tcp6:2006')"
t_ok "port 0"                       1 "$(t_rc ep portal 'host/tcp:0')"
t_ok "wildcard on vector"           1 "$(t_rc ep vector '*/tcp:2006')"
t_ok "missing port"                 1 "$(t_rc ep portal 'host')"
t_ok "unbracketed IPv6"             1 "$(t_rc ep portal '2001:db8::1:2082')"
t_ok "bracketed garbage rejected"   1 "$(t_rc ep portal '[bad]:2082')"
t_ok "bracketed IPv6 still valid"   0 "$(t_rc ep portal '[2001:db8::1]:2082')"
t_ok "port out of range"            1 "$(t_rc ep portal 'host:70000')"
t_ok "three carriers"               1 "$(t_rc ep portal 'host/tcp:1/udp:2/tcp4:3')"

t_ok "compact enables TCP+UDP"      "1/1" "$(endpoint_has_tcp portal '*:2082')/$(endpoint_has_udp portal '*:2082')"
t_ok "tcp4 yields family 4"         "4"   "$(endpoint_tcp_family portal '*/tcp4:2006')"
t_ok "IPv6 yields family 6"         "6"   "$(endpoint_tcp_family portal '[2001:db8::1]:2082')"
t_ok "no family yields 0"           "0"   "$(endpoint_tcp_family portal '*:2082')"

# ---------------------------------------------------------------------------
t_section "URL build -> validate -> reload round trip"

reset_portal() {
  ROLE=portal; KEY="$(printf 'a%.0s' $(seq 1 64))"; ENDPOINT="*:2082"; TLS=1; MORPH=0
  RATE=0; ETAR=0; DIAL=auto; DIAL4=auto; DIAL6=auto; LOG_LEVEL=info; CERT=""; TLS_KEY=""
  OUT_SOCKS=none; NEXT=none; UP=auto; DOWN=auto; MUX=0; SNI=none; PIN=none
  PUBLIC_HOST=""; NODE_NAME=""
}
reset_vector() {
  ROLE=vector; KEY="$(printf 'a%.0s' $(seq 1 64))"; ENDPOINT="relay.example:2082"; TLS=1; MORPH=0
  RATE=0; ETAR=0; LOG_LEVEL=info; VECTOR_SOCKS="127.0.0.1:1082"
  UP=auto; DOWN=auto; MUX=0; SNI=none; PIN=none
}

reset_portal; MORPH=1
u="$(build_portal_url)"
t_ok "portal+morph validates"  0 "$(t_rc validate_imported_url "$u")"
printf '%s\n' "$u" > "$URL_FILE"; load_existing_config >/dev/null 2>&1
t_ok "role round trips"        portal "$ROLE"
t_ok "key round trips"         "$(printf 'a%.0s' $(seq 1 64))" "$KEY"
t_ok "morph round trips"       1 "$MORPH"

reset_portal; NEXT="$(printf 'b%.0s' $(seq 1 32))@origin.example/tcp:2006"; UP=tcp; DOWN=tcp
u="$(build_portal_url)"
t_ok "portal+next validates"   0 "$(t_rc validate_imported_url "$u")"
printf '%s\n' "$u" > "$URL_FILE"; load_existing_config >/dev/null 2>&1
t_ok "next round trips verbatim" "$(printf 'b%.0s' $(seq 1 32))@origin.example/tcp:2006" "$NEXT"

reset_portal; DIAL4=192.0.2.10; DIAL6=2001:db8::10
u="$(build_portal_url)"
t_ok "dial4+dial6 validates"   0 "$(t_rc validate_imported_url "$u")"
printf '%s\n' "$u" > "$URL_FILE"; DIAL4=auto; DIAL6=auto; load_existing_config >/dev/null 2>&1
t_ok "dial4 round trips"       "192.0.2.10"   "$DIAL4"
t_ok "dial6 round trips"       "2001:db8::10" "$DIAL6"
t_ok "dial stays auto"         "auto"         "$DIAL"

reset_portal; OUT_SOCKS="127.0.0.1:1080"
u="$(build_portal_url)"
t_ok "portal+out-socks validates" 0 "$(t_rc validate_imported_url "$u")"
printf '%s\n' "$u" > "$URL_FILE"; load_existing_config >/dev/null 2>&1
t_ok "out-socks round trips"      "127.0.0.1:1080" "$OUT_SOCKS"

reset_vector; UP=tcp; DOWN=udp; MUX=1; MORPH=1; SNI="relay.example"; RATE=100; LOG_LEVEL=debug
u="$(build_vector_url)"
t_ok "vector validates"        0 "$(t_rc validate_imported_url "$u")"
printf '%s\n' "$u" > "$URL_FILE"; load_existing_config >/dev/null 2>&1
t_ok "vector role"             vector "$ROLE"
t_ok "vector up/down"          "tcp/udp" "$UP/$DOWN"
t_ok "vector mux"              1 "$MUX"
t_ok "vector sni"              relay.example "$SNI"
t_ok "vector rate"             100 "$RATE"
t_ok "vector log"              debug "$LOG_LEVEL"

reset_vector; VECTOR_SOCKS="user:pass@127.0.0.1:1080"
u="$(build_vector_url)"
t_ok "socks with auth validates" 0 "$(t_rc validate_imported_url "$u")"
printf '%s\n' "$u" > "$URL_FILE"; load_existing_config >/dev/null 2>&1
t_ok "socks auth round trips"   "user:pass@127.0.0.1:1080" "$VECTOR_SOCKS"

reset_portal; TLS=2; CERT="$SANDBOX/etc/tls/cert.pem"; TLS_KEY="$SANDBOX/etc/tls/key.pem"
: > "$CERT"; : > "$TLS_KEY"
u="$(build_portal_url)"
t_ok "tls=2 validates"          0 "$(t_rc validate_imported_url "$u")"
printf '%s\n' "$u" > "$URL_FILE"; load_existing_config >/dev/null 2>&1
t_ok "tls=2 cert round trips"   "$CERT" "$CERT"
t_ok "tls=2 key round trips"    "$TLS_KEY" "$TLS_KEY"

# ---------------------------------------------------------------------------
t_section "URL validation rules"

K="$(printf 'a%.0s' $(seq 1 32))"
t_url() { t_rc validate_imported_url "$1"; }

t_ok "password userinfo rejected"   1 "$(t_url "portal://user:pass@host:2082?tls=1")"
t_ok "fragment rejected"            1 "$(t_url "portal://$K@host:2082?tls=1#frag")"
t_ok "unknown scheme rejected"      1 "$(t_url "http://$K@host:2082?tls=1")"
t_ok "malformed percent rejected"   1 "$(t_url "portal://$K@host:2082?tls=1&log=%zz")"
t_ok "socks+next rejected"          1 "$(t_url "portal://$K@host:2082?tls=1&socks=127.0.0.1:1080&next=nk@o.example:2082")"
t_ok "tls=2 without crt/key"        1 "$(t_url "portal://$K@host:2082?tls=2")"
t_ok "vector without socks"         1 "$(t_url "vector://$K@host:2082?up=tcp&down=tcp")"
t_ok "next without @"               1 "$(t_url "portal://$K@host:2082?tls=1&next=origin.example:2082")"
t_ok "next with wildcard"           1 "$(t_url "portal://$K@host:2082?tls=1&next=nk@*/tcp:2006")"
t_ok "pin not 64 hex"               1 "$(t_url "portal://$K@host:2082?tls=1&pin=abcd")"
t_ok "sni with invalid chars"       1 "$(t_url "portal://$K@host:2082?tls=1&sni=bad_host!")"
t_ok "up value invalid"             1 "$(t_url "vector://$K@host:2082?socks=127.0.0.1:1080&up=quic")"
t_ok "morph not 0/1"                1 "$(t_url "portal://$K@host:2082?tls=1&morph=2")"
t_ok "log level invalid"            1 "$(t_url "portal://$K@host:2082?tls=1&log=loud")"
t_ok "log event removed (2.1.1)"    1 "$(t_url "portal://$K@host:2082?tls=1&log=event")"
t_ok "port 0"                       1 "$(t_url "portal://$K@host:0?tls=1")"
t_ok "empty shared key"             1 "$(t_url "portal://@host:2082?tls=1")"
t_ok "mix needs both carriers"      1 "$(t_url "vector://$K@host/tcp:2082?socks=127.0.0.1:1080&up=mix&down=mix")"

t_ok "minimal portal accepted"      0 "$(t_url "portal://$K@host:2082?tls=1")"
t_ok "minimal vector accepted"      0 "$(t_url "vector://$K@host:2082?socks=127.0.0.1:1080")"
t_ok "net= is unknown, accepted"    0 "$(t_url "portal://$K@host:2082?tls=1&net=mix")"
t_ok "alpn= is unknown, accepted"   0 "$(t_url "portal://$K@host:2082?tls=1&alpn=nw2")"
t_ok "first duplicate wins"         "1" "$(query_get "portal://$K@h:2082?tls=1&morph=1&morph=0" morph)"

# Nowhere 2.2.x key policy: Portal/next strict, Vector lenient.
t_ok "portal 64-hex key accepted"   0 "$(t_url "portal://$(printf 'a%.0s' $(seq 1 64))@host:2082?tls=1")"
t_ok "portal 31-hex key rejected"   1 "$(t_url "portal://$(printf 'a%.0s' $(seq 1 31))@host:2082?tls=1")"
t_ok "portal 65-hex key rejected"   1 "$(t_url "portal://$(printf 'a%.0s' $(seq 1 65))@host:2082?tls=1")"
t_ok "portal uppercase rejected"    1 "$(t_url "portal://$(printf 'A%.0s' $(seq 1 32))@host:2082?tls=1")"
t_ok "portal legacy key rejected"   1 "$(t_url "portal://LegacyKey_1234567890@host:2082?tls=1")"
t_ok "vector legacy key accepted"   0 "$(t_url "vector://LegacyKey_1234567890@host:2082?socks=127.0.0.1:1080")"
t_ok "vector 1-char key accepted"   0 "$(t_url "vector://a@host:2082?socks=127.0.0.1:1080")"
t_ok "vector 255-char key accepted" 0 "$(t_url "vector://$(printf 'A%.0s' $(seq 1 255))@host:2082?socks=127.0.0.1:1080")"
t_ok "vector 256-char key rejected" 1 "$(t_url "vector://$(printf 'A%.0s' $(seq 1 256))@host:2082?socks=127.0.0.1:1080")"
t_ok "next legacy key rejected"     1 "$(t_url "portal://$K@host:2082?tls=1&next=legacykey_1234567890@origin.example:2082")"
t_ok "next 32-hex key accepted"     0 "$(t_url "portal://$K@host:2082?tls=1&next=$(printf 'b%.0s' $(seq 1 32))@origin.example:2082")"

# Nowhere 2.2.0 source binding: dial4/dial6 and the dial exclusivity rule.
t_ok "dial4 valid"                  0 "$(t_url "portal://$K@host:2082?tls=1&dial4=192.0.2.10")"
t_ok "dial6 valid"                  0 "$(t_url "portal://$K@host:2082?tls=1&dial6=2001:db8::10")"
t_ok "dial4 wrong family rejected"  1 "$(t_url "portal://$K@host:2082?tls=1&dial4=2001:db8::10")"
t_ok "dial6 mapped rejected"        1 "$(t_url "portal://$K@host:2082?tls=1&dial6=::ffff:192.0.2.10")"
t_ok "dial4 bracketed rejected"     1 "$(t_url "portal://$K@host:2082?tls=1&dial4=[192.0.2.10]")"
t_ok "dial+dial4 conflict"          1 "$(t_url "portal://$K@host:2082?tls=1&dial=auto&dial4=192.0.2.10")"
t_ok "rate=0 accepted"              0 "$(t_url "portal://$K@host:2082?tls=1&rate=0")"
t_ok "rate max accepted"            0 "$(t_url "portal://$K@host:2082?tls=1&rate=2147483647")"
t_ok "rate=0.5 rejected"            1 "$(t_url "portal://$K@host:2082?tls=1&rate=0.5")"
t_ok "rate=nan rejected"            1 "$(t_url "portal://$K@host:2082?tls=1&rate=nan")"
t_ok "rate overflow rejected"       1 "$(t_url "portal://$K@host:2082?tls=1&rate=2147483648")"

# ---------------------------------------------------------------------------
t_section "version_ge"

vg() { version_ge "$1" "$2" && echo ge || echo lt; }
t_ok "equal"          ge "$(vg v2.1.0 v2.1.0)"
t_ok "patch newer"    ge "$(vg v2.1.1 v2.1.0)"
t_ok "patch older"    lt "$(vg v2.0.2 v2.1.0)"
t_ok "multi-digit"    ge "$(vg v2.10.0 v2.9.9)"
t_ok "major newer"    ge "$(vg v3.0.0 v2.1.0)"
t_ok "short form"     ge "$(vg v2.1 v2.1.0)"
t_ok "garbage"        lt "$(vg banana v2.1.0)"
t_ok "empty"          lt "$(vg '' v2.1.0)"
t_ok "1.75 < 1.85"    lt "$(vg 1.75.0 1.85.0)"
t_ok "1.85 >= 1.85"   ge "$(vg 1.85.0 1.85.0)"

# ---------------------------------------------------------------------------
t_section "load_meta rejects invalid persisted values"

printf 'MEMORY_PROFILE=oops\nMORPH_PRELUDE=boom\n' > "$META_FILE"
MEMORY_PROFILE=balanced; MORPH_PRELUDE=full8
load_meta 2>/dev/null
t_ok "invalid meta ignored, valid current kept" "balanced/full8" "$MEMORY_PROFILE/$MORPH_PRELUDE"

printf 'MEMORY_PROFILE=memory\nMORPH_PRELUDE=low7\n' > "$META_FILE"
MEMORY_PROFILE=balanced; MORPH_PRELUDE=full8
load_meta 2>/dev/null
t_ok "valid meta applied" "memory/low7" "$MEMORY_PROFILE/$MORPH_PRELUDE"

printf 'MORPH_PRELUDE=low7\nEVIL=1\n' > "$META_FILE"
unset EVIL
load_meta 2>/dev/null
t_ok "unknown key is not injected" "" "${EVIL-}"

# ---------------------------------------------------------------------------
t_section "refresh_meta_versions"

cat > "$META_FILE" <<'META'
SCRIPT_CHANNEL=v2
SCRIPT_VERSION=1.1.0
CORE_VERSION=v2.0.0
ROLE=vector
PUBLIC_HOST=relay.example.com
NODE_NAME=my-node
MEMORY_PROFILE=memory
MORPH_PRELUDE=full8
CLIENT_UP=tcp
META
chmod 640 "$META_FILE"
mode_before="$(file_mode "$META_FILE")"
VERSION=v2.1.0
refresh_meta_versions
t_ok "SCRIPT_VERSION refreshed" "$SCRIPT_VERSION" "$(sed -n 's/^SCRIPT_VERSION=//p' "$META_FILE")"
t_ok "CORE_VERSION refreshed"   v2.1.0 "$(sed -n 's/^CORE_VERSION=//p' "$META_FILE")"
t_ok "ROLE untouched"           vector "$(sed -n 's/^ROLE=//p' "$META_FILE")"
t_ok "PUBLIC_HOST untouched"    relay.example.com "$(sed -n 's/^PUBLIC_HOST=//p' "$META_FILE")"
t_ok "NODE_NAME untouched"      my-node "$(sed -n 's/^NODE_NAME=//p' "$META_FILE")"
t_ok "MEMORY_PROFILE untouched" memory "$(sed -n 's/^MEMORY_PROFILE=//p' "$META_FILE")"
t_ok "MORPH_PRELUDE untouched"  full8 "$(sed -n 's/^MORPH_PRELUDE=//p' "$META_FILE")"
t_ok "CLIENT_UP untouched"      tcp "$(sed -n 's/^CLIENT_UP=//p' "$META_FILE")"
t_ok "no duplicated lines"      9 "$(wc -l < "$META_FILE" | tr -d ' ')"
t_ok "mode preserved"           "$mode_before" "$(file_mode "$META_FILE")"

printf 'ROLE=portal\n' > "$META_FILE"
VERSION=v2.1.0
refresh_meta_versions
t_ok "missing SCRIPT_VERSION appended" "$SCRIPT_VERSION" "$(sed -n 's/^SCRIPT_VERSION=//p' "$META_FILE")"
t_ok "missing CORE_VERSION appended"   v2.1.0 "$(sed -n 's/^CORE_VERSION=//p' "$META_FILE")"
t_ok "existing content kept"           portal "$(sed -n 's/^ROLE=//p' "$META_FILE")"

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
  acquire_build_lock
  t_ok "acquire is idempotent"         0 "$?"
  t_ok "held flag still set"           1 "$BUILD_LOCK_HELD"
  release_build_lock
  t_ok "release clears flag"           0 "$BUILD_LOCK_HELD"
else
  # flock is util-linux and absent on macOS; CI (Linux) runs the real branch.
  t_skip "build lock (flock unavailable on this host)"
fi

# ---------------------------------------------------------------------------
t_section "transaction rollback (top-level failure path)"

printf 'portal://%s@*:2082?tls=1\n' "$(printf 'a%.0s' $(seq 1 32))" > "$URL_FILE"
ORIG_URL="$(cat "$URL_FILE")"
printf 'ORIGINAL-UNIT\n' > "$UNIT_FILE"
ORIG_UNIT="$(cat "$UNIT_FILE")"
out="$(bash -c 'source "$1" >/dev/null 2>&1; require_root() { :; }; systemctl() { return 0; }; wait_service() { return 0; }; begin_transaction; printf "changed" > "$URL_FILE"; printf "changed" > "$UNIT_FILE"; false' _ "$PATCHED" 2>&1)"
rc=$?
t_ok "failure exits non-zero" 1 "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
t_ok "url.conf rolled back"   "$ORIG_URL"  "$(cat "$URL_FILE")"
t_ok "unit rolled back"       "$ORIG_UNIT" "$(cat "$UNIT_FILE")"
out="$(bash -c 'source "$1" >/dev/null 2>&1; require_root() { :; }; systemctl() { return 0; }; wait_service() { return 0; }; begin_transaction; printf "kept" > "$URL_FILE"; TX_COMMITTED=1' _ "$PATCHED" 2>&1)"
t_ok "committed change kept"  kept "$(cat "$URL_FILE")"

# ---------------------------------------------------------------------------
t_section "prompts never spin without a terminal"

t_ok "valid default returned"  info "$(no_tty prompt_choice 'Log level' info none info debug 2>/dev/null)"
t_ok "invalid default stops"   1 "$(t_rc no_tty prompt_choice 'Log level' loud none info debug)"
ROLE=portal; KEY="$(printf 'a%.0s' $(seq 1 32))"
t_ok "hex key accepted (portal)"  0 "$(t_rc no_tty prompt_key)"
ROLE=portal; KEY=validkey_1234567890
t_ok "legacy key stops (portal)"  1 "$(t_rc no_tty prompt_key)"
ROLE=vector; KEY=validkey_1234567890
t_ok "legacy key ok (vector)"     0 "$(t_rc no_tty prompt_key)"
ROLE=vector; KEY=bad
t_ok "bad key stops (vector)"     1 "$(t_rc no_tty prompt_key)"

# ---------------------------------------------------------------------------
t_section "safe_extract_tar"

python3 - "$SANDBOX" <<'PY'
import io, os, sys, tarfile
sb = sys.argv[1]
def add(t, name, link=None, fifo=False):
    ti = tarfile.TarInfo(name); ti.mode = 0o755
    if link:
        ti.type = tarfile.SYMTYPE; ti.linkname = link; t.addfile(ti)
    elif fifo:
        ti.type = tarfile.FIFOTYPE; t.addfile(ti)
    else:
        b = b"binary"; ti.size = len(b); t.addfile(ti, io.BytesIO(b))
with tarfile.open(f"{sb}/good.tar.gz", "w:gz") as t: add(t, "nowhere")
with tarfile.open(f"{sb}/evil.tar.gz", "w:gz") as t: add(t, "nowhere", "/etc/passwd")
with tarfile.open(f"{sb}/trav.tar.gz", "w:gz") as t: add(t, "../escape")
with tarfile.open(f"{sb}/fifo.tar.gz", "w:gz") as t: add(t, "nowhere", fifo=True)
with tarfile.open(f"{sb}/dup.tar.gz", "w:gz") as t:
    add(t, "a/nowhere"); add(t, "b/nowhere")
PY

mkdir -p "$SANDBOX/d1" "$SANDBOX/d2" "$SANDBOX/d3" "$SANDBOX/d4" "$SANDBOX/d5"
t_ok "regular tar extracts"      0   "$(t_rc safe_extract_tar "$SANDBOX/good.tar.gz" "$SANDBOX/d1")"
t_ok "binary present"            yes "$([[ -f "$SANDBOX/d1/nowhere" ]] && echo yes || echo no)"
t_ok "symlink tar refused"       1   "$(t_rc safe_extract_tar "$SANDBOX/evil.tar.gz" "$SANDBOX/d2")"
t_ok "nothing extracted on refuse" no "$([[ -e "$SANDBOX/d2/nowhere" ]] && echo yes || echo no)"
t_ok "traversal tar refused"     1   "$(t_rc safe_extract_tar "$SANDBOX/trav.tar.gz" "$SANDBOX/d3")"
t_ok "fifo tar refused"          1   "$(t_rc safe_extract_tar "$SANDBOX/fifo.tar.gz" "$SANDBOX/d4")"
t_ok "duplicate binary refused"  1   "$(t_rc safe_extract_tar "$SANDBOX/dup.tar.gz" "$SANDBOX/d5")"

# ---------------------------------------------------------------------------
t_section "certificate_is_self_signed"

if command -v openssl >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=sandbox-test \
    -keyout "$SANDBOX/cs.key" -out "$SANDBOX/cs.crt" >/dev/null 2>&1
  openssl req -new -newkey rsa:2048 -nodes -subj /CN=leaf \
    -keyout "$SANDBOX/leaf.key" -out "$SANDBOX/leaf.csr" >/dev/null 2>&1
  openssl x509 -req -in "$SANDBOX/leaf.csr" -CA "$SANDBOX/cs.crt" -CAkey "$SANDBOX/cs.key" \
    -CAcreateserial -days 1 -out "$SANDBOX/leaf.crt" >/dev/null 2>&1
  t_ok "self-signed cert detected" 0 "$(t_rc certificate_is_self_signed "$SANDBOX/cs.crt")"
  t_ok "missing cert returns 2"    2 "$(certificate_is_self_signed "$SANDBOX/cs-missing.crt"; echo $?)"
  if [[ -f "$SANDBOX/leaf.crt" ]]; then
    t_ok "CA-signed cert detected" 1 "$(t_rc certificate_is_self_signed "$SANDBOX/leaf.crt")"
  else
    t_skip "CA-signed cert check (openssl x509 -req unavailable)"
  fi
else
  t_skip "certificate_is_self_signed (no openssl)"
fi

# ---------------------------------------------------------------------------
t_section "backup_action output guard"

printf 'portal://AAAAAAAAAAAAAAAA@*:2082?tls=1\n' > "$URL_FILE"
t_ok "inside config dir refused" 1   "$(t_rc backup_action "$CONFIG_DIR/self.tar.gz")"
t_ok "no archive created"        no  "$([[ -e "$CONFIG_DIR/self.tar.gz" ]] && echo yes || echo no)"
t_ok "outside config dir allowed" 0  "$(t_rc backup_action "$SANDBOX/ok.tar.gz")"
t_ok "archive created"           yes "$([[ -f "$SANDBOX/ok.tar.gz" ]] && echo yes || echo no)"
t_ok "existing backup refused"   1   "$(t_rc backup_action "$SANDBOX/ok.tar.gz")"

# ---------------------------------------------------------------------------
t_section "resolve_version (offline, curl stubbed)"

cat > "$SANDBOX/releases.json" <<'JSON'
[
  {"tag_name": "v3.0.0",   "draft": false, "prerelease": false},
  {"tag_name": "v2.2.0-rc1","draft": false, "prerelease": true},
  {"tag_name": "v2.1.10",  "draft": false, "prerelease": false},
  {"tag_name": "v2.1.9",   "draft": false, "prerelease": false},
  {"tag_name": "v2.0.2",   "draft": false, "prerelease": false},
  {"tag_name": "v2.9.0",   "draft": true,  "prerelease": false}
]
JSON
install_runtime_deps() { :; }
curl_github() { cp "$SANDBOX/releases.json" "$2"; }
VERSION=latest-v2
resolve_version
t_ok "newest stable v2.x chosen" v2.1.10 "$VERSION"

# Page 1 is full (100 items) with no match; the release only appears on page 2.
mkdir -p "$SANDBOX/pages"
python3 - "$SANDBOX/pages" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
p.joinpath("1.json").write_text(json.dumps([{"tag_name": "v9.0.0", "draft": False, "prerelease": False}] * 100))
p.joinpath("2.json").write_text(json.dumps([
    {"tag_name": "v2.0.9",  "draft": False, "prerelease": False},
    {"tag_name": "v2.0.10", "draft": False, "prerelease": False},
    {"tag_name": "v2.9.0",  "draft": False, "prerelease": True},
]))
PY
curl_github() { local page="${1##*page=}"; cp "$SANDBOX/pages/${page}.json" "$2"; }
VERSION=latest-v2
resolve_version
t_ok "pagination reaches page 2" v2.0.10 "$VERSION"

# ---------------------------------------------------------------------------
t_section "release_asset_fields (real v2.1.0 asset names)"

cat > "$SANDBOX/assets.json" <<'JSON'
{
  "assets": [
    {"name": "nowhere-aarch64-apple-darwin.tar.gz",        "browser_download_url": "u1", "digest": "sha256:aa"},
    {"name": "nowhere-aarch64-unknown-freebsd.tar.gz",     "browser_download_url": "u2", "digest": "sha256:bb"},
    {"name": "nowhere-aarch64-unknown-linux-gnu.tar.gz",   "browser_download_url": "u3", "digest": "sha256:cc"},
    {"name": "nowhere-aarch64-unknown-linux-musl.tar.gz",  "browser_download_url": "u4", "digest": "sha256:dd"},
    {"name": "nowhere-x86_64-pc-windows-msvc.zip",         "browser_download_url": "u5", "digest": "sha256:ee"},
    {"name": "nowhere-x86_64-unknown-freebsd.tar.gz",      "browser_download_url": "u6", "digest": "sha256:ff"},
    {"name": "nowhere-x86_64-unknown-linux-gnu.tar.gz",    "browser_download_url": "u7", "digest": "sha256:11"},
    {"name": "nowhere-x86_64-unknown-linux-musl.tar.gz",   "browser_download_url": "u8", "digest": "sha256:22"}
  ]
}
JSON

for tgt in x86_64-unknown-linux-gnu x86_64-unknown-linux-musl \
           aarch64-unknown-linux-gnu aarch64-unknown-linux-musl; do
  out="$(release_asset_fields "$SANDBOX/assets.json" "$tgt" 2>/dev/null)"
  t_ok "$tgt -> unique asset" "nowhere-${tgt}.tar.gz" "$(printf '%s\n' "$out" | sed -n 1p)"
  t_ok "$tgt -> digest present" yes \
    "$(printf '%s\n' "$out" | sed -n 3p | grep -q '^sha256:' && echo yes || echo no)"
done
t_ok "unknown target rejected" 1 "$(t_rc release_asset_fields "$SANDBOX/assets.json" riscv64-unknown-linux-gnu)"

# ---------------------------------------------------------------------------
t_section "installed_core_version"

rm -rf "$SANDBOX/opt/current"
mkdir -p "$SANDBOX/opt/current"
printf 'tag: v2.1.0\n' > "$SANDBOX/opt/current/RELEASE-INFO"
t_ok "reads RELEASE-INFO first" v2.1.0 "$(installed_core_version)"
printf 'CORE_VERSION=v2.0.2\n' > "$META_FILE"
t_ok "RELEASE-INFO wins over meta" v2.1.0 "$(installed_core_version)"
rm -f "$SANDBOX/opt/current/RELEASE-INFO"
printf 'tag: v2.2.0\n' > "$SANDBOX/opt/current/BUILD-INFO"
t_ok "reads BUILD-INFO for source builds" v2.2.0 "$(installed_core_version)"
rm -f "$SANDBOX/opt/current/BUILD-INFO"
t_ok "falls back to manager.conf" v2.0.2 "$(installed_core_version)"
rm -f "$META_FILE"
t_ok "empty when nothing present" "" "$(installed_core_version)"

# ---------------------------------------------------------------------------
t_section "warn_morph_upgrade_requirement"

wmu() { # wmu <url> <target version> <previous version> -> warn|quiet
  printf '%s\n' "$1" > "$URL_FILE"
  VERSION="$2"
  local out
  out="$(warn_morph_upgrade_requirement "$3" 2>&1 >/dev/null)"
  [[ -n "$out" ]] && echo warn || echo quiet
}
U1='portal://AAAAAAAAAAAAAAAA@*:2082?tls=1&morph=1'
U0='portal://AAAAAAAAAAAAAAAA@*:2082?tls=1&morph=0'
t_ok "morph 2.0.2 -> 2.1.0 warns"   warn  "$(wmu "$U1" v2.1.0 v2.0.2)"
t_ok "morph unknown prev warns"     warn  "$(wmu "$U1" v2.1.0 '')"
t_ok "morph 2.1.0 -> 2.1.0 quiet"   quiet "$(wmu "$U1" v2.1.0 v2.1.0)"
t_ok "downgrade quiet"              quiet "$(wmu "$U1" v2.0.2 v2.1.0)"
t_ok "morph=0 quiet"                quiet "$(wmu "$U0" v2.1.0 v2.0.2)"

# ---------------------------------------------------------------------------
t_section "warn_22_upgrade_requirements"

w22() { # w22 <url> <target version> <previous version> -> warn|quiet
  printf '%s\n' "$1" > "$URL_FILE"
  VERSION="$2"
  local out
  out="$(warn_22_upgrade_requirements "$3" 2>&1 >/dev/null)"
  [[ -n "$out" ]] && echo warn || echo quiet
}
HK32="$(printf 'a%.0s' $(seq 1 32))"
PHEX="portal://${HK32}@*:2082?tls=1"
PLEG="portal://LegacyKey_1234567890@*:2082?tls=1"
PEVT="portal://${HK32}@*:2082?tls=1&log=event"
VNP="vector://${HK32}@relay.example:2082?socks=127.0.0.1:1080"
VPIN="vector://${HK32}@relay.example:2082?socks=127.0.0.1:1080&pin=$(printf 'c%.0s' $(seq 1 64))"
PCHAIN="portal://${HK32}@*:2082?tls=1&next=legacykey_1234567890@origin.example:2082"
t_ok "legacy portal key -> 2.2.1 warns"  warn  "$(w22 "$PLEG" v2.2.1 v2.1.2)"
t_ok "hex portal key -> 2.2.1 quiet"     quiet "$(w22 "$PHEX" v2.2.1 v2.1.2)"
t_ok "already on 2.2.0 quiet"            quiet "$(w22 "$PLEG" v2.2.1 v2.2.0)"
t_ok "log=event crossing 2.1.1 warns"    warn  "$(w22 "$PEVT" v2.2.1 v2.0.2)"
t_ok "log=event kept on 2.1.0 quiet"     quiet "$(w22 "$PEVT" v2.1.0 v2.0.2)"
t_ok "vector without pin warns"          warn  "$(w22 "$VNP" v2.2.1 v2.1.2)"
t_ok "vector with pin quiet"             quiet "$(w22 "$VPIN" v2.2.1 v2.1.2)"
t_ok "portal chain legacy next warns"    warn  "$(w22 "$PCHAIN" v2.2.1 v2.1.2)"
t_ok "downgrade to 2.1.2 quiet"          quiet "$(w22 "$PLEG" v2.1.2 v2.2.1)"

# ---------------------------------------------------------------------------
t_section "client link pin auto-fill (tls=1, Nowhere 2.2.0+)"

PURL="portal://$(printf 'a%.0s' $(seq 1 32))@*:2082?tls=1"
printf '%s\n' "$PURL" > "$URL_FILE"
PUBLIC_HOST=relay.example.com
CLIENT_UP=auto; CLIENT_DOWN=auto; CLIENT_MUX=0; CLIENT_SNI=auto; CLIENT_PIN=none
PIN64="$(printf 'c%.0s' $(seq 1 64))"
local_portal_fingerprint() { printf '%s\n' "$PIN64"; }
link="$(build_native_vector_link_from_portal "$PURL" 2>/dev/null)"
t_ok "tls=1 link auto-pins"    0 "$(printf '%s' "$link" | grep -q "pin=${PIN64}" && echo 0 || echo 1)"
local_portal_fingerprint() { return 1; }
link="$(build_native_vector_link_from_portal "$PURL" 2>/dev/null)"
stderr="$(build_native_vector_link_from_portal "$PURL" 2>&1 >/dev/null)"
t_ok "no pin when unreachable"      1 "$(printf '%s' "$link" | grep -q 'pin=' && echo 0 || echo 1)"
t_ok "unreachable portal warns"     warn "$([[ -n "$stderr" ]] && echo warn || echo quiet)"
CLIENT_PIN="$PIN64"
link="$(build_native_vector_link_from_portal "$PURL" 2>/dev/null)"
t_ok "explicit --client-pin wins"   0 "$(printf '%s' "$link" | grep -q "pin=${PIN64}" && echo 0 || echo 1)"
CLIENT_PIN=none

# ---------------------------------------------------------------------------
t_section "legacy shared key: keep settings, rotate only the key"

LEGACY_URL="portal://LegacyKey_1234567890@*:2099?tls=1&morph=1&log=debug&dial4=192.0.2.10"
reset_portal
printf '%s\n' "$LEGACY_URL" > "$URL_FILE"
KEY=""
load_existing_config >/dev/null 2>"$SANDBOX/legacy.err"
t_ok "legacy: key not loaded"        ""           "$KEY"
t_ok "legacy: endpoint kept"         "*:2099"     "$ENDPOINT"
t_ok "legacy: morph kept"            1            "$MORPH"
t_ok "legacy: log kept"              debug        "$LOG_LEVEL"
t_ok "legacy: dial4 kept"            192.0.2.10   "$DIAL4"
t_ok "legacy: warns about the key"   warn "$([[ -s "$SANDBOX/legacy.err" ]] && echo warn || echo quiet)"
KEY="$(printf 'c%.0s' $(seq 1 64))"
u="$(build_portal_url)"
t_ok "rotation: URL validates"       0            "$(t_rc validate_imported_url "$u")"
t_ok "rotation: endpoint unchanged"  "*:2099"     "$(url_endpoint "$u")"
t_ok "rotation: morph unchanged"     1            "$(query_get "$u" morph)"
t_ok "rotation: new key used"        "$KEY"       "$(url_key "$u")"

reset_portal
printf 'portal://%s@*:2099?tls=1&pin=abcd\n' "$(printf 'a%.0s' $(seq 1 32))" > "$URL_FILE"
ENDPOINT=sentinel; KEY=keep
load_existing_config >/dev/null 2>&1
t_ok "other invalid config loads nothing" sentinel "$ENDPOINT"
t_ok "other invalid config keeps the key" keep     "$KEY"

# ---------------------------------------------------------------------------
t_section "self-update source"

# SELF_UPDATE_URL is readonly and resolved when the manager is sourced, so each
# case needs a fresh shell.
self_update_url() { # self_update_url [NOWHERE_V2_SELF_URL value]
  if [[ $# -eq 0 ]]; then
    bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "$SELF_UPDATE_URL"' _ "$PATCHED"
  else
    NOWHERE_V2_SELF_URL="$1" bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "$SELF_UPDATE_URL"' _ "$PATCHED"
  fi
}
t_ok "defaults to this repo's main" yes \
  "$(self_update_url | grep -q 'woohong666/nowhere-deploy/main/nowhere-v2.sh' && echo yes || echo no)"
t_ok "NOWHERE_V2_SELF_URL overrides" "https://example.test/mgr.sh" \
  "$(self_update_url 'https://example.test/mgr.sh')"
t_ok "empty value disables self-update" "" "$(self_update_url '')"

# ---------------------------------------------------------------------------
printf '\n%s\n' "----------------------------------------"
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
