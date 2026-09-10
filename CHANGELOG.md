# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased] - 2026-09-10

### Added
- **Critical**: Added "Download & Run the Script" section (§0) in both README.md and README.zh-CN.md with clear download instructions
- **Critical**: Added `client-link` command that builds `nowhere://` share URIs directly in shell (parses stored `portal://` config)
- Added script selection guidance explaining the difference between `nowhere.sh`, `install.sh`, and `install-source.sh`
- Added two download methods: recommended (wget + verify) and alternative (one-line command)
- Created `.gitignore` to exclude backup and temporary files
- Added comprehensive parameter validation in `validate_config()` function
- Added detailed explanation of `portal://` vs `nowhere://` link formats in documentation
- Added `--host` and `--name` flags to `client-link` command for customizing the generated share URI
- Added helper functions: `is_ip_literal()`, `parse_query_param()`, `detect_public_ip()`, and `build_nowhere_link()`
- Added interactive menu option [6] for generating client links

### Fixed
- **Critical**: Fixed documentation incorrectly stating the Nowhere binary has a `client-link` subcommand (it doesn't; the script builds the URI itself)
- **Critical**: Fixed documentation incorrectly stating `portal://` is for client import (it's server-side config only)
- **Critical**: Clarified that `nowhere://` is the correct format for Anywhere 2.0 client import
- **Critical**: Reverted the `<YOUR-SERVER-IP-OR-DOMAIN>` placeholder injection in `build_portal()` across all three scripts—empty host is correct for server-side wildcard binding
- **Critical**: Fixed `show_client_link()` attempting to call non-existent binary subcommands; replaced with shell-native URI builder
- **Critical**: Added missing `README.md` at repository root for GitHub landing page visibility
- Fixed README cross-references to use correct filenames (`README.md` instead of `README.EN.md`)
- Fixed `nowhere.sh` requiring `python3` unnecessarily in source compilation mode
- Added validation for `--method` parameter (only accepts `release` or `source`)
- Added validation for `--swap` parameter format
- Added validation for `--commit` parameter format (7-40 hex characters)

### Changed
- Renamed `README.EN.md` to `README.md` for proper GitHub repository landing page
- Updated all internal README cross-references to match new filenames
- Renumbered all chapters in both READMEs due to new §0 section
- Improved error messages for invalid parameters with multilingual support
- Updated table of contents in both READMEs to reflect new structure
- Enhanced `show_link()` to clarify it shows server config, not client link
- Restructured §6 "Client Connection & Import" with subsections explaining link formats
- Updated interactive menu numbering to accommodate new client-link option (shifted from 11 options to 12)
- Client link generation now follows host precedence: `--host` flag > config `LISTEN_HOST` > detected public IP
- Client link now includes SNI parameter automatically when TLS=2 and host is a domain name
- Client link warns when TLS=1 (self-signed) that clients must trust the certificate fingerprint

