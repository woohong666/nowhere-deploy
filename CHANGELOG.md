# Changelog

All notable changes to this project will be documented in this file.

Version numbers in this file follow the **V1 manager** (`nowhere-v1.sh`) unless a
section says otherwise. The V2 manager (`nowhere-v2.sh`) versions independently
and its own `SCRIPT_VERSION` is stated in each heading.

## [Unreleased]

### Nowhere V2 manager (`nowhere-v2.sh`) — v1.5.0

#### ✨ Added

- **Structured `diagnostics`**: emits an allowlisted JSON document (`--output FILE`, `O_EXCL`, mode 600) with service state, configuration summary and certificate expiry — never raw URLs, logs, environment, keys or tokens.
- **`backup` / `restore`**: backups are bounded (10,000 entries, 256 MiB per file, 1 GiB total), reject symlinks/special files and existing targets, carry a per-file SHA-256 manifest and are published atomically. `restore` validates the archive (channel, manifest, PEM validity) before touching anything, supports `--dry-run`, keeps an automatic before-restore backup and rolls back through the transaction if the service fails to restart.

#### 🐛 Fixed

- **`doctor` certificate checks**: expiry, certificate/key match, trusted-certificate hostname verification for the public host and restart counts are now part of the health check; error diagnostics no longer dump raw logs that may contain credentials.
- **`links` fail closed on certificates**: links now verify expiry, server purpose and hostname/IP; a trusted certificate for the wrong hostname is refused instead of silently falling back to a pin, and self-signed detection no longer relies on `subject == issuer` alone.

### Nowhere V2 manager (`nowhere-v2.sh`) — v1.4.2

#### 🐛 Fixed
- **`links` no longer aborts on a trusted certificate**: `certificate_needs_pin` returning 1 (system-trusted chain) was called as a bare command while building a `tls=2` Vector link — under `errexit` the safest path could terminate link generation before anything was printed. The call now runs in an `if` branch and captures the status safely.
- **Unreadable certificates fail closed**: when the certificate cannot be inspected (status 2), the manager no longer assumes normal CA verification and emits a link that may not verify; it refuses with guidance to check the file or pass an explicit `--client-pin`.
- **Vector keys keep upstream compatibility**: the exact-v2.2.0 rule (64 lowercase hex) now applies to Portal and native `next` keys only; the Vector-role wizard again accepts upstream's documented 1-255 byte client keys instead of rejecting short ones.
- **`doctor --fix` is a real transaction**: repairs run first, under the build lock and a config snapshot; `enable` / `restart` / liveness failures now exit non-zero and roll back through the EXIT trap instead of being ignored, and the report afterwards reflects the repaired state instead of pre-repair counters. Config URL validation now uses the installed core version.

### Nowhere V2 manager (`nowhere-v2.sh`) — v1.1.3 → v1.4.0

#### ✨ Added

- **Crash-safe install / configure transactions** (`v1.4.0`): both actions snapshot `url.conf`/`manager.conf`, the unit, the launcher, and the previous binary link before mutating anything, and restore them through the EXIT trap when a step fails. The interactive menu now runs each action inside a subshell that re-arms that trap, so a failed menu action is rolled back exactly like a failed CLI action.
- **Advisory `flock` build lock, paginated release resolution, stricter release checks** (`v1.4.0`): the lock is a real `flock` on `/run/nowhere-v2-build.lock` (no mkdir/PID recovery race); `latest-v2` walks the GitHub release list 100 items per page (up to 20 pages) and picks the newest stable `v2.x.y` numerically; a release tag must resolve to a matching non-prerelease whose asset URL is under the official release path with a SHA-256 digest.
- **Morph-aware fingerprint probing** (`v1.4.0`): `tls=1` fingerprints are read with the installed core's `fingerprint` command, so Morph-enabled and other non-plain-TLS listeners work; fingerprints are normalized to 64 lowercase hex (no colons) before they become `pin=`, and `links` refuses to emit a client link whose pin cannot be verified.
- **Nowhere v2.2.x support** (`v1.3.0`): the V2 manager now tracks the 2.2.x core semantics end to end. Shared keys are generated as 64 lowercase hex characters and validated as 32-64 (the 2.2.0 policy; 64 stays valid on an exact v2.2.0 pin), native `next=` keys follow the same rule, and `--dial4` / `--dial6` expose the new dual-stack outbound source binding — mutually exclusive with `dial`, with the same rule enforced for imported URLs.
- **Upgrade warnings for the 2.1.1 / 2.2.0 admission changes** (`v1.3.0`): `install` / `upgrade` warn when an existing config crosses a boundary that would refuse it — a legacy Portal or next-hop key, `log=event` (removed in 2.1.1), or a Vector / chained hop without a pin once certificate verification became mandatory in 2.2.0. `doctor` also names a legacy Portal key when the installed core is `>=2.2.0`.
- **Auto-pin for generated-certificate client links** (`v1.3.0`): on a `tls=1` Portal, `links` fetches the running certificate fingerprint and embeds `pin=` in the generated Vector URL, with a warning that a generated certificate changes on every Portal restart (prefer `tls=2` in production).
- **Nowhere v2.1.0 support** (`v1.2.0`): raised the default core version and added the `--morph-prelude low7|full8` option plus the `NOW_MORPH_TCP_PRELUDE` systemd environment variable, matching upstream's new client-side TCP Morph prelude policy. `low7` was the upstream default at that time; upstream moved to `full8` in 2.2.0 (see the v1.3.0 entries). (#1)
- **Morph upgrade warning** (`v1.2.2`): `install` / `upgrade` now warn when a `morph=1` config actually crosses the 2.1.0 wire break. It reads the previously installed core version from `RELEASE-INFO`, so the warning stays quiet once every peer is already on `>=2.1.0`. (#3)
- **Accurate status output** (`v1.2.3`): `status` reports the Core version actually installed (read from `RELEASE-INFO`, falling back to `manager.conf`) instead of restating the configured target. (#4)

#### 🐛 Fixed

- **Critical** (`v1.3.0`): fresh installs on a Nowhere 2.2.x core were broken. `random_key` generated base64-style keys and `validate_key` accepted any 16-255 safe characters, but a 2.2.0+ Portal refuses to start unless its listener (and each enabled native `next`) key is 32-64 lowercase hex. Keys are now generated and validated accordingly; the Vector role keeps upstream's documented 1-255 byte client leniency with a warning, so it can still reach a Portal that runs `<=2.1`.
- **Critical** (`v1.3.0`): `tls=1` client links could never connect on 2.2.0+. Native clients now always verify the peer certificate against the system CA and the endpoint hostname, and `pin=none` no longer disables verification, so a generated certificate requires an explicit pin. `links` auto-fills it (above) and `fingerprint` remains the documented way to obtain it through a trusted channel.
- (`v1.3.0`): `log=event` was still accepted by the validator, the advanced wizard, and the imported-URL checker although Nowhere 2.1.1 removed it and the core now refuses to start with it.
- (`v1.3.0`): `doctor` now reports a legacy Portal / next-hop key on a `>=2.2.0` core instead of leaving only "service not active".
- (`v1.3.1`): a saved configuration whose shared key was pre-2.2 failed validation as a whole, so `configure` could not prefill the endpoint, TLS, or Morph settings. Only the key is now left out; everything else loads, and `configure -y --config-mode quick --key <new 64-hex key>` rotates just the key.
- (`v1.3.1`): the example commands in the README, ACCEPTANCE checklist, and V1 guide shipped fixed keys. A copy-pasted key like that would authenticate against a production Portal, so the examples now generate a key with `openssl rand -hex`, and the Vector placeholder fails validation until it is replaced.
- `manager.conf` kept the pre-upgrade `CORE_VERSION` after a binary-only `install`/`upgrade` (`v1.2.7`). That path only replaces the binary and never rewrites the metadata, so the recorded version drifted from the installed one. The file's version fields are now refreshed in place — deliberately *not* by rewriting the whole file, because `load_meta` does not restore every field (`ROLE`, for instance) and the defaults would be written instead. (#10)
- **Critical** (`v1.2.6`): `prompt_choice` and `prompt_key` could spin forever. When `/dev/tty` was unavailable the `read` failed, the default was substituted, and if that default was not in the allowed list the retry loop never terminated — it printed an invalid-choice warning indefinitely. Reproduced: a 3-second run emitted 12,365 lines and never returned. Reachable from `NOWHERE_V2_LOG=loud sudo bash nowhere-v2.sh configure --advanced` (or any invalid `NOWHERE_V2_*` value feeding a wizard prompt) on a host without a controlling terminal. Both now accept a valid default and otherwise stop with a message naming the rejected value and the allowed ones. (#9)
- `safe_extract_tar` validated member paths but not member types, so a tar containing a symlink or hardlink was extracted unchecked. It now refuses link members, matching the fact that a release asset only ever contains one regular file. (#9)
- `backup_action` accepted an output path inside `/etc/nowhere-v2`, which made `tar` archive its own output. It now refuses a destination inside the configuration directory. (#9)
- **Critical** (`v1.2.5`): `doctor --fix` rewrote the systemd unit without re-reading `manager.conf`. Because `write_unit` interpolates `MEMORY_PROFILE` and `MORPH_PRELUDE`, a repair silently reset a configured `memory` / `full8` back to the script defaults while `manager.conf` kept the original — leaving the unit, the service, and the manager metadata disagreeing. `doctor_action` now calls `load_meta` before `write_unit`. (#8)
- **Critical** (`v1.2.5`): `restore_config_state` restored `manager.conf` from the snapshot but then rewrote the unit from the in-memory globals, which still held the *failed attempt's* values. A failed `configure` therefore left the unit on the values that had just been rolled back. It now re-reads the restored `manager.conf` first. (#8)
- **Critical** (`v1.2.1`): `--morph-prelude` was assigned directly instead of through `set_cli`, so it never registered as a CLI override. On an existing install, `load_meta` restored the persisted `MORPH_PRELUDE` from `manager.conf` and `apply_cli_overrides` had nothing to re-apply, silently discarding the flag. Fresh installs were unaffected, which hid the bug. (#2)
- **Critical** (`v1.2.2`): `load_meta()` copied persisted values into the systemd unit without validation. `MEMORY_PROFILE` and `MORPH_PRELUDE` are interpolated into the unit verbatim, so a corrupted or hand-edited `manager.conf` propagated straight through — including on the binary-only `install` path. Both are now validated, and a rejected value falls back to the already-validated current value with a warning. (#3)
- **Critical** (`v1.2.2`): `main()` validated `MEMORY_PROFILE` but not `MORPH_PRELUDE`. An invalid `NOWHERE_V2_MORPH_PRELUDE` could therefore reach `write_unit` on paths that skip both `parse_args` validation and `apply_noninteractive_defaults`. Upstream rejects anything other than `low7`/`full8`, so the service failed to start with a misleading "configuration failed" message. (#3)
- `validate_next_endpoint` accepted a second `@` in the shared key. Upstream splits on the last `@` and then bails with *"reserved shared-key characters must be percent-encoded"* (`src/vector/config.rs`), so a key like `a@b@c` was accepted here and rejected later by the core with a less clear message. (#4)
- **Critical** (`v1.1.3`): fixed `configure` (menu option [3]) silently returning without doing anything. `load_existing_config()` chained `v="$(...)"; [[ -n "$v" ]] && VAR="$v"` assignments, and the final one returned non-zero whenever an optional query parameter (typically `pin`) was absent from the stored URL — the normal case — so `set -e` aborted the whole script. Added a `load_q` helper and an explicit `return 0` so existing configs always load.
- **Critical** (`v1.1.3`): `validate_imported_url()` and `validate_socks_endpoint()` used `python3 ...; [[ $? -eq 0 ]] || die`, which under `set -e` exited *before* the friendly error message on direct calls, while the internal `die` killed the whole manager on the soft boolean checks in `load_existing_config()` / `doctor`. Switched to `if ! python3 ...; then die ...; fi` and wrapped the boolean call sites in subshells.
- `configure_action` (`v1.1.3`): `[[ portal ]] && build_portal_url || build_vector_url` could fall through to building a Vector URL when the Portal URL failed; replaced with `if/else`. Same fix for the `advanced_wizard` / `quick_wizard` selection.
- `fingerprint` with `tls=2` (`v1.1.3`): a missing or unreadable certificate no longer exits silently via `pipefail`; it now reports a clear error.
- Interactive menu actions (`v1.1.3`): install, configure, links, fingerprint, rollback, clean-releases, and check-updates no longer quit the entire manager on a benign non-zero return.
- `tls=2` copy flow (`v1.1.3`): the wizard and `prepare_tls_files()` now offer the managed TLS directory copy as a second line of defense, so a root-only PEM can no longer dead-end the install.

#### 🔄 Changed

- `rate` / `etar` now follow the documented integer range `0..2147483647` (`v1.4.0`); decimals, `nan`, and values above `i32` are rejected in the CLI and in imported URLs.
- Bracketed IPv6 literals are actually parsed (`v1.4.0`): `[bad]:2082` and similar values are rejected instead of reaching the core.
- `tls=2` links auto-pin only when the certificate is self-signed (`v1.4.0`); a CA-signed certificate is left unpinned so renewals do not break every client. Imported `tls=2` URLs now sync the TLS mode before the certificate readability check runs.
- The unit sets `TMPDIR=/run/nowhere-v2` and the TUI runs as the service user (`v1.4.0`): upstream telemetry lives under `$TMPDIR/nowhere-telemetry-<uid>`, which `PrivateTmp=true` otherwise hides from a root TUI.
- Release tarballs are unpacked by a Python whitelist (`v1.4.0`): regular files/directories only, exactly one `nowhere` binary, with a size cap — FIFOs and duplicates are refused. `installed_core_version` falls back to `BUILD-INFO` for source builds, and backups refuse to overwrite an existing target.
- The hardening above originated from an independent GPT-assisted review of the v1.3.0 script (`v1.4.0`). Every reported item was reproduced here before merging, and the review's own gaps were fixed on top: menu-path rollback (the EXIT trap does not fire in plain subshells), the CA-certificate pinning policy, the misleading link-refusal message, and several single-language fallback messages.
- `DEFAULT_MORPH_PRELUDE` is now `full8` (`v1.3.0`), matching the upstream default since 2.2.0. Persisted `MORPH_PRELUDE` values (including an explicit `low7`) are left untouched, and `low7` remains a supported explicit choice.
- The version policy now states that `v3.x` / NW3 is out of scope (`v1.3.0`): `--version` keeps accepting only `latest-v2` or an exact `v2.x.y`, which also keeps `latest-v2` resolving to the newest stable v2 release (currently `v2.2.1`).
- **Self-update now works out of the box** (`v1.2.8`). `SELF_UPDATE_URL` defaults to this repository's `main` branch, so menu option [18] and `self-update` no longer require `NOWHERE_V2_SELF_URL` to be configured first — previously they just warned and returned. The variable still overrides the source (point it at a fork or mirror), and setting it to an empty string disables self-update deliberately. (#12)
- The doctor Morph reminder was reworded (`v1.2.8`) to say that peer versions cannot be checked from this host. It fires whenever `morph=1` because the local side genuinely cannot verify the rest of the path, and the old wording read like a detected fault rather than a standing reminder. (#12)
- Installs and release pruning are now serialised by the existing build lock (`v1.2.7`). `install_action` and `cleanup_old_releases` acquire it, so two concurrent runs can no longer race on the releases directory or the `current` symlink. It is idempotent, so the source-build path (which already held it) is unaffected, and a stale lock from a crashed run is still detected by PID and reclaimed. (#10)
- `self_update` now refuses to **downgrade** the manager (`v1.2.5`). It previously compared versions with `!=`, so pointing `NOWHERE_V2_SELF_URL` at an older copy prompted an "update" to that older version. It now requires the remote version to be `>=` the local one, and the confirmation prompt is bilingual like the rest of the script. (#8)
- `ensure_rust` now checks the toolchain version before accepting a system Rust (`v1.2.5`). Upstream is `edition = "2024"` (stabilised in Rust 1.85) and ships no `rust-toolchain` file, so an older distro toolchain failed deep inside `cargo` with a confusing error. It now warns and installs a managed toolchain instead. (#8)
- `DEFAULT_CORE_VERSION` no longer pins a literal tag (`v1.2.3`). It defaults to `latest-v2`, which `resolve_version` turns into the newest stable `v2.x.y` at install time, so the manager stops going stale on every upstream release. `--version v2.x.y` and `NOWHERE_V2_VERSION` still pin an exact tag.
- 68 operator-facing messages are now bilingual (`v1.2.4`). The manager defaults to `LANG_CODE=zh`, yet every validator, URL/endpoint check, release-install, source-build, doctor, and self-update message was English-only. Embedded Python diagnostics are intentionally left in English: they are printed just before the bilingual wrapper and name the exact field that failed. (#5)

#### 🧹 Cleanup

- Removed the unused `allowed` query-key set from the imported-URL validator (`v1.3.0`). Unknown keys follow upstream first-wins/ignore semantics, so the set only documented a rule that was never enforced.
- Removed dead code (`v1.2.3`): `validate_policy` (superseded by `validate_policy_against_endpoint`), `urldecode`, and the unused `CORE_MAJOR` along with its `shellcheck` suppression.
- Removed dead state (`v1.1.3`): `SWAP_CREATED`, `NEW_TARGET`, and the unused build-lock loop variable. `shellcheck -S warning` is now clean.

### Nowhere V3 manager (`nowhere-v3.sh`) — v1.4.0

#### ✨ Added

- **Managed renewal lifecycle (`cert-timer`, `cert-renew`, `cert-status`)**: `cert-renew` renews only the current Portal's managed certificate, clears legacy acme.sh deploy/reload hooks (without sourcing `domain.conf`), validates the new certificate before installing it and rolls back on failure; "not due" performs no restart, a held lock is logged as a skip, and the last managed result is recorded. `cert-timer` installs the renewal timer with a fixed manager copy under `/opt/nowhere-v3/manager/` and verifies it is enabled and active. `cert-status` reports validity dates, days remaining, key match, timer state and the last result, and flags legacy direct-cron timers.
- **`preview` / `configure --dry-run`**: prints a masked diff of the proposed configuration (shared key, pin and SOCKS credentials hidden; role switches gated by `--allow-role-switch`) without writing configuration, issuing certificates, installing packages or restarting the service.
- **`backup` / `restore` / `diagnostics`**: bounded manifest-backed backups, validated transactional restore and allowlisted JSON diagnostics, matching the V2 manager v1.5.0 behaviour.
- **Hardened ACME bootstrap**: acme.sh remains pinned to 3.1.6; the release tarball, the installed program and the DNS plugin are digest-verified and only the two expected regular files are extracted.

#### 🐛 Fixed

- `uninstall` also removes the `nowhere-v3-cert-renew.service` / `.timer` units; `doctor` checks certificate expiry, key match, service-account readability and warns 30 days before expiry.

### Nowhere V3 manager (`nowhere-v3.sh`) — v1.3.1

#### 🐛 Fixed
- **DNS-01 could never run**: `ensure_acme` copied only the acme.sh main script; the `dns_cf` plugin is now installed alongside it (`dnsapi/dns_cf.sh`) and its presence is verified before use.
- **The CA is pinned explicitly**: account registration and issuance now pass `--server letsencrypt`; acme.sh 3.1.6 otherwise defaults to ZeroSSL, so what was issued did not match the documented "Let's Encrypt" behaviour.
- **Isolated ACME state**: acme.sh now lives under `/etc/nowhere-v3/acme`, covered by config backups and transaction rollback; the legacy shared `/root/.acme.sh` is left untouched.
- **Early certificate rollback**: the transaction opens before any ACME or certificate-file change, so a failed re-issue restores the previous `le.<domain>` certificate; the renewal timer is created only after the service passes its post-switch liveness check.
- **Renewal is serialized with management**: the timer runs `acme.sh --cron` under the same flock as install/configure (`flock -n -E 0`, so lock contention skips quietly instead of marking the unit failed).
- **Stable renewal paths**: on reconfigure a managed `le.<domain>` fullchain/key pair stays at its original path (no longer copied into a `pem.*` staging directory), so renewals keep updating the file the service actually loads.
- **CA-aware native links**: `links` omits `pin=` when the certificate verifies against the system trust store for the public host (chain, purpose and hostname/IP checked with `openssl verify`), so routine renewals no longer break pinned Vector/Egress links; self-signed and private-CA certificates keep the leaf pin.
- **Shortcut symlink safety**: `install_shortcut` refuses to write through an existing symlink at `/usr/local/bin/nh`.
- Tests: the V3 suite's self-update fixtures now derive from the live `SCRIPT_VERSION` and include a `dns_cf` fixture; the V2 suite disables real dependency installation. New offline targeted regressions live in `tests/test_fixes.py` (13 checks) and run in CI, with a local `flock`/`install` shim keeping them runnable without root or util-linux.

> Review provenance: fix package produced by GPT from byte-identical baselines (patches verified to reproduce the builds exactly, SHA256SUMS all pass). This review added the `-E 0` conflict-exit refinement and the test-environment shims.

### Nowhere V3 manager (`nowhere-v3.sh`) — v1.3.0

#### Added
- **Let's Encrypt certificate automation (`cert`)**: issues and renews certificates with no package-manager dependency — acme.sh is installed from a pinned GitHub release tarball (3.1.6, not `curl | bash`) under `/root/.acme.sh`. Two validation modes: Cloudflare DNS-01 (API token via hidden input or `--cf-token-file`, handed to acme.sh only through the environment so it never shows up in process argv) and HTTP-01 standalone (`--http`, port 80). Files are staged to `/etc/nowhere-v3/tls/le.<domain>/` (640 root:nowhere-v3), `url.conf` is rewritten inside the transaction and the service restarts; a daily `nowhere-v3-cert-renew.timer` runs `acme.sh --cron`, and a successful renewal restarts the service. Uninstall removes the timer/service units; `--purge` removes the staged certificate with the config directory.
- **Menu item 23** ("证书") plus CLI flags `--domain / --cf-token-file / --email / --http / --force`; help text (EN/zh-CN) documents the new action.
- README (EN/zh-CN): new §13.5 certificate walkthrough (prerequisites, commands, staged files, renewal inspection, security notes); §13.1/§13.3 and the acceptance checklist mention `cert`.
- README (EN/zh-CN) restructured V3-first: the preamble and §0 now present `nowhere-v3.sh` as the primary channel (V3 highlights list + three-minute deploy block), the V1/V2 documentation is folded into a collapsible maintenance section, the table of contents is collapsible, and §13.5 gained a detailed Cloudflare API Token walkthrough (scoped `Zone.DNS:Edit`, template and custom-token paths, storage, revocation).
- 13 sandbox regression assertions: domain validation, both issuance modes, staged files, `url.conf` rewrite, timer units, and the guarantee that the token never reaches acme.sh's argv.

### Nowhere V3 manager (`nowhere-v3.sh`) — v1.2.0

#### Added
- **Remote certificate fingerprint**: `fingerprint` now takes an optional `nowhere://KEY@HOST:PORT?morph=0|1` share link and inspects the remote Portal's certificate with the core's `fingerprint` subcommand (over TCP/TLS even when the link says `net=udp`). The URL is validated before use, the shared key never reaches any output (the preview shows `nowhere://***@host:port`), the result is normalized to 64 lowercase hex, and a hint reminds the operator to compare it through a trusted channel before using it as a pin. The argument-less form keeps reading the local certificate.
- Fingerprint normalization (`normalize_fingerprint`) is now shared by the local and remote paths, so colon/space-separated output from the core is accepted everywhere.
- **`nh` shortcut**: install/configure/self-update (re)create `/usr/local/bin/nh`, a marker-owned wrapper that opens the menu or forwards arguments (`nh status`); a foreign file at that path is never overwritten, and `uninstall --purge` removes only a marker-owned shortcut.
- **Numbered choices and y/n confirmations**: `prompt_choice` accepts an index (1..N) besides the value word — values that already look numeric win over the index — and the wizard labels list `1=... 2=...`; `prompt_confirm` accepts `y`/`yes`/`是` with a `[y/N]（y=是 n=否）` hint. Both honor `NOWHERE_V3_PROMPT_TTY` for scripted input.
- **qrencode auto-install**: `links` installs qrencode on demand (apt-get/dnf/yum/apk) so QR codes render by default; with no supported package manager (or a failed installation) it warns and prints the links without QR.
- README (EN/zh-CN) documents the remote form; the acceptance checklist gained a matching probe/privacy bullet.
- README (EN/zh-CN): new step-by-step V3 installation walkthrough (§13.1 — menu wizard field table, unattended commands, post-install checks, client import, firewall), a document map in the §13 preamble, and a post-install file-layout table (§13.4); QR behavior updated to auto-install in the docs and the acceptance checklist.
- README (EN/zh-CN) §3.0/§13.1 and FAQ Q9: documented the root-without-sudo case on minimal VPS images (drop the `sudo` prefix — identical as root); the in-script usage lines now note "omit sudo when already root".

### Nowhere V3 manager (`nowhere-v3.sh`) — v1.1.0

#### Added
- Manager-only, channel-checked self-update with downgrade refusal and atomic backup/replacement.
- Complete 22-action bilingual looping menu and Portal/Vector/Egress installation wizards.
- `versions`, `generate-key`, redacted `probe`, status panel and persisted language selection.
- Native pinned links plus canonical pin-free share links and optional QR rendering.
- Optional `doctor --probe` diagnostics; existing transaction, lock, PEM and role guards retained.
- Expanded offline, non-root sandbox regression coverage and bilingual operation documentation.
- Link output labels the share-link block and notes that a shared-port endpoint only needs one tcp/udp import (the variants differ only in carrier).

#### Fixed
- Interactive prompts (menu, wizard, confirmations) are visible again: an integration review found every `read -p` label hidden behind a stderr redirect, turning the wizard into blind input.
- `rate`/`etar` configured through `--url-file` survive a wizard or CLI reconfigure instead of being dropped from the rebuilt URL; the same pre-load keeps morph/out/in/pin/SNI/dial settings on CLI reconfigures.
- The test suite skips cleanly on hosts without util-linux / GNU coreutils (flock, timeout, chmod/chown `--reference`) instead of failing.
- Wizard and menu prompts are unambiguous after a field report: choices read `value=meaning`, the invalid-input reply lists the allowed values (e.g. `无效选项；可选：managed supplied`), and the menu asks `请输入选项 [0-22]：`.

### Nowhere V3 manager (`nowhere-v3.sh`) — v1.0.1

A new, fully isolated manager for the Nowhere `v3.x` line (NW3). It shares no
files, services, accounts, or ports with the V2 manager and refuses NW2 tags;
NW3 is wire-incompatible with NW2, with no negotiation or fallback.

#### ✨ Added

- **V3 (NW3) support** (`v1.0.1`): `nowhere-v3.sh` deploys `portal` / `vector` / `egress` roles against the official v3.0.0 configuration grammar — 32-character lowercase-hex keys, `in=` SOCKS ingress, `out=direct|SOCKS|egress` exits, Morph on by default, integer `rate`/`etar`, and `dial`/`dial4`/`dial6` source binding. NW2-era or unknown parameters (`socks=`, `next=`, `up`/`down`, `mux`, `log=`) are refused, so an imported V2 URL cannot silently change routing.
- **Stable client pins by default** (`v1.0.1`): a new Portal without `--cert`/`--tls-key` gets a persistent self-signed PEM under `/etc/nowhere-v3/tls/`; `links` reads its fingerprint and refuses to print Vector/Egress URLs without a verified `pin=`. NW3 dropped the TUI, so monitoring uses `status`/`telemetry`, run as the service user with the same `TMPDIR`.
- **Fixed verified default** (`v1.0.1`): the default core is pinned to the verified `v3.0.0`; `--version latest-v3` explicitly opts in to newer stable v3 releases through the same paginated resolver and digest checks as V2.
- **Integration fixes** (`v1.0.1`): `configure` reuses the existing staged PEM so the client pin survives a reconfigure (pass `--cert`/`--tls-key` to rotate); a role switch requires confirmation or `--allow-role-switch`; `validate` tolerates an unreadable `manager.conf`; superseded PEM directories are pruned.

> The V3 manager came from an external GPT-assisted pass written against the
> official v3.0.0 docs, and was merged after a line-by-line review; its provenance
> is noted in the script header. It prints Chinese-first messages for now.

### Nowhere V1 manager and installers

#### 🐛 Fixed

- **Critical**: `install.sh` download always failed — `archive="$tmpdir/$asset"` was declared in a single `local` statement, so `$tmpdir`/`$asset` expanded before the assignments took effect and `curl -o` received `/`. Verified against HEAD: `archive=[/]`. Now split into two `local` statements.
- `nowhere-v1.sh client-link --host/--name/--client-*` were silently overridden by values stored in `manager.conf`; `show_links` now re-applies CLI overrides after `load_meta`, so command-line flags win as documented.
- `nowhere-v1.sh status` / `fingerprint` / `doctor` failed with "No config" on systems installed by `install.sh` / `install-source.sh` (legacy `nowhere.env`); they now run `import_legacy_config` first.
- `install-source.sh`: build swapfile moved from `/swapfile-nowhere` (root filesystem) to `/var/tmp/nowhere-build-swap`, matching the unified script; `clean-build` now deactivates an in-use swapfile before removal, keeps the file if `swapoff` fails, and cleans the swapfile even when no build tree exists.
- `nowhere-v1.sh self-update` replaced the running script in place (truncate + write on the same inode), which can corrupt the executing copy; it now stages the update and renames it atomically.
- Interactive menu restart ([7]) reported nothing on failure; it now warns with a follow-up command.
- Interactive prompts (`prompt`, `prompt_yes`, `prompt_confirm`, `prompt_port`, `prompt_key`, `prompt_choice`, menu, version picker) survive EOF / Ctrl+D / dropped SSH sessions instead of aborting the whole script via `set -e`.
- `fingerprint` prefers the colon-separated certificate fingerprint from logs before falling back to a bare hex string, so unrelated 64-char hashes are no longer matched.
- systemd unit hardening parity: `UMask=0077` added to the units written by `install.sh` and `install-source.sh`.
- `install-source.sh` usage text referenced `install.sh clean-build` instead of `install-source.sh clean-build`.

#### 🔄 Changed

- `install.sh` / `install-source.sh` now accept `--version latest` (the default stays pinned to `v1.8.3` for reproducible CI installs): `install.sh` resolves via the GitHub API, `install-source.sh` via `git ls-remote --sort=-v:refname` (no `python3` dependency).

### 📚 Documentation

- **Documented the Anywhere client's NW2 → NW3 switch** (observed on 2.4 build 401): 2.3 and earlier implement only NW2; 2.4 and later only NW3 at the binary level — an updated client cannot reach V2 (`nw2`) without negotiation or fallback, while the V2 Portal itself stays healthy (`doctor`, `probe`, external `-alpn nw2`). Added FAQ Q8 (EN/zh-CN), a client-version note in §13, and the matching precondition in the V3 acceptance track.
- README (EN/zh-CN): added the V3 (NW3) channel section — quick start, the V2/V3 isolation table, and the one-registered-Egress behavior (`v1.4.0`).
- `ACCEPTANCE.md`: added a V3 acceptance track — persistent pin, Vector via `--url-file`, Egress registration and offline behavior, and the role-switch guard (`v1.4.0`).
- **README (EN/zh-CN) updated for Nowhere v2.2.x** (`v1.3.0`): documented the 32-64 lowercase-hex shared-key policy, the always-on certificate verification and pin semantics for native clients, the `full8` Morph default, and `--dial4` / `--dial6`.
- **Documented the official v3.0.0 / NW3 release as out of scope** (`v1.3.0`): NW3 is wire-incompatible with NW2, so the manager deliberately stays on the `v2.x` line and refuses `v3.x` tags. `latest-v2` keeps resolving to the newest stable v2 release (currently `v2.2.1`).
- **README (EN/zh-CN) rewritten V2-first** (#6): V2 is now the primary channel and is documented end to end — script selection, release vs source, prerequisites, quick start (interactive and non-interactive, with Portal / Vector / TLS 2 / Morph examples), TLS and `--copy-cert`, per-endpoint firewall rules, client links (`vector://` vs `nowhere://`), daily operations, upgrade / rollback / backup / uninstall, the full CLI reference, file layout and sandbox hardening, and an FAQ covering the 2.1.0 Morph wire break. V1 is reduced to a deployment-only §12 that links to its detailed docs.
- Corrected the V2 default version to `latest-v2` (was documented as `v2.0.0`), documented `status` as reporting the installed Core version, and removed a documented `--socks` option that does not exist (the option is `--out-socks`).
- README (EN/zh-CN): corrected TLS default (`1`), version default (`latest`), `url.conf`/`manager.conf` file layout, `fingerprint` command name (was `show-fingerprint`), removed non-existent `--lang`/`--commit`/`--jobs` rows from the unified-script table.
- Unified V1 entry point renamed to `nowhere-v1.sh`; updated the self-update URL, built-in help, English/Chinese deployment steps, and the V1 stable guide.
- Two-scripts README (EN/zh-CN): documented `--version latest` support.
- Removed legacy `nowhere.sh.v2.1.0.backup` from version control; added `*.backup` to `.gitignore`.
- README (EN/zh-CN): added a V1 vs V2 channel comparison (§1.1) and listed `nowhere-v2.sh` in the script-selection guidance.

## [2.5.2] - 2026-09-10

### 🎉 Major Release - Feature Complete

This is a major update merging v2.3.0 and v3.0.0 features into a production-ready release.

### ⚠️ Breaking Changes

- **DEFAULT_TLS changed from 2 to 1**: Now defaults to self-signed certificates for quick testing. Production deployments should explicitly use `--tls 2 --cert --tls-key` with proper certificates.
- **Configuration architecture**: Migrated from `nowhere.env` to `url.conf` + `manager.conf` for cleaner URL-based configuration.

### ✨ New Features

#### Core Functionality
- **Script Self-Update** (`self-update` command): Download, verify, backup, and auto-update the script itself
- **Version List Selector**: Interactive GitHub API-powered version picker showing latest 10 releases
- **URL Import/Migration**: Parse and import `portal://`, `vector://`, and `nowhere://` URLs directly
- **Vector Client Mode**: Full SOCKS5 client mode support with `--type vector`
- **TLS Fingerprint Display** (`show-fingerprint` command): View SHA-256 certificate fingerprints for tls=1

#### Advanced Configuration
- **Complete Parameter Coverage**: rate, etar, dial, socks, next, alpn, up, down, mux, sni, pin
- **Launcher Script**: `/usr/local/libexec/nowhere-launch` wrapper for cleaner systemd integration
- **Multi-Version Management**: Keep last N releases in `/opt/nowhere/releases/` with configurable retention
- **Build Lock Mechanism**: Prevent concurrent compilation with `/run/nowhere-build.lock.d`
- **Swap Cleanup**: Automatic cleanup of stale swap files from interrupted builds

#### User Experience
- **17 Menu Options**: Expanded from 13 to 17 interactive menu items
- **Status Panel**: Enhanced `show-status` with role detection, URL display, and configuration summary
- **Input Validation**: 23 validation functions with retry loops for robust user input
- **GitHub Token Support**: `--github-token` to bypass API rate limits
- **Copy Certificate Mode**: `--copy-cert` to copy TLS files into `/etc/nowhere/tls/`

### 🐛 Fixed

- **SWAP_FILE Path**: Changed from `/swapfile-nowhere-$$` to fixed `/var/tmp/nowhere-build-swap` to prevent garbage file accumulation
- **Array Initialization**: `CLEANUP_PATHS=()` properly initialized as empty array
- **Menu Loop**: Replaced recursive calls with `while true` loop to prevent stack overflow
- **stdout/stderr Separation**: UI prompts to stderr, results to stdout for proper `$()` capture
- **Input Validation**: All user inputs now validated in retry loops until valid
- **Certificate Permissions**: Proper chmod 600/640/700 and chown for security

### 🔄 Changed

- **Menu Structure**: Reorganized from 13 to 17 items with logical grouping
- **Default Version**: Changed from `v1.8.3` to `latest` with automatic GitHub resolution
- **SWAP Location**: Moved from `/swapfile-nowhere` to `/var/tmp/nowhere-build-swap`
- **Error Handling**: 41 `|| true` checkpoints for graceful degradation under `set -e`
- **Language Selection**: All prompts now use `</dev/tty` for proper terminal input
- **Configuration Files**: Split into URL-based (`url.conf`) and metadata (`manager.conf`)

### 📚 Documentation

- Added comprehensive CLI usage help (`--help`)
- Updated README with TLS security warnings
- Documented all 40+ command-line parameters
- Added Vector client mode configuration examples
- Clarified `portal://` vs `nowhere://` vs `vector://` URL formats

### 🎯 Quality Metrics

- **Code Size**: 2166 lines (vs 1014 in v2.1.0)
- **Validation Functions**: 23
- **Error Handlers**: 41 `|| true` checkpoints
- **Menu Items**: 17 (0-16)
- **Syntax**: ✅ bash -n clean
- **Security**: ✅ No `rm -rf /`, no `eval`

---

## [2.1.0] - 2026-09-10

### Added
- **Critical**: Added "Download & Run the Script" section (§0) in both README.md and README.zh-CN.md
- **Critical**: Added `client-link` command that builds `nowhere://` share URIs directly in shell
- Added script selection guidance explaining difference between scripts
- Added comprehensive parameter validation in `validate_config()` function
- Added `--host` and `--name` flags to `client-link` command
- Added helper functions: `is_ip_literal()`, `parse_query_param()`, `detect_public_ip()`, `build_nowhere_link()`
- Added interactive menu option [6] for generating client links
- Added TUI monitor launcher [10] in interactive menu

### Fixed
- **Critical**: Fixed documentation incorrectly stating the Nowhere binary has `client-link` subcommand
- **Critical**: Clarified that `nowhere://` is the correct format for Anywhere 2.0 client import
- **Critical**: Reverted `<YOUR-SERVER-IP-OR-DOMAIN>` placeholder injection in `build_portal()`
- **Critical**: Fixed `show_client_link()` attempting to call non-existent binary subcommands
- Fixed README cross-references to use correct filenames
- Added validation for `--method`, `--swap`, `--commit` parameters

### Changed
- Renamed `README.EN.md` to `README.md` for proper GitHub landing page
- Updated interactive menu from 12 to 13 items
- Client link follows host precedence: `--host` flag > config `LISTEN_HOST` > auto-detected IP
- Client link includes SNI parameter automatically when TLS=2 and host is domain
- Client link warns when TLS=1 that clients must trust certificate fingerprint

---

## [1.0.0] - 2026-09-09

### Initial Release

- Basic install/upgrade functionality for Nowhere VPS deployment
- Support for both prebuilt binary and source compilation
- Interactive menu with 11 options
- Three-language support (English, 简体中文, Русский)
- TLS certificate management
- Service management (start/stop/restart)
- Rollback functionality
