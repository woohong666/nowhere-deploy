# Nowhere 一键部署脚本（Linux VPS）

> 两个脚本，同一个目标，不同的信任取舍。**先看第 0 节决定用哪个。**
>
> 适用环境：systemd Linux、x86_64 或 aarch64、root 或 sudo 权限
> 默认上游版本：`v1.8.3`

## 0. 两个脚本怎么选

| | `install.sh` | `install-source.sh` |
|---|---|---|
| 二进制来源 | 下载官方预编译 Release | **在你这台机器上编译** |
| 首次安装 | 约 1 分钟 | **20–60 分钟**（1 核 VPS） |
| 升级 | 约 1 分钟 | **20–60 分钟**（重新编译） |
| 完整性校验 | 官方 GitHub API 公布的 SHA-256 digest，拿不到就拒绝安装 | 编译产物，无需校验 |
| 额外依赖 | `curl` `python3` `tar` `sha256sum` | 另需 `git` 和 C 编译器（自动装），Rust 工具链（自动装） |
| 磁盘 | 几十 MB | 构建期 5 GB 以上 |
| 需要信任 | ① 上游发布的二进制 ② crates.io ③ rustup 工具链 | ① 上游源码 ② crates.io ③ rustup 工具链 |

**怎么选：**

- **只想快点用上** → `install.sh`。这是绝大多数人的选择，脚本本身仍然是你自己能通读的，只是它下载的是别人编译好的二进制。
- **就是不想信任别人编译的二进制** → `install-source.sh`。用 20–60 分钟换「产物可追溯到源码」。
- **拿不准** → 先用 `install.sh` 装上跑通，以后想换随时换（见 §10，两个脚本可以互相接管，配置和服务都不用动）。

### 0.1 信任边界（请如实理解）

无论哪条路，下面这三层都**没有**被解决，这是在一台 VPS 上能做到的合理上限，不是零信任：

| 环节 | install.sh | install-source.sh |
|---|---|---|
| 第三方一键脚本本身有后门 | ✅ 解决（脚本可通读，不 `curl \| bash`） | ✅ 解决 |
| 预编译二进制被植入后门 | ⚠️ 部分（只能靠官方 digest 比对，信任 GitHub 与上游发布流程） | ✅ 解决（不下载任何二进制） |
| 上游**源码**本身有问题 | ❌ 未解决 | ❌ 未解决（可用 `--commit` 锁到你审过的提交） |
| 依赖链（crates.io 上的 200+ 个 crate） | ❌ 未解决 | ❌ 未解决（最强做法是 `cargo vendor`，见 §9.3） |
| Rust 工具链（rustup 下发的官方构建） | ❌ 不涉及 | ⚠️ 部分解决（有 SHA-256 校验，可 `--trust-rustup-sha` 固定） |
| 传输途中被替换 | ✅ HTTPS + digest 校验 | ✅ git 的提交哈希本身就是内容寻址 |

---

## 1. 前置条件

| 项目 | 要求 |
|---|---|
| 系统 | Linux，systemd 正在运行（`ps -p 1 -o comm=` 输出 `systemd`） |
| 架构 | `x86_64` 或 `aarch64` |
| 权限 | root 或 sudo |
| 端口 | 计划使用的端口 ≥ 1024，且未被占用 |
| 网络 | 能访问 github.com（编译版还需 crates.io、static.rust-lang.org） |

编译版额外要求：内存 ≥ 1 GB（< 2 GB 时脚本会自动加临时 swap）、`/var/tmp` 所在分区 ≥ 5 GB 空闲。

编译不需要预装 Rust，脚本会自己装；需要 `git`、`curl` 和一个 C 编译器，缺了会自动调用 `apt-get`/`dnf`/`yum`/`apk`/`zypper` 安装（可用 `--no-install-deps` 禁止）。

### 1.1 为什么编译版需要 C 编译器

Nowhere 的加密后端是 `ring`。它是 Rust 生态的库，但内部有汇编/C 代码，需要 C 编译器参与构建。**好消息**：不像 `aws-lc-rs` 那样还需要 `cmake`、`nasm`、`perl`，也不需要系统 OpenSSL——`build-essential` 级别的工具链就够了。

### 1.2 为什么编译这么慢

上游 `Cargo.toml` 里写死了发布配置：

```toml
[profile.release]
lto = "fat"          # 全程序链接时优化
codegen-units = 1    # 禁止并行代码生成
panic = "abort"
strip = "symbols"
```

`lto = "fat"` + `codegen-units = 1` 优化效果最好，也**最慢、最吃内存**——大部分时间花在单线程的 LTO 阶段。1 核机器上 20–60 分钟属于正常，不是卡死了。内存不足 2 GB 时链接阶段容易 OOM，脚本会自动加临时 swap。

### 1.3 关于 libc（仅 `install.sh`）

`install.sh` 会自动判断该用 GNU 还是 musl 构建。如果 VPS 的 glibc 比官方 GNU 构建所要求的还旧，脚本装上的二进制会跑不起来（报 `GLIBC_2.xx not found`），这时改用静态的 musl 版本：

```bash
sudo bash install.sh install ... --libc musl
```

---

## 2. 快速开始

### 2.1 把脚本传到 VPS

在 Mac 上：

```bash
scp ~/nowhere-deploy/install.sh <VPS用户>@<VPS地址>:/tmp/install.sh
```

登录后先做语法检查（不会执行任何安装动作）：

```bash
ssh <VPS用户>@<VPS地址>
chmod 700 /tmp/install.sh
bash -n /tmp/install.sh          # 只检查语法
```

### 2.2 用 TLS 2（PEM 证书）时，必须先做这一步

Let's Encrypt 的私钥默认是 `600 root:root`，且上级目录 `700`，服务用户 `nowhere` 读不到。**不要**放宽原证书的权限，而是复制一份：

```bash
sudo bash /tmp/install.sh prepare-tls \
  --cert /etc/letsencrypt/live/<节点域名>/fullchain.pem \
  --tls-key /etc/letsencrypt/live/<节点域名>/privkey.pem
```

它会创建 `nowhere` 用户/组，把证书复制到 `/etc/nowhere/tls/`（`640 root:nowhere`），并打印出接下来要用的路径。**每次证书续期后都要重跑一次**，或把它写进 certbot 的 deploy hook。

> 只想先跑通、不折腾证书？把下面命令里的 `--tls 2 --cert ... --tls-key ...` 换成 `--tls 1` 即可，客户端会接受临时自签证书。生产环境不要这么用。

### 2.3 安装

```bash
sudo bash /tmp/install.sh install \
  --key '<至少16字符的共享密钥>' \
  --port 2077 \
  --net mix \
  --tls 2 \
  --cert /etc/nowhere/tls/fullchain.pem \
  --tls-key /etc/nowhere/tls/privkey.pem
```

装完脚本会直接打印客户端要用的 `portal://` 链接（含密钥，注意别泄露）。

**编译版的话，把脚本名换成 `install-source.sh`，其余完全一样。** 编译要跑半小时，建议放在 `tmux` 里，免得 SSH 断线白等：

```bash
tmux new -s nowhere
sudo bash /tmp/install-source.sh install --key '...' --port 2077 --tls 1
# Ctrl+B 然后按 D 脱离；随时 tmux attach -t nowhere 回来看
```

### 2.4 编译失败会怎样

没有 dry-run 模式。失败时脚本直接退出：**不会**写配置、**不会**创建 systemd 服务、**不会**动 `current` 软链（升级场景还会自动切回旧版本）。

留下的残留只有 `nowhere` 系统用户和 `/var/tmp/nowhere-build` 构建树。用 `install-source.sh clean-build` 清掉，或者加 `--keep-source` 留着——重跑同一版本会复用 cargo 缓存，比第一次快得多。

---

## 3. 参数说明

### 3.1 两个脚本都有的（服务相关）

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--key KEY` | 无（首次必填） | Portal 共享密钥，16–255 字符，只能用 `A-Za-z0-9._~-` |
| `--port PORT` | `2077` | 监听端口，必须 ≥ 1024（服务以非 root 用户运行） |
| `--net MODE` | `mix` | `mix` / `tcp` / `udp`；`mix` 表示 TCP 与 UDP 共用同一端口 |
| `--tls MODE` | `2` | `1` 临时自签证书（重启后指纹变化），`2` 使用 PEM 文件 |
| `--cert PATH` | 无 | `--tls 2` 时必填，证书链（`fullchain.pem`） |
| `--tls-key PATH` | 无 | `--tls 2` 时必填，私钥（`privkey.pem`） |
| `--listen-host HOST` | 空 | 绑定地址；留空使用 Nowhere 的通配默认值 |
| `--purge` | — | 卸载时一并删除 `/etc/nowhere` 与 `/var/lib/nowhere` |

### 3.2 仅 `install.sh`（下载二进制）

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--version TAG` | `v1.8.3` | 要安装的官方 Release tag |
| `--libc MODE` | `auto` | `gnu` / `musl` / `auto`；glibc 太旧时用 `musl` |

### 3.3 仅 `install-source.sh`（编译）

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--version TAG` | `v1.8.3` | 要编译的 git tag |
| `--commit SHA` | 无 | 锁定到具体提交（完整克隆，更慢但可复现）；与 `--version` 二选一 |
| `--git-url URL` | 官方仓库 | 换成你自己的 fork 或镜像 |
| `--jobs N` | cargo 默认 | 限制并行编译任务数，小内存 VPS 上设 `1` |
| `--swap auto\|off\|MB` | `auto` | `auto`：内存 <2G 建 2G swap，<1G 建 4G；也可指定 MB 数 |
| `--keep-source` | 关 | 编译成功后保留 `/var/tmp/nowhere-build`（下次升级可增量编译） |
| `--no-install-deps` | — | 不自动装系统依赖，缺什么直接报错 |
| `--no-install-rust` | — | 不自动装 Rust，版本不够直接报错 |
| `--trust-rustup-sha HEX` | 无 | 要求 rustup-init 的 SHA-256 等于该值 |

---

## 4. 脚本都做了什么

1. 校验版本号、端口、密钥、证书路径，**在开始下载/编译前**把所有廉价检查做完；
2. 检查端口是否被占用（仅首次安装）；
3. 检查证书能否被服务用户读取，读不到就报错并给 `prepare-tls` 的用法；
4. `install.sh`：向 GitHub API 索取该资产的 SHA-256 digest，下载后比对，不符即中止；`install-source.sh`：校验并（必要时）安装 Rust 工具链、按需加临时 swap、拉源码、打印 commit、编译；
5. 把二进制装到 `/opt/nowhere/releases/<tag>/nowhere`，写入溯源文件，切换 `/opt/nowhere/current` 软链；
6. 首次安装写 `/etc/nowhere/nowhere.env`（`600`、root 所有），创建 systemd 服务并启动；
7. 服务起不来时：首次安装直接报错并打印日志；升级则自动切回旧版本。

### 4.1 安装后的文件布局

```text
/opt/nowhere/releases/v1.8.3/nowhere        二进制
/opt/nowhere/releases/v1.8.3/BUILD-INFO     溯源信息（编译版）
/opt/nowhere/releases/v1.8.3/RELEASE-INFO   溯源信息（二进制版）
/opt/nowhere/current -> /opt/nowhere/releases/v1.8.3
/usr/local/bin/nowhere -> /opt/nowhere/current/nowhere
/etc/nowhere/nowhere.env                    配置（600，含 portal:// 链接与密钥）
/etc/nowhere/tls/                           prepare-tls 复制的证书（640 root:nowhere）
/etc/systemd/system/nowhere.service         服务单元（含 systemd 沙箱加固）
/var/lib/nowhere/                           服务状态目录
```

溯源文件用来回答「现在跑的到底是哪份东西」，编译版长这样：

```text
repository:   https://github.com/NodePassProject/Nowhere.git
tag:          v1.8.3
commit:       1a2b3c...
built_at:     2026-09-10T05:12:33Z
toolchain:    rustc 1.89.0 (29483883e 2025-08-01)
binary_sha256: 9f8e...
```

二进制版长这样：

```text
repository:   https://github.com/NodePassProject/Nowhere
tag:          v1.8.3
asset:        nowhere-x86_64-unknown-linux-gnu.tar.gz
source:       official prebuilt Release (not compiled locally)
asset_sha256: <GitHub API 公布的 digest>
binary_sha256: <解包后二进制的实际校验和>
```

### 4.2 systemd 沙箱

服务以系统用户 `nowhere`（无登录 shell）运行，单元文件里开启了 `NoNewPrivileges`、`ProtectSystem=strict`、`ProtectHome`、`PrivateTmp`、`PrivateDevices`、`RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`、`CapabilityBoundingSet=`（清空 capabilities）等加固项，并把监听端口限制在 1024 以上，避免服务持有 root 能力。

---

## 5. 客户端连接

安装完成后脚本会打印链接，也可以随时再取（两个脚本都有）：

```bash
sudo bash /tmp/install.sh link
```

链接格式（`--tls 2`）：

```text
portal://<共享密钥>@<域名或IP>:<端口>?tls=2&crt=<已编码的证书路径>&key=<已编码的私钥路径>
```

`--net` 不是 `mix` 时会多一个 `&net=tcp` 或 `&net=udp`。

把这条链接导入客户端即可。**它等同于密码**：`portal://` 里的共享密钥一旦泄露，任何人都能用你的节点。不要提交到 Git、不要贴到聊天记录里。

---

## 6. 放行端口

云厂商安全组和系统防火墙都要放行（`--net mix` 时 TCP 和 UDP 都要）：

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

确认监听：

```bash
sudo ss -lntup | grep ':2077'
sudo systemctl is-active nowhere
```

---

## 7. 日常运维

```bash
sudo bash /tmp/install.sh status     # 服务状态 + 当前版本目录
sudo bash /tmp/install.sh logs       # 跟踪日志（Ctrl+C 退出）
sudo bash /tmp/install.sh restart
sudo bash /tmp/install.sh link       # 打印客户端链接

readlink /opt/nowhere/current                     # 当前跑的是哪个版本
cat /opt/nowhere/current/BUILD-INFO               # 溯源信息（编译版）
sudo journalctl -u nowhere -n 100 --no-pager      # 最近日志
```

两个脚本都是**无状态**的：每次都从磁盘上的实际状态判断该做什么，放在 `/tmp` 下丢了也没关系，重新拷一份即可（建议连同文档一起放到 `/root/` 或自己的 Git 仓库里）。

---

## 8. 升级、回滚与重新编译

### 8.1 升级

```bash
# 先看上游最新 tag：https://github.com/NodePassProject/Nowhere/releases
sudo bash /tmp/install.sh upgrade --version v1.9.0
```

升级会重新下载（或重新编译）并切换软链、重启服务，**保留 `/etc/nowhere/nowhere.env` 不变**。升级不会改配置：`--port`、`--key`、`--tls`、`--cert` 这些参数在升级时**不生效**。

升级前建议：

```bash
sudo cp -a /etc/nowhere /etc/nowhere.backup.$(date +%F-%H%M%S)
readlink /opt/nowhere/current        # 记下旧版本，回滚要用
```

### 8.2 回滚

```bash
sudo bash /tmp/install.sh rollback
```

回滚只是把 `current` 软链指向上一个发布目录并重启，**不重新下载/编译**，秒级完成。前提是旧版本目录还在——脚本从不主动删除旧版本目录。手动删过 `/opt/nowhere/releases/` 里的目录就没法回滚了。

### 8.3 修改配置（端口/证书/密钥）

脚本刻意不允许在 upgrade 时改配置，避免「以为改了其实没改」。要改配置，直接编辑再重启：

```bash
sudo cp /etc/nowhere/nowhere.env /etc/nowhere/nowhere.env.bak
sudo vi /etc/nowhere/nowhere.env     # 改 NOWHERE_PORTAL
sudo systemctl restart nowhere
sudo systemctl is-active nowhere
```

`NOWHERE_PORTAL` 的值就是那条 `portal://` 链接。改端口后记得同步放行新端口的防火墙规则。

### 8.4 重新编译当前版本（仅编译版）

想验证一次「我本地编译的和现在跑的是一样的」，或怀疑二进制被替换：

```bash
sudo bash /tmp/install-source.sh upgrade --version v1.8.3 --keep-source
cat /opt/nowhere/releases/v1.8.3/BUILD-INFO    # 对比 binary_sha256
```

### 8.5 清理构建缓存（仅编译版）

```bash
sudo bash /tmp/install-source.sh clean-build     # 删除 /var/tmp/nowhere-build 和遗留的 swapfile
```

默认编译成功后脚本会自己清掉构建树（约 2–4 GB）；用 `--keep-source` 才会保留，代价是占磁盘、好处是下次升级增量编译快很多。

---

## 9. 安全说明

### 9.1 安装期

- 两个脚本都以 root 运行，所有下载都走 HTTPS；
- `install.sh` 在 digests 缺失或校验不符时**拒绝安装**，并且从不解压后再执行任何网络内容；
- `install-source.sh` 编译在 `/var/tmp/nowhere-build` 进行，源目录权限 700，rustup-init 会校验 SHA-256；
- 配置文件 `600`、root 所有，服务用户只能通过 systemd 读取其中的环境变量。

### 9.2 运行期

- 服务以 `nowhere` 用户运行，无 shell、无 capabilities、`ProtectSystem=strict`；
- 二进制放在 `/opt/nowhere`，普通用户不可写；软链由 root 掌控。

### 9.3 想要更强的可复现性

```bash
# 1) 锁定到你审计过的提交
sudo bash /tmp/install-source.sh upgrade --commit <40位SHA>

# 2) 固定 rustup 的指纹（从可信渠道获取后传入）
sudo bash /tmp/install-source.sh install ... --trust-rustup-sha <rustup-init的SHA256>
```

`--locked` 只保证**依赖版本**由仓库里的 `Cargo.lock` 决定，依赖包本身仍是从 crates.io 下载的。要做到完全不依赖网络分发，可以在构建机上 `cargo vendor` 后把依赖树一起放进仓库，再改成 `--offline` 构建——这是更强也更重的方案，需要时再来做。

---

## 10. 两个脚本的关系

**它们可以互相接管。** 两个脚本使用完全相同的路径、配置文件和 systemd 服务名：

```text
/opt/nowhere/current          /etc/nowhere/nowhere.env
/etc/systemd/system/nowhere.service
```

所以迁移就是跑一次 `upgrade`，配置和服务都不用动：

```bash
# 二进制版 → 编译版（开始自己编译）
sudo bash /tmp/install-source.sh upgrade --version v1.8.3

# 编译版 → 二进制版（不想再等编译了）
sudo bash /tmp/install.sh upgrade --version v1.8.3
```

注意两点：

1. `upgrade` 会**覆盖同一个 tag 的 release 目录**（`/opt/nowhere/releases/<tag>/`），所以迁移后 `BUILD-INFO` 会变成 `RELEASE-INFO`（或反之），不会并存；
2. 想保留旧的那份，迁移前先 `readlink /opt/nowhere/current` 记下路径，或把旧目录复制一份。

---

## 11. 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| `Install a C compiler` / 编译中断 | 编译版缺工具链；去掉 `--no-install-deps` 重跑 |
| `rustc ... is older than 1.85.0` | 编译版：系统 rustc 太旧，脚本会自动装新工具链；用 `--no-install-rust` 时需自己装 |
| 编译中途 `signal: 9` / `Killed` | 编译版内存不足，LTO 阶段被 OOM Killer 杀掉。用 `--swap 4096` 或 `--jobs 1` 重跑；保留源码树可增量续编 |
| 编译很久没动静 | `lto="fat"` + `codegen-units=1` 的单线程链接阶段，属正常。看 `top` 确认 rustc/cc 仍在吃 CPU |
| `GitHub did not publish a SHA-256 digest` | 二进制版：官方没为这个资产公布 digest，脚本拒绝安装。别绕过，改用编译版 |
| `SHA-256 mismatch` | 二进制版：下载内容与官方 digest 不符。**不要跳过校验**，换网络重试；持续出现要警惕 |
| `GLIBC_2.xx not found` | 二进制版：官方 GNU 构建要求更新的 glibc。加 `--libc musl` 装静态版本 |
| `Could not download rustup-init` | 编译版：到 static.rust-lang.org 不通；换网络或手动装好 Rust 后加 `--no-install-rust` |
| `git clone failed` | 编译版：到 github.com 不通；可用 `--git-url` 指向自己的镜像/fork（注意这会把信任转移到镜像方） |
| `Need ~...MB free on /` | 编译版磁盘不够，清理后重试，或先 `clean-build` |
| `Port 2077 is already in use` | 换端口或停掉冲突服务 |
| `Service user nowhere cannot read certificate` | 私钥权限问题。用 `prepare-tls --cert ... --tls-key ...` 复制一份，**不要** `chmod 644` 私钥 |
| 服务起不来 | `journalctl -u nowhere -n 100 --no-pager`；常见是证书路径、端口被占、URI 写错 |
| 外部连不上 | 按顺序查：服务是否 active → `ss -lntup` 是否监听 → 系统防火墙 → 云安全组 → DNS |
| 证书续期后客户端报错 | 重跑一次 `prepare-tls`，再 `systemctl restart nowhere`；可放进 certbot 的 deploy hook，但先在维护窗口手动验证一次 |

---

## 12. 卸载

```bash
# 只删服务和二进制，保留配置与状态
sudo bash /tmp/install.sh uninstall

# 连配置和密钥一起删（不可逆，先备份）
sudo bash /tmp/install.sh uninstall --purge
```

两个脚本的卸载行为一致。`--purge` 会删掉 `/etc/nowhere`（含 `portal://` 链接）和 `/var/lib/nowhere`。

---

## 13. 变更记录模板

```text
日期：
VPS / 节点域名：
操作：首次安装 / 升级 / 回滚 / 改配置 / 重新编译 / 换脚本
使用的脚本与版本：
目标版本与 commit：
端口与网络模式：
TLS 模式与证书路径：
执行命令：
编译耗时 / 峰值内存：
执行前服务状态：
执行后服务状态：
binary_sha256：
遇到的问题与处理：
下一步：
```
