# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### 🐛 Fixed

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

### 📚 Documentation

- README (EN/zh-CN): corrected TLS default (`1`), version default (`latest`), `url.conf`/`manager.conf` file layout, `fingerprint` command name (was `show-fingerprint`), removed non-existent `--lang`/`--commit`/`--jobs` rows from the unified-script table.
- Unified V1 entry point renamed to `nowhere-v1.sh`; updated the self-update URL, built-in help, English/Chinese deployment steps, and the V1 stable guide.
- Two-scripts README (EN/zh-CN): documented `--version latest` support.
- Removed legacy `nowhere.sh.v2.1.0.backup` from version control; added `*.backup` to `.gitignore`.

### ✨ Changed

- `install.sh` / `install-source.sh` now accept `--version latest` (default stays pinned to `v1.8.3` for reproducible CI installs): `install.sh` resolves via the GitHub API, `install-source.sh` via `git ls-remote --sort=-v:refname` (no python3 dependency).

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
