# 真机验收清单（`nowhere-v2.sh`）

> 这份清单用来补上**自动化测试覆盖不到的那一块**：真实的 Linux + systemd 环境。
> 仓库里的 `tests/nowhere-v2.test.sh` 验证的是逻辑，**从未在真机上跑过安装流程**。
> 请在一台**可以随时销毁的 VPS** 上逐条执行，并在末尾的表格里记录结果。

---

## 0. 准备

| # | 操作 | 期望 |
|---|---|---|
| 0.1 | 准备一台**一次性** VPS（Debian 12 / Ubuntu 22.04 优先），先做快照 | 有快照可回滚 |
| 0.2 | `uname -m` | `x86_64` 或 `aarch64` |
| 0.3 | `ps -p 1 -o comm=` | `systemd` |
| 0.4 | 下载脚本并做语法检查（见下） | `bash -n` 无输出 |

```bash
cd /root
wget https://raw.githubusercontent.com/woohong666/nowhere-deploy/main/nowhere-v2.sh
chmod 700 nowhere-v2.sh
bash -n nowhere-v2.sh && echo "syntax OK"
```

> 本清单假定全程使用 `/root/nowhere-v2.sh`。

---

## 1. 全新安装（release + portal + TLS 1）

```bash
sudo bash nowhere-v2.sh install -y \
  --type portal --endpoint '*:2082' \
  --key 'AcceptanceKey_1234567890' --tls 1
```

| # | 检查 | 期望 |
|---|---|---|
| 1.1 | 命令退出码 | `0` |
| 1.2 | `systemctl is-active nowhere-v2` | `active` |
| 1.3 | `systemctl is-enabled nowhere-v2` | `enabled` |
| 1.4 | `readlink -f /usr/local/bin/nowhere-v2` | 指向 `/opt/nowhere-v2/current/nowhere` |
| 1.5 | `/usr/local/bin/nowhere-v2 --version` | `nowhere-v2.x.y linux/<arch>` |
| 1.6 | `cat /opt/nowhere-v2/current/RELEASE-INFO` | 有 `tag:` / `asset_sha256:` / `binary_sha256:` |
| 1.7 | `ls -l /etc/nowhere-v2/url.conf` | `640 root:nowhere-v2` |
| 1.8 | `ss -lntup \| grep 2082` | TCP 与 UDP 都在监听 |
| 1.9 | `journalctl -u nowhere-v2 -n 20 --no-pager` | 无 panic / 无 `must be low7 or full8` 之类错误 |

> **1.10（重点回归）** 安装的 core 版本应等于官网最新稳定版：
> ```bash
> curl -s https://api.github.com/repos/NodePassProject/Nowhere/releases \
>   | python3 -c 'import json,sys,re;t=[r["tag_name"] for r in json.load(sys.stdin) if re.fullmatch(r"v2\.\d+\.\d+",r["tag_name"]) and not r["prerelease"] and not r["draft"]];print(max(t,key=lambda s:tuple(map(int,s[1:].split(".")))))'
> grep '^tag:' /opt/nowhere-v2/current/RELEASE-INFO
> ```
> 两者应一致 —— 这验证 `DEFAULT_CORE_VERSION="latest-v2"` 真的跟随官网。

---

## 2. 状态 / 链接 / 指纹 / 日志

```bash
sudo bash nowhere-v2.sh status
sudo bash nowhere-v2.sh configure --public-host <你的公网IP>
sudo bash nowhere-v2.sh links
sudo bash nowhere-v2.sh fingerprint
```

| # | 检查 | 期望 |
|---|---|---|
| 2.1 | `status` 输出的 `Core installed` | 是**实际安装**的版本，不是 `latest-v2` |
| 2.2 | `links` | 输出 Native V2 Vector URL 与 Generic V2 share URI |
| 2.3 | `links` 里的 host | 是你指定的公网 IP |
| 2.4 | `fingerprint` | 输出 64 位十六进制 SHA-256 |
| 2.5 | `ss -lntup \| grep 2082` | 端口未因 configure 而改变 |

---

## 3. TLS 2 + `--copy-cert`

```bash
# 用自签证书模拟生产证书
mkdir -p /root/tls && cd /root/tls
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout key.pem -out cert.pem -subj '/CN=relay.example.com'
chmod 600 key.pem

sudo bash nowhere-v2.sh configure \
  --url "$(cat /etc/nowhere-v2/url.conf | sed 's/&tls=1//;s/tls=1/tls=2/')" \
  --cert /root/tls/cert.pem --tls-key /root/tls/key.pem --copy-cert
```

| # | 检查 | 期望 |
|---|---|---|
| 3.1 | 退出码 | `0` |
| 3.2 | `ls -l /etc/nowhere-v2/tls/` | `cert.pem` / `key.pem`，`640 root:nowhere-v2` |
| 3.3 | `grep -o 'tls=[0-9]' /etc/nowhere-v2/url.conf` | `tls=2` |
| 3.4 | `grep -o 'crt=[^&]*' /etc/nowhere-v2/url.conf` | 指向 `/etc/nowhere-v2/tls/cert.pem` |
| 3.5 | `systemctl is-active nowhere-v2` | `active` |
| 3.6 | `sudo bash nowhere-v2.sh fingerprint` | 与 `openssl x509 -in /root/tls/cert.pem -noout -fingerprint -sha256` 一致 |

---

## 4. Vector 客户端（第二台机器或本机）

```bash
sudo bash nowhere-v2.sh install -y \
  --type vector --endpoint '<portal-ip>:2082' \
  --key 'AcceptanceKey_1234567890' \
  --vector-socks '127.0.0.1:1082' --tls 2
```

| # | 检查 | 期望 |
|---|---|---|
| 4.1 | `systemctl is-active nowhere-v2` | `active` |
| 4.2 | `ss -lntp \| grep 1082` | 本地 SOCKS5 在监听 |
| 4.3 | `curl -x socks5h://127.0.0.1:1082 -s https://api.ipify.org` | 返回 **Portal 的**公网 IP |
| 4.4 | `journalctl -u nowhere-v2 -n 30 --no-pager` | 无 TLS/ALPN 报错 |

---

## 5. Morph 开关 + 升级告警（重点回归）

| # | 操作 | 期望 |
|---|---|---|
| 5.1 | 两端都 `configure --morph 1` | 退出码 0，服务 active |
| 5.2 | 在 Portal 上 `configure --morph-prelude full8` | 退出码 0 |
| 5.3 | `grep NOW_MORPH_TCP_PRELUDE /etc/systemd/system/nowhere-v2.service` | `=full8` |
| 5.4 | **重启后**再 `systemctl show nowhere-v2 -p Environment` | 仍含 `NOW_MORPH_TCP_PRELUDE=full8` |
| 5.5 | 客户端 `curl -x socks5h://127.0.0.1:1082 https://api.ipify.org` | 仍能通（morph 两端一致） |

> **5.2–5.4 是回归重点**：早期版本 `--morph-prelude` 会被 `manager.conf` 里的旧值静默覆盖。

---

## 6. Doctor / Doctor --fix（**最高优先级回归**）

```bash
# 先设置一个非默认值，再跑 doctor --fix，看它是否被重置
sudo bash nowhere-v2.sh configure --memory-profile memory --morph-prelude full8
grep -E 'MEMORY_PROFILE|MORPH_PRELUDE' /etc/nowhere-v2/manager.conf
sudo bash nowhere-v2.sh doctor
sudo bash nowhere-v2.sh doctor --fix
```

| # | 检查 | 期望 |
|---|---|---|
| 6.1 | `doctor` 退出码 | `0`（全部通过或仅警告） |
| 6.2 | `doctor` 输出 | 端口/服务/配置/用户检查均有结论 |
| 6.3 | `doctor --fix` 后 `grep NOW_TRANSPORT_MEMORY_PROFILE /etc/systemd/system/nowhere-v2.service` | **`=memory`**（不得变成 `throughput`） |
| 6.4 | 同上，`NOW_MORPH_TCP_PRELUDE` | **`=full8`**（不得变成 `low7`） |
| 6.5 | `doctor --fix` 后 `systemctl is-active nowhere-v2` | `active` |

> **6.3 / 6.4 是回归重点**：早期版本 `doctor --fix` 会把 unit 里的值重置为默认，而 `manager.conf` 不变，造成三者不一致。

---

## 7. 升级 / 回滚

```bash
BEFORE=$(readlink -f /opt/nowhere-v2/current)
sudo bash nowhere-v2.sh upgrade
sudo bash nowhere-v2.sh status
sudo bash nowhere-v2.sh rollback
```

| # | 检查 | 期望 |
|---|---|---|
| 7.1 | `upgrade` 退出码 | `0` |
| 7.2 | `upgrade` 后 `grep CORE_VERSION /etc/nowhere-v2/manager.conf` | 与 `RELEASE-INFO` 的 `tag:` **一致**（回归点） |
| 7.3 | `upgrade` 后 `/etc/nowhere-v2/url.conf` | **未被改动**（与升级前 diff 为空） |
| 7.4 | `rollback` 后 `readlink -f /opt/nowhere-v2/current` | 回到 `$BEFORE` |
| 7.5 | `ls -1d /opt/nowhere-v2/releases/*` | 数量 ≤ `keep-releases`（默认 3）+1 |

> **7.2 是回归重点**：早期版本"仅换二进制"的升级不会刷新 `manager.conf`。

---

## 8. 无终端不死循环（重点回归）

```bash
# 用一个非法的环境变量值触发向导，且不给终端
NOWHERE_V2_LOG=loud setsid sudo bash nowhere-v2.sh configure --advanced < /dev/null
echo "exit=$?"
```

| # | 检查 | 期望 |
|---|---|---|
| 8.1 | 命令在 **10 秒内**返回 | 不挂起 |
| 8.2 | 输出 | 明确报错说明 `loud` 不是有效值，或直接退出 |
| 8.3 | 反复执行 3 次 | 每次都能返回 |

> **8.1 是回归重点**：早期版本会无限循环打印"无效选项"（实测 3 秒 12,365 行）。
> 若 `setsid` 不可用，用 `ssh` 到该机执行 `bash -c '...' < /dev/null` 也可以。

---

## 9. 备份 / 恢复 / 清理

```bash
sudo bash nowhere-v2.sh backup /root/nw-backup.tar.gz
tar -tzf /root/nw-backup.tar.gz | head
sudo bash nowhere-v2.sh clean-releases
sudo bash nowhere-v2.sh clean-build
sudo bash nowhere-v2.sh check-updates
```

| # | 检查 | 期望 |
|---|---|---|
| 9.1 | 备份文件存在且 `600` | 是 |
| 9.2 | 备份内容含 `url.conf` / `manager.conf` / `tls/` | 是 |
| 9.3 | `backup /etc/nowhere-v2/x.tar.gz`（放配置目录内） | **被拒绝**（回归点） |
| 9.4 | `clean-releases` | 退出码 0，保留当前版本 |
| 9.5 | `check-updates` | 打印一个 `v2.x.y` |

---

## 10. 源码编译（可选，20–60 分钟）

```bash
sudo bash nowhere-v2.sh install -y --method source --version latest-v2 \
  --type portal --endpoint '*:2082' --key 'AcceptanceKey_1234567890' --tls 1
```

| # | 检查 | 期望 |
|---|---|---|
| 10.1 | 退出码 | `0` |
| 10.2 | `cat /opt/nowhere-v2/current/BUILD-INFO` | 有 `commit:` / `binary_sha256:` |
| 10.3 | `systemctl is-active nowhere-v2` | `active` |
| 10.4 | （若系统 Rust < 1.85）日志中应出现"低于 1.85…改为安装受管工具链" | 是（回归点） |

---

## 11. 卸载

```bash
sudo bash nowhere-v2.sh uninstall
ls /etc/nowhere-v2                      # 配置应保留
sudo bash nowhere-v2.sh uninstall --purge
ls /etc/nowhere-v2 2>&1                 # 应不存在
id nowhere-v2 2>&1                      # 应不存在
```

| # | 检查 | 期望 |
|---|---|---|
| 11.1 | 第一次卸载后服务与二进制消失，配置保留 | 是 |
| 11.2 | `--purge` 后配置目录与专用用户消失 | 是 |
| 11.3 | V1 相关路径（若存在）未被触碰 | `/etc/nowhere`、`nowhere.service` 不变 |

---

## 12. V1 共存（可选）

若同时安装 V1：

| # | 检查 | 期望 |
|---|---|---|
| 12.1 | 两者服务名/目录/端口互不冲突 | `nowhere` + `nowhere-v2` 同时 active |
| 12.2 | `doctor` 是否提示 V1 服务存在 | 提示端口不得冲突 |

---

## 13. 清理

```bash
sudo bash nowhere-v2.sh uninstall --purge
rm -rf /root/tls /root/nw-backup.tar.gz /root/nowhere-v2.sh
# 按需回滚 VPS 快照
```

---

## 验收记录

| 阶段 | 结果 | 备注 |
|---|---|---|
| 1 全新安装 | ☐ 通过 ☐ 失败 | |
| 2 状态/链接/指纹 | ☐ 通过 ☐ 失败 | |
| 3 TLS 2 + copy-cert | ☐ 通过 ☐ 失败 | |
| 4 Vector 客户端 | ☐ 通过 ☐ 失败 | |
| 5 Morph | ☐ 通过 ☐ 失败 | |
| 6 Doctor --fix | ☐ 通过 ☐ 失败 | **回归重点** |
| 7 升级/回滚 | ☐ 通过 ☐ 失败 | **回归重点** |
| 8 无终端不死循环 | ☐ 通过 ☐ 失败 | **回归重点** |
| 9 备份/清理 | ☐ 通过 ☐ 失败 | |
| 10 源码编译 | ☐ 通过 ☐ 失败 ☐ 跳过 | |
| 11 卸载 | ☐ 通过 ☐ 失败 | |
| 12 V1 共存 | ☐ 通过 ☐ 失败 ☐ 跳过 | |

**环境信息（便于定位问题）**

```
发行版 / 内核 :
架构          :
bash 版本     :
脚本版本      : （grep '^readonly SCRIPT_VERSION' nowhere-v2.sh）
core 版本     : （grep '^tag:' /opt/nowhere-v2/current/RELEASE-INFO）
```

---

## 出问题怎么办

1. 先收集：`sudo bash nowhere-v2.sh doctor`、`journalctl -u nowhere-v2 -n 100 --no-pager`
2. 保留现场：`sudo bash nowhere-v2.sh backup /root/fail-backup.tar.gz`
3. 把上面的环境信息 + 出错阶段编号 + 完整命令与输出记录下来

> 自动化测试覆盖逻辑，本清单覆盖集成。**两者都过了，才能说这个脚本"完善"。**
