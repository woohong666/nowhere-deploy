# Nowhere 一键部署与综合管理脚本（Linux VPS）

[English](README.md) | [简体中文](README.zh-CN.md)

基于 [NodePassProject/Nowhere](https://github.com/NodePassProject/Nowhere) 官方核心协议编写的生产级一键部署与运维管理脚本。

> **✅ 主通道：V2** —— `nowhere-v2.sh`，面向 Nowhere `v2.x`。**新部署请优先使用它。**
> 默认跟随官网最新稳定版（`latest-v2`，安装时自动解析为最新的 `v2.x.y`），也可用 `--version v2.x.y` 精确锁定。
> 使用独立路径与服务（`/opt/nowhere-v2`、`/etc/nowhere-v2`、`nowhere-v2.service`），不会触碰任何 V1 安装。
> `v2.x` 线目前仍然完整可用：官方最新的 v2 正式版为 **v2.2.1**。官方同时已发布 **v3.0.0（NW3）**，其线协议与 NW2 **不兼容**——V2 管理器会明确拒绝 `v3.x` 版本标签。
>
> **🆕 V3 通道（NW3）：** `nowhere-v3.sh` 是面向 Nowhere `v3.x` 的独立管理器——Portal / Vector / **Egress** 三种角色、`in=` 入口、`out=egress` 远程出口、32 位 hex 密钥、Morph 默认开启。使用独立路径与服务（`/opt/nowhere-v3`、`/etc/nowhere-v3`、`nowhere-v3.service`、端口 2083/1083），不会触碰 V2。见 [§13](#13-v3-通道nw3)。
>
> **🔒 V1 稳定通道：** `nowhere-v1.sh`，固定 Nowhere `v1.8.3`，不跟随 `latest`，也不支持 V2。
> 仅用于已有 V1 节点或需要俄文界面的场景，部署方式见 [§12](#12-v1-稳定通道仅部署)。

V2 管理器融合了官方 Release 二进制 SHA-256 强校验、本地 Rust 源码全程序优化编译（Fat-LTO）、systemd 高强度权限沙箱、TLS 证书权限隔离，以及支持中 / 英双语的终端彩色交互控制台（TUI）。

---

## 目录

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

---

## 0. 我该用哪个脚本

本仓库包含四个脚本，**默认推荐 V2**：

| 脚本 | 通道 | 用途 |
|---|---|---|
| **`nowhere-v2.sh`** | **V2（主）** | **推荐**。Nowhere v2.x，带完整 TUI 菜单：预编译安装 / 源码编译 / 配置 / 诊断 / 回滚 / 备份 |
| `nowhere-v1.sh` | V1 稳定 | 固定 `v1.8.3`，不跟随 `latest`。仅用于已有 V1 节点或需要俄文界面 |
| `install.sh` | V1 | 自动化 / CI 专用，仅 V1 预编译二进制 |
| `install-source.sh` | V1 | 自动化 / CI 专用，仅 V1 源码编译 |
| **`nowhere-v3.sh`** | **V3（NW3）** | Nowhere v3.x：Portal / Vector / Egress；默认固定 `v3.0.0`，`latest-v3` 显式跟进 |

**怎么选：**

- **全新部署 / 想用 V2 协议与特性** → 用 `nowhere-v2.sh`（[§3](#3-快速开始v2)）。
- **全新 V3 部署 / 需要远程 Egress 出口** → 用 `nowhere-v3.sh`（[§13](#13-v3-通道nw3)）；V2 与 V3 完全隔离，可同机并存。
- **已有 V1 节点需要继续维护** → 用 `nowhere-v1.sh`（[§12](#12-v1-稳定通道仅部署)）。
- **想两套对比着跑** → 各自用不同端口安装即可，二者文件与服务完全隔离。

> **⚠️ 线协议警告**：V1 与 V2 节点**无法互通**。同一条流量路径上的所有节点必须使用同一个大版本。
> 不要把 V1 Portal / Vector / native-next 客户端指向 V2 服务，反之亦然。
>
> 另外，**Morph 在 Nowhere 2.1.0 有破坏性变更**：开启 `morph=1` 的 2.1 节点与 2.0.x 节点不兼容，整条链路上的所有对端必须一起升级到 `>=2.1.0`。管理器在升级跨越该边界时会主动告警。
>
> **Nowhere 2.2.0 准入新规**：Portal 监听密钥与 native `next` 密钥必须为 **32-64 位小写十六进制**（`nowhere generate-key` 输出 32 位；本管理器生成 64 位）。native 客户端（Vector、`probe`、链式 Portal 的 `next`）现在**始终验证对端证书**（系统 CA + 端点主机名），`pin=none` 不再关闭验证。因此自签名（`tls=1`）Portal 必须配置 `pin=<sha256>`，且生成的证书每次重启都会变化——生产环境请优先 `tls=2`。管理器会按新规生成/校验密钥、为 `links` 自动填充 pin，并在升级跨越 2.1.1 / 2.2.0 边界时主动告警。
>
> **NW3 是另一种协议**：Nowhere **v3.0.0** 引入了 NW3（`nw3` ALPN、远端 Egress 角色、`egress://`），与 NW2 线协议不兼容，且没有协议协商或回落。本管理器只面向 **v2.x 线**；`latest-v2` 仍解析为最新的稳定 v2 版本（当前为 `v2.2.1`）。

---

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

### 8.3 备份配置与证书

```bash
# 默认备份到 /root/nowhere-v2-backup-<时间戳>.tar.gz
sudo bash nowhere-v2.sh backup

# 或指定输出路径
sudo bash nowhere-v2.sh backup /root/my-backup.tar.gz
```

备份内容为 `/etc/nowhere-v2`（运行配置、管理元数据、TLS 证书），不含二进制。

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
| `backup [路径]` | 备份配置与证书 |
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

---

## 13. V3 通道（NW3）

> `nowhere-v3.sh` 是面向 Nowhere **v3.x** 的**独立管理器**，与 V2 完全隔离（独立服务、账户、路径、端口），不会转换或触碰 V2 安装。NW3 与 NW2 线协议不兼容，没有协商或回落。

### 13.1 快速开始

```bash
# 下载
wget https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v3.sh -O nowhere-v3.sh
chmod 700 nowhere-v3.sh && bash -n nowhere-v3.sh

# 新建 Portal（默认固定 v3.0.0）。不传 --cert/--tls-key 时自动生成持久自签 PEM，
# 客户端 pin 永久稳定。
sudo bash nowhere-v3.sh install --version v3.0.0 --public-host relay.example.com

# 或使用你自己的证书
sudo bash nowhere-v3.sh install --public-host relay.example.com \
  --cert /etc/letsencrypt/live/relay.example.com/fullchain.pem \
  --tls-key /etc/letsencrypt/live/relay.example.com/privkey.pem

sudo bash nowhere-v3.sh doctor
sudo bash nowhere-v3.sh links        # Vector（及 Egress）URL，均自带 pin
sudo bash nowhere-v3.sh telemetry    # 只读统计（NW3 已取消 TUI）
```

- **Vector**：把输出的 `vector://` URL 保存为权限 600 的文件，执行 `sudo bash nowhere-v3.sh install --url-file /root/vector-v3.url`（SOCKS5 监听 `127.0.0.1:1083`）。
- **Egress（远程出口）**：Portal 用 `--out egress` 安装；把输出的 `egress://` URL 传到出口机器并 `install --url-file`。一个 Portal 只接受一个已注册 Egress，其离线时不会回退直连。
- **跟进 v3.x**：默认固定已核验的 `v3.0.0`；用 `upgrade --version latest-v3` 显式跟进更新的稳定 v3 版本。

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

### 13.3 v1.1.0 日常操作

无参数运行进入22项循环菜单；安装/重配提供Portal、Vector、Egress向导。
菜单失败在独立子shell恢复事务后返回；无终端读取失败直接退出。

```bash
sudo bash nowhere-v3.sh                         # 完整菜单
sudo bash nowhere-v3.sh install --yes           # 默认Portal、2083、持久PEM
bash nowhere-v3.sh versions                     # 所有稳定V3，数值倒序
bash nowhere-v3.sh check-updates
bash nowhere-v3.sh generate-key                 # 仅输出32位小写hex
sudo bash nowhere-v3.sh probe example.com:443    # 脱敏URL + Result
sudo bash nowhere-v3.sh doctor --probe          # 探测失败仅警告
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
默认仍固定v3.0.0，跟进新版本必须显式`upgrade --version latest-v3`。
自更新验证Bash语法、V3通道与版本，拒绝降级，同目录原子替换并保留备份；
不更新服务、配置或内核。来源默认本仓库main，可通过NOWHERE_V3_SELF_URL覆盖。

`links`输出带pin的原生Vector/Egress URL，以及每个carrier对应的
`nowhere://KEY@host:port?net=tcp|udp&morph=0|1#NAME`。
分享链接不携带pin；自签证书应将`fingerprint`结果添加到客户端信任列表。
`fingerprint` 无参数查本机；`fingerprint 'nowhere://KEY@HOST:PORT?morph=0|1'` 查**远端**证书指纹（v1.2.0 起；强制 TCP/TLS、链接打码，`net=udp` 链接同样适用）——请带外核对后再用作 pin 或客户端信任项。
若安装了qrencode则显示二维码，否则静默跳过。链接含密钥勿外传。
`generate-key`与`fingerprint`是明确的密钥/指纹输出例外；其他状态、日志和probe输出脱敏。

Portal probe需要PUBLIC_HOST，可临时传`--public-host`；持久证书读取本机PEM指纹，
临时tls=1用官方内核探测本机TCP指纹；纯UDP临时证书无法核实时拒绝链接/探测。
Egress角色不能发起probe。Egress自身可使用dial*；只有Portal的out=egress禁止dial*。
重配同角色复用PEM；明确提供--cert/--tls-key才轮换；角色切换仍需确认或--allow-role-switch。
本版未实现可选的`backup --restore`，不要将普通备份命令当作恢复功能。

## 测试

逻辑部分由沙箱测试覆盖，**不需要 root、不联网**：

```bash
bash tests/nowhere-v2.test.sh
bash tests/nowhere-v3.test.sh
```

它在 source 之前会把管理器的路径声明改写到一个临时目录，因此**永远不会碰到真实的
`/etc/nowhere-v2` 或 systemd**；而且一旦某条声明被改名，测试会**直接中止**，而不是悄悄
落到真实路径上。CI 每次 push 都会连同 `bash -n` 与 `shellcheck` 一起跑它。

**集成部分没有自动化覆盖。** 安装、升级、systemd 这些流程**从未被测试套件执行过**。
在依赖某个版本之前，请在一台一次性 VPS 上跑一遍 [`ACCEPTANCE.md`](ACCEPTANCE.md)。

---

## 许可

本项目采用 [GPL-3.0](LICENSE) 许可，与上游 [NodePassProject/Nowhere](https://github.com/NodePassProject/Nowhere) 保持一致。
