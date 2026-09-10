# Nowhere One-Click Deployment & Management Script (Linux VPS)

[English](README.md) | [简体中文](README.zh-CN.md)

A production-grade one-click deployment and operations script built on the official [NodePassProject/Nowhere](https://github.com/NodePassProject/Nowhere) core protocol.

It combines strict SHA-256 hash verification of official release binaries, fully-optimized local Rust source compilation (Fat-LTO), a hardened systemd permission sandbox, Let's Encrypt certificate permission isolation, and a color terminal interactive console (TUI) available in Chinese / English / Russian.

---

## Table of Contents

- [0. Download & Run the Script](#0-download--run-the-script)
- [1. Feature Comparison & Mode Selection](#1-feature-comparison--mode-selection)
- [2. Prerequisites](#2-prerequisites)
- [3. Quick Start (One-Click Install)](#3-quick-start-one-click-install)
  - [3.1 Interactive Console Mode (Recommended for Beginners)](#31-interactive-console-mode-recommended-for-beginners)
  - [3.2 Non-Interactive CLI Deployment (Automation / Scripting)](#32-non-interactive-cli-deployment-automation--scripting)
- [4. TLS Certificate Configuration & Permission Handling](#4-tls-certificate-configuration--permission-handling)
- [5. Firewall & Network Rules](#5-firewall--network-rules)
- [6. Client Connection & Import](#6-client-connection--import)
- [7. Daily Operations & Service Management](#7-daily-operations--service-management)
- [8. Upgrade, Zero-Downtime Rollback & Uninstall](#8-upgrade-zero-downtime-rollback--uninstall)
- [9. Full CLI Parameter Reference](#9-full-cli-parameter-reference)
- [10. File Layout & Security Sandbox](#10-file-layout--security-sandbox)
- [11. Troubleshooting (FAQ)](#11-troubleshooting-faq)

---

## 0. Download & Run the Script

### Recommended: Download and Verify First (Safest)

```bash
# Download the unified management script
wget https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere.sh

# Make it executable
chmod +x nowhere.sh

# Run with root privileges
sudo bash nowhere.sh
```

### Alternative: One-Line Command (For Trusted Sources)

```bash
curl -fsSL https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere.sh -o nowhere.sh && chmod +x nowhere.sh && sudo bash nowhere.sh
```

> **💡 Which script should I use?**
>
> This repository contains three scripts:
> - **`nowhere.sh`** ← **Recommended for most users** (supports both prebuilt and source compilation via TUI menu)
> - `install.sh` ← For automation/CI, prebuilt binary only
> - `install-source.sh` ← For automation/CI, source compilation only
>
> **If you're not sure, just use `nowhere.sh`** — it provides an interactive menu where you can choose your preferred installation method.

---

## 1. Feature Comparison & Mode Selection

The script supports two installation modes. Configuration and the service interface are fully unified, so you can switch between them smoothly at any time:

| Aspect | Official Prebuilt Binary (Release) | Local Source Build (Source) |
|---|---|---|
| **Acquisition** | Downloads the official static binary published on GitHub | **Clones the Git source directly on the machine and builds it live** |
| **Deploy time** | ~1 minute | 20–60 minutes (longer on 1–2 core VPS) |
| **Integrity check** | Mandatory SHA-256 digest comparison against the GitHub API; install is refused without verification | Build artifacts are produced entirely by the local compiler — no extra digest needed |
| **Performance** | Standard official release-level optimization | Automatically enables `lto = "fat"` + `codegen-units = 1` for maximum optimization |
| **Extra dependencies** | `curl` `python3` `tar` `sha256sum` | Automatically installs `git`, a C compiler, and the Rust 1.85+ toolchain |
| **Memory & disk** | No memory requirement; disk usage in the tens of MB | Requires ≥5 GB of temporary space during compilation; auto-mounts swap if memory is insufficient |
| **Best for** | Time-saving quick setup and primary/production use | Full audit-level scenarios and users who refuse third-party binaries |

---

## 2. Prerequisites

| Check | Requirement |
|---|---|
| **OS** | Mainstream Linux distributions (Debian 11+, Ubuntu 20.04+, CentOS 8+, Rocky / AlmaLinux, Arch, etc.) |
| **Init system** | `systemd` must be running (confirm with `ps -p 1 -o comm=` returning `systemd`) |
| **Architecture** | `x86_64` (amd64) or `aarch64` (arm64) |
| **Privileges** | `root` account, or full `sudo` authorization |
| **Port** | Recommended listening port range `1024-65535` (the service runs as an unprivileged user) |
| **Network** | The VPS must be able to reach `github.com` (the source-build mode also needs `static.rust-lang.org` and `crates.io`) |

---

## 3. Quick Start (One-Click Install)

### 3.1 Interactive Console Mode (Recommended for Beginners)

After downloading the script (see [§0](#0-download--run-the-script)), run it directly:

```bash
chmod +x nowhere.sh
sudo bash nowhere.sh
```

After launch, choose the interface language (Chinese, English, or Russian), then select the corresponding number in the TUI menu:

* Press `1`: **Install the official prebuilt version** (enter the port, key, and certificate paths; deployment starts within 1 minute).
* Press `2`: **Build from source locally** (automatically sets up the Rust toolchain and temporary swap, then starts compiling).

> **Tip**: In source-build mode, it's recommended to run inside a `tmux` or `screen` session so a network hiccup doesn't kill your SSH connection — and the build — mid-way:
>
> ```bash
> tmux new -s nowhere
> sudo bash nowhere.sh
> # Detach anytime with Ctrl+B then D; reattach anytime with tmux attach -t nowhere
> ```

---

### 3.2 Non-Interactive CLI Deployment (Automation / Scripting)

#### Scenario A: Quick install for temporary testing (TLS 1, self-signed)

No domain or certificate setup required — verify connectivity quickly:

```bash
sudo bash nowhere.sh install \
  --method release \
  --port 2077 \
  --net mix \
  --tls 1 \
  --key 'MyGeneratedKey_12345678'
```

#### Scenario B: Production deployment (TLS 2, strictly verified PEM certificate)

Use your own real-domain PEM certificate (e.g. issued by Let's Encrypt / acme.sh):

```bash
# 1. Copy the authorized certificate into a dedicated, isolated path
sudo bash nowhere.sh prepare-tls \
  --cert /etc/letsencrypt/live/example.com/fullchain.pem \
  --tls-key /etc/letsencrypt/live/example.com/privkey.pem

# 2. Start the production deployment
sudo bash nowhere.sh install \
  --method release \
  --port 2077 \
  --net mix \
  --tls 2 \
  --cert /etc/nowhere/tls/fullchain.pem \
  --tls-key /etc/nowhere/tls/privkey.pem \
  --key 'MyGeneratedKey_12345678'
```

---

## 4. TLS Certificate Configuration & Permission Handling

### 4.1 Why is `prepare-tls` required?

Let's Encrypt's default private key permissions are `600 root:root`, with the parent directory at `700`. The unprivileged `nowhere` service user, running inside a strict systemd sandbox, has no permission to read it.

**It is strongly discouraged** to `chmod 644` the original certificate private key directly — doing so undermines system security. Running `prepare-tls` safely syncs the certificate into `/etc/nowhere/tls/` and grants group ownership to the `nowhere` system user (`640 root:nowhere`).

### 4.2 Automatic Renewal & Hook Configuration

If you use Certbot to manage certificates, add a renewal hook at `/etc/letsencrypt/renewal-hooks/deploy/nowhere.sh`:

```bash
#!/usr/bin/env bash
bash /path/to/nowhere.sh prepare-tls \
  --cert "$RENEWED_LINEAGE/fullchain.pem" \
  --tls-key "$RENEWED_LINEAGE/privkey.pem"
systemctl restart nowhere
```

Make it executable: `chmod +x /etc/letsencrypt/renewal-hooks/deploy/nowhere.sh`. From then on, every certificate renewal automatically re-authorizes the files and hot-reloads the service.

---

## 5. Firewall & Network Rules

Depending on your `--net` parameter, open the corresponding port in both the system firewall and your cloud provider's console (security group):

### UFW (Ubuntu / Debian)

```bash
# If using --net mix, both TCP and UDP must be allowed
sudo ufw allow 2077/tcp
sudo ufw allow 2077/udp
sudo ufw reload
sudo ufw status numbered
```

### Firewalld (CentOS / RHEL / Fedora / Rocky)

```bash
sudo firewall-cmd --permanent --add-port=2077/tcp
sudo firewall-cmd --permanent --add-port=2077/udp
sudo firewall-cmd --reload
```

---

## 6. Client Connection & Import

Once deployment completes, the script prints your dedicated node connection link in the terminal:

```text
portal://<key>@<your-domain-or-ip>:<port>?tls=2&crt=%2Fetc%2Fnowhere%2Ftls%2Ffullchain.pem&key=%2Fetc%2Fnowhere%2Ftls%2Fprivkey.pem
```

* **mix mode**: TCP and UDP share the same port.
* **Security warning**: the `portal://` link embeds your connection password. Anyone who obtains this link can use your VPS as an outbound proxy. Never post it in public groups or public repositories!

Retrieve the link again at any time:

```bash
sudo bash nowhere.sh link
```

---

## 7. Daily Operations & Service Management

Regardless of which installation mode you used, the following commands are available:

```bash
# Open the interactive control menu
sudo bash nowhere.sh menu

# Check service status and the currently running release version
sudo bash nowhere.sh status

# Tail live system logs (Ctrl+C to exit)
sudo bash nowhere.sh logs

# Restart the Nowhere service
sudo bash nowhere.sh restart

# Native systemctl operations
sudo systemctl status nowhere
sudo systemctl restart nowhere
```

---

## 8. Upgrade, Zero-Downtime Rollback & Uninstall

### 8.1 Upgrading

```bash
# Upgrade to a specific official release tag
sudo bash nowhere.sh upgrade --version v1.9.0
```

The `/etc/nowhere/nowhere.env` configuration is preserved during an upgrade. If the new version fails its startup check, the script automatically reverts to the previous version to prevent service loss.

### 8.2 Instant, Lossless Rollback

If a new version misbehaves, roll back immediately:

```bash
sudo bash nowhere.sh rollback
```

The script repoints the symlink to the last successfully built/running release and restarts the service — instant, with no re-download or rebuild required.

### 8.3 Cleanup & Uninstall

```bash
# Clean up leftover source-build cache and temporary swap
sudo bash nowhere.sh clean-build

# Uninstall the binary and systemd service (keeps /etc/nowhere config and keys)
sudo bash nowhere.sh uninstall

# Full uninstall (also removes all config, certificate grants, and runtime state — irreversible)
sudo bash nowhere.sh uninstall --purge
```

---

## 9. Full CLI Parameter Reference

| Parameter | Default | Description |
| --- | --- | --- |
| `--method MODE` | `release` | Install mode: `release` (prebuilt) or `source` (local build) |
| `--key KEY` | auto-generated | Portal shared key (16–255 chars; letters, digits, and `._~-` only) |
| `--port PORT` | `2077` | Listening port (must be within `1024-65535`) |
| `--net MODE` | `mix` | Network protocol: `mix` (TCP/UDP on the same port), `tcp`, or `udp` |
| `--tls MODE` | `2` | TLS mode: `1` (temporary self-signed cert), `2` (local PEM certificate file) |
| `--cert PATH` | none | Full-chain certificate path (`fullchain.pem`); required for TLS 2 |
| `--tls-key PATH` | none | Private key file path (`privkey.pem`); required for TLS 2 |
| `--version TAG` | `v1.8.3` | GitHub Release or Git tag version to pull |
| `--libc MODE` | `auto` | C library compatibility (prebuilt mode only): `auto`, `gnu`, or `musl` |
| `--commit SHA` | none | Pin an exact Git commit hash for the source build |
| `--jobs N` | number of cores | Limit parallel cargo build jobs; use `1` on single-core machines |
| `--swap MODE` | `auto` | Temporary swap control: `auto`, `off`, or a custom size in MB |
| `--keep-source` | off | Keep the build tree and cache after compiling to speed up the next incremental build |
| `--lang LANG` | `ask` | Interface language: `zh` (Chinese), `en` (English), `ru` (Russian) |

---

## 10. File Layout & Security Sandbox

After installation, files are laid out as follows:

```text
/opt/nowhere/
├── releases/
│   ├── v1.8.3-prebuilt-xxxxxxxxxxxx/     # Official prebuilt binary release directory
│   │   ├── nowhere
│   │   └── RELEASE-INFO                  # Official download & digest audit record
│   └── v1.8.3-source-yyyy-zzzzzzzzzzzz/  # Local source-build release directory
│       ├── nowhere
│       └── BUILD-INFO                    # Compiler & commit-hash provenance record
└── current -> releases/...               # Atomic symlink pointing to the active release

/usr/local/bin/nowhere -> /opt/nowhere/current/nowhere  # Global executable symlink

/etc/nowhere/
├── nowhere.env                           # Runtime config file (mode 600, root read/write only)
└── tls/
    ├── fullchain.pem                     # Authorized certificate (mode 640, root:nowhere)
    └── privkey.pem                       # Authorized private key (mode 640, root:nowhere)

/etc/systemd/system/nowhere.service       # Hardened systemd sandbox unit
/var/lib/nowhere/                         # Dedicated runtime home / state directory
```

---

## 11. Troubleshooting (FAQ)

### Q1: `GLIBC_2.xx not found`

* **Cause**: The system's bundled glibc version is older than the one used to build the official GNU binary.
* **Fix**: Reinstall using the official static musl build:

```bash
sudo bash nowhere.sh install --method release --libc musl [other args...]
```

### Q2: Source build is killed with `signal: 9 Killed`

* **Cause**: Full-program link-time optimization (Fat-LTO) exceeded available physical memory and was terminated by the OOM killer.
* **Fix**: Allocate more temporary swap and limit parallel jobs, then retry:

```bash
sudo bash nowhere.sh install --method source --swap 4096 --jobs 1 [other args...]
```

### Q3: `GitHub did not publish a SHA-256 digest`

* **Cause**: The script enforces zero-trust verification; occasionally the official release pipeline doesn't publish a digest file for the artifact, so the script aborts the download rather than proceed unverified.
* **Fix**: Use local source-build mode instead: `--method source`.

### Q4: `Service user nowhere cannot read certificate`

* **Cause**: TLS 2 mode referenced the raw Let's Encrypt private key directly, which the service user has no permission to read.
* **Fix**: Always run `sudo bash nowhere.sh prepare-tls --cert ... --tls-key ...` first, and use the `/etc/nowhere/tls/` paths it outputs as your install parameters.

### Q5: Client can't connect, or the handshake times out

* **Checklist**:
  1. Confirm the service is running: `sudo systemctl status nowhere`;
  2. Confirm the local port is listening: `sudo ss -lntup | grep 2077`;
  3. Confirm the system firewall (UFW / Firewalld) allows the port/protocol (TCP/UDP);
  4. Confirm your VPS provider's console (Alibaba Cloud, Tencent Cloud, AWS, Oracle, etc.) security-group inbound rules allow the port;
  5. Confirm DNS resolution is correct and CDN proxying is disabled (direct connection required).
