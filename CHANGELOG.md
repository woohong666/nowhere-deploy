# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased] - 2026-09-10

### Added
- **Critical**: Added "Download & Run the Script" section (§0) in both README.md and README.zh-CN.md with clear download instructions
- Added script selection guidance explaining the difference between `nowhere.sh`, `install.sh`, and `install-source.sh`
- Added two download methods: recommended (wget + verify) and alternative (one-line command)
- Created `.gitignore` to exclude backup and temporary files
- Added comprehensive parameter validation in `validate_config()` function

### Fixed
- **Critical**: Fixed empty host in portal URL causing malformed `portal://@:port` format. Now shows `<YOUR-SERVER-IP-OR-DOMAIN>` placeholder when `LISTEN_HOST` is empty
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
