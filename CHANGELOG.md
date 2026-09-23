# Changelog

All notable changes to this project will be documented in this file.

Version numbers in this file follow the **V1 manager** (`nowhere-v1.sh`) unless a
section says otherwise. The V2 manager (`nowhere-v2.sh`) versions independently
and its own `SCRIPT_VERSION` is stated in each heading.

## [Unreleased]

### Nowhere V2 manager (`nowhere-v2.sh`) — v1.1.3 → v1.2.4

#### ✨ Added

- **Nowhere v2.1.0 support** (`v1.2.0`): raised the default core version and added the `--morph-prelude low7|full8` option plus the `NOW_MORPH_TCP_PRELUDE` systemd environment variable, matching upstream's new client-side TCP Morph prelude policy. `low7` remains the upstream default. (#1)
- **Morph upgrade warning** (`v1.2.2`): `install` / `upgrade` now warn when a `morph=1` config actually crosses the 2.1.0 wire break. It reads the previously installed core version from `RELEASE-INFO`, so the warning stays quiet once every peer is already on `>=2.1.0`. (#3)
- **Accurate status output** (`v1.2.3`): `status` reports the Core version actually installed (read from `RELEASE-INFO`, falling back to `manager.conf`) instead of restating the configured target. (#4)

#### 🐛 Fixed

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

- `DEFAULT_CORE_VERSION` no longer pins a literal tag (`v1.2.3`). It defaults to `latest-v2`, which `resolve_version` turns into the newest stable `v2.x.y` at install time, so the manager stops going stale on every upstream release. `--version v2.x.y` and `NOWHERE_V2_VERSION` still pin an exact tag.
- 68 operator-facing messages are now bilingual (`v1.2.4`). The manager defaults to `LANG_CODE=zh`, yet every validator, URL/endpoint check, release-install, source-build, doctor, and self-update message was English-only. Embedded Python diagnostics are intentionally left in English: they are printed just before the bilingual wrapper and name the exact field that failed. (#5)

#### 🧹 Cleanup

- Removed dead code (`v1.2.3`): `validate_policy` (superseded by `validate_policy_against_endpoint`), `urldecode`, and the unused `CORE_MAJOR` along with its `shellcheck` suppression.
- Removed dead state (`v1.1.3`): `SWAP_CREATED`, `NEW_TARGET`, and the unused build-lock loop variable. `shellcheck -S warning` is now clean.

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
