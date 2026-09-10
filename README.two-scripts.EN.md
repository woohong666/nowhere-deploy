# Nowhere One-Click Deployment Scripts (Linux VPS) — EN

> Two scripts, one goal, different trust trade-offs. **Read §0 first to decide which one to use.**
>
> Environment: systemd Linux, x86_64 or aarch64, root or sudo privileges
> Default upstream version: `v1.8.3`

## 0. Which script should you use?

| | `install.sh` | `install-source.sh` |
|---|---|---|
| Binary source | Downloads the official prebuilt Release | **Compiled on this machine** |
| First install | ~1 minute | **20–60 minutes** (on a 1-core VPS) |
| Upgrade | ~1 minute | **20–60 minutes** (recompiles) |
| Integrity check | SHA-256 digest published by the official GitHub API; install is refused if unavailable | Build artifact — no external checksum needed |
| Extra dependencies | `curl` `python3` `tar` `sha256sum` | Also needs `git` and a C compiler (auto-installed), Rust toolchain (auto-installed) |
| Disk | Tens of MB | ≥5 GB during the build |
| Requires trusting | ① the upstream published binary ② crates.io ③ the rustup toolchain | ① the upstream source ② crates.io ③ the rustup toolchain |

**Which to pick:**

- **Just want it running fast** → `install.sh`. This is the right choice for most people — the script itself is still fully readable, it just downloads a binary someone else compiled.
- **Refuse to trust someone else's compiled binary** → `install-source.sh`. Trade 20–60 minutes for artifacts you can trace back to source.
- **Not sure** → start with `install.sh` to get things running; you can switch later at any time (see §10 — the two scripts can take over from each other without touching config or the service).

### 0.1 Trust boundary (read this honestly)

Whichever path you take, the following three layers are **not** resolved — this is the reasonable ceiling of what a single VPS can achieve, not zero-trust:

| Layer | install.sh | install-source.sh |
|---|---|---|
| Backdoor in the one-click script itself | ✅ Resolved (script is readable, no `curl \| bash`) | ✅ Resolved |
| Backdoor planted in the prebuilt binary | ⚠️ Partial (relies on the official digest match; trusts GitHub and the upstream release pipeline) | ✅ Resolved (no binary is ever downloaded) |
| A problem in the upstream **source** itself | ❌ Not resolved | ❌ Not resolved (can be pinned to a commit you've audited via `--commit`) |
| Dependency chain (200+ crates on crates.io) | ❌ Not resolved | ❌ Not resolved (the strongest mitigation is `cargo vendor`, see §9.3) |
| Rust toolchain (the official build distributed by rustup) | ❌ Not applicable | ⚠️ Partially resolved (SHA-256 verified; can be pinned with `--trust-rustup-sha`) |
| Tampering in transit | ✅ HTTPS + digest verification | ✅ git's commit hash is itself content-addressed |

---

## 1. Prerequisites

| Item | Requirement |
|---|---|
| OS | Linux with `systemd` running (confirm with `ps -p 1 -o comm=` returning `systemd`) |
| Architecture | `x86_64` or `aarch64` |
| Privileges | root or sudo |
| Port | The intended port must be ≥1024 and not already in use |
| Network | Must reach github.com (the source build also needs crates.io and static.rust-lang.org) |

Source-build mode additionally requires: ≥1 GB of RAM (the script auto-adds temporary swap below 2 GB) and ≥5 GB free on the partition holding `/var/tmp`.

Rust does not need to be preinstalled for compiling — the script installs it. It needs `git`, `curl`, and a C compiler; if missing, it auto-invokes `apt-get`/`dnf`/`yum`/`apk`/`zypper` (disable with `--no-install-deps`).

### 1.1 Why does the source build need a C compiler?

Nowhere's crypto backend is `ring`. It's a Rust-ecosystem library, but it contains assembly/C code internally that requires a C compiler to build. **Good news**: unlike `aws-lc-rs`, it doesn't also need `cmake`, `nasm`, `perl`, or a system OpenSSL — a `build-essential`-level toolchain is enough.

### 1.2 Why is the compile so slow?

The upstream `Cargo.toml` hard-codes this release profile:

```toml
[profile.release]
lto = "fat"          # whole-program link-time optimization
codegen-units = 1    # disable parallel codegen
panic = "abort"
strip = "symbols"
```

`lto = "fat"` + `codegen-units = 1` gives the best optimization, but is also **the slowest and most memory-hungry** — most of the time is spent in the single-threaded LTO phase. 20–60 minutes on a 1-core machine is normal, not a hang. With under 2 GB of RAM, the link phase is prone to OOM, so the script auto-adds temporary swap.

### 1.3 About libc (`install.sh` only)

`install.sh` automatically decides whether to use the GNU or musl build. If your VPS's glibc is older than what the official GNU build requires, the installed binary won't run (`GLIBC_2.xx not found`). In that case, switch to the static musl build:

```bash
sudo bash install.sh install ... --libc musl
```

---

## 2. Quick Start

### 2.1 Copy the script to the VPS

From your Mac:

```bash
scp ~/nowhere-deploy/install.sh <vps-user>@<vps-address>:/tmp/install.sh
```

After logging in, do a syntax check first (this performs no installation actions):

```bash
ssh <vps-user>@<vps-address>
chmod 700 /tmp/install.sh
bash -n /tmp/install.sh          # syntax check only
```

### 2.2 Required step before using TLS 2 (PEM certificate)

Let's Encrypt's private key defaults to `600 root:root`, with the parent directory at `700` — the service user `nowhere` cannot read it. **Do not** loosen the original certificate's permissions; instead, copy it:

```bash
sudo bash /tmp/install.sh prepare-tls \
  --cert /etc/letsencrypt/live/<your-domain>/fullchain.pem \
  --tls-key /etc/letsencrypt/live/<your-domain>/privkey.pem
```

This creates the `nowhere` user/group, copies the certificate to `/etc/nowhere/tls/` (`640 root:nowhere`), and prints the paths to use next. **Re-run this every time the certificate renews**, or add it to certbot's deploy hook.

> Just want to get it running without dealing with certificates yet? Replace `--tls 2 --cert ... --tls-key ...` below with `--tls 1` — clients will accept a temporary self-signed certificate. Don't use this in production.

### 2.3 Install

```bash
sudo bash /tmp/install.sh install \
  --key '<a shared key at least 16 characters long>' \
  --port 2077 \
  --net mix \
  --tls 2 \
  --cert /etc/nowhere/tls/fullchain.pem \
  --tls-key /etc/nowhere/tls/privkey.pem
```

Once done, the script prints the `portal://` link the client needs (it contains the key — don't leak it).

**For the source-build version, just swap the script name for `install-source.sh`; everything else is identical.** Compiling takes about half an hour, so run it inside `tmux` to avoid losing progress to an SSH disconnect:

```bash
tmux new -s nowhere
sudo bash /tmp/install-source.sh install --key '...' --port 2077 --tls 1
# Detach with Ctrl+B then D; reattach anytime with tmux attach -t nowhere
```

### 2.4 What happens if the compile fails?

There is no dry-run mode. On failure the script simply exits: it **will not** write config, **will not** create the systemd service, and **will not** touch the `current` symlink (on an upgrade, it automatically reverts to the previous version).

The only leftovers are the `nowhere` system user and the `/var/tmp/nowhere-build` build tree. Clear it with `install-source.sh clean-build`, or keep it with `--keep-source` — re-running the same version will reuse the cargo cache and be much faster than the first run.

---

## 3. Parameter Reference

### 3.1 Shared by both scripts (service-related)

| Parameter | Default | Description |
|---|---|---|
| `--key KEY` | none (required on first install) | Portal shared key, 16–255 characters, only `A-Za-z0-9._~-` allowed |
| `--port PORT` | `2077` | Listening port, must be ≥1024 (service runs as a non-root user) |
| `--net MODE` | `mix` | `mix` / `tcp` / `udp`; `mix` means TCP and UDP share the same port |
| `--tls MODE` | `2` | `1` = temporary self-signed cert (fingerprint changes on restart), `2` = use a PEM file |
| `--cert PATH` | none | Required with `--tls 2`; the certificate chain (`fullchain.pem`) |
| `--tls-key PATH` | none | Required with `--tls 2`; the private key (`privkey.pem`) |
| `--listen-host HOST` | empty | Bind address; leave empty to use Nowhere's wildcard default |
| `--purge` | — | On uninstall, also removes `/etc/nowhere` and `/var/lib/nowhere` |

### 3.2 `install.sh` only (downloads a binary)

| Parameter | Default | Description |
|---|---|---|
| `--version TAG` | `v1.8.3` | The official Release tag to install |
| `--libc MODE` | `auto` | `gnu` / `musl` / `auto`; use `musl` when glibc is too old |

### 3.3 `install-source.sh` only (compiles)

| Parameter | Default | Description |
|---|---|---|
| `--version TAG` | `v1.8.3` | The git tag to build |
| `--commit SHA` | none | Pin to a specific commit (full clone, slower but reproducible); mutually exclusive with `--version` |
| `--git-url URL` | official repo | Point to your own fork or mirror |
| `--jobs N` | cargo default | Limit parallel build jobs; set to `1` on low-memory VPS |
| `--swap auto\|off\|MB` | `auto` | `auto`: 2 GB swap if RAM <2 GB, 4 GB if RAM <1 GB; or specify a size in MB |
| `--keep-source` | off | Keep `/var/tmp/nowhere-build` after a successful build (enables incremental builds on the next upgrade) |
| `--no-install-deps` | — | Don't auto-install system dependencies; error out on anything missing |
| `--no-install-rust` | — | Don't auto-install Rust; error out if the version isn't sufficient |
| `--trust-rustup-sha HEX` | none | Require rustup-init's SHA-256 to equal this value |

---

## 4. What the scripts actually do

1. Validate the version, port, key, and certificate paths — completing all cheap checks **before** any download/compile begins;
2. Check whether the port is already in use (first install only);
3. Check whether the certificate is readable by the service user; if not, error out with instructions for `prepare-tls`;
4. `install.sh`: requests the SHA-256 digest for the asset from the GitHub API, downloads it, and compares — aborting on mismatch. `install-source.sh`: verifies and (if needed) installs the Rust toolchain, adds temporary swap if needed, pulls the source, prints the commit, and compiles;
5. Installs the binary to `/opt/nowhere/releases/<tag>/nowhere`, writes a provenance file, and switches the `/opt/nowhere/current` symlink;
6. On first install, writes `/etc/nowhere/nowhere.env` (`600`, owned by root), creates the systemd service, and starts it;
7. If the service fails to start: on a first install, the script errors out and prints the logs; on an upgrade, it automatically reverts to the previous version.

### 4.1 File layout after installation

```text
/opt/nowhere/releases/v1.8.3/nowhere        binary
/opt/nowhere/releases/v1.8.3/BUILD-INFO     provenance info (source build)
/opt/nowhere/releases/v1.8.3/RELEASE-INFO   provenance info (binary build)
/opt/nowhere/current -> /opt/nowhere/releases/v1.8.3
/usr/local/bin/nowhere -> /opt/nowhere/current/nowhere
/etc/nowhere/nowhere.env                    config (600, contains the portal:// link and key)
/etc/nowhere/tls/                           certificate copied by prepare-tls (640 root:nowhere)
/etc/systemd/system/nowhere.service         service unit (includes systemd sandbox hardening)
/var/lib/nowhere/                           service state directory
```

The provenance file answers "what exactly is running right now." For a source build it looks like this:

```text
repository:   https://github.com/NodePassProject/Nowhere.git
tag:          v1.8.3
commit:       1a2b3c...
built_at:     2026-09-10T05:12:33Z
toolchain:    rustc 1.89.0 (29483883e 2025-08-01)
binary_sha256: 9f8e...
```

For a prebuilt binary it looks like this:

```text
repository:   https://github.com/NodePassProject/Nowhere
tag:          v1.8.3
asset:        nowhere-x86_64-unknown-linux-gnu.tar.gz
source:       official prebuilt Release (not compiled locally)
asset_sha256: <digest published by the GitHub API>
binary_sha256: <actual checksum of the unpacked binary>
```

### 4.2 systemd sandbox

The service runs as the system user `nowhere` (no login shell). The unit file enables hardening options including `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`, and `CapabilityBoundingSet=` (empties all capabilities), and restricts the listening port to above 1024 so the service never needs root capabilities.

---

## 5. Client Connection

After installation the script prints the link; you can also retrieve it again at any time (both scripts support this):

```bash
sudo bash /tmp/install.sh link
```

Link format (with `--tls 2`):

```text
portal://<shared-key>@<domain-or-ip>:<port>?tls=2&crt=<url-encoded-cert-path>&key=<url-encoded-key-path>
```

When `--net` is not `mix`, an extra `&net=tcp` or `&net=udp` is appended.

Import this link into your client. **It's equivalent to a password**: if the shared key inside the `portal://` link leaks, anyone can use your node. Don't commit it to Git or paste it into chat logs.

---

## 6. Firewall Rules

Both the cloud provider's security group and the system firewall must allow the port (with `--net mix`, both TCP and UDP):

```bash
# UFW
sudo ufw allow 2077/tcp
sudo ufw allow 2077/udp
sudo ufw status numbered

# firewalld
sudo firewall-cmd --permanent --add-port=2077/tcp
sudo firewall-cmd --permanent --add-port=2077/udp
sudo firewall-cmd --reload
```

Confirm it's listening:

```bash
sudo ss -lntup | grep ':2077'
sudo systemctl is-active nowhere
```

---

## 7. Day-to-Day Operations

```bash
sudo bash /tmp/install.sh status     # service status + current release directory
sudo bash /tmp/install.sh logs       # tail logs (Ctrl+C to exit)
sudo bash /tmp/install.sh restart
sudo bash /tmp/install.sh link       # print the client link

readlink /opt/nowhere/current                     # which version is currently running
cat /opt/nowhere/current/BUILD-INFO               # provenance info (source build)
sudo journalctl -u nowhere -n 100 --no-pager      # recent logs
```

Both scripts are **stateless**: every run determines what to do from the actual state on disk. If the copy in `/tmp` gets lost, it doesn't matter — just copy it over again (it's a good idea to keep it, along with the docs, under `/root/` or your own Git repo).

---

## 8. Upgrade, Rollback & Recompiling

### 8.1 Upgrade

```bash
# Check the latest upstream tag first: https://github.com/NodePassProject/Nowhere/releases
sudo bash /tmp/install.sh upgrade --version v1.9.0
```

An upgrade re-downloads (or recompiles), switches the symlink, and restarts the service, **leaving `/etc/nowhere/nowhere.env` unchanged**. An upgrade does not change config: `--port`, `--key`, `--tls`, `--cert` and similar parameters **have no effect** during an upgrade.

Recommended before upgrading:

```bash
sudo cp -a /etc/nowhere /etc/nowhere.backup.$(date +%F-%H%M%S)
readlink /opt/nowhere/current        # note the old version, needed for rollback
```

### 8.2 Rollback

```bash
sudo bash /tmp/install.sh rollback
```

A rollback simply repoints the `current` symlink to the previous release directory and restarts the service — **no re-download or recompile**, completes instantly. This requires that the old version's directory still exists — the script never deletes old version directories on its own. If you've manually deleted a directory under `/opt/nowhere/releases/`, that rollback target is gone.

### 8.3 Changing config (port / certificate / key)

The script deliberately does not allow config changes during an upgrade, to avoid the "I thought I changed it but I didn't" trap. To change config, edit it directly and restart:

```bash
sudo cp /etc/nowhere/nowhere.env /etc/nowhere/nowhere.env.bak
sudo vi /etc/nowhere/nowhere.env     # edit NOWHERE_PORTAL
sudo systemctl restart nowhere
sudo systemctl is-active nowhere
```

`NOWHERE_PORTAL`'s value is the `portal://` link itself. After changing the port, remember to also open the new port in your firewall.

### 8.4 Recompiling the current version (source build only)

To verify "what I compiled locally matches what's currently running," or if you suspect the binary was tampered with:

```bash
sudo bash /tmp/install-source.sh upgrade --version v1.8.3 --keep-source
cat /opt/nowhere/releases/v1.8.3/BUILD-INFO    # compare binary_sha256
```

### 8.5 Cleaning the build cache (source build only)

```bash
sudo bash /tmp/install-source.sh clean-build     # removes /var/tmp/nowhere-build and any leftover swapfile
```

By default, the script cleans up the build tree (roughly 2–4 GB) after a successful compile on its own; it's only kept with `--keep-source`, at the cost of disk space but with the benefit of much faster incremental builds on the next upgrade.

---

## 9. Security Notes

### 9.1 During installation

- Both scripts run as root; all downloads go over HTTPS;
- `install.sh` **refuses to install** if digests are missing or don't match, and never executes any downloaded network content after unpacking it;
- `install-source.sh` compiles inside `/var/tmp/nowhere-build`, with the source directory at permission 700; rustup-init verifies its SHA-256;
- The config file is `600`, owned by root — the service user can only read its environment variables via systemd.

### 9.2 At runtime

- The service runs as the `nowhere` user: no shell, no capabilities, `ProtectSystem=strict`;
- The binary lives in `/opt/nowhere`, which normal users cannot write to; the symlink is controlled by root only.

### 9.3 For stronger reproducibility

```bash
# 1) Pin to a commit you've audited
sudo bash /tmp/install-source.sh upgrade --commit <40-char SHA>

# 2) Pin rustup's fingerprint (obtain it from a trusted channel first)
sudo bash /tmp/install-source.sh install ... --trust-rustup-sha <rustup-init's SHA256>
```

`--locked` only guarantees that **dependency versions** are determined by the repo's `Cargo.lock` — the dependency packages themselves are still downloaded from crates.io. For a build that's fully independent of network distribution, run `cargo vendor` on your build machine to bundle the dependency tree into the repo, then build with `--offline`. This is a stronger but heavier approach — take it on when you actually need it.

---

## 10. How the Two Scripts Relate

**They can take over from each other.** Both scripts use exactly the same paths, config file, and systemd service name:

```text
/opt/nowhere/current          /etc/nowhere/nowhere.env
/etc/systemd/system/nowhere.service
```

So migrating between them is just running `upgrade` — config and service don't need to be touched:

```bash
# Binary → source (start compiling it yourself)
sudo bash /tmp/install-source.sh upgrade --version v1.8.3

# Source → binary (stop waiting on compiles)
sudo bash /tmp/install.sh upgrade --version v1.8.3
```

Two things to note:

1. `upgrade` **overwrites the release directory for the same tag** (`/opt/nowhere/releases/<tag>/`), so after migrating, `BUILD-INFO` becomes `RELEASE-INFO` (or vice versa) — the two don't coexist;
2. To keep the old one, run `readlink /opt/nowhere/current` before migrating to note the path, or copy the old directory elsewhere first.

---

## 11. Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `Install a C compiler` / compile aborts | Source build: missing toolchain; re-run without `--no-install-deps` |
| `rustc ... is older than 1.85.0` | Source build: system rustc too old — the script auto-installs a newer toolchain; with `--no-install-rust` you must install it yourself |
| `signal: 9` / `Killed` mid-compile | Source build: out of memory, LTO phase killed by the OOM killer. Retry with `--swap 4096` or `--jobs 1`; keeping the source tree allows an incremental resume |
| Compile seems stuck for a long time | Normal — this is the single-threaded link phase from `lto="fat"` + `codegen-units=1`. Check `top` to confirm rustc/cc is still consuming CPU |
| `GitHub did not publish a SHA-256 digest` | Binary build: the official pipeline didn't publish a digest for this asset, so the script refuses to install. Don't bypass this — switch to the source build |
| `SHA-256 mismatch` | Binary build: the downloaded content doesn't match the official digest. **Don't skip the check** — retry over a different network; if it persists, be wary |
| `GLIBC_2.xx not found` | Binary build: the official GNU build needs a newer glibc. Add `--libc musl` for a static build |
| `Could not download rustup-init` | Source build: can't reach static.rust-lang.org; switch networks, or install Rust manually and add `--no-install-rust` |
| `git clone failed` | Source build: can't reach github.com; point at your own mirror/fork with `--git-url` (note this shifts trust to the mirror maintainer) |
| `Need ~...MB free on /` | Source build: insufficient disk — clean up and retry, or run `clean-build` first |
| `Port 2077 is already in use` | Change the port, or stop the conflicting service |
| `Service user nowhere cannot read certificate` | Private key permission issue. Use `prepare-tls --cert ... --tls-key ...` to copy it — **do not** `chmod 644` the private key |
| Service won't start | Check `journalctl -u nowhere -n 100 --no-pager`; common causes are the certificate path, a port conflict, or a malformed URI |
| Can't connect from outside | Check in order: is the service active → is `ss -lntup` listening → system firewall → cloud security group → DNS |
| Client errors after certificate renewal | Re-run `prepare-tls`, then `systemctl restart nowhere`; this can go into certbot's deploy hook, but verify it manually in a maintenance window first |

---

## 12. Uninstall

```bash
# Remove only the service and binary, keep config and state
sudo bash /tmp/install.sh uninstall

# Remove config and keys too (irreversible — back up first)
sudo bash /tmp/install.sh uninstall --purge
```

Uninstall behavior is identical for both scripts. `--purge` also deletes `/etc/nowhere` (including the `portal://` link) and `/var/lib/nowhere`.

---

## 13. Change Log Template

```text
Date:
VPS / node domain:
Action: first install / upgrade / rollback / config change / recompile / script switch
Script and version used:
Target version and commit:
Port and network mode:
TLS mode and certificate paths:
Command executed:
Compile time / peak memory:
Service state before:
Service state after:
binary_sha256:
Issues encountered and resolution:
Next steps:
```
