# Nowhere One-Click Deployment & Management Scripts (Linux VPS)

[English](README.md) | [简体中文](README.zh-CN.md)

Production-grade one-click deployment and operations scripts built on the official [NodePassProject/Nowhere](https://github.com/NodePassProject/Nowhere) core protocol.

> **✅ Primary channel: V2** — `nowhere-v2.sh`, targeting Nowhere `v2.x`. **Use this for new deployments.**
> It follows the newest official stable release by default (`latest-v2`, resolved to the latest `v2.x.y` at install time); pin an exact tag with `--version v2.x.y` when you need reproducibility.
> It uses its own paths and service (`/opt/nowhere-v2`, `/etc/nowhere-v2`, `nowhere-v2.service`) and never touches a V1 install.
> The `v2.x` line is current and fully supported: the newest official v2 release is **v2.2.1**. The upstream project has also shipped **v3.0.0 (NW3)**, which is wire-incompatible with NW2 — the V2 manager refuses `v3.x` tags on purpose.
>
> **🆕 V3 channel (NW3):** `nowhere-v3.sh` is a dedicated manager for Nowhere `v3.x` — Portal / Vector / **Egress** roles, `in=` ingress, `out=egress` remote exits, 32-hex keys, Morph on by default. It uses its own paths and service (`/opt/nowhere-v3`, `/etc/nowhere-v3`, `nowhere-v3.service`, ports 2083/1083) and never touches V2. See [§13](#13-v3-channel-nw3).
>
> **🔒 V1 stable channel:** `nowhere-v1.sh`, pinned to Nowhere `v1.8.3`. It does not follow `latest` and does not install V2.
> Intended only for existing V1 nodes or when you need the Russian interface. See [§12](#12-v1-stable-channel-deployment-only).

The V2 manager combines strict SHA-256 verification of official release binaries, fully-optimized local Rust source compilation (Fat-LTO), a hardened systemd sandbox, TLS certificate permission isolation, and a bilingual (Chinese / English) colour terminal console.

---

## Table of Contents

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

---

## 0. Which Script Should I Use?

This repository contains four scripts. **V2 is the recommended default:**

| Script | Channel | Purpose |
|---|---|---|
| **`nowhere-v2.sh`** | **V2 (primary)** | **Recommended.** Nowhere v2.x with a full TUI menu: release install / source build / configure / doctor / rollback / backup |
| `nowhere-v1.sh` | V1 stable | Pinned to `v1.8.3`, does not follow `latest`. For existing V1 nodes or the Russian interface |
| `install.sh` | V1 | Automation / CI only, V1 prebuilt binary |
| `install-source.sh` | V1 | Automation / CI only, V1 source build |
| **`nowhere-v3.sh`** | **V3 (NW3)** | Nowhere v3.x: Portal / Vector / Egress; fixed default `v3.0.0`, `latest-v3` opt-in |

**How to choose:**

- **New deployment / want V2 features** → `nowhere-v2.sh` ([§3](#3-quick-start-v2)).
- **New V3 deployment or a remote Egress exit** → `nowhere-v3.sh` ([§13](#13-v3-channel-nw3)); V2 and V3 are fully isolated and can run side by side.
- **Existing V1 node to maintain** → `nowhere-v1.sh` ([§12](#12-v1-stable-channel-deployment-only)).
- **Want both side by side** → install each on different ports; they are fully isolated.

> **⚠️ Wire protocol warning:** V1 and V2 nodes are **not interoperable**. Every node on the same traffic path must run the same major version.
> Do not point a V1 Portal / Vector / native-next client at a V2 service, or vice versa.
>
> Also note: **Morph changed its wire format in Nowhere 2.1.0.** Morph-enabled 2.1 peers cannot talk to 2.0.x peers, so every peer on a `morph=1` path must be upgraded to `>=2.1.0` together. The manager warns when an upgrade crosses that boundary.
>
> **Nowhere 2.2.0 admission changes:** Portal listener and native `next` keys must be **32-64 lowercase hex characters** (`nowhere generate-key` prints 32; the manager generates 64). Native clients (Vector, `probe`, chained Portal `next`) now **always verify the peer certificate** against the system CA and the endpoint hostname — `pin=none` no longer disables verification. A self-signed (`tls=1`) Portal therefore requires `pin=<sha256>`, and generated certificates change on every restart, so prefer `tls=2` in production. The manager generates/validates keys accordingly, auto-pins `links`, and warns when an upgrade crosses the 2.1.1 / 2.2.0 boundaries.
>
> **NW3 is a different protocol:** Nowhere **v3.0.0** introduced NW3 (`nw3` ALPN, remote Egress role, `egress://`). It is wire-incompatible with NW2, and there is no protocol negotiation or fallback. This manager targets the **v2.x line only**; `latest-v2` keeps resolving to the newest stable v2 release (currently `v2.2.1`).

---

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

### 8.3 Backing up config and certificates

```bash
# Defaults to /root/nowhere-v2-backup-<timestamp>.tar.gz
sudo bash nowhere-v2.sh backup

# Or choose the output path
sudo bash nowhere-v2.sh backup /root/my-backup.tar.gz
```

The archive contains `/etc/nowhere-v2` (runtime config, manager metadata, TLS material), not the binary.

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
| `backup [PATH]` | Back up config and certificates |
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

---

## 13. V3 Channel (NW3)

> `nowhere-v3.sh` is a **separate manager** for the Nowhere **v3.x** line. It is fully isolated from V2 (own service, account, paths, ports) and never converts or touches a V2 install. NW3 is wire-incompatible with NW2, with no negotiation or fallback.

### 13.1 Quick start

```bash
# Download
wget https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v3.sh -O nowhere-v3.sh
chmod 700 nowhere-v3.sh && bash -n nowhere-v3.sh

# New Portal (fixed default core v3.0.0). Without --cert/--tls-key the manager
# generates a persistent self-signed PEM, so the client pin stays stable.
sudo bash nowhere-v3.sh install --version v3.0.0 --public-host relay.example.com

# Or bring your own certificate
sudo bash nowhere-v3.sh install --public-host relay.example.com \
  --cert /etc/letsencrypt/live/relay.example.com/fullchain.pem \
  --tls-key /etc/letsencrypt/live/relay.example.com/privkey.pem

sudo bash nowhere-v3.sh doctor
sudo bash nowhere-v3.sh links        # Vector (+ Egress) URLs, always carrying the pin
sudo bash nowhere-v3.sh telemetry    # read-only status (NW3 removed the TUI)
```

- **Vector**: save the printed `vector://` URL into a `600` file and run `sudo bash nowhere-v3.sh install --url-file /root/vector-v3.url` (SOCKS5 on `127.0.0.1:1083`).
- **Egress** (a remote exit behind an outbound QUIC connection): install the Portal with `--out egress`, move the printed `egress://` URL to the exit host, and `install --url-file` it there. A Portal accepts one registered Egress and does not fall back to direct access while it is offline.
- **Tracking v3.x**: the default is pinned to the verified `v3.0.0`; `upgrade --version latest-v3` opts in to newer stable v3 releases.

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

### 13.3 v1.1.0 daily operations

No arguments opens a looping 22-action menu. Portal, Vector and Egress have
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
means fewer than ten results, never invented tags. The default stays v3.0.0;
`upgrade --version latest-v3` explicitly opts in. Self-update checks Bash syntax,
V3 channel and numeric version, rejects downgrades and replaces atomically in the
same directory with a backup. It changes no service, configuration or core binary.
The source defaults to this repository main and can be overridden with NOWHERE_V3_SELF_URL.

`links` emits pinned native Vector/Egress URLs and one share per carrier:
`nowhere://KEY@host:port?net=tcp|udp&morph=0|1#NAME`.
Shares omit pin. For self-signed certificates, add the fingerprint command result
to the client trust list. Without an argument `fingerprint` reads the local certificate;
`fingerprint 'nowhere://KEY@HOST:PORT?morph=0|1'` inspects a **remote** certificate over
TCP/TLS (v1.2.0; the link is redacted and `net=udp` links are still inspected over TCP) —
compare it through a trusted channel before using it as a pin. Optional qrencode renders
QR codes; absence is silent.
Links contain shared keys; keep them private. generate-key and fingerprint are
explicit secret-output exceptions; status, logs and probe are redacted.

Portal probe requires PUBLIC_HOST (or transient --public-host). Persistent PEM
supplies a local pin; tls=1 uses the native core to inspect the local TCP listener.
A UDP-only temporary certificate cannot be verified and links/probe are refused.
Egress cannot initiate probe. Egress itself allows dial*; only Portal out=egress forbids it.
Same-role reconfiguration reuses PEM; explicit --cert/--tls-key rotates it.
Role switches still require confirmation or --allow-role-switch.
Optional `backup --restore` is not implemented in this release.

## Testing

Logic is covered by sandboxed suites that need no root and no network:

```bash
bash tests/nowhere-v2.test.sh
bash tests/nowhere-v3.test.sh
```

Before sourcing the manager it rewrites its path declarations into a temporary
directory, so the suite can never touch a real `/etc/nowhere-v2` or systemd — and
it aborts if a declaration has been renamed rather than silently falling through
to the real paths. CI runs it on every push together with `bash -n` and
`shellcheck`.

**Integration is not covered automatically.** The install, upgrade, and systemd
flows have never been executed by the test suite. Run
[`ACCEPTANCE.md`](ACCEPTANCE.md) on a throwaway VPS before relying on a release.

---

## License

[GPL-3.0](LICENSE), matching upstream [NodePassProject/Nowhere](https://github.com/NodePassProject/Nowhere).
