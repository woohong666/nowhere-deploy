# Nowhere One-Click Deployment & Management Scripts (Linux VPS)

[English](README.md) | [简体中文](README.zh-CN.md)

Production-grade one-click deployment and operations scripts built on the official [NodePassProject/Nowhere](https://github.com/NodePassProject/Nowhere) core protocol.

> **⭐ Primary channel: V3 (NW3)** — `nowhere-v3.sh`, targeting Nowhere `v3.x`. **Use it for every new deployment.**
> Portal / Vector / Egress roles, `in=` ingress, `out=egress` remote exits, 32-hex keys, Morph on by default; plus hardenings of its own: SHA-256 zero-trust installs, transactional configuration (automatic rollback), `doctor` health checks, backup / instant rollback, **remote certificate fingerprints**, **Let's Encrypt issuance with daily auto-renewal**, and the `nh` shortcut menu (numbered choices / y-n / QR codes).
> It uses its own paths and service (`/opt/nowhere-v3`, `/etc/nowhere-v3`, `nowhere-v3.service`, ports 2083/1083) and never touches V1/V2. Full documentation: [§13](#13-v3-channel-nw3).
>
> **V2 channel (maintenance):** `nowhere-v2.sh`, targeting Nowhere `v2.x` (newest official v2: **v2.2.1**) — **for maintaining existing NW2 deployments only** (e.g. clients still on Anywhere ≤ 2.3). The full TUI, source builds, and more remain in the collapsed section below ([§3](#3-quick-start-v2) onward).
>
> **🔒 V1 stable channel (maintenance):** `nowhere-v1.sh`, pinned to `v1.8.3`, does not follow `latest` and does not install V2. Intended only for existing V1 nodes or the Russian interface; see [§12](#12-v1-stable-channel-deployment-only).

The V3 manager combines strict SHA-256 verification of official release binaries, transactional install/configure (automatic rollback on failure), `doctor` health checks, config backup and instant rollback, automatic Let's Encrypt issuance with daily renewal, the `nh` shortcut menu (numbered choices / y-n shorthand / QR share links / remote fingerprint checks), and bilingual documentation with a sandboxed test suite. The V2 source-build and TUI capabilities remain documented in the maintenance section below.

---

## Table of Contents

<details>
<summary>Click to expand the contents (⭐ §13 V3 is the primary channel; V1 / V2 are maintenance docs, folded into a separate block)</summary>

- [0. Which Script Should I Use?](#0-which-script-should-i-use)
- [1. Install Modes (Release / Source)](#1-install-modes-release--source)
- [2. Prerequisites](#2-prerequisites)
- [3. Quick Start (V2)](#3-quick-start-v2)
  - [3.0 Download, Verify, and Run](#30-download-verify-and-run)
  - [3.1 Interactive Menu (Recommended)](#31-interactive-menu-recommended)
  - [3.2 Non-Interactive CLI Deployment (Automation)](#32-non-interactive-cli-deployment-automation)
- [4. TLS Certificates and Permission Handling](#4-tls-certificates-and-permission-handling)
- [5. Firewall and Network Rules](#5-firewall-and-network-rules)
- [6. Client Links and Import](#6-client-links-and-import)
- [7. Daily Operations](#7-daily-operations)
- [8. Upgrade, Rollback, Backup, and Uninstall](#8-upgrade-rollback-backup-and-uninstall)
- [9. Full CLI Reference](#9-full-cli-reference)
- [10. File Layout and Sandbox](#10-file-layout-and-sandbox)
- [11. Troubleshooting (FAQ)](#11-troubleshooting-faq)
- [12. V1 Stable Channel (Deployment Only)](#12-v1-stable-channel-deployment-only)
- [13. V3 Channel (NW3)](#13-v3-channel-nw3)

</details>

---

## 0. Which Script Should I Use?

**Use `nowhere-v3.sh` (the NW3 primary channel) for every new deployment**; V2 is only for maintaining existing NW2 deployments, and V1 only for older V1 nodes.

| Script | Protocol line | Purpose |
|---|---|---|
| **`nowhere-v3.sh`** | **NW3 (v3.x)** | ⭐ **Primary**: new deployments and daily management (the `nh` menu) — see [§13](#13-v3-channel-nw3) |
| `nowhere-v2.sh` | NW2 (v2.2.1 LTS) | Maintenance for existing V2 deployments; full TUI / source-build docs in the collapsed section ([§3](#3-quick-start-v2) onward) |
| `nowhere-v1.sh` | V1 (pinned v1.8.3) | Existing V1 nodes / Russian interface only — see [§12](#12-v1-stable-channel-deployment-only) |
| `install.sh` / `install-source.sh` | V1 | Automation / CI only (V1) |

### V3 highlights

- **Modern protocol**: NW3 = TLS 1.3 (fixed `nw3` ALPN) with an optional QUIC carrier; authentication bound to the TLS exporter; exactly 32-hex shared keys; Morph on by default and must match on both ends
- **Three roles**: Portal (listener), Vector (local SOCKS5 ingress), **Egress** (remote exit — dials out over QUIC, so **the exit host needs no inbound ports at all**)
- **Certificates on autopilot**: one-command Let's Encrypt issuance with **daily auto-renewal** (Cloudflare DNS-01 or HTTP-01); the switch runs inside a transaction and rolls back on failure — see §13.5
- **Management UX**: the `nh` shortcut menu (23 actions, numbered choices, y/n shorthand), client links + **QR codes**, certificate fingerprints (local and **remote**)
- **Operations safety**: zero-trust installs (no SHA-256 digest, no install), transactional configuration, `doctor` health checks, config backup / instant rollback, `flock` concurrency guard
- **Quality**: a full sandboxed test suite with GitHub CI regression runs; bilingual documentation and an acceptance checklist

### Deploy in three minutes (V3)

```bash
cd /root
wget https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v3.sh -O nowhere-v3.sh
chmod 700 nowhere-v3.sh
sudo bash nowhere-v3.sh      # menu -> type 1 to install a Portal (wizard; Enter keeps defaults)
# afterwards: nh (menu) · sudo bash nowhere-v3.sh links (links + QR)
```

> **Protocol compatibility (must read):** NW2 / NW3 are **not interoperable** — no negotiation, no fallback; the Anywhere client is **NW2-only up to 2.3 and NW3-only from 2.4** (see [FAQ Q8](#11-troubleshooting-faq)); V1 and V2 are likewise not interoperable. Every node on a path must stay on the same protocol line.
>
> **V2 maintenance notes:** since Nowhere 2.2.0 keys must be 32-64 lowercase hex and native clients always verify certificates (self-signed needs `pin=`); Morph had a breaking change in 2.1.0. Details live in the collapsed V2 documentation below.

---

<details>
<summary><b>V1 / V2 full documentation (for maintaining existing deployments; new deployments should use the V3 flow above → §13) — click to expand</b></summary>

## 1. Install Modes (Release / Source)

Both modes share identical configuration and service interfaces, and can take over from each other at any time:

| Dimension | Official release binary (Release) | Local source build (Source) |
|---|---|---|
| **Source** | Download the official prebuilt static binary from GitHub | **Clone and compile the upstream source on this machine** |
| **Time** | ~1 minute | 20–60 minutes (slow on 1–2 vCPU VPS) |
| **Integrity** | Mandatory SHA-256 digest comparison against the GitHub API; refuses to install without one | Artifact is produced by the local compiler; no extra digest needed |
| **Performance** | Upstream release-grade optimisation | Forces `lto = "fat"` + `codegen-units = 1` |
| **Extra deps** | `curl` `python3` `tar` `sha256sum` | Auto-installs `git`, a C compiler, and the Rust toolchain |
| **Resources** | No memory requirement; tens of MB of disk | Needs ≥5 GB scratch space; auto-mounts swap when memory is low |
| **Best for** | Getting running fast | Full auditability, avoiding third-party binaries |

---

## 2. Prerequisites

| Check | Requirement |
|---|---|
| **OS** | Mainstream Linux (Debian 11+, Ubuntu 20.04+, CentOS 8+, Rocky / AlmaLinux, Arch, …) |
| **Init system** | A running `systemd` (verify with `ps -p 1 -o comm=`) |
| **Architecture** | `x86_64` (amd64) or `aarch64` (arm64) |
| **Privileges** | `root` or full `sudo` |
| **Ports** | Prefer `1024-65535` (the service runs as an unprivileged user) |
| **Network** | Reachable `github.com` (source builds also need `static.rust-lang.org` and `crates.io`) |

---

## 3. Quick Start (V2)

### 3.0 Download, Verify, and Run

```bash
# Download the V2 manager
wget https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v2.sh -O nowhere-v2.sh

# Make it executable
chmod 700 nowhere-v2.sh

# Syntax check first (optional but recommended)
bash -n nowhere-v2.sh

# Run with root privileges
sudo bash nowhere-v2.sh
```

> 💡 **On machines where you already log in as root and `sudo` is not installed** (common on minimal VPS images): drop the `sudo` prefix and run the command directly (e.g. `bash nowhere-v2.sh links`) — as root both forms are equivalent; `sudo: command not found` has exactly this cause.

Or in one line (trusted sources only):

```bash
curl -fsSL https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v2.sh -o nowhere-v2.sh && chmod 700 nowhere-v2.sh && bash -n nowhere-v2.sh && sudo bash nowhere-v2.sh
```

### 3.1 Interactive Menu (Recommended)

Run `sudo bash nowhere-v2.sh`, pick a language (Chinese / English), then choose from the menu:

```
 [1] Install/Reinstall official V2 release    [10] Rollback V2 binary
 [2] Build/install V2 from source             [11] Doctor
 [3] Configure / Import V2 URL                [12] Doctor --fix
 [4] Status                                   [13] Clean old V2 releases
 [5] Show V2 links                            [14] Clean V2 build cache
 [6] Live logs                                [15] Check latest stable V2
 [7] Restart V2 service                       [16] V1 -> V2 compatibility note
 [8] Open V2 TUI                              [17] Uninstall V2 only
 [9] TLS SHA-256 fingerprint                  [18] Self-update V2 manager
 [0] Exit
```

The installer asks for the node role (portal / vector), shared key, listen endpoint, TLS mode, and whether to enable Morph.

> **Tip:** run source builds inside `tmux` or `screen` so an SSH drop does not kill the compile:
>
> ```bash
> tmux new -s nowhere
> sudo bash nowhere-v2.sh
> # Ctrl+B then D to detach; tmux attach -t nowhere to return
> ```

### 3.2 Non-Interactive CLI Deployment (Automation)

Add `-y` / `--yes` for non-interactive mode. See [§9](#9-full-cli-reference) for every option.

#### Case A: Portal for a quick test

```bash
sudo bash nowhere-v2.sh install -y \
  --type portal \
  --endpoint '*:2082' \
  --key "$(openssl rand -hex 32)" \
  --tls 1
```

> Keys are 32-64 lowercase hex characters (Nowhere 2.2.0+); omit `--key` and the manager generates one. `--tls 1` uses a generated self-signed certificate and is only suitable for a quick check: on 2.2.0+ clients must pin it via `sudo bash nowhere-v2.sh fingerprint`, and that pin changes on every Portal restart. Prefer `--tls 2` for anything long-lived.

#### Case B: Portal in production ⭐ Recommended

```bash
sudo bash nowhere-v2.sh install -y \
  --type portal \
  --endpoint '*:2082' \
  --key "$(openssl rand -hex 32)" \
  --tls 2 \
  --cert /etc/letsencrypt/live/example.com/fullchain.pem \
  --tls-key /etc/letsencrypt/live/example.com/privkey.pem \
  --copy-cert \
  --public-host relay.example.com
```

`--copy-cert` copies the certificate into `/etc/nowhere-v2/tls/` with service-readable permissions (`640 root:nowhere-v2`), so no manual `chmod` is needed.

#### Case C: Vector client

```bash
sudo bash nowhere-v2.sh install -y \
  --type vector \
  --endpoint 'relay.example.com:2082' \
  --key '<64-hex key from the Portal>' \
  --vector-socks '127.0.0.1:1082'
```

> On Nowhere 2.2.0+ the Vector **verifies the Portal certificate**. With a CA-trusted `tls=2` certificate behind a matching hostname this just works; with a self-signed Portal add `--pin <sha256>` (copy it from `links` on the Portal host or `fingerprint`).

#### Case D: Enable Morph

```bash
sudo bash nowhere-v2.sh install -y --type portal \
  --endpoint '*:2082' --key "$(openssl rand -hex 32)" --tls 2 \
  --cert ... --tls-key ... --copy-cert \
  --morph 1
```

> **Note:** `morph` must be enabled on **both** ends of a hop with the same shared key. The Morph wire format also changed in Nowhere **2.1.0**, so every node on a `morph=1` path must be on `>=2.1.0`. The client TCP prelude policy now defaults to `full8` (upstream default since 2.2.0); `--morph-prelude low7` remains available as an explicit choice.

---

## 4. TLS Certificates and Permission Handling

### 4.1 Why `--copy-cert` is recommended

Let's Encrypt private keys default to `600 root:root` inside a `700` directory, which the unprivileged `nowhere-v2` user cannot read under the systemd sandbox.

**Do not** `chmod 644` the original key — that weakens system security. `--copy-cert` instead:

1. Copies the certificate and key to `/etc/nowhere-v2/tls/cert.pem` and `key.pem`
2. Sets them to `640 root:nowhere-v2`
3. Verifies the service account can actually read them, and fails loudly if not

During interactive setup, if the script detects that the service user cannot read the PEM you selected, it **offers to copy it automatically** rather than dead-ending on a root-only file.

### 4.2 Renewal hook

With Certbot, add `/etc/letsencrypt/renewal-hooks/deploy/nowhere-v2.sh`:

```bash
#!/usr/bin/env bash
bash /path/to/nowhere-v2.sh configure \
  --url "$(head -1 /etc/nowhere-v2/url.conf)" \
  --cert "$RENEWED_LINEAGE/fullchain.pem" \
  --tls-key "$RENEWED_LINEAGE/privkey.pem" \
  --copy-cert
systemctl restart nowhere-v2
```

Then `chmod +x /etc/letsencrypt/renewal-hooks/deploy/nowhere-v2.sh`.

### 4.3 Certificate verification (Nowhere 2.2.0+)

Native clients (Vector, `probe`, and a chained Portal's `next`) **always** verify the peer certificate: system CA trust plus the endpoint hostname/IP. `sni=` overrides the verified name, and `pin=none` does **not** disable verification.

| Portal certificate | What the client needs |
|---|---|
| CA-signed (`tls=2`, e.g. Let's Encrypt) | Nothing extra when clients reach the Portal by a name the certificate covers; otherwise set `sni=` or `pin=` |
| Self-managed / self-signed (`tls=2`) | `pin=<sha256>` — stable as long as you keep the certificate |
| Generated (`tls=1`) | `pin=<sha256>`; the generated certificate **changes on every Portal restart**, so the pin must be refreshed — testing only |

Get the fingerprint on the Portal host with `sudo bash nowhere-v2.sh fingerprint` (or from the certificate log), and treat a remotely fetched fingerprint as untrusted until it matches the Portal host. On a `tls=1` Portal, `links` auto-fills the pin into generated Vector URLs.

---

## 5. Firewall and Network Rules

Open the ports you actually listen on, both in the host firewall and in your cloud provider's security group. The V2 default port is `2082`, and the endpoint form decides which protocols are needed:

| Endpoint | Open |
|---|---|
| `*:2082` | TCP `2082` **and** UDP `2082` |
| `*/tcp:2082` | TCP `2082` only |
| `*/udp:2082` | UDP `2082` only |
| `*/tcp:2082/udp:2083` | TCP `2082` and UDP `2083` |

### UFW (Ubuntu / Debian)

```bash
sudo ufw allow 2082/tcp
sudo ufw allow 2082/udp
sudo ufw reload
sudo ufw status numbered
```

### Firewalld (CentOS / RHEL / Fedora / Rocky)

```bash
sudo firewall-cmd --permanent --add-port=2082/tcp
sudo firewall-cmd --permanent --add-port=2082/udp
sudo firewall-cmd --reload
```

> After deployment the script prints `Firewall: allow TCP/UDP <port>` hints.

---

## 6. Client Links and Import

### 6.1 URI formats

Nowhere V2 involves two kinds of URI:

1. **`portal://` / `vector://`** — the node's own runtime configuration (internal)
   - Stored in `/etc/nowhere-v2/url.conf`
   - **Not** for client import (a Vector's own `vector://` link can be used by a matching client)
2. **`nowhere://`** — a generic share URI
   - Use it only with clients that **explicitly support V2 / ALPN nw2**; Anywhere **2.4 (401) and later removed NW2** — a V2 link times out on updated clients (see FAQ Q8)

### 6.2 Generating client links

```bash
# Auto-detect the public IP (needs --public-host already set, or reachable api.ipify.org)
sudo bash nowhere-v2.sh links

# Or set the public host first
sudo bash nowhere-v2.sh configure --public-host relay.example.com
```

On a Portal this prints:

- **Native V2 Vector URL** — a `vector://` link usable by a matching Vector
- **Generic V2 share URI** — a `nowhere://` link with `socks=` removed and the node name as the fragment

> If you see `Set --public-host or PUBLIC_HOST to generate client links`, the script could not determine a public address; pass `--public-host` explicitly.

### 6.3 Security notes

* A link **contains the shared key**. Anyone who has it can use your VPS as an egress proxy. **Never post it publicly or commit it to a repository.**
* `--tls 1` (generated self-signed) requires the client to pin the certificate on 2.2.0+; `links` auto-fills the pin, but it changes on every Portal restart — use `tls=2` for production (see [§4.3](#43-certificate-verification-nowhere-220)).
* `morph` only works when both ends are configured identically.

### 6.4 Inspecting the server configuration

```bash
sudo bash nowhere-v2.sh link     # show the runtime URI from url.conf
```

---

## 7. Daily Operations

```bash
# Interactive menu
sudo bash nowhere-v2.sh

# Status (includes the Core version actually installed)
sudo bash nowhere-v2.sh status

# Live logs (Ctrl+C to stop)
sudo bash nowhere-v2.sh logs

# Restart / start / stop
sudo bash nowhere-v2.sh restart

# Health check; --fix repairs common problems
sudo bash nowhere-v2.sh doctor
sudo bash nowhere-v2.sh doctor --fix

# TLS SHA-256 fingerprint (Portal)
sudo bash nowhere-v2.sh fingerprint

# Read-only TUI monitor
sudo bash nowhere-v2.sh tui

# Native systemctl
sudo systemctl status nowhere-v2
sudo systemctl restart nowhere-v2
```

---

## 8. Upgrade, Rollback, Backup, and Uninstall

### 8.1 Upgrade

```bash
# Upgrade to the newest official stable release (the default)
sudo bash nowhere-v2.sh upgrade

# Or pin an exact version
sudo bash nowhere-v2.sh upgrade --version v2.2.1
```

> `upgrade` **requires an existing V2 configuration**; use `install` for a first deployment.
> When a config already exists, `install` / `upgrade` only replace the binary. Add `--force-reconfigure` to re-apply configuration options at the same time.
>
> **Crossing 2.2.0 with an existing config:** admission got stricter. If the Portal / `next=` key is not 32-64 lowercase hex, the new core refuses to start; and a Vector that relied on `pin=none` against a self-signed Portal fails the handshake. `install` / `upgrade` warns about both — rotate keys with `nowhere generate-key` (update every peer of that hop) and add the pin (see [§4.3](#43-certificate-verification-nowhere-220)) before upgrading. To rotate only the key and keep every other setting, run `sudo bash nowhere-v2.sh configure -y --config-mode quick --key "$(openssl rand -hex 32)"`, then update every peer.

### 8.2 Zero-downtime rollback

```bash
sudo bash nowhere-v2.sh rollback
```

This repoints the symlink to the previous usable release and restarts the service — no re-download or rebuild. If a new release fails to start during `upgrade`, the manager **rolls back automatically** and keeps the logs.

Retained releases are controlled by `--keep-releases` (default `3`):

```bash
sudo bash nowhere-v2.sh clean-releases          # prune manually
sudo bash nowhere-v2.sh clean-build             # drop source-build cache and swap
```

### 8.3 Backing up, restoring, and diagnostics

```bash
# Defaults to /root/nowhere-v2-backup-<timestamp>.tar.gz (contains secrets; mode 600)
sudo bash nowhere-v2.sh backup

# Or choose the output path (an existing file is never overwritten)
sudo bash nowhere-v2.sh backup /root/my-backup.tar.gz

# Validate an archive without changing anything
sudo bash nowhere-v2.sh restore /root/my-backup.tar.gz --dry-run

# Restore after confirmation (an automatic before-restore backup is saved next to the archive)
sudo bash nowhere-v2.sh restore /root/my-backup.tar.gz

# Shareable JSON health snapshot (allowlisted fields only; no keys, URLs, logs or tokens)
sudo bash nowhere-v2.sh diagnostics
sudo bash nowhere-v2.sh diagnostics --output /root/nowhere-v2-diagnostics.json
```

The archive contains `/etc/nowhere-v2` (runtime config, manager metadata, TLS material), not the binary. Backups are bounded (10,000 entries, 256 MiB per file, 1 GiB total), reject symlinks and special files, and carry a per-file SHA-256 manifest; `restore` checks the channel, the manifest and the PEM material before replacing anything, keeps the installed core and rolls back if the restarted service fails. Only restore archives you trust — the manifest detects corruption, it is not a signature.

### 8.4 Checking for new versions

```bash
sudo bash nowhere-v2.sh check-updates
```

### 8.5 Uninstall

```bash
# Remove the program and service, keeping /etc/nowhere-v2
sudo bash nowhere-v2.sh uninstall

# Purge everything, including config, certificates, and the dedicated user
sudo bash nowhere-v2.sh uninstall --purge
```

> V2 uninstall **never** touches V1's `/etc/nowhere`, `/opt/nowhere`, or `nowhere.service`.

---

## 9. Full CLI Reference

### 9.1 Actions

| Action | Description |
| --- | --- |
| `install` / `upgrade` / `update` | Install or upgrade (`upgrade` needs an existing config) |
| `configure` / `config` | Modify or import configuration |
| `status` | Runtime status, including the installed Core version |
| `link` / `links` | Show the runtime URI / generate client links |
| `logs` | Live logs |
| `restart` / `start` / `stop` | Service control |
| `tui` | Open the read-only TUI monitor |
| `fingerprint` | Portal TLS SHA-256 fingerprint |
| `rollback` | Roll back to the previous usable release |
| `doctor` / `check` / `diagnose` | Health check (`--fix` repairs) |
| `clean-releases` / `clean-build` | Prune releases / build cache |
| `check-updates` | Query the newest official stable version |
| `backup [PATH]` | Back up config and certificates (bounded, SHA-256 manifest) |
| `restore ARCHIVE [--dry-run]` | Validate and restore a backup (channel/manifest/PEM checked; automatic before-restore backup) |
| `diagnostics [--output FILE]` | Allowlisted JSON health snapshot (no secrets) |
| `uninstall` / `remove` | Uninstall (`--purge` deletes everything) |
| `self-update` | Update the manager itself (defaults to this repository's `main`) |
| `help` | Usage |

### 9.2 Options

| Option | Default | Description |
| --- | --- | --- |
| `-y`, `--yes` | off | Non-interactive mode |
| `--method MODE` | `release` | `release` (prebuilt) or `source` (local build) |
| `--version TAG` | `latest-v2` | `latest-v2` (newest official stable v2) or an exact `v2.x.y`; `v3.x` / NW3 is rejected |
| `--type`, `--role` | `portal` | Node role: `portal` / `vector` |
| `--url URL` | — | Import a `portal://` / `vector://` config (takes precedence over other config options) |
| `--key KEY` | generated (64 lowercase hex) | Shared key: 32-64 lowercase hex (Nowhere 2.2.0+). Legacy 1-255 safe keys are accepted for the Vector role only |
| `--endpoint EP` | `*:2082` (Portal) | `HOST:PORT` or `HOST/tcp:PORT/udp:PORT` |
| `--public-host HOST` | auto-detected | Public domain / IP used to build client links |
| `--name NAME` | `Nowhere-V2` | Node display name |
| `--tls MODE` | `1` | `1` self-signed; `2` local PEM. **Use `2` in production** |
| `--cert`, `--crt` PATH | — | Certificate chain path, required for TLS 2 |
| `--tls-key` PATH | — | Private key path, required for TLS 2 |
| `--copy-cert` | off | Copy the certificate into `/etc/nowhere-v2/tls/` with service-readable permissions |
| `--morph 0\|1` | `0` | Wire masking; must match on both ends |
| `--morph-prelude` | `full8` | Client TCP Morph prelude policy: `full8` (upstream default since 2.2.0) or `low7` |
| `--up` / `--down` | `auto` | Carrier policy: `auto` / `tcp` / `udp` / `mix` |
| `--mux 0\|1` | `0` | TLS multiplexing |
| `--sni NAME\|none` | `none` | DNS name for certificate verification |
| `--pin SHA256\|none` | `none` | Pinned certificate SHA-256; on 2.2.0+ `none` no longer disables verification (see [§4.3](#43-certificate-verification-nowhere-220)) |
| `--out-socks HOST:PORT\|none` | `none` | Outbound SOCKS5 (mutually exclusive with `next`) |
| `--next KEY@EP` | `none` | Native V2 next-hop Portal |
| `--vector-socks` | `127.0.0.1:1082` | Vector local SOCKS5 listener |
| `--client-up/down/mux/sni/pin` | auto | Options used when generating client links |
| `--rate` / `--etar` | `0` | Forward / reverse rate limit in Mbps (0 = unlimited) |
| `--dial` | `auto` | Outbound source IP (single family); mutually exclusive with `--dial4` / `--dial6` |
| `--dial4` / `--dial6` | `auto` | Nowhere 2.2.0+ dual-stack outbound sources: `auto` or a bare IPv4 / IPv6 literal |
| `--log LEVEL` | `info` | `none` / `debug` / `info` / `warn` / `error` (`event` was removed in 2.1.1) |
| `--memory-profile` | `throughput` | Transport memory profile: `memory` / `balanced` / `throughput` |
| `--config-mode` | `ask` | `ask` / `quick` / `advanced`; also `--quick` / `--advanced` |
| `--keep-releases N` | `3` | Releases to retain (0–20) |
| `--libc auto\|gnu\|musl` | `auto` | libc choice for release installs |
| `--swap auto\|off\|MB` | `auto` | Temporary swap control |
| `--keep-source` | off | Keep the build tree to speed up later builds |
| `--github-token TOKEN` | — | Token for GitHub API calls (avoids rate limits) |
| `--force-reconfigure` | off | With `install` / `upgrade`, explicitly re-apply configuration options |
| `--fix` | off | With `doctor`, repair automatically |
| `--purge` | off | With `uninstall`, delete configuration too |

### 9.3 Environment variables

Every configuration value has a matching `NOWHERE_V2_*` variable, for example `NOWHERE_V2_LANG` (`zh` / `en`), `NOWHERE_V2_KEY`, `NOWHERE_V2_TLS`, `NOWHERE_V2_MORPH`, `NOWHERE_V2_MEMORY_PROFILE`, `NOWHERE_V2_MORPH_PRELUDE`, `NOWHERE_V2_DIAL4` / `NOWHERE_V2_DIAL6`, and `NOWHERE_V2_VERSION`.

> Persisted values in `manager.conf` take precedence over environment variables; command-line options take precedence over both.

---

## 10. File Layout and Sandbox

```text
/opt/nowhere-v2/
├── releases/
│   ├── v2.2.1-release-xxxxxxxxxxxx/          # official prebuilt release
│   │   ├── nowhere
│   │   └── RELEASE-INFO                      # tag / asset / SHA-256 audit record
│   └── v2.2.1-source-aaaa-bbbbbbbbbbbb/      # local source build
│       ├── nowhere
│       └── BUILD-INFO                        # commit / SHA-256 provenance
└── current -> releases/...                   # atomic symlink to the active release

/usr/local/bin/nowhere-v2 -> /opt/nowhere-v2/current/nowhere   # global executable symlink
/usr/local/libexec/nowhere-v2-launch                            # root-owned launcher (reads url.conf)

/etc/nowhere-v2/
├── url.conf                                  # runtime URL (640, root:nowhere-v2)
├── manager.conf                              # manager metadata (640, root:nowhere-v2)
└── tls/
    ├── cert.pem                              # certificate (640, root:nowhere-v2)
    └── key.pem                               # private key (640, root:nowhere-v2)

/etc/systemd/system/nowhere-v2.service        # hardened systemd sandbox unit
```

The unit enables `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `CapabilityBoundingSet=CAP_NET_BIND_SERVICE`, and injects only `NOW_TRANSPORT_MEMORY_PROFILE` and `NOW_MORPH_TCP_PRELUDE` via `Environment=`.

---

## 11. Troubleshooting (FAQ)

### Q1: `GLIBC_2.xx not found`

* **Cause:** the host glibc is older than the one used for the official GNU build.
* **Fix:** reinstall with the musl static build:

```bash
sudo bash nowhere-v2.sh install -y --method release --libc musl [options...]
```

### Q2: The source build is killed with `signal: 9 Killed`

* **Cause:** Fat-LTO linking exceeded memory and the OOM killer terminated it.
* **Fix:** allocate a larger temporary swap and retry:

```bash
sudo bash nowhere-v2.sh install -y --method source --swap 4096 [options...]
```

### Q3: `GitHub release does not expose a SHA-256 digest ... refusing binary install`

* **Cause:** the manager enforces zero-trust verification, and that release does not publish a digest for the asset.
* **Fix:** use the source build instead: `--method source`.

### Q4: `V2 service user cannot read TLS files`

* **Cause:** `--tls 2` referenced a root-only PEM that the service user cannot read.
* **Fix:** reconfigure with `--copy-cert` so the manager copies the material into `/etc/nowhere-v2/tls/`.

### Q5: Traffic breaks after an upgrade (especially with `morph`)

* **Cause (2.1.0):** the Morph wire format changed; morph-enabled 2.1 peers are incompatible with 2.0.x peers.
  * **Fix:** upgrade **every** node on the path (Portal / Vector / native next / other clients) to `>=2.1.0`.
* **Cause (2.2.0):** admission got stricter — a legacy shared key makes the Portal refuse to start, and native clients now verify certificates, so a self-signed Portal without `pin=` fails the handshake.
  * **Fix:** rotate to 32-64 lowercase hex keys on every peer of the hop (`nowhere generate-key`), and add `pin=<sha256>` or switch to a CA-trusted certificate (see [§4.3](#43-certificate-verification-nowhere-220)).
* Check `journalctl -u nowhere-v2 -n 50` — 2.2.x names the offending endpoint without printing the key.

### Q6: Clients cannot connect or handshakes time out

1. Check the service: `sudo systemctl status nowhere-v2`
2. Check listeners: `sudo ss -lntup | grep 2082`
3. Check the host firewall (UFW / Firewalld) for the right ports and protocols
4. Check your cloud provider's **security group** inbound rules
5. Confirm DNS resolves and is not proxied by a CDN (a direct connection is required)
6. On 2.2.0+, confirm certificate trust: CA-signed certificate with a matching name, or `pin=<sha256>` for a self-signed Portal (see [§4.3](#43-certificate-verification-nowhere-220))
7. Run `sudo bash nowhere-v2.sh doctor` for a full check

### Q7: `Portal shared key must be 32-64 lowercase hex characters`

* **Cause:** the config still uses a pre-2.2 key format. Nowhere 2.2.0+ refuses to start with it (`nowhere generate-key` outputs the required form).
* **Fix:** rotate only the key, keeping the other settings, with `sudo bash nowhere-v2.sh configure -y --config-mode quick --key "$(openssl rand -hex 32)"`. Then configure the **same** text on every peer of that hop. Legacy 1-255 byte keys keep working only against Portals `<=2.1`.

### Q8: V2 stopped connecting after updating the Anywhere app (2.4+)

* **Cause (client-side, not a server fault):** Anywhere **2.4 (401)** replaced its embedded Nowhere implementation with NW3 — the app and network-extension binaries contain only the `nw3` ALPN and `nowhere/nw3/auth-root`, with no `nw2` implementation left. NW2 and NW3 are wire-incompatible with **no negotiation or fallback**, so on 2.4+ a V2 (`nw2`) entry keeps timing out; conversely, 2.3 and earlier cannot reach V3.
* **Prove the server is healthy:** `sudo bash nowhere-v2.sh doctor`; from outside, `echo | openssl s_client -connect <host>:2082 -servername <name> -alpn nw2 2>&1 | grep ALPN` — `ALPN protocol: nw2` means the Portal is intact (probes with a mismatched ALPN are silently dropped by design).
* **Choices:** keep V2 → keep the client on 2.3 or earlier; already on 2.4+ → migrate to the [V3 channel (NW3)](#13-v3-channel-nw3). One app version cannot serve both V2 and V3 on the same device.

### Q9: `sudo: command not found`

* **Cause:** you are already logged in as root, and this VPS image (some Evoxt images, for example) is minimal and does not ship `sudo`. It is unrelated to the manager or the service.
* **Fix:** drop the `sudo` prefix and run the command directly, e.g. `bash nowhere-v2.sh status`, `bash nowhere-v3.sh links`, or just `nh`. As root both forms are equivalent. Installing sudo (Debian/Ubuntu: `apt-get install -y sudo`) is possible but unnecessary.

---

## 12. V1 Stable Channel (Deployment Only)

> The V1 channel is **pinned to Nowhere `v1.8.3`**, does not follow `latest`, and **does not support V2**.
> Use it only for existing V1 nodes or when you need the Russian interface.

### Deploy

```bash
# Download
wget https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v1.sh -O nowhere-v1.sh

# Verify and run
chmod 700 nowhere-v1.sh
bash -n nowhere-v1.sh
sudo bash nowhere-v1.sh
```

### Non-interactive production example

```bash
sudo bash nowhere-v1.sh install \
  --method release \
  --port 2077 \
  --net mix \
  --tls 2 \
  --cert /etc/nowhere/tls/fullchain.pem \
  --tls-key /etc/nowhere/tls/privkey.pem \
  --key "$(openssl rand -hex 16)"
```

### V1 / V2 isolation

| | V1 | V2 |
|---|---|---|
| Service | `nowhere` | `nowhere-v2` |
| Install root | `/opt/nowhere` | `/opt/nowhere-v2` |
| Config dir | `/etc/nowhere` | `/etc/nowhere-v2` |
| Global binary | `/usr/local/bin/nowhere` | `/usr/local/bin/nowhere-v2` |
| Default port | `2077` | `2082` |
| Languages | Chinese / English / Russian | Chinese / English |

They coexist on one VPS as long as their ports do not collide, and neither modifies the other's files or services.

### V1 documentation

- [`NOWHERE_V1_STABLE_README.md`](NOWHERE_V1_STABLE_README.md) — full V1 stable manager documentation
- [`README.two-scripts.EN.md`](README.two-scripts.EN.md) — `install.sh` / `install-source.sh` automation installers

> V1 feature details (`prepare-tls`, `client-link`, `--net`, …) live in those documents. This main README only keeps the deployment entry point.

</details>

---

## 13. V3 Channel (NW3)

> `nowhere-v3.sh` is a **separate manager** for the Nowhere **v3.x** line. It is fully isolated from V2 (own service, account, paths, ports) and never converts or touches a V2 install. NW3 is wire-incompatible with NW2, with no negotiation or fallback.
>
> Document map: V3 installation and operations = this section §13; acceptance checklist = [`ACCEPTANCE.md`](ACCEPTANCE.md) §13; change history = [`CHANGELOG.md`](CHANGELOG.md); full V2 documentation = §2–§11 of this file.

### 13.1 Step-by-step installation

The first installation is best done through the menu wizard (Step 1); use Step 2 for unattended deployments.

**Step 0 · Download the script (keep it in `/root`)**

```bash
cd /root
wget https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v3.sh -O nowhere-v3.sh
chmod 700 nowhere-v3.sh
bash -n nowhere-v3.sh        # syntax self-check; no output means it passed
```

> 💡 On machines where you already log in as root and `sudo` is not installed (e.g. minimal Evoxt images): drop the `sudo` prefix from every command in this document (e.g. `bash nowhere-v3.sh links`) — identical result.

**Step 1 · Open the menu and install a Portal with the wizard (recommended)**

```bash
sudo bash nowhere-v3.sh      # no arguments = the full 23-action menu
```

The menu has three groups: **1–6 install & configure** (1=Portal 2=Vector 3=Egress 4=reconfigure 5=pick a version 6=upgrade), **7–15 service & diagnostics** (start/stop/restart, status, client links, certificate fingerprint, key generation, TCP probe, live logs), **16–22 maintenance** (health check, prune, backup, rollback, uninstall, language, update the manager) and **23 certificate** (issue/renew a TLS certificate).

To install a Portal, **type `1`** (Vector is `2`, Egress is `3`) and follow the wizard — **Enter keeps the default shown in brackets**:

| Wizard prompt | Type | Meaning |
|---|---|---|
| Role | `1` | 1=portal (default) 2=vector 3=egress |
| Shared key | Enter | Generates a 32-hex key; paste your own to override |
| Listener preset | Enter (1) | 1=both (TCP+UDP on one port); 4=split asks for a UDP port (default 2084) |
| Primary port | Enter | Default 2083 |
| TLS mode | Enter (1) | 1=managed: generates a **persistent** self-signed PEM (pin stays stable across restarts); 2=supplied: bring your own certificate (two paths follow) |
| Output | Enter (1) | 1=direct 2=socks (upstream SOCKS, hidden input) 3=egress (remote exit) |
| Public host | your domain/IP | Used in client links (e.g. relay.example.com) |
| Morph | Enter (1) | Must match the client |

The service starts automatically and the `nh` shortcut is created — from then on just type `nh` to reopen the menu.

> **Existing instance:** menu `1` first asks "Existing instance: reconfigure with the wizard?" — **type `y` to enter the wizard**; pressing Enter / typing `n` only reinstalls the binary and leaves the configuration alone.

**Step 2 · Or one unattended command**

```bash
# Minimal: self-signed certificate + generated key + port 2083 + morph=1
sudo bash nowhere-v3.sh install --yes --public-host relay.example.com

# Bring a domain certificate (e.g. Let's Encrypt)
sudo bash nowhere-v3.sh install --public-host relay.example.com \
  --cert /etc/letsencrypt/live/relay.example.com/fullchain.pem \
  --tls-key /etc/letsencrypt/live/relay.example.com/privkey.pem

# Pin a version / port / key
sudo bash nowhere-v3.sh install --version v3.1.0 --endpoint '*:8443' \
  --key "$(openssl rand -hex 16)"
```

> Want an automatically issued/renewed Let's Encrypt certificate (with a domain)? After installing, run `sudo bash nowhere-v3.sh cert --domain your.example.com`, or use the menu (`nh` → `23`) — see §13.5.

**Step 3 · Verify after installation**

```bash
sudo bash nowhere-v3.sh doctor     # service / certificate / account checks
sudo bash nowhere-v3.sh links      # Vector URL + share links + QR codes
nh                                 # or just reopen the menu with the shortcut
```

**Step 4 · Import into the client (Anywhere 2.4+)**

- Scan the QR code from `links`, or copy a `nowhere://` link into the app
- Self-signed certificate: add the `sudo bash nowhere-v3.sh fingerprint` result to the app's trust list
- Import either the `net=tcp` or the `net=udp` link (same endpoint, different carrier; with a shared port import only one)

**Step 5 · Firewall (including your cloud security group)**

- Portal: allow **TCP and UDP 2083** (or the custom/split ports you chose)
- Egress: no inbound ports; it only needs QUIC/UDP outbound to the Portal

**Other roles and version tracking**

- **Vector**: save the printed `vector://` URL into a `600` file and run `sudo bash nowhere-v3.sh install --url-file /root/vector-v3.url` (SOCKS5 on `127.0.0.1:1083`).
- **Egress** (a remote exit behind an outbound QUIC connection): install the Portal with `--out egress`, move the printed `egress://` URL to the exit host, and `install --url-file` it there. A Portal accepts one registered Egress and does not fall back to direct access while it is offline.
- **Tracking v3.x**: the default is pinned to the verified `v3.1.0`; `upgrade --version latest-v3` follows the newest stable release; `upgrade --version latest-v3-prerelease` (or an explicit tag plus `--allow-prerelease`) opts in to prereleases, warns before installing, and can be reverted with `rollback`.

### 13.2 V2 / V3 at a glance

| | V2 (`nowhere-v2.sh`) | V3 (`nowhere-v3.sh`) |
|---|---|---|
| ALPN / protocol | `nw2` | `nw3` |
| Roles | Portal / Vector | Portal / Vector / Egress |
| Vector ingress | `socks=` | `in=` |
| Portal exit | direct / `socks=` / `next=` | `out=direct` / SOCKS / `out=egress` |
| up/down, Mux, native next | supported | removed (old parameters are refused) |
| Morph default | `0` | `1` |
| Service / config / binary | `nowhere-v2` · `/etc/nowhere-v2` · `nowhere-v2` | `nowhere-v3` · `/etc/nowhere-v3` · `nowhere-v3` |
| Default ports | 2082 / SOCKS 1082 | 2083 / SOCKS 1083 |
| Monitoring | TUI | `status` / `telemetry` |
| Source build / self-update | yes / yes | no source build / yes self-update |

> V3 v1.1.0 provides complete Chinese and English interaction. Firewall: allow TCP **and** UDP `2083`; an Egress host needs QUIC/UDP outbound to the Portal.

> **Client versions (observed):** Anywhere **2.3 and earlier implement only NW2** (cannot reach V3); **2.4 (401) and later implement only NW3** (cannot reach V2 — the NW2 implementation is gone from its binaries). A V2 entry timing out after an app update is expected, not a server failure; prove the V2 Portal with `doctor` / `probe` and an external `-alpn nw2` probe. See [FAQ Q8](#11-troubleshooting-faq).

---

### 13.3 Daily operations

No arguments opens a looping 23-action menu. Portal, Vector and Egress have
install/configure wizards. Install, configure or self-update create the `nh`
shortcut (opens this menu; arguments pass through, e.g. `nh status`; removed by
`uninstall --purge`). Wizard choices accept numbers (`1=both 2=tcp`; the value word
still works) and confirmations accept `y/n` (`yes`/`no`/`是`/`否`). Failed actions
restore their transaction in an isolated child shell before returning; unavailable
terminal input exits cleanly.

```bash
sudo bash nowhere-v3.sh                         # Full menu
sudo bash nowhere-v3.sh install --yes           # Default Portal, 2083, persistent PEM
bash nowhere-v3.sh versions                     # All stable V3 tags, numeric descending
bash nowhere-v3.sh check-updates
bash nowhere-v3.sh generate-key                 # Only 32 lowercase hex characters
sudo bash nowhere-v3.sh probe example.com:443    # Redacted URL + Result
sudo bash nowhere-v3.sh doctor --probe           # Probe failure warns only
sudo bash nowhere-v3.sh cert --domain relay.example.com  # Issue/renew a LE certificate (§13.5)
sudo bash nowhere-v3.sh status
sudo bash nowhere-v3.sh telemetry
sudo bash nowhere-v3.sh clean-releases
sudo bash nowhere-v3.sh language --lang en       # Persist language
sudo bash nowhere-v3.sh self-update              # Manager script only
NOWHERE_V3_SELF_URL= bash nowhere-v3.sh self-update # Disabled
```

Language precedence: `--lang` > `NOWHERE_V3_LANG` > manager.conf LANG > Chinese.
The menu and language action persist the choice; explicit --lang on mutations is
also saved. help/validate/generate-key/self-update do not edit service preferences.
New options: `--name` (share name), `--wizard`, `--dial/--dial4/--dial6`;
all previous CLI options remain supported.

`versions` lists every available stable tag; fewer than ten upstream releases
means fewer than ten results, never invented tags. The default stays v3.1.0
(v3.2.0 is a prerelease and is never selected by `latest-v3` or `versions`; an
explicit prerelease tag requires `--allow-prerelease`, or use
`latest-v3-prerelease` to opt in);
`upgrade --version latest-v3` explicitly opts in. Self-update checks Bash syntax,
V3 channel and numeric version, rejects downgrades and replaces atomically in the
same directory with a backup. It changes no service, configuration or core binary.
The source defaults to this repository main and can be overridden with NOWHERE_V3_SELF_URL.

`--morph-prelude` accepts `fade|full8|low7` (default `full8`; `fade` requires core ≥ v3.0.1 and is refused for v3.0.0; the prelude is a sender-side policy and need not match the peer).

`links` emits native Vector/Egress URLs (no pin when the certificate is system-CA verified, otherwise a leaf pin) and one share per carrier:
`nowhere://KEY@host:port?net=tcp|udp&morph=0|1#NAME`.
Shares omit pin. For self-signed certificates, add the fingerprint command result
to the client trust list. Without an argument `fingerprint` reads the local certificate;
`fingerprint 'nowhere://KEY@HOST:PORT?morph=0|1'` inspects a **remote** certificate over
TCP/TLS (v1.2.0; the link is redacted and `net=udp` links are still inspected over TCP) —
compare it through a trusted channel before using it as a pin. qrencode is installed on
demand (apt/dnf/yum/apk) so QR codes render by default; if unavailable, the manager warns
and prints the links without QR.
Links contain shared keys; keep them private. generate-key and fingerprint are
explicit secret-output exceptions; status, logs and probe are redacted.

Portal probe requires PUBLIC_HOST (or transient --public-host). Persistent PEM
supplies a local pin; tls=1 uses the native core to inspect the local TCP listener.
A UDP-only temporary certificate cannot be verified and links/probe are refused.
Egress cannot initiate probe. Egress itself allows dial*; only Portal out=egress forbids it.
Same-role reconfiguration reuses PEM; explicit --cert/--tls-key rotates it.
Role switches still require confirmation or --allow-role-switch.
Backup, restore, diagnostics and preview (v1.4.0). `restore` validates the
channel, the manifest and the PEM material first, keeps an automatic
before-restore backup, keeps the installed core and rolls back if the restarted
service fails:

```bash
sudo bash nowhere-v3.sh backup /root/nowhere-v3-backup.tar.gz
sudo bash nowhere-v3.sh restore /root/nowhere-v3-backup.tar.gz --dry-run
sudo bash nowhere-v3.sh restore /root/nowhere-v3-backup.tar.gz
sudo bash nowhere-v3.sh diagnostics --output /root/nowhere-v3-diagnostics.json
sudo bash nowhere-v3.sh cert-status                    # certificate + timer + last renewal
sudo bash nowhere-v3.sh cert-timer                     # sync the managed renewal timer
sudo bash nowhere-v3.sh preview --url-file /root/proposed-url.conf
sudo bash nowhere-v3.sh configure --dry-run --endpoint '*:2084'
```

`preview` / `configure --dry-run` print a masked diff (shared key, pin and SOCKS
credentials hidden; role switches require `--allow-role-switch`) and write
nothing. After replacing the manager script, run `cert-timer` once so the fixed
renewal entry picks up the new code.

### 13.4 Files after installation

| Item | Location |
|---|---|
| Manager script | wherever you downloaded it (recommended `/root/nowhere-v3.sh`); `nh` points at it — rerun install/configure/self-update after moving it |
| Shortcut | `/usr/local/bin/nh` (removed by `uninstall --purge`) |
| Current core | `/usr/local/bin/nowhere-v3` → `/opt/nowhere-v3/current/nowhere` |
| Releases | `/opt/nowhere-v3/releases/v3.x.y/` (newest 3 kept by default; `--keep-releases`) |
| Service config | `/etc/nowhere-v3/url.conf` (holds the shared key) |
| Manager metadata | `/etc/nowhere-v3/manager.conf` |
| Certificates/PEM | `/etc/nowhere-v3/tls/pem.XXXXXX/` (only the current one is kept) |
| systemd unit | `/etc/systemd/system/nowhere-v3.service` |
| Launcher | `/usr/local/libexec/nowhere-v3-launch` |
| Service account | `nowhere-v3` (system account, no login) |
| Logs | `journalctl -u nowhere-v3` (`nh logs` to follow) |
| Config backup | `/root/nowhere-v3-backup-YYYYmmdd-HHMMSS.tar.gz` by default (`nh backup`) |
| Build lock | `/run/nowhere-v3-build.lock.d` (prevents concurrent management operations) |

### 13.5 Automatic certificate issuance/renewal (Let's Encrypt, optional)

With a domain you can have the manager issue and renew a Let's Encrypt certificate automatically (no more pin bookkeeping):

```bash
# Interactive: asks for the domain and validation mode; the Cloudflare token input is hidden
sudo bash nowhere-v3.sh cert --domain relay.example.com

# Read the token from a file (keeps it out of shell history)
printf '%s' '<your-CF-API-token>' > /root/cf.token && chmod 600 /root/cf.token
sudo bash nowhere-v3.sh cert --domain relay.example.com --cf-token-file /root/cf.token

# No Cloudflare: HTTP-01 mode (port 80 must be reachable from the internet)
sudo bash nowhere-v3.sh cert --domain relay.example.com --http

# Menu: nh -> 23
```

**Prerequisites**

- DNS-01: the domain is hosted on **Cloudflare** and the token only needs **`Zone.DNS:Edit`** on that zone (**do not use a Global API Key**)
- HTTP-01: port 80 reachable from the internet (any DNS provider); it is used briefly during issuance/renewal

**Creating the Cloudflare API Token (DNS-01, ~5 minutes)**

1. Open the Cloudflare dashboard and go to **API Tokens**:
   👉 https://dash.cloudflare.com/profile/api-tokens (top-right avatar → **My Profile** → **API Tokens**)
2. Click **Create Token**.
3. Pick the **"Edit zone DNS"** template (recommended — its permissions are exactly `Zone → DNS → Edit`), or click **Create Custom Token** and set:
   - **Permissions**: **Zone → DNS → Edit**
   - **Zone Resources**: **Include → Specific zone → your domain** (e.g. `example.com`)
   - Leave Client IP filtering and TTL at their defaults
4. **Continue to summary → Create Token**; the token is shown **once** — copy it immediately (a long alphanumeric string, sometimes starting with `v1.0-`).
5. Store it on the server (out of shell history, restrictive permissions):

   ```bash
   printf '%s' '<paste-the-token>' > /root/cf.token
   chmod 600 /root/cf.token
   ```

6. Use it:

   ```bash
   sudo bash nowhere-v3.sh cert --domain your.example.com --cf-token-file /root/cf.token
   ```

> **Why not a Global API Key**: it controls **every zone in your Cloudflare account**. A scoped API Token can be limited to DNS edits on this one domain, so a leak stays contained — and if you ever suspect one, roll/delete the token on the same page.

**What it does**

1. Installs **pinned acme.sh 3.1.6** and its `dns_cf` plugin from a GitHub release tarball (no `curl | bash`) into `/etc/nowhere-v3/acme` (covered by config backups and transaction rollback; the legacy `/root/.acme.sh` is left untouched)
2. Issues the certificate (DNS-01 or HTTP-01; **explicitly on Let's Encrypt** — acme.sh defaults to ZeroSSL)
3. Stages the files under `/etc/nowhere-v3/tls/le.<domain>/` (`fullchain.pem` / `key.pem`, 640 root:nowhere-v3)
4. Rewrites `url.conf` inside the transaction (a failed re-issue restores the **previous certificate**)
5. Restarts the service and, only after the liveness check passes, creates the **daily renewal timer** `nowhere-v3-cert-renew.timer` (it shares the management flock — contention skips quietly)

**Security notes**

- The token is read via hidden input or `--cf-token-file` only; it reaches acme.sh through the environment and **never appears in process argv** (invisible to `ps`)
- Credentials are kept by acme.sh in `/etc/nowhere-v3/acme/account.conf` (600; the whole directory is created under this manager's umask 077, root-only, and is included in config backups)

**Inspect and troubleshoot**

```bash
sudo bash nowhere-v3.sh cert-status                 # validity, days left, key match, timer, last managed result
sudo bash nowhere-v3.sh cert-timer                  # (re)install the managed timer — run once after replacing the manager script
sudo bash nowhere-v3.sh cert-renew                  # managed renewal now; not due => no restart, held lock => logged skip
systemctl list-timers 'nowhere-v3-cert-renew*'      # next renewal
journalctl -u nowhere-v3-cert-renew                 # renewal logs
sudo bash nowhere-v3.sh cert --domain your.example.com --force   # force reissue
```

**Notes**

- Switching from self-signed to LE **changes the fingerprint**: clients that pinned the old one must update their trust entry; `links` prints the new fingerprint/pin
- **Pin policy for native links**: when the certificate verifies against the system CA for the public host (chain + hostname), `links` emits Vector/Egress URLs **without** `pin=` — nothing to re-import after a renewal; self-signed / private-CA certificates still get a leaf pin; an unreadable certificate refuses to emit a link (fix the file or pass an explicit pin)
- To reissue for another domain just run `cert --domain new.example.com`; the old `le.<old-domain>` directory can be removed by hand
- **Managed renewal**: the daily timer runs `cert-renew`, which renews only the current Portal's managed certificate and clears legacy acme.sh deploy/reload hooks before validating the new one (rollback on failure; "not due" never restarts the service; a held lock is recorded as a skip). `cert-status` shows validity, days remaining, key match, timer state and the last managed result (`/etc/nowhere-v3/renewal-status.json`); a legacy direct-`--cron` timer is flagged and can be migrated with `cert-timer`. Damaged/expired/mismatched certificates and unparseable dates still print the timer state and last managed result but make the command exit non-zero; custom certificates are labeled as not timer-managed and skip timer queries.

## Testing

Logic is covered by sandboxed suites that need no root and no network:

```bash
bash tests/nowhere-v2.test.sh
bash tests/nowhere-v3.test.sh
python3 tests/test_fixes.py .
python3 tests/test_features.py .
python3 tests/test_review.py .
python3 tests/test_core_sync.py .
```

Before sourcing the manager it rewrites its path declarations into a temporary
directory, so the suite can never touch a real `/etc/nowhere-v2` or systemd — and
it aborts if a declaration has been renamed rather than silently falling through
to the real paths. CI runs it on every push together with `bash -n` and
`shellcheck`. `tests/test_fixes.py` holds the targeted offline regressions for
reviewed fix batches (stubbed systemd/ACME); `tests/test_features.py` covers
backup/restore, diagnostics, preview and managed renewal in a sandbox and uses
the pinned `tests/fixtures/acme-3.1.6.tar.gz` offline; `tests/test_review.py`
adds the 16 focused checks from the 1.5.1/1.4.1 batch (atomic backup fallback,
metadata normalization, piped execution, version-parameterized ACME and
certificate-status failures); `tests/test_core_sync.py` covers the pinned core
default, prerelease policy, the opt-in prerelease install path and `fade`
validation order (12 offline checks).
`tests/smoke_native.py` needs official v3.0.1/v3.1.0 binaries for optional
loopback flow checks and is not run in CI. CI runs all of the others.

**Integration is not covered automatically.** The install, upgrade, and systemd
flows have never been executed by the test suite. Run
[`ACCEPTANCE.md`](ACCEPTANCE.md) on a throwaway VPS before relying on a release.

---

## License

[GPL-3.0](LICENSE), matching upstream [NodePassProject/Nowhere](https://github.com/NodePassProject/Nowhere).
