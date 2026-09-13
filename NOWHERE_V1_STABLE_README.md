# Nowhere V1 稳定版一键管理脚本说明（`nowhere-v1.sh`）

> 管理脚本版本：**v2.5.3**  
> 固定 Nowhere 核心：**v1.8.3**  
> 通道：**V1 Stable / v1-stable**  
> 目标：稳定优先，不追随 `latest`，不跨代升级到 Nowhere v2。

## 1. 为什么固定在 Nowhere v1.8.3

Nowhere 官方已在 2026-09-11 发布 **v2.0.0**，并将其标记为 Latest。

但 v2.0.0 不是对 v1.x 的普通兼容升级。官方明确说明：

- Nowhere v2 使用新的、**与 v1.x wire-incompatible（线协议不兼容）**的数据面协议。
- v1.x Portal、Vector、原生 `next` 链路以及其它 v1 客户端，**不能直接连接 v2.0.0**。
- 一条业务链路上的 Portal、Vector、`next` 节点和其它客户端必须**一起升级**，不能只升级其中一端。
- v2 固定使用 ALPN `nw2`；v1 的 `now/1`、自定义 ALPN 或缺失 ALPN 都会被 v2 拒绝。
- v2 的认证、Mux framing、QUIC UDP framing、flow-ID 布局都与 v1.x 不兼容。
- v2 改为 carrier-specific endpoint，例如：
  - `HOST:PORT`
  - `HOST/tcp:PORT`
  - `HOST/udp:PORT`
  - `HOST/tcp4:PORT/udp6:PORT`
- v1 的 `net=tcp|udp|mix` 在 v2 中已经不再用于选择 carrier；v2 使用 endpoint path 控制 carrier。
- v2 新增 `morph=0|1`，要求同一 hop 两端配置一致。

官方发布说明：
https://github.com/NodePassProject/Nowhere/releases/tag/v2.0.0

因此，本脚本不再使用 `latest`。为了避免误把 v1 配置套到 v2 核心上，**v2.5.3 明确固定 Nowhere v1.8.3**。

## 2. V2 是否兼容旧版？

**不兼容。**

这里的“不兼容”不是指某个 URL 参数名字不同，而是底层通信协议本身发生了变化。

以下组合不能直接互通：

- V1 Portal ↔ V2 Vector
- V2 Portal ↔ V1 Vector
- V1 Portal `next` ↔ V2 Portal
- V2 Portal `next` ↔ V1 Portal
- 只支持 V1 协议的第三方客户端 ↔ V2 Portal

官方要求：**Upgrade every peer on a traffic path together.**

所以正确做法不是在 V1 脚本里“兼容一点 V2 参数”，而是：

1. 保留一套稳定的 V1 脚本。
2. 单独重写一套 V2 脚本。
3. V2 脚本使用 V2 自己的 endpoint、ALPN、Morph、Mux 和迁移逻辑。
4. 实际迁移时整条链路一起切换。

## 3. v2.5.3 的版本锁定策略

本脚本内部固定：

```bash
SCRIPT_CHANNEL="v1-stable"
PINNED_NOWHERE_VERSION="v1.8.3"
DEFAULT_VERSION="$PINNED_NOWHERE_VERSION"
```

行为如下：

- 默认安装：只安装 `v1.8.3`
- `--version v1.8.3`：允许
- `--version latest`：拒绝
- `--version v2.0.0`：拒绝
- `--version` 其它版本：拒绝
- `NOWHERE_VERSION=latest`：在安装/升级解析版本时拒绝
- 交互式安装：不再访问 GitHub 列版本供选择，直接使用 v1.8.3

这样即使 GitHub 的 Latest 已经变成 v2.x，也不会误升级。

## 4. 自更新的跨代保护

v2.5.3 的 `self-update` 除了原有的：

- HTTPS/TLS 限制
- Bash 语法检查
- `SCRIPT_VERSION` 检查
- `NodePassProject/Nowhere` 项目标识检查
- 原子替换和备份

还增加：

- 必须是 `SCRIPT_CHANNEL="v1-stable"`
- 必须是 `PINNED_NOWHERE_VERSION="v1.8.3"`

如果以后同一个地址放的是 V2 管理脚本，V1 稳定版会拒绝跨代自更新。

建议以后为 V2 使用独立更新地址或独立分支，例如：

```text
main/v1/nowhere-v1.sh
main/v2/nowhere-v2.sh
```

这样 V1/V2 生命周期完全隔离。

## 5. 下载与部署步骤

本仓库的 V1 稳定管理脚本统一命名为 `nowhere-v1.sh`。请不要再使用旧文件名 `nowhere.sh` 或 `nowhere-v1-stable.sh`。

### 5.1 下载脚本并检查

在 VPS 上执行：

```bash
wget https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v1.sh -O nowhere-v1.sh
chmod 700 nowhere-v1.sh
bash -n nowhere-v1.sh
```

也可以使用 `curl`：

```bash
curl -fsSL https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v1.sh -o nowhere-v1.sh
chmod 700 nowhere-v1.sh
bash -n nowhere-v1.sh
```

### 5.2 交互式部署

```bash
sudo bash nowhere-v1.sh
```

在菜单中选择安装方式：

- `[1] Install prebuilt`：下载并校验官方 Nowhere `v1.8.3` 预编译版本；
- `[2] Build from source`：在 VPS 本机编译固定的 Nowhere `v1.8.3`。

### 5.3 非交互式部署

预编译版本部署示例：

```bash
sudo bash nowhere-v1.sh install \
  --method release \
  --port 2077 \
  --net mix \
  --tls 1 \
  --key 'ChangeThisKey_12345678'
```

生产环境建议使用真实 PEM 证书。先复制证书到脚本管理的安全目录：

```bash
sudo bash nowhere-v1.sh prepare-tls \
  --cert /etc/letsencrypt/live/example.com/fullchain.pem \
  --tls-key /etc/letsencrypt/live/example.com/privkey.pem
```

然后执行生产部署：

```bash
sudo bash nowhere-v1.sh install \
  --method release \
  --port 2077 \
  --net mix \
  --tls 2 \
  --cert /etc/nowhere/tls/fullchain.pem \
  --tls-key /etc/nowhere/tls/privkey.pem \
  --key 'ChangeThisKey_12345678'
```

`nowhere-v1.sh` 内部已固定 Nowhere `v1.8.3`，不需要也不允许通过 `--version` 切换到 `latest` 或 V2。

## 6. 当前稳定版已有的保护

v2.5.3 保留 v2.5.2 已经完成的稳定性设计：

- `set -Eeuo pipefail`
- 不使用容易误触发的全局 `ERR trap`
- 交互式 `read` 从 `/dev/tty` 读取
- 源码构建锁，避免并发构建互相破坏
- 固定临时 swap 路径并由构建锁保护所有权
- 残留 swap 安全清理
- 官方 Release SHA-256 digest 校验
- Rust 安装包 SHA-256 校验
- 安全 tar 路径检查
- 独立 `nowhere` systemd 用户
- 配置快照与配置失败恢复
- TLS 文件快照与恢复
- 新版本启动失败自动回滚
- URL 导入参数预校验
- Portal / Vector 状态检查
- Doctor 健康诊断
- 旧 Release 自动保留/清理
- 自更新语法、来源和通道保护

## 7. 关于 v1.8.3 的长期定位

v1.8.3 应当视为本脚本的“冻结核心”。

这意味着：

- 不再为了追求版本号自动升级核心。
- 只修管理脚本自己的 Bug、安全边界和使用体验。
- 不把 V2 新参数反向塞进 V1 脚本。
- V1 和 V2 分开维护。

如果未来 v1.8.3 本身出现上游公开的严重安全问题，再单独评估是否继续冻结，而不是自动跟随 Latest。

## 8. V2 一键脚本的重写原则

后续 V2 脚本建议重新设计，而不是 fork 当前 V1 解析器后大量打补丁。

至少需要重新实现：

### Endpoint

支持：

```text
HOST:PORT
HOST/tcp:PORT
HOST/udp:PORT
HOST/tcp4:PORT/udp6:PORT
```

并正确处理：

- IPv4
- IPv6
- wildcard
- TCP-only
- UDP-only
- TCP/UDP 独立端口
- 地址族选择

### ALPN

V2 固定：

```text
nw2
```

不再提供 V1 风格的自定义 ALPN 向导。

### `net`

V2 不应继续把 `net=tcp|udp|mix` 当成 carrier 配置。

应通过 endpoint path 控制。

### Morph

新增：

```text
morph=0|1
```

需要检查整条 hop 两端一致。

### Mux

按 V2 的 full-duplex carrier pool 逻辑重新设计配置和提示，不复用 V1 的假设。

### 迁移工具

可以单独做：

```text
v1 URL -> migration hints
```

但不建议静默把 V1 URL 自动转换成 V2 并直接启动。

因为协议不兼容，真正迁移需要同时确认对端版本。

## 9. 推荐的版本规划

```text
管理脚本 v2.5.3
└── V1 Stable
    └── Nowhere core v1.8.3（固定）

未来新脚本
└── V2 Stable
    └── Nowhere core v2.x
```

两个脚本不要共用“自动 latest”逻辑。

## 10. 结论

如果当前目标是：

> 装上以后长期稳定跑，不因为上游 Latest 变更突然跨代升级。

那么 **v2.5.3 + Nowhere v1.8.3 固定核心** 是更合理的方案。

Nowhere v2.0.0 是一次协议代际变化，不是普通小版本升级。V1/V2 分开维护，可以最大程度减少误升级、参数错配和整条链路突然失联的风险。
