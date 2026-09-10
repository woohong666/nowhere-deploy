# Nowhere 一键部署与综合管理脚本（Linux VPS）

[English](README.md) | [简体中文](README.zh-CN.md)

基于 [NodePassProject/Nowhere](https://github.com/NodePassProject/Nowhere) 官方核心协议编写的生产级一键部署与运维管理脚本。

融合了官方 Release 二进制哈希强校验、本地 Rust 源码全程序优化编译（Fat-LTO）、systemd 高强度权限沙箱、Let's Encrypt 证书权限隔离，以及支持中 / 英 / 俄三语的终端彩色交互控制台（TUI）。

---

## 目录

- [0. 下载与运行脚本](#0-下载与运行脚本)
- [1. 核心特性对比与选型](#1-核心特性对比与选型)
- [2. 前置环境与准备工作](#2-前置环境与准备工作)
- [3. 快速开始（一键安装）](#3-快速开始一键安装)
  - [3.1 交互控制台模式（推荐新手）](#31-交互控制台模式推荐新手)
  - [3.2 命令行无交互部署（自动化 / 脚本）](#32-命令行无交互部署自动化--脚本)
- [4. TLS 证书配置与权限安全处理](#4-tls-证书配置与权限安全处理)
- [5. 防火墙与网络放行](#5-防火墙与网络放行)
- [6. 客户端连接与导入](#6-客户端连接与导入)
- [7. 日常运维与服务管理](#7-日常运维与服务管理)
- [8. 版本升级、无损回滚与卸载](#8-版本升级无损回滚与卸载)
- [9. 完整 CLI 命令参数速查表](#9-完整-cli-命令参数速查表)
- [10. 文件结构与安全沙箱布局](#10-文件结构与安全沙箱布局)
- [11. 常见问题排查（FAQ）](#11-常见问题排查faq)

---

## 0. 下载与运行脚本

### 推荐方式：先下载再验证（最安全）

```bash
# 下载统一管理脚本
wget https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere.sh

# 赋予执行权限
chmod +x nowhere.sh

# 以 root 权限运行
sudo bash nowhere.sh
```

### 备选方式：一行命令执行（适用于可信来源）

```bash
curl -fsSL https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere.sh -o nowhere.sh && chmod +x nowhere.sh && sudo bash nowhere.sh
```

> **💡 我该用哪个脚本？**
>
> 本仓库包含三个脚本：
> - **`nowhere.sh`** ← **推荐大多数用户使用**（支持预编译和源码编译两种模式，带 TUI 交互菜单）
> - `install.sh` ← 用于自动化/CI，仅支持预编译二进制
> - `install-source.sh` ← 用于自动化/CI，仅支持源码编译
>
> **如果不确定，就用 `nowhere.sh`** — 它提供了交互式菜单，让你选择喜欢的安装方式。

---

## 1. 核心特性对比与选型

脚本支持两种安装模式，配置与服务接口完全统一，可以随时互相平滑接管：

| 评估维度 | 官方预编译二进制版（Release） | 本地源码编译版（Source） |
|---|---|---|
| **获取方式** | 下载 GitHub 官方打包发布的静态二进制 | **本机直接克隆 Git 源码实时编译** |
| **部署耗时** | 约 1 分钟 | 20–60 分钟（1-2 核 VPS 构建较久） |
| **完整性校验** | 强制查询 GitHub API 比对 SHA-256 Digest，无校验拒绝安装 | 编译产物全部由本机编译器生成，无需额外摘要 |
| **性能表现** | 官方常规发布级编译优化 | 自动启用 `lto = "fat"` + `codegen-units = 1` 极限优化 |
| **额外依赖** | `curl` `python3` `tar` `sha256sum` | 自动安装 `git`、C 编译器与 Rust 1.85+ 工具链 |
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
| **网络环境** | VPS 需能够正常访问 `github.com`（编译版还需连接 `static.rust-lang.org` 与 `crates.io`） |

---

## 3. 快速开始（一键安装）

### 3.1 交互控制台模式（推荐新手）

下载脚本后（参见 [§0](#0-下载与运行脚本)），直接运行：

```bash
chmod +x nowhere.sh
sudo bash nowhere.sh
```

进入后可选择界面语言（支持中文、英文、俄文），随后在 TUI 菜单中输入对应编号：

* 按 `1`：**安装官方预编译版**（输入端口、密钥与证书路径后，1 分钟内完成部署启动）。
* 按 `2`：**本地源码编译安装**（自动配置 Rust 工具链与临时 Swap 并开始编译）。

> **提示**：如果在编译模式下，建议在 `tmux` 或 `screen` 会话中运行，避免网络波动导致 SSH 断开终止编译：
>
> ```bash
> tmux new -s nowhere
> sudo bash nowhere.sh
> # 可随时使用 Ctrl+B 然后按 D 脱离终端；随时执行 tmux attach -t nowhere 回到现场
> ```

---

### 3.2 命令行无交互部署（自动化 / 脚本）

> **⚠️ 重要：v2.5.2 版本 TLS 默认值变更**
>
> 从 v2.5.2 开始，脚本默认使用 **TLS 1（自签名证书）** 用于快速测试。
> 
> **生产环境部署必须显式指定 `--tls 2` 并提供有效证书**，否则客户端会遇到证书验证错误或需要固定证书指纹。

#### 场景 A：快速安装与临时测试（TLS 1 临时自签）

无需申请域名与配置证书，快速验证连通性：

```bash
sudo bash nowhere.sh install \
  --method release \
  --port 2077 \
  --net mix \
  --tls 1 \
  --key 'MyGeneratedKey_12345678'
```

> **注意**：TLS 1 使用自签名证书。客户端必须：
> - 手动信任该证书，或
> - 使用 `sudo bash nowhere.sh show-fingerprint` 查看指纹并固定

#### 场景 B：生产环境部署（TLS 2 强校验 PEM 证书）⭐ 推荐

使用自有的真实域名 PEM 证书（如 Let's Encrypt / acme.sh 颁发）：

```bash
# 1. 复制授权证书，生成专用隔离路径
sudo bash nowhere.sh prepare-tls \
  --cert /etc/letsencrypt/live/example.com/fullchain.pem \
  --tls-key /etc/letsencrypt/live/example.com/privkey.pem

# 2. 启动生产部署
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

## 4. TLS 证书配置与权限安全处理

### 4.1 为什么必须运行 `prepare-tls`？

Let's Encrypt 默认的私钥权限为 `600 root:root`，父目录为 `700`，而非特权用户 `nowhere` 在严格的 systemd 沙箱隔离下无权读取。

**强烈不建议**直接将原证书私钥执行 `chmod 644`，这会破坏系统的安全性。运行 `prepare-tls` 会将证书安全同步到 `/etc/nowhere/tls/` 并将其所属组授权给 `nowhere` 系统用户（`640 root:nowhere`）。

### 4.2 证书自动续期与 Hook 配置

如果使用 Certbot 维护证书，在 `/etc/letsencrypt/renewal-hooks/deploy/nowhere.sh` 写入更新钩子：

```bash
#!/usr/bin/env bash
bash /path/to/nowhere.sh prepare-tls \
  --cert "$RENEWED_LINEAGE/fullchain.pem" \
  --tls-key "$RENEWED_LINEAGE/privkey.pem"
systemctl restart nowhere
```

赋予权限：`chmod +x /etc/letsencrypt/renewal-hooks/deploy/nowhere.sh`。每次证书续期后将自动完成授权与服务热重载。

---

## 5. 防火墙与网络放行

依据你配置的 `--net` 参数类型，在系统防火墙以及云厂商控制台（安全组）放行端口：

### UFW（Ubuntu / Debian）

```bash
# 如果使用 --net mix（TCP 和 UDP 均需放行）
sudo ufw allow 2077/tcp
sudo ufw allow 2077/udp
sudo ufw reload
sudo ufw status numbered
```

### Firewalld（CentOS / RHEL / Fedora / Rocky）

```bash
sudo firewall-cmd --permanent --add-port=2077/tcp
sudo firewall-cmd --permanent --add-port=2077/udp
sudo firewall-cmd --reload
```

---

## 6. 客户端连接与导入

### 6.1 理解链接格式

**Nowhere 使用两种不同的 URI 格式：**

1. **`portal://`** - 服务端配置格式（内部使用）
   - 用于 Nowhere 服务启动服务器
   - 存储在 `/etc/nowhere/nowhere.env`
   - **不能用于客户端导入！**

2. **`nowhere://`** - 客户端连接链接（用于 Anywhere 2.0）
   - 格式：`nowhere://shared-key@relay.example:2077?up=udp&down=udp#Nowhere%20VPS`
   - 这才是导入到 Anywhere 客户端的正确格式
   - 参数 `up`/`down` 指定上行/下行载波策略：`tcp`、`udp` 或 `mix`
   - TCP 模式会自动启用多路复用 (`mux=1`)
   - TLS 2 + 域名时自动添加 SNI 参数

### 6.2 获取客户端连接链接

部署完成后，使用管理脚本生成客户端可导入的 `nowhere://` 链接：

```bash
# 自动检测公网 IP 并生成链接
sudo bash nowhere.sh client-link

# 手动指定服务器域名或 IP（优先级高于配置）
sudo bash nowhere.sh client-link --host relay.example.com

# 自定义节点显示名称
sudo bash nowhere.sh client-link --name "US-NYC-01"
```

**注意：**
- 早期版本的 Nowhere 二进制不提供 `client-link` 子命令，脚本会根据存储的 `portal://` 配置自行构建 `nowhere://` 链接
- TLS 模式 1（自签名证书）需要客户端信任或固定证书指纹才能连接
- `--host` 优先级：命令行参数 > 配置文件中的 `LISTEN_HOST` > 自动检测的公网 IP


> **注意**：具体命令语法取决于你的 Nowhere 版本。如果上述命令不工作，请查看官方 [Nowhere 文档](https://github.com/NodePassProject/Nowhere) 了解正确语法。

### 6.3 安全警告

* **mix 模式**：TCP 与 UDP 共用该端口。
* **保管好你的链接**：连接链接包含了共享密钥。任何人获得该链接都可以将你的 VPS 作为出口代理。严禁发送至公共群组或上传至公开仓库！

### 6.4 查看服务端配置（高级）

查看内部服务端配置（不用于客户端）：

```bash
sudo bash nowhere.sh link
```

这会显示 systemd 服务使用的 `portal://` URI。

---

## 7. 日常运维与服务管理

无论在何种安装模式下，都可以使用以下通用快捷指令：

```bash
# 打开交互控制菜单
sudo bash nowhere.sh menu

# 查看服务状态与当前跑的发布版本
sudo bash nowhere.sh status

# 跟踪查看系统实时日志（Ctrl+C 退出）
sudo bash nowhere.sh logs

# 重启 Nowhere 服务
sudo bash nowhere.sh restart

# 原生 systemctl 操作
sudo systemctl status nowhere
sudo systemctl restart nowhere
```

---

## 8. 版本升级、无损回滚与卸载

### 8.1 版本升级

```bash
# 升级至指定的官方最新 release tag
sudo bash nowhere.sh upgrade --version v1.9.0
```

升级时将保留 `/etc/nowhere/nowhere.env` 配置不变。如果新版本启动检测失败，脚本会自动切回旧版本，防止服务失联。

### 8.2 秒级无损回滚

当新版本出现异常时，直接执行回滚命令：

```bash
sudo bash nowhere.sh rollback
```

脚本会将软链指向上一个编译 / 运行成功的目录并重启服务，无需重新下载或编译，秒级生效。

### 8.3 清理与卸载

```bash
# 清理源码编译残留缓存与临时 Swap
sudo bash nowhere.sh clean-build

# 卸载程序本体与 systemd 服务（保留 /etc/nowhere 中的配置与密钥）
sudo bash nowhere.sh uninstall

# 彻底卸载（一并删除所有配置、证书授权与运行状态，不可逆）
sudo bash nowhere.sh uninstall --purge
```

---

## 9. 完整 CLI 命令参数速查表

| 参数 | 默认值 | 作用说明 |
| --- | --- | --- |
| `--method MODE` | `release` | 指定安装模式：`release`（预编译）或 `source`（本地编译） |
| `--key KEY` | 自动生成 | Portal 共享密钥（16–255 字符，仅限字母数字及 `._~-`） |
| `--port PORT` | `2077` | 监听端口（必须在 `1024-65535` 范围内） |
| `--net MODE` | `mix` | 网络协议：`mix`（TCP/UDP 同端口混用）、`tcp`、`udp` |
| `--tls MODE` | `2` | TLS 模式：`1`（临时自签证书）、`2`（本地 PEM 证书文件） |
| `--cert PATH` | 无 | 证书全链路径（`fullchain.pem`），TLS 2 必填 |
| `--tls-key PATH` | 无 | 私钥文件路径（`privkey.pem`），TLS 2 必填 |
| `--version TAG` | `v1.8.3` | 指定拉取的 GitHub Release 或 Git Tag 版本 |
| `--libc MODE` | `auto` | C 库兼容选项（预编译模式）：`auto`、`gnu` 或 `musl` |
| `--commit SHA` | 无 | 锁定源码构建的精确 Git Commit Hash（编译模式） |
| `--jobs N` | 核心数 | 限制 cargo 编译并行任务数，建议 1 核机器设为 `1` |
| `--swap MODE` | `auto` | 临时 Swap 控制：`auto`、`off` 或自定义大小（MB） |
| `--keep-source` | 关 | 编译后保留构建树与缓存，加速下一次增量编译 |
| `--lang LANG` | `ask` | 界面语言：`zh`（中文）、`en`（英文）、`ru`（俄文） |

---

## 10. 文件结构与安全沙箱布局

安装完成后，系统内的文件分布如下：

```text
/opt/nowhere/
├── releases/
│   ├── v1.8.3-prebuilt-xxxxxxxxxxxx/     # 官方预编译二进制发布目录
│   │   ├── nowhere
│   │   └── RELEASE-INFO                  # 官方下载与摘要审计凭据
│   └── v1.8.3-source-yyyy-zzzzzzzzzzzz/  # 本地源码编译发布目录
│       ├── nowhere
│       └── BUILD-INFO                    # 源码编译器、Commit Hash 溯源凭据
└── current -> releases/...               # 原子软链，指向当前激活目录

/usr/local/bin/nowhere -> /opt/nowhere/current/nowhere  # 全局可执行软链

/etc/nowhere/
├── nowhere.env                           # 运行配置文件（权限 600，仅 root 可读写）
└── tls/
    ├── fullchain.pem                     # 授权证书（权限 640，root:nowhere）
    └── privkey.pem                       # 授权私钥（权限 640，root:nowhere）

/etc/systemd/system/nowhere.service       # systemd 安全隔离沙箱单元
/var/lib/nowhere/                         # 服务运行专用主目录与状态目录
```

---

## 11. 常见问题排查（FAQ）

### Q1: 运行提示 `GLIBC_2.xx not found`

* **根因**：系统环境自带的 glibc 版本低于官方构建 GNU 库的编译环境。
* **解决**：使用官方静态编译的 musl 构建重新安装：

```bash
sudo bash nowhere.sh install --method release --libc musl [其他参数...]
```

### Q2: 源码编译被中止，报 `signal: 9 Killed`

* **根因**：全程序链接时优化（Fat-LTO）消耗内存超出物理上限，被系统 OOM Killer 强制终结。
* **解决**：指定分配更大的临时 Swap，并限制并行进程数重试：

```bash
sudo bash nowhere.sh install --method source --swap 4096 --jobs 1 [其他参数...]
```

### Q3: 报错 `GitHub did not publish a SHA-256 digest`

* **根因**：脚本启用零信任验证，由于官方 Release 构建流程偶尔未落盘对应文件的哈希摘要，脚本主动中止下载。
* **解决**：改用本地源码编译模式运行：`--method source`。

### Q4: 提示 `Service user nowhere cannot read certificate`

* **根因**：TLS 2 模式直接引用了原生 Let's Encrypt 私钥，服务用户无权限读取。
* **解决**：务必先执行 `sudo bash nowhere.sh prepare-tls --cert ... --tls-key ...`，并使用该命令输出的 `/etc/nowhere/tls/` 路径作为参数。

### Q5: 客户端无法连接或握手超时

* **排查步骤**：
  1. 检查服务存活：`sudo systemctl status nowhere`；
  2. 检查本地端口监听：`sudo ss -lntup | grep 2077`；
  3. 检查系统防火墙（UFW / Firewalld）是否放行了对应端口与协议（TCP/UDP）；
  4. 检查 VPS 服务商后台（如阿里云、腾讯云、AWS、甲骨文等）的**安全组入站规则**是否放行该端口；
  5. 确认域名解析是否生效且未开启 CDN 代理（需直连）。
