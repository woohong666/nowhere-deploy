# Nowhere 一键部署与综合管理脚本（Linux VPS）

[English](README.md) | [简体中文](README.zh-CN.md)

基于 [NodePassProject/Nowhere](https://github.com/NodePassProject/Nowhere) 官方核心协议编写的生产级一键部署与运维管理脚本。

> **⭐ 主力通道：V3（NW3）** —— `nowhere-v3.sh`，面向 Nowhere `v3.x`。**新部署一律用它。**
> Portal / Vector / Egress 三种角色、`in=` 入口、`out=egress` 远程出口、32 位 hex 密钥、Morph 默认开启；并自带加固：安装 SHA-256 零信任校验、事务化配置（失败自动回滚）、`doctor` 体检、备份 / 秒级回滚、**远端证书指纹**、**Let's Encrypt 自动签发 + 每日自动续期**、`nh` 快捷菜单（数字选项 / y-n / 二维码）。
> 使用独立路径与服务（`/opt/nowhere-v3`、`/etc/nowhere-v3`、`nowhere-v3.service`、端口 2083/1083），不会触碰 V1/V2。完整文档见 [§13](#13-v3-通道nw3)。
>
> **V2 通道（维护模式）：** `nowhere-v2.sh`，面向 Nowhere `v2.x`（官方最新 v2 正式版 **v2.2.1**）——**仅用于维护既有 NW2 部署**（例如客户端还停留在 Anywhere ≤2.3）。完整 TUI / 源码编译等能力保留在下方折叠区（[§3](#3-快速开始v2) 起）。
>
> **🔒 V1 稳定通道（维护模式）：** `nowhere-v1.sh`，固定 Nowhere `v1.8.3`，不跟随 `latest`，也不支持 V2。仅用于已有 V1 节点或需要俄文界面的场景，部署方式见 [§12](#12-v1-稳定通道仅部署)。

V3 管理器融合官方 Release 二进制 SHA-256 强校验、事务化安装 / 配置（失败自动回滚）、`doctor` 体检、配置备份与秒级回滚、Let's Encrypt 证书自动签发与续期、`nh` 快捷菜单（数字选项 / y-n 缩写 / 二维码分享链接 / 远端指纹核对），以及中英双语文档与沙箱测试套件。V2 的源码编译、TUI 等能力保留在其维护区文档中。

---

## 目录

<details>
<summary>点击展开目录（⭐ 主力为 §13 V3；V1 / V2 为维护文档，已折叠）</summary>

- [0. 我该用哪个脚本](#0-我该用哪个脚本)
- [1. 安装模式对比（Release / Source）](#1-安装模式对比release--source)
- [2. 前置环境与准备工作](#2-前置环境与准备工作)
- [3. 快速开始（V2）](#3-快速开始v2)
  - [3.0 下载、检查并运行](#30-下载检查并运行)
  - [3.1 交互菜单模式（推荐）](#31-交互菜单模式推荐)
  - [3.2 命令行无交互部署（自动化 / 脚本）](#32-命令行无交互部署自动化--脚本)
- [4. TLS 证书配置与权限安全处理](#4-tls-证书配置与权限安全处理)
- [5. 防火墙与网络放行](#5-防火墙与网络放行)
- [6. 客户端连接与导入](#6-客户端连接与导入)
- [7. 日常运维与服务管理](#7-日常运维与服务管理)
- [8. 版本升级、无损回滚、备份与卸载](#8-版本升级无损回滚备份与卸载)
- [9. 完整 CLI 命令参数速查表](#9-完整-cli-命令参数速查表)
- [10. 文件结构与安全沙箱布局](#10-文件结构与安全沙箱布局)
- [11. 常见问题排查（FAQ）](#11-常见问题排查faq)
- [12. V1 稳定通道（仅部署）](#12-v1-稳定通道仅部署)
- [13. V3 通道（NW3）](#13-v3-通道nw3)

</details>

---

## 0. 我该用哪个脚本

**新部署一律用 `nowhere-v3.sh`（NW3 主力通道）**；V2 只用于维护既有 NW2 部署，V1 只用于维护老的 V1 节点。

| 脚本 | 协议线 | 用途 |
|---|---|---|
| **`nowhere-v3.sh`** | **NW3（v3.x）** | ⭐ **主力**：新部署与日常管理（`nh` 快捷菜单），见 [§13](#13-v3-通道nw3) |
| `nowhere-v2.sh` | NW2（v2.2.1 LTS） | 维护既有 V2 部署；完整 TUI / 源码编译等文档在下方折叠区（[§3](#3-快速开始v2) 起） |
| `nowhere-v1.sh` | V1（固定 v1.8.3） | 仅维护老 V1 节点 / 俄文界面，见 [§12](#12-v1-稳定通道仅部署) |
| `install.sh` / `install-source.sh` | V1 | 自动化 / CI 专用（V1） |

### V3 的特点与优势

- **协议现代**：NW3 = TLS 1.3（固定 `nw3` ALPN）+ 可选 QUIC 载体；认证绑定 TLS exporter；共享密钥恰好 32 位 hex；Morph 默认开启、两端必须一致
- **三种角色**：Portal（监听）、Vector（本地 SOCKS5 入口）、**Egress**（远程出口——主动出站 QUIC 回连，**出口机无需开放任何入站端口**）
- **证书全自动**：Let's Encrypt 一键签发 + **每日自动续期**（Cloudflare DNS-01 或 HTTP-01），切换证书走事务、失败自动回滚，见 §13.5
- **管理体验**：`nh` 快捷菜单（23 项、编号选择、y/n 缩写）、客户端链接 + **二维码**、证书指纹（本机 / **远端**核对）
- **运维安全**：零信任安装（无 SHA-256 摘要拒装）、事务化配置、`doctor` 体检、配置备份 / 秒级回滚、flock 防并发
- **质量保证**：完整沙箱测试套件 + GitHub CI 回归；中英双语文档与验收清单

### 三分钟部署（V3）

```bash
cd /root
wget https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v3.sh -O nowhere-v3.sh
chmod 700 nowhere-v3.sh
sudo bash nowhere-v3.sh      # 菜单 → 输入 1 装 Portal（向导；每步回车=默认）
# 装完：nh（快捷菜单）· sudo bash nowhere-v3.sh links（链接 + 二维码）
```

> **协议兼容（必读）**：NW2 / NW3 **不互通**、无协商无回落——Anywhere 客户端 **2.3 及以下只有 NW2，2.4 起只有 NW3**（见 [FAQ Q8](#11-常见问题排查faq)）；V1 与 V2 同样不互通。同一条链路的所有节点必须处于同一协议线。
>
> **V2 维护提示**：Nowhere 2.2.0 起密钥必须为 32-64 位小写 hex、native 客户端强制验证证书（自签需 `pin=`）；Morph 在 2.1.0 有破坏性变更。细节见下方折叠区的 V2 文档。

---

<details>
<summary><b>V1 / V2 完整文档（维护既有部署用；新部署请用上方 V3 流程 → §13）——点击展开</b></summary>

## 1. 安装模式对比（Release / Source）

两种安装模式配置与服务接口完全统一，可随时互相平滑接管：

| 评估维度 | 官方预编译二进制版（Release） | 本地源码编译版（Source） |
|---|---|---|
| **获取方式** | 下载 GitHub 官方打包发布的静态二进制 | **本机直接克隆 Git 源码实时编译** |
| **部署耗时** | 约 1 分钟 | 20–60 分钟（1-2 核 VPS 构建较久） |
| **完整性校验** | 强制查询 GitHub API 比对 SHA-256 Digest，无校验则拒绝安装 | 编译产物全部由本机编译器生成，无需额外摘要 |
| **性能表现** | 官方常规发布级编译优化 | 自动启用 `lto = "fat"` + `codegen-units = 1` 极限优化 |
| **额外依赖** | `curl` `python3` `tar` `sha256sum` | 自动安装 `git`、C 编译器与 Rust 工具链 |
| **内存与磁盘** | 内存无要求，磁盘占用几十 MB | 编译期需 ≥5 GB 临时空间，内存不足自动挂载 Swap |
| **适用场景** | 追求省时、快速上手测试与主力使用 | 追求 100% 审计级别、拒绝使用第三方二进制的极客场景 |

---

## 2. 前置环境与准备工作

| 检查项 | 要求说明 |
|---|---|
| **操作系统** | 主流 Linux 发行版（Debian 11+、Ubuntu 20.04+、CentOS 8+、Rocky / AlmaLinux、Arch 等） |
| **初始化系统** | 正在运行的 `systemd`（通过 `ps -p 1 -o comm=` 确认返回 `systemd`） |
| **系统架构** | `x86_64` (amd64) 或 `aarch64` (arm64) |
| **执行权限** | `root` 账户或拥有完整的 `sudo` 授权 |
| **端口要求** | 预备监听端口建议在 `1024-65535` 之间（服务以安全非特权用户运行） |
| **网络环境** | VPS 需能访问 `github.com`（源码编译还需 `static.rust-lang.org` 与 `crates.io`） |

---

## 3. 快速开始（V2）

### 3.0 下载、检查并运行

```bash
# 下载 V2 管理脚本
wget https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v2.sh -O nowhere-v2.sh

# 赋予执行权限
chmod 700 nowhere-v2.sh

# 先做语法检查（可选，但推荐）
bash -n nowhere-v2.sh

# 以 root 权限运行
sudo bash nowhere-v2.sh
```

> 💡 **已直接用 root 登录的机器（很多 VPS 精简系统没装 `sudo`）**：把命令开头的 `sudo` 去掉直接运行即可（如 `bash nowhere-v2.sh links`）——root 下两者效果相同；出现 `sudo: command not found` 就是这个原因。

也可一行完成（适用于可信来源）：

```bash
curl -fsSL https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v2.sh -o nowhere-v2.sh && chmod 700 nowhere-v2.sh && bash -n nowhere-v2.sh && sudo bash nowhere-v2.sh
```

### 3.1 交互菜单模式（推荐）

直接运行 `sudo bash nowhere-v2.sh`，选择语言（中文 / English）后进入菜单：

```
 [1] 安装/重装官方 V2 预编译版        [10] 回滚 V2 二进制版本
 [2] 从源码编译安装 V2                [11] 健康检查 / Doctor
 [3] 修改 / 导入 V2 配置              [12] 健康检查并自动修复 / Doctor --fix
 [4] 查看运行状态                     [13] 清理旧的 V2 Release
 [5] 显示 V2 连接链接                 [14] 清理 V2 编译缓存
 [6] 查看实时日志                     [15] 检查最新稳定 V2 版本
 [7] 重启 V2 服务                     [16] 查看 V1 -> V2 兼容性说明
 [8] 打开 V2 TUI 监控                 [17] 仅卸载 V2
 [9] 查看 TLS SHA-256 指纹            [18] 更新 V2 管理脚本
 [0] 退出
```

安装时会依次询问：节点角色（portal / vector）、共享密钥、监听端点、TLS 模式、是否开启 Morph 等。

> **提示**：源码编译建议在 `tmux` 或 `screen` 中运行，避免 SSH 断线中断编译：
>
> ```bash
> tmux new -s nowhere
> sudo bash nowhere-v2.sh
> # Ctrl+B 然后按 D 脱离；tmux attach -t nowhere 回到现场
> ```

### 3.2 命令行无交互部署（自动化 / 脚本）

加 `-y` / `--yes` 即为非交互模式。常用参数见 [§9](#9-完整-cli-命令参数速查表)。

#### 场景 A：服务端（Portal），快速测试

```bash
sudo bash nowhere-v2.sh install -y \
  --type portal \
  --endpoint '*:2082' \
  --key "$(openssl rand -hex 32)" \
  --tls 1
```

> 密钥为 32-64 位小写十六进制（Nowhere 2.2.0+ 规则）；省略 `--key` 时管理器会自动生成。`--tls 1` 使用生成的自签名证书，仅适合快速验证：在 2.2.0+ 上客户端必须固定 pin（`sudo bash nowhere-v2.sh fingerprint`），且该 pin 会随 Portal 每次重启而变化。长期使用请选择 `--tls 2`。

#### 场景 B：服务端（Portal），生产环境 ⭐ 推荐

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

`--copy-cert` 会把证书复制到 `/etc/nowhere-v2/tls/` 并设为服务账户可读（`640 root:nowhere-v2`），无需手工改权限。

#### 场景 C：客户端（Vector）

```bash
sudo bash nowhere-v2.sh install -y \
  --type vector \
  --endpoint 'relay.example.com:2082' \
  --key '<填入 Portal 的 64 位 hex 密钥>' \
  --vector-socks '127.0.0.1:1082'
```

> 在 Nowhere 2.2.0+ 上，Vector 会**验证 Portal 证书**：使用受信任 CA 签发且主机名匹配的 `tls=2` 证书即可直接连通；若 Portal 使用自签名证书，需要加 `--pin <sha256>`（可从 Portal 主机的 `links` 输出或 `fingerprint` 获取）。

#### 场景 D：开启 Morph 线路伪装

```bash
sudo bash nowhere-v2.sh install -y --type portal \
  --endpoint '*:2082' --key "$(openssl rand -hex 32)" --tls 2 \
  --cert ... --tls-key ... --copy-cert \
  --morph 1
```

> **注意**：`morph` 必须在同一条链路的两端**同时开启**且共享密钥一致。另外 Morph 线协议在 Nowhere **2.1.0** 有破坏性变更，`morph=1` 的路径上所有节点必须一起升到 `>=2.1.0`。客户端 TCP prelude 策略自 2.2.0 起默认 `full8`；仍可显式指定 `--morph-prelude low7`。

---

## 4. TLS 证书配置与权限安全处理

### 4.1 为什么推荐 `--copy-cert`

Let's Encrypt 默认私钥权限为 `600 root:root`、父目录 `700`，而非特权用户 `nowhere-v2` 在 systemd 沙箱下无权读取。

**不建议**直接把原私钥 `chmod 644`（会破坏系统安全性）。使用 `--copy-cert` 会：

1. 把证书 / 私钥复制到 `/etc/nowhere-v2/tls/cert.pem`、`key.pem`
2. 设置为 `640 root:nowhere-v2`
3. 校验服务账户确实可读，读不到就报错退出

交互式安装时，如果检测到服务账户读不到你选的证书，脚本也会**主动询问**是否自动复制，不会让你卡在 root-only 的 PEM 上。

### 4.2 证书自动续期与 Hook 配置

如果使用 Certbot 维护证书，在 `/etc/letsencrypt/renewal-hooks/deploy/nowhere-v2.sh` 写入更新钩子：

```bash
#!/usr/bin/env bash
bash /path/to/nowhere-v2.sh configure \
  --url "$(head -1 /etc/nowhere-v2/url.conf)" \
  --cert "$RENEWED_LINEAGE/fullchain.pem" \
  --tls-key "$RENEWED_LINEAGE/privkey.pem" \
  --copy-cert
systemctl restart nowhere-v2
```

赋予权限：`chmod +x /etc/letsencrypt/renewal-hooks/deploy/nowhere-v2.sh`。

### 4.3 客户端证书验证（Nowhere 2.2.0+）

native 客户端（Vector、`probe`、链式 Portal 的 `next`）**始终**验证对端证书：系统 CA 信任 + 端点主机名/IP。`sni=` 可覆盖被验证的名称；`pin=none` **不会**关闭验证。

| Portal 证书 | 客户端需要什么 |
|---|---|
| CA 签发（`tls=2`，如 Let's Encrypt） | 客户端通过证书覆盖的域名访问时无需额外配置；否则设置 `sni=` 或 `pin=` |
| 自管理 / 自签名（`tls=2`） | `pin=<sha256>`——只要证书不换就一直有效 |
| 生成的自签名（`tls=1`） | `pin=<sha256>`；生成的证书**每次 Portal 重启都会变化**，pin 必须同步更新——仅适合测试 |

在 Portal 主机上用 `sudo bash nowhere-v2.sh fingerprint` 获取指纹（也可从证书日志获取）；远程拿到的指纹在与你 Portal 主机核对之前都应视为不可信。`tls=1` 时 `links` 会自动把 pin 填进生成的 Vector 链接。

---

## 5. 防火墙与网络放行

在系统防火墙以及云厂商控制台（安全组）放行你实际监听的端口。V2 默认端口为 `2082`，端点形态决定需要放行哪些协议：

| 端点写法 | 需要放行 |
|---|---|
| `*:2082` | TCP `2082` **和** UDP `2082` |
| `*/tcp:2082` | 仅 TCP `2082` |
| `*/udp:2082` | 仅 UDP `2082` |
| `*/tcp:2082/udp:2083` | TCP `2082` 和 UDP `2083` |

### UFW（Ubuntu / Debian）

```bash
sudo ufw allow 2082/tcp
sudo ufw allow 2082/udp
sudo ufw reload
sudo ufw status numbered
```

### Firewalld（CentOS / RHEL / Fedora / Rocky）

```bash
sudo firewall-cmd --permanent --add-port=2082/tcp
sudo firewall-cmd --permanent --add-port=2082/udp
sudo firewall-cmd --reload
```

> 部署完成后脚本会打印 `Firewall: allow TCP/UDP <port>` 提示，按提示放行即可。

---

## 6. 客户端连接与导入

### 6.1 理解链接格式

Nowhere V2 涉及两种 URI：

1. **`portal://` / `vector://`** —— 节点自身的运行配置（内部使用）
   - 存储在 `/etc/nowhere-v2/url.conf`
   - **不是给客户端导入用的**（Vector 的 `vector://` 链接可直接给同版本客户端使用）
2. **`nowhere://`** —— 通用分享 URI
   - 仅在客户端**明确支持 V2 / ALPN nw2** 时使用；Anywhere **2.4 (401) 起已移除 NW2**——升级 App 后 V2 链接必然超时（见 FAQ Q8）

### 6.2 获取客户端连接链接

```bash
# 自动检测公网 IP 并生成链接（需已配置 --public-host，或能访问 api.ipify.org）
sudo bash nowhere-v2.sh links

# 或指定公网域名后重新生成
sudo bash nowhere-v2.sh configure --public-host relay.example.com
```

Portal 上会输出：

- **Native V2 Vector URL** —— 原生 `vector://` 链接，可直接给同版本 Vector 使用
- **Generic V2 share URI** —— 去掉 `socks=` 的 `nowhere://` 链接，附带节点名作为 fragment

> 若提示 `Set --public-host or PUBLIC_HOST to generate client links`，说明脚本无法自动判定公网地址，请显式指定 `--public-host`。

### 6.3 安全警告

* 连接链接**包含共享密钥**。任何人拿到链接都能把你的 VPS 当出口代理。**严禁发到公共群组或上传公开仓库！**
* `--tls 1`（生成的自签名证书）在 2.2.0+ 上需要客户端固定 pin；`links` 会自动填入，但 pin 随 Portal 每次重启变化——生产环境请用 `tls=2`（见 [§4.3](#43-客户端证书验证nowhere-220)）。
* `morph` 只在两端配置一致时才能通信。

### 6.4 查看服务端配置（高级）

```bash
sudo bash nowhere-v2.sh link     # 显示 url.conf 中的运行 URI
```

---

## 7. 日常运维与服务管理

```bash
# 打开交互菜单
sudo bash nowhere-v2.sh

# 查看状态（含当前实际安装的 Core 版本）
sudo bash nowhere-v2.sh status

# 实时日志（Ctrl+C 退出）
sudo bash nowhere-v2.sh logs

# 重启 / 启动 / 停止
sudo bash nowhere-v2.sh restart

# 健康检查；加 --fix 可自动修复常见问题
sudo bash nowhere-v2.sh doctor
sudo bash nowhere-v2.sh doctor --fix

# 查看 TLS SHA-256 指纹（Portal）
sudo bash nowhere-v2.sh fingerprint

# 打开只读 TUI 监控
sudo bash nowhere-v2.sh tui

# 原生 systemctl 操作
sudo systemctl status nowhere-v2
sudo systemctl restart nowhere-v2
```

---

## 8. 版本升级、无损回滚、备份与卸载

### 8.1 版本升级

```bash
# 升级到官网最新稳定版（默认行为）
sudo bash nowhere-v2.sh upgrade

# 或锁定到指定版本
sudo bash nowhere-v2.sh upgrade --version v2.2.1
```

> `upgrade` **需要已有 V2 配置**；首次部署请用 `install`。
> 若已有配置，`install` / `upgrade` 默认**只替换二进制**、不动配置。想同时重新应用配置参数，加 `--force-reconfigure`。
>
> **已有配置跨越 2.2.0 时注意：** 新核心的准入更严格——Portal / `next=` 密钥不是 32-64 位小写十六进制时会拒绝启动；依赖 `pin=none` 连接自签名 Portal 的 Vector 会握手失败。`install` / `upgrade` 会对这两种情况主动告警；升级前请先用 `nowhere generate-key` 轮换密钥（同步该跳所有对端），并按 [§4.3](#43-客户端证书验证nowhere-220) 补上 pin。只换密钥、保留其它设置可执行 `sudo bash nowhere-v2.sh configure -y --config-mode quick --key "$(openssl rand -hex 32)"`，然后同步该跳所有对端。

### 8.2 秒级无损回滚

```bash
sudo bash nowhere-v2.sh rollback
```

脚本会把软链指向上一个可用的 Release 目录并重启服务，无需重新下载或编译。`upgrade` 时若新版启动失败，脚本也会**自动回滚**并保留日志。

保留的旧版本数量由 `--keep-releases`（默认 `3`）控制：

```bash
sudo bash nowhere-v2.sh clean-releases          # 手动清理
sudo bash nowhere-v2.sh clean-build             # 清理源码编译缓存与临时 Swap
```

### 8.3 备份、恢复与诊断

```bash
# 默认备份到 /root/nowhere-v2-backup-<时间戳>.tar.gz（含密钥，权限 600）
sudo bash nowhere-v2.sh backup

# 或指定输出路径（目标已存在时拒绝覆盖）
sudo bash nowhere-v2.sh backup /root/my-backup.tar.gz

# 先校验备份包，不改动任何东西
sudo bash nowhere-v2.sh restore /root/my-backup.tar.gz --dry-run

# 交互确认后恢复（恢复前会自动在备份包旁另存一份 before-restore 备份）
sudo bash nowhere-v2.sh restore /root/my-backup.tar.gz

# 可分享的 JSON 健康快照（仅白名单字段；不含密钥、链接、日志或令牌）
sudo bash nowhere-v2.sh diagnostics
sudo bash nowhere-v2.sh diagnostics --output /root/nowhere-v2-diagnostics.json
```

备份内容为 `/etc/nowhere-v2`（运行配置、管理元数据、TLS 证书），不含二进制。备份包有大小上限（10000 个条目、单文件 256 MiB、总量 1 GiB），拒绝软链接与特殊文件，并带逐文件 SHA-256 清单；`restore` 会先校验通道、清单与 PEM 材料，恢复时保留当前内核，重启失败自动回滚。只恢复自己信任的备份——清单用于检测损坏，不是签名。

### 8.4 检查新版本

```bash
sudo bash nowhere-v2.sh check-updates
```

### 8.5 卸载

```bash
# 卸载程序本体与 systemd 服务（保留 /etc/nowhere-v2 中的配置与密钥）
sudo bash nowhere-v2.sh uninstall

# 彻底卸载（一并删除配置、证书与专用用户，不可逆）
sudo bash nowhere-v2.sh uninstall --purge
```

> V2 的卸载**绝不会**触碰 V1 的 `/etc/nowhere`、`/opt/nowhere`、`nowhere.service`。

---

## 9. 完整 CLI 命令参数速查表

### 9.1 动作（子命令）

| 动作 | 说明 |
| --- | --- |
| `install` / `upgrade` / `update` | 安装或升级（`upgrade` 需已有配置） |
| `configure` / `config` | 修改或导入配置 |
| `status` | 运行状态（含实际安装的 Core 版本） |
| `link` / `links` | 显示运行 URI / 生成客户端链接 |
| `logs` | 实时日志 |
| `restart` / `start` / `stop` | 服务控制 |
| `tui` | 打开只读 TUI 监控 |
| `fingerprint` | 查看 Portal 的 TLS SHA-256 指纹 |
| `rollback` | 回滚到上一个可用 Release |
| `doctor` / `check` / `diagnose` | 健康检查（`--fix` 自动修复） |
| `clean-releases` / `clean-build` | 清理旧 Release / 编译缓存 |
| `check-updates` | 查询官网最新稳定版本 |
| `backup [路径]` | 备份配置与证书（有大小上限、带 SHA-256 清单） |
| `restore 备份包 [--dry-run]` | 校验并恢复备份（校验通道/清单/PEM；恢复前自动另存备份） |
| `diagnostics [--output 文件]` | 白名单字段的 JSON 健康快照（不含密钥） |
| `uninstall` / `remove` | 卸载（`--purge` 彻底删除） |
| `self-update` | 更新管理脚本本身（默认从本仓库 `main` 分支拉取） |
| `help` | 帮助 |

### 9.2 参数

| 参数 | 默认值 | 作用说明 |
| --- | --- | --- |
| `-y`, `--yes` | 关 | 非交互模式 |
| `--method MODE` | `release` | `release`（预编译）或 `source`（本地编译） |
| `--version TAG` | `latest-v2` | `latest-v2`（跟随官网最新稳定 v2 版）或精确 `v2.x.y`；`v3.x` / NW3 会被拒绝 |
| `--type`, `--role` | `portal` | 节点角色：`portal` / `vector` |
| `--url URL` | 无 | 直接导入 `portal://` / `vector://` 配置（优先于其它配置参数） |
| `--key KEY` | 自动生成（64 位小写 hex） | 共享密钥：32-64 位小写十六进制（Nowhere 2.2.0+ 规则）。旧式 1-255 位安全字符仅 Vector 角色可用 |
| `--endpoint EP` | `*:2082`（Portal） | 端点：`HOST:PORT` 或 `HOST/tcp:PORT/udp:PORT` |
| `--public-host HOST` | 自动探测 | 用于生成客户端链接的公网域名 / IP |
| `--name NAME` | `Nowhere-V2` | 节点显示名称 |
| `--tls MODE` | `1` | `1` 自签名证书；`2` 本地 PEM 证书。**生产环境请用 `2`** |
| `--cert`, `--crt` PATH | 无 | 证书全链路径，TLS 2 必填 |
| `--tls-key` PATH | 无 | 私钥路径，TLS 2 必填 |
| `--copy-cert` | 关 | 复制证书到 `/etc/nowhere-v2/tls/` 并设为服务账户可读 |
| `--morph 0\|1` | `0` | 线路伪装开关，两端必须一致 |
| `--morph-prelude` | `full8` | TCP Morph 客户端 prelude 策略：`full8`（2.2.0 起为官方默认）或 `low7` |
| `--up` / `--down` | `auto` | 载波策略：`auto` / `tcp` / `udp` / `mix` |
| `--mux 0\|1` | `0` | TLS 多路复用 |
| `--sni NAME\|none` | `none` | 证书校验用域名 |
| `--pin SHA256\|none` | `none` | 证书 SHA-256 指纹固定；2.2.0+ 起 `none` 不再关闭验证（见 [§4.3](#43-客户端证书验证nowhere-220)） |
| `--out-socks HOST:PORT\|none` | `none` | 出站 SOCKS5（与 `next` 互斥） |
| `--next KEY@EP` | `none` | 原生 V2 下一跳 Portal |
| `--vector-socks` | `127.0.0.1:1082` | Vector 本地 SOCKS5 监听地址 |
| `--client-up/down/mux/sni/pin` | 自动 | 生成客户端链接时使用的参数 |
| `--rate` / `--etar` | `0` | 正向 / 反向限速（Mbps，0 为不限） |
| `--dial` | `auto` | 出站源 IP（单地址族）；与 `--dial4` / `--dial6` 互斥 |
| `--dial4` / `--dial6` | `auto` | Nowhere 2.2.0+ 双栈出站源：`auto` 或裸 IPv4 / IPv6 字面量 |
| `--log LEVEL` | `info` | `none` / `debug` / `info` / `warn` / `error`（`event` 已在 2.1.1 移除） |
| `--memory-profile` | `throughput` | 传输内存模式：`memory` / `balanced` / `throughput` |
| `--config-mode` | `ask` | `ask` / `quick` / `advanced`；亦可 `--quick` / `--advanced` |
| `--keep-releases N` | `3` | 保留的旧 Release 数量（0–20） |
| `--libc auto\|gnu\|musl` | `auto` | C 库兼容选项（预编译模式） |
| `--swap auto\|off\|MB` | `auto` | 临时 Swap 控制 |
| `--keep-source` | 关 | 编译后保留构建树，加速增量编译 |
| `--github-token TOKEN` | 无 | 访问 GitHub API 的令牌（规避限流） |
| `--force-reconfigure` | 关 | `install` / `upgrade` 时明确重新应用配置参数 |
| `--fix` | 关 | 配合 `doctor` 自动修复 |
| `--purge` | 关 | 配合 `uninstall` 彻底删除配置 |

### 9.3 环境变量

所有配置项都有对应的 `NOWHERE_V2_*` 环境变量，例如 `NOWHERE_V2_LANG`（`zh` / `en`）、`NOWHERE_V2_KEY`、`NOWHERE_V2_TLS`、`NOWHERE_V2_MORPH`、`NOWHERE_V2_MEMORY_PROFILE`、`NOWHERE_V2_MORPH_PRELUDE`、`NOWHERE_V2_DIAL4` / `NOWHERE_V2_DIAL6`、`NOWHERE_V2_VERSION` 等。

> 注意：`manager.conf` 中的持久化值优先于环境变量；命令行参数优先级最高。

---

## 10. 文件结构与安全沙箱布局

```text
/opt/nowhere-v2/
├── releases/
│   ├── v2.2.1-release-xxxxxxxxxxxx/          # 官方预编译二进制发布目录
│   │   ├── nowhere
│   │   └── RELEASE-INFO                      # tag / asset / SHA-256 审计凭据
│   └── v2.2.1-source-aaaa-bbbbbbbbbbbb/      # 本地源码编译发布目录
│       ├── nowhere
│       └── BUILD-INFO                        # commit / SHA-256 溯源凭据
└── current -> releases/...                   # 原子软链，指向当前激活目录

/usr/local/bin/nowhere-v2 -> /opt/nowhere-v2/current/nowhere   # 全局可执行软链
/usr/local/libexec/nowhere-v2-launch                            # root 所属启动器（读取 url.conf）

/etc/nowhere-v2/
├── url.conf                                  # 运行 URL（640，root:nowhere-v2）
├── manager.conf                              # 管理元数据（640，root:nowhere-v2）
└── tls/
    ├── cert.pem                              # 授权证书（640，root:nowhere-v2）
    └── key.pem                               # 授权私钥（640，root:nowhere-v2）

/etc/systemd/system/nowhere-v2.service        # systemd 安全隔离沙箱单元
```

systemd 单元启用了 `NoNewPrivileges`、`ProtectSystem=strict`、`ProtectHome`、`PrivateTmp`、`CapabilityBoundingSet=CAP_NET_BIND_SERVICE` 等加固项，并仅通过 `Environment=` 注入 `NOW_TRANSPORT_MEMORY_PROFILE` 与 `NOW_MORPH_TCP_PRELUDE`。

---

## 11. 常见问题排查（FAQ）

### Q1: 运行提示 `GLIBC_2.xx not found`

* **根因**：系统 glibc 版本低于官方 GNU 构建的编译环境。
* **解决**：改用 musl 静态构建重新安装：

```bash
sudo bash nowhere-v2.sh install -y --method release --libc musl [其他参数...]
```

### Q2: 源码编译被中止，报 `signal: 9 Killed`

* **根因**：Fat-LTO 链接阶段内存超限，被 OOM Killer 终止。
* **解决**：分配更大的临时 Swap 后重试：

```bash
sudo bash nowhere-v2.sh install -y --method source --swap 4096 [其他参数...]
```

### Q3: 报错 `GitHub release does not expose a SHA-256 digest ... refusing binary install`

* **根因**：脚本启用零信任校验，官方该 Release 未提供对应资产的哈希摘要，脚本主动中止。
* **解决**：改用源码编译模式：`--method source`。

### Q4: 提示 `V2 service user cannot read TLS files`

* **根因**：`--tls 2` 直接引用了 root-only 的 PEM 文件，服务用户无权读取。
* **解决**：加 `--copy-cert` 重新配置，让脚本把证书复制到 `/etc/nowhere-v2/tls/`。

### Q5: 升级后流量中断（尤其开了 `morph`）

* **根因（2.1.0）**：Morph 线协议变更，`morph=1` 的 2.1 节点与 2.0.x 节点不兼容。
  * **解决**：把**整条链路上**的所有节点（Portal / Vector / native next / 其它客户端）一起升级到 `>=2.1.0`。
* **根因（2.2.0）**：准入更严格——旧格式共享密钥会让 Portal 拒绝启动；native 客户端开始强制验证证书，自签名 Portal 没有 `pin=` 会握手失败。
  * **解决**：把该跳所有对端都换成 32-64 位小写十六进制密钥（`nowhere generate-key`），并按 [§4.3](#43-客户端证书验证nowhere-220) 添加 `pin=<sha256>` 或改用受信任 CA 证书。
* 可查看 `journalctl -u nowhere-v2 -n 50`——2.2.x 会指明出问题的端点且不会打印密钥。

### Q6: 客户端无法连接或握手超时

1. 检查服务：`sudo systemctl status nowhere-v2`
2. 检查端口监听：`sudo ss -lntup | grep 2082`
3. 检查防火墙（UFW / Firewalld）是否放行了对应端口与协议
4. 检查云厂商**安全组入站规则**
5. 确认域名解析生效且未开启 CDN 代理（需直连）
6. 2.2.0+ 请确认证书信任：CA 签发且主机名匹配，或自签名 Portal 配置 `pin=<sha256>`（见 [§4.3](#43-客户端证书验证nowhere-220)）
7. 运行 `sudo bash nowhere-v2.sh doctor` 做一次完整体检

### Q7: 报错 `Portal shared key must be 32-64 lowercase hex characters`

* **根因**：配置仍是 2.2 之前的密钥格式，Nowhere 2.2.0+ 会拒绝启动（`nowhere generate-key` 输出即为要求的格式）。
* **解决**：用 `sudo bash nowhere-v2.sh configure -y --config-mode quick --key "$(openssl rand -hex 32)"` 只轮换密钥、保留其它设置，然后把**同一串文本**配置到该跳的每个对端。旧式 1-255 位密钥仅在 Portal `<=2.1` 上继续可用。

### Q8: 更新 Anywhere App（2.4 起）之后 V2 连不上了

* **根因（客户端侧，不是服务器故障）**：Anywhere **2.4 (401)** 把内嵌的 Nowhere 协议实现从 NW2 整体换成了 NW3——实测其主程序与网络扩展二进制只包含 `nw3` ALPN 和 `nowhere/nw3/auth-root`，不含任何 `nw2` 标识。NW2 / NW3 线协议不兼容且**没有协商与回落**，所以 2.4+ 上指向 V2（`nw2`）的配置会持续"超时"；反过来，2.3 及以下连不了 V3。
* **自证服务器正常**：`sudo bash nowhere-v2.sh doctor`；外部再跑一条 `echo | openssl s_client -connect <host>:2082 -servername <域名> -alpn nw2 2>&1 | grep ALPN`——显示 `ALPN protocol: nw2` 即 Portal 完好（不匹配 ALPN 的探测会被静默断开，属正常设计）。
* **选择**：继续用 V2 → 客户端保留在 **2.3 及以下**；已升级到 **2.4+** → 迁移到 [V3 通道（NW3）](#13-v3-通道nw3)。同一台设备上的一个 App 版本无法同时兼顾 V2 与 V3。

### Q9: 报错 `sudo: command not found`

* **根因**：你已经以 root 登录，而这台 VPS（如 Evoxt 的部分镜像）是精简系统、没有安装 `sudo`。与脚本或服务无关。
* **解决**：把命令开头的 `sudo` 去掉直接运行，例如 `bash nowhere-v2.sh status`、`bash nowhere-v3.sh links`、或直接 `nh`。root 下两者权限完全相同。想装 sudo 也可以（Debian/Ubuntu：`apt-get install -y sudo`），但没有必要。

---

## 12. V1 稳定通道（仅部署）

> V1 通道**固定 Nowhere `v1.8.3`**，不跟随 `latest`，**不支持 V2**。
> 只在「已有 V1 节点需要继续维护」或「需要俄文界面」时使用。

### 部署

```bash
# 下载
wget https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v1.sh -O nowhere-v1.sh

# 检查并运行
chmod 700 nowhere-v1.sh
bash -n nowhere-v1.sh
sudo bash nowhere-v1.sh
```

### 无交互部署（生产环境示例）

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

### V1 与 V2 的隔离

| | V1 | V2 |
|---|---|---|
| 服务名 | `nowhere` | `nowhere-v2` |
| 安装目录 | `/opt/nowhere` | `/opt/nowhere-v2` |
| 配置目录 | `/etc/nowhere` | `/etc/nowhere-v2` |
| 全局二进制 | `/usr/local/bin/nowhere` | `/usr/local/bin/nowhere-v2` |
| 默认端口 | `2077` | `2082` |
| 界面语言 | 中文 / English / Русский | 中文 / English |

两者只要监听端口不冲突即可在同一台 VPS 共存，且不会互相修改文件或服务。

### V1 详细文档

- [`NOWHERE_V1_STABLE_README.md`](NOWHERE_V1_STABLE_README.md) —— V1 稳定版管理脚本完整说明
- [`README.two-scripts.zh-CN.md`](README.two-scripts.zh-CN.md) —— `install.sh` / `install-source.sh` 自动化安装器说明

> V1 通道的功能细节（`prepare-tls`、`client-link`、`--net` 等）请以上述文档为准，本主 README 只保留部署入口。

</details>

---

## 13. V3 通道（NW3）

> `nowhere-v3.sh` 是面向 Nowhere **v3.x** 的**独立管理器**，与 V2 完全隔离（独立服务、账户、路径、端口），不会转换或触碰 V2 安装。NW3 与 NW2 线协议不兼容，没有协商或回落。
>
> 文档位置：V3 安装与操作=本文件 §13；验收清单=[`ACCEPTANCE.md`](ACCEPTANCE.md) §13；变更历史=[`CHANGELOG.md`](CHANGELOG.md)；V2 的完整文档=本文件 §2–§11。

### 13.1 安装步骤（详细走查）

第一次装推荐**直接走菜单向导（Step 1）**；批量/自动化部署看 Step 2。

**Step 0 · 下载脚本（建议固定在 `/root`）**

```bash
cd /root
wget https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v3.sh -O nowhere-v3.sh
chmod 700 nowhere-v3.sh
bash -n nowhere-v3.sh        # 语法自检；无输出即通过
```

> 💡 在 Evoxt 这类**没装 `sudo`、已用 root 登录**的机器上：把本文所有命令开头的 `sudo` 去掉（如 `bash nowhere-v3.sh links`）——效果完全相同。

**Step 1 · 打开菜单，用向导安装 Portal（推荐）**

```bash
sudo bash nowhere-v3.sh      # 不带参数 = 打开完整菜单（23 项）
```

菜单分三组：**1–6 安装与配置**（1=Portal 2=Vector 3=Egress 4=改配置 5=选版本 6=升级）、**7–15 服务与诊断**（启停重启、状态统计、客户端链接、证书指纹、生成密钥、TCP 探测、实时日志）、**16–22 维护**（体检、清理、备份、回滚、卸载、语言、更新脚本）、**23 证书**（自动签发/续期 TLS 证书）。

安装 Portal：**输入 `1`**（Vector 输入 `2`、Egress 输入 `3`），然后跟着向导走，**每一步直接回车 = 用括号里的默认值**：

| 向导提示 | 输入 | 说明 |
|---|---|---|
| 角色 | `1` | 1=portal（默认）2=vector 3=egress |
| 共享密钥 | 回车 | 自动生成 32 位 hex；也可粘贴自己的 |
| 监听预设 | 回车（1） | 1=both（TCP+UDP 共用端口）；选 4=split 会多问一个 UDP 端口（默认 2084） |
| 主端口 | 回车 | 默认 2083 |
| TLS 模式 | 回车（1） | 1=managed：自动生成**持久**自签 PEM（pin 不随重启变）；2=supplied：用你自己的证书（接着填证书与私钥两个路径） |
| 出口 | 回车（1） | 1=direct（直连）2=socks（上游 SOCKS，输入隐藏）3=egress（远程出口） |
| 公网地址 | 填域名/IP | 生成客户端链接用（如 relay.example.com） |
| Morph | 回车（1） | 必须与客户端一致 |

装完自动启动服务，并生成快捷命令 `nh`——以后直接敲 `nh` 就能回到这个菜单。

> **已有实例时留意**：菜单 `1` 会先问「已有实例：使用向导重配？」——**输入 `y` 才进入向导**；直接回车/输入 `n` 只是重装二进制（配置不动）。

**Step 2 · 或一条命令无人值守安装**

```bash
# 最小安装：自签证书 + 自动生成密钥 + 端口 2083 + morph=1
sudo bash nowhere-v3.sh install --yes --public-host relay.example.com

# 用域名证书（如 Let's Encrypt）
sudo bash nowhere-v3.sh install --public-host relay.example.com \
  --cert /etc/letsencrypt/live/relay.example.com/fullchain.pem \
  --tls-key /etc/letsencrypt/live/relay.example.com/privkey.pem

# 指定版本 / 端口 / 密钥
sudo bash nowhere-v3.sh install --version v3.1.0 --endpoint '*:8443' \
  --key "$(openssl rand -hex 16)"
```

> 想要自动签发/续期 Let's Encrypt 证书（有域名时）？安装后跑 `sudo bash nowhere-v3.sh cert --domain 你的域名`，或菜单 `nh` → `23`（见 §13.5）。

**Step 3 · 安装后确认**

```bash
sudo bash nowhere-v3.sh doctor     # 服务 / 证书 / 账户体检
sudo bash nowhere-v3.sh links      # Vector URL + 分享链接 + 二维码
nh                                 # 或直接用快捷命令回到菜单
```

**Step 4 · 客户端导入（Anywhere 2.4+）**

- 扫 `links` 输出的二维码，或把 `nowhere://` 链接复制进 App 导入
- 自签证书：把 `sudo bash nowhere-v3.sh fingerprint` 的结果加入 App 的证书信任列表
- `net=tcp` / `net=udp` 两条链接任选一条导入即可（仅载体不同，共用端口时不要两条都导）

**Step 5 · 防火墙（别忘云安全组）**

- Portal：放行 **TCP 和 UDP 2083**（split/自定义端口时对应各自端口）
- Egress：无需入站，只需能向 Portal 发起 QUIC/UDP 出站

**其他角色与版本跟进**

- **Vector**：把输出的 `vector://` URL 保存为权限 600 的文件，执行 `sudo bash nowhere-v3.sh install --url-file /root/vector-v3.url`（SOCKS5 监听 `127.0.0.1:1083`）。
- **Egress（远程出口）**：Portal 用 `--out egress` 安装；把输出的 `egress://` URL 传到出口机器并 `install --url-file`。一个 Portal 只接受一个已注册 Egress，其离线时不会回退直连。
- **跟进 v3.x**：默认固定已核验的 `v3.1.0`（v3.2.0 为 GitHub 预发布，`latest-v3` 只跟进稳定版）；用 `upgrade --version latest-v3` 显式升级到更新的稳定 v3 版本。

### 13.2 V2 / V3 对照

| | V2（`nowhere-v2.sh`） | V3（`nowhere-v3.sh`） |
|---|---|---|
| ALPN / 协议 | `nw2` | `nw3` |
| 角色 | Portal / Vector | Portal / Vector / Egress |
| Vector 入口 | `socks=` | `in=` |
| Portal 出口 | direct / `socks=` / `next=` | `out=direct` / SOCKS / `out=egress` |
| up/down、Mux、native next | 支持 | 已移除（旧参数直接拒绝） |
| Morph 默认 | `0` | `1` |
| 服务 / 配置 / 二进制 | `nowhere-v2` · `/etc/nowhere-v2` · `nowhere-v2` | `nowhere-v3` · `/etc/nowhere-v3` · `nowhere-v3` |
| 默认端口 | 2082 / SOCKS 1082 | 2083 / SOCKS 1083 |
| 监控 | TUI | `status` / `telemetry` |
| 源码编译 / 自更新 | 支持 / 支持 | 不提供源码 / 支持自更新 |

> V3 v1.1.0 支持完整中文/英文交互。防火墙：放行 TCP **和** UDP `2083`；Egress 机器需能向 Portal 发起 QUIC/UDP 出站。

> **客户端版本对应（实测）**：Anywhere **2.3 及以下只有 NW2**（连不了 V3）；**2.4 (401) 起只有 NW3**（连不了 V2——其二进制中 NW2 实现已被移除）。升级 App 后 V2 配置持续超时属预期现象，不是服务器故障；V2 服务可用 `doctor` / `probe` 与外部 `-alpn nw2` 探测自证。详见 [FAQ Q8](#11-常见问题排查faq)。

---

### 13.3 日常操作

无参数运行进入23项循环菜单；安装/重配提供Portal、Vector、Egress向导。
安装/重配或自更新成功后自动生成快捷命令 `nh`（=打开本菜单；参数透传，如 `nh status`、`nh doctor`；`uninstall --purge` 时移除）。
向导选项支持编号选择（如 `1=both 2=tcp`；编号与原值都认），确认提示支持 `y/n`（`是/否`）。
菜单失败在独立子shell恢复事务后返回；无终端读取失败直接退出。

```bash
sudo bash nowhere-v3.sh                         # 完整菜单
sudo bash nowhere-v3.sh install --yes           # 默认Portal、2083、持久PEM
bash nowhere-v3.sh versions                     # 所有稳定V3，数值倒序
bash nowhere-v3.sh check-updates
bash nowhere-v3.sh generate-key                 # 仅输出32位小写hex
sudo bash nowhere-v3.sh probe example.com:443    # 脱敏URL + Result
sudo bash nowhere-v3.sh doctor --probe          # 探测失败仅警告
sudo bash nowhere-v3.sh cert --domain relay.example.com  # 申请/续期LE证书（见§13.5）
sudo bash nowhere-v3.sh status
sudo bash nowhere-v3.sh telemetry
sudo bash nowhere-v3.sh clean-releases
sudo bash nowhere-v3.sh language --lang en      # 保存语言
sudo bash nowhere-v3.sh self-update             # 仅更新管理脚本
NOWHERE_V3_SELF_URL= bash nowhere-v3.sh self-update # 禁用
```

语言优先级：`--lang` > `NOWHERE_V3_LANG` > `manager.conf` 的LANG > 中文。
菜单切换与language命令保存语言；修改类命令的显式--lang也保存；
help/validate/generate-key/self-update不为语言选项修改服务配置。
新增 `--name`（分享链接名称）、`--wizard`、`--dial/--dial4/--dial6`；原CLI选项全部保留。

`versions`展示实际全部稳定版本；若官方不足10个，不补造版本。
默认仍固定v3.1.0（v3.2.0 为预发布，`latest-v3` 不会选中；显式指定预发布会被拒绝），跟进新版本必须显式`upgrade --version latest-v3`。
`--morph-prelude` 支持 `fade|full8|low7`（默认 `full8`；`fade` 需内核 ≥ v3.0.1，指定 v3.0.0 会被拒绝；prelude 是发送端策略，无需与对端一致）。
自更新验证Bash语法、V3通道与版本，拒绝降级，同目录原子替换并保留备份；
不更新服务、配置或内核。来源默认本仓库main，可通过NOWHERE_V3_SELF_URL覆盖。

`links`输出原生Vector/Egress URL（证书经系统CA验证时**不带pin**，否则带叶证书pin），以及每个carrier对应的
`nowhere://KEY@host:port?net=tcp|udp&morph=0|1#NAME`。
分享链接不携带pin；自签证书应将`fingerprint`结果添加到客户端信任列表。
`fingerprint` 无参数查本机；`fingerprint 'nowhere://KEY@HOST:PORT?morph=0|1'` 查**远端**证书指纹（v1.2.0 起；强制 TCP/TLS、链接打码，`net=udp` 链接同样适用）——请带外核对后再用作 pin 或客户端信任项。
二维码会自动安装 qrencode（apt/dnf/yum/apk）后显示；无包管理器或安装失败时仅警告并跳过。链接含密钥勿外传。
`generate-key`与`fingerprint`是明确的密钥/指纹输出例外；其他状态、日志和probe输出脱敏。

Portal probe需要PUBLIC_HOST，可临时传`--public-host`；持久证书读取本机PEM指纹，
临时tls=1用官方内核探测本机TCP指纹；纯UDP临时证书无法核实时拒绝链接/探测。
Egress角色不能发起probe。Egress自身可使用dial*；只有Portal的out=egress禁止dial*。
重配同角色复用PEM；明确提供--cert/--tls-key才轮换；角色切换仍需确认或--allow-role-switch。
备份、恢复、诊断与预览（v1.4.0）。恢复会先校验通道、清单与 PEM 材料，恢复前自动另存备份，保留当前内核，重启失败自动回滚：

```bash
sudo bash nowhere-v3.sh backup /root/nowhere-v3-backup.tar.gz
sudo bash nowhere-v3.sh restore /root/nowhere-v3-backup.tar.gz --dry-run
sudo bash nowhere-v3.sh restore /root/nowhere-v3-backup.tar.gz
sudo bash nowhere-v3.sh diagnostics --output /root/nowhere-v3-diagnostics.json
sudo bash nowhere-v3.sh cert-status                    # 证书 + 定时器 + 上次续期结果
sudo bash nowhere-v3.sh cert-timer                     # 同步受管理的续期定时器
sudo bash nowhere-v3.sh preview --url-file /root/proposed-url.conf
sudo bash nowhere-v3.sh configure --dry-run --endpoint '*:2084'
```

`preview` / `configure --dry-run` 输出脱敏差异（共享密钥、pin 与 SOCKS 口令隐藏；切换角色需 `--allow-role-switch`），不写任何文件。**更换管理脚本后请运行一次 `cert-timer`**，让固定续期入口同步新代码。

### 13.4 安装后的文件位置

| 内容 | 位置 |
|---|---|
| 管理脚本 | 你下载的路径（建议 `/root/nowhere-v3.sh`）；`nh` 指向它，挪动后重跑一次 install/configure/self-update 即可刷新 |
| 快捷命令 | `/usr/local/bin/nh`（`uninstall --purge` 时移除） |
| 当前内核 | `/usr/local/bin/nowhere-v3` → `/opt/nowhere-v3/current/nowhere` |
| 版本目录 | `/opt/nowhere-v3/releases/v3.x.y/`（默认保留最近 3 个，用 `--keep-releases` 调整） |
| 服务配置 | `/etc/nowhere-v3/url.conf`（含共享密钥，注意保密） |
| 管理元数据 | `/etc/nowhere-v3/manager.conf` |
| 证书/PEM | `/etc/nowhere-v3/tls/pem.XXXXXX/`（只保留当前一份） |
| systemd 单元 | `/etc/systemd/system/nowhere-v3.service` |
| 启动器 | `/usr/local/libexec/nowhere-v3-launch` |
| 服务账户 | `nowhere-v3`（系统账户，无登录） |
| 日志 | `journalctl -u nowhere-v3`（`nh logs` 实时跟随） |
| 配置备份 | 默认 `/root/nowhere-v3-backup-YYYYmmdd-HHMMSS.tar.gz`（`nh backup`） |
| 构建锁 | `/run/nowhere-v3-build.lock.d`（防止并发管理操作） |

### 13.5 自动签发/续期证书（Let's Encrypt，可选）

有域名时可以让管理器全自动申请并续期 Let's Encrypt 证书（日常不用再自己管 pin）：

```bash
# 交互式：会问域名和验证方式；Cloudflare Token 输入不回显
sudo bash nowhere-v3.sh cert --domain relay.example.com

# Token 从文件读取（不进 shell 历史）
printf '%s' '<你的CF-API-Token>' > /root/cf.token && chmod 600 /root/cf.token
sudo bash nowhere-v3.sh cert --domain relay.example.com --cf-token-file /root/cf.token

# 不用 Cloudflare：HTTP-01 模式（需 80 端口从公网可达）
sudo bash nowhere-v3.sh cert --domain relay.example.com --http

# 菜单操作：nh → 23
```

**前置条件**

- DNS-01 模式：域名托管在 **Cloudflare**，Token 只需该域的 **`Zone.DNS:Edit`** 权限（**别用 Global API Key**）
- HTTP-01 模式：80 端口可从公网访问（DNS 在哪都行）；申请/续期时会临时占用 80 端口

**Cloudflare Token 申请步骤（DNS-01 用，约 5 分钟）**

1. 浏览器登录 Cloudflare，打开 **API Tokens** 页面：
   👉 https://dash.cloudflare.com/profile/api-tokens （右上角头像 → **My Profile** → **API Tokens**）
2. 点 **Create Token**（创建令牌）。
3. 选模板 **「Edit zone DNS」**（推荐，最简单）——它的权限恰好就是需要的 `Zone → DNS → Edit`；
   也可以点 **Create Custom Token** 手动配置：
   - **Permissions（权限）**：选 **Zone → DNS → Edit**
   - **Zone Resources（区域资源）**：**Include（包括）→ Specific zone（特定区域）→ 选中你的域名**（例如 `960606.xyz`）
   - 其他项（Client IP、TTL）留空 / 默认即可
4. 点 **Continue to summary → Create Token**；页面**只显示这一次 Token**，立刻复制（一长串字母数字，可能以 `v1.0-` 开头）。
5. 在服务器保存（不进 shell 历史、权限收紧）：

   ```bash
   printf '%s' '<粘贴Token>' > /root/cf.token
   chmod 600 /root/cf.token
   ```

6. 直接使用：

   ```bash
   sudo bash nowhere-v3.sh cert --domain 你的域名 --cf-token-file /root/cf.token
   ```

> **为什么不用 Global API Key**：它是**全账号钥匙**——你 CF 名下**所有域名**都能被改。API Token 可以只授权"这一个域名的 DNS 编辑"，泄露后损失可控；一旦怀疑泄露，去同一页面 **Roll / Delete** 该 Token 即可。

**它做了什么**

1. 安装**固定版本 acme.sh 3.1.6** 及其 `dns_cf` 插件（从 GitHub release tarball 安装，不走 `curl | bash`）到 `/etc/nowhere-v3/acme`（随配置一起备份 / 事务回滚；旧版 `/root/.acme.sh` 原样保留、不会被改动）
2. 签发证书（DNS-01 或 HTTP-01；**显式指定 Let's Encrypt**——acme.sh 默认 CA 是 ZeroSSL）
3. 证书写入 `/etc/nowhere-v3/tls/le.<域名>/`（`fullchain.pem` / `key.pem`，640 root:nowhere-v3）
4. `url.conf` 切换到该证书（在事务里改写；申请中途失败会恢复到**之前的证书**）
5. 重启服务并通过存活检查后，创建**每日自动续期定时器** `nowhere-v3-cert-renew.timer`（与管理操作共用同一把锁，互斥时本轮静默跳过）

**安全细节**

- Token 只通过隐藏输入或 `--cf-token-file` 读取；传给 acme.sh 时走环境变量，**不会出现在进程命令行**（`ps` 看不到）
- 凭据由 acme.sh 自管在 `/etc/nowhere-v3/acme/account.conf`（600；整个目录在本管理器 umask 077 下创建，仅 root 可读，且纳入配置备份）

**查看与排查**

```bash
sudo bash nowhere-v3.sh cert-status                 # 有效期、剩余天数、私钥匹配、定时器、上次受管理结果
sudo bash nowhere-v3.sh cert-timer                  # 安装/同步受管理定时器——更换管理脚本后运行一次
sudo bash nowhere-v3.sh cert-renew                  # 立即执行受管理续期；未到期不重启，锁被占用会记录跳过
systemctl list-timers 'nowhere-v3-cert-renew*'      # 下次续期时间
journalctl -u nowhere-v3-cert-renew                 # 续期日志
sudo bash nowhere-v3.sh cert --domain 你的域名 --force   # 手动强制重签
```

**注意**

- 从自签切换为 LE 后**指纹会变**：此前在 App 里 pin 过旧指纹的要更新信任项；`links` 会输出新的指纹/pin
- **原生链接的 pin 策略**：证书能被系统 CA 验证（证书链 + 主机名）时，`links` 输出**不带 pin** 的 Vector/Egress 链接——续期后无需重新导入；自签 / 私有 CA 证书仍输出叶证书 pin；证书不可读取时拒绝输出，请修复文件或显式传 pin
- 想换域名重签：再跑一次 `cert --domain 新域名`；旧目录 `le.<旧域名>` 可手动删除
- **受管理续期**：每日定时器执行 `cert-renew`，仅续期当前 Portal 的托管证书；部署前清除旧 acme.sh 的自动部署/重载钩子并校验新证书，失败自动回滚；未到期不会重启服务，锁被占用会记录跳过。`cert-status` 显示有效期、剩余天数、私钥匹配、定时器状态与上次受管理结果（`/etc/nowhere-v3/renewal-status.json`）；检测到旧版直接 `--cron` 的定时器会提示，可用 `cert-timer` 迁移。证书损坏/过期/私钥不匹配/日期异常时仍会展示定时器与上次结果，但命令返回非零；自备证书明确标示不走内置续期且不查询 timer。

## 测试

逻辑部分由沙箱测试覆盖，**不需要 root、不联网**：

```bash
bash tests/nowhere-v2.test.sh
bash tests/nowhere-v3.test.sh
python3 tests/test_fixes.py .
python3 tests/test_features.py .
python3 tests/test_review.py .
python3 tests/test_core_sync.py .
```

它在 source 之前会把管理器的路径声明改写到一个临时目录，因此**永远不会碰到真实的
`/etc/nowhere-v2` 或 systemd**；而且一旦某条声明被改名，测试会**直接中止**，而不是悄悄
落到真实路径上。CI 每次 push 都会连同 `bash -n` 与 `shellcheck` 一起跑它。
`tests/test_features.py` 在沙箱里覆盖备份/恢复、诊断、预览与受管理续期，离线使用固定的
`tests/fixtures/acme-3.1.6.tar.gz`；CI 会一并运行。
`tests/test_fixes.py` 是历次评审批次的专项离线回归（替身 systemd / ACME），CI 一并执行。
`tests/test_review.py` 是 1.5.1/1.4.1 评审批次的 16 项专项回归（原子备份回退、元数据规范化、管道执行、ACME 版本参数、证书状态异常）；CI 会运行以上全部。
`tests/test_core_sync.py` 校验内核默认版本、预发布策略与 `fade` 校验顺序（8 项，离线）；`tests/smoke_native.py` 需自备官方 v3.0.1/v3.1.0 二进制做回环连通验证（可选，CI 不运行）。

**集成部分没有自动化覆盖。** 安装、升级、systemd 这些流程**从未被测试套件执行过**。
在依赖某个版本之前，请在一台一次性 VPS 上跑一遍 [`ACCEPTANCE.md`](ACCEPTANCE.md)。

---

## 许可

本项目采用 [GPL-3.0](LICENSE) 许可，与上游 [NodePassProject/Nowhere](https://github.com/NodePassProject/Nowhere) 保持一致。
