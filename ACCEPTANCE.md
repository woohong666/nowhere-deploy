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
KEY=$(openssl rand -hex 32)   # 记下这个值：§4 的 Vector 必须使用同一个密钥
sudo bash nowhere-v2.sh install -y \
  --type portal --endpoint '*:2082' \
  --key "$KEY" --tls 1
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
| 1.10 | `grep -oE 'portal://[0-9a-f]{32,64}@' /etc/nowhere-v2/url.conf` | 匹配成功（2.2.x 密钥格式，回归点） |

> **1.11（重点回归）** 安装的 core 版本应等于官网最新稳定版：
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
| 2.6 | `links` 输出的 Vector URL | 含 `pin=<64 位 hex>`（tls=1 自动 pin，2.2.0+ 回归点） |

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

先在 Portal 上取指纹（此时 Portal 是第 3 步的自签证书，2.2.0+ 客户端必须 pin）：

```bash
PIN=$(sudo bash nowhere-v2.sh fingerprint)   # 在 Portal 主机执行
```

```bash
sudo bash nowhere-v2.sh install -y \
  --type vector --endpoint '<portal-ip>:2082' \
  --key '<填入 §1 的 64 位 hex 密钥>' \
  --vector-socks '127.0.0.1:1082' \
  --pin "$PIN"
```

| # | 检查 | 期望 |
|---|---|---|
| 4.1 | `systemctl is-active nowhere-v2` | `active` |
| 4.2 | `ss -lntp \| grep 1082` | 本地 SOCKS5 在监听 |
| 4.3 | `curl -x socks5h://127.0.0.1:1082 -s https://api.ipify.org` | 返回 **Portal 的**公网 IP |
| 4.4 | `journalctl -u nowhere-v2 -n 30 --no-pager` | 无 TLS/ALPN 报错 |
| 4.5 |（负向，可选）`configure --pin none` 后重启 | 连接**失败**（2.2.0+ 强制验证，回归点）；改回 `--pin "$PIN"` 恢复 |

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
>
> **跨 2.2.0 升级告警（可选回归）**：先 `install --version v2.1.2` 并手工把 url.conf 的密钥改成旧格式（如 `LegacyKey_1234567890`），再 `upgrade` 到最新版：应看到密钥轮换告警（若角色是 vector 且无 pin，还应看到证书验证告警），且 `doctor` 会点名旧格式密钥。随后执行 `configure -y --config-mode quick --key <新的 64 位 hex>`，应只更换密钥，端点、模式等设置保持不变（回归点）。

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
  --type portal --endpoint '*:2082' --key "$(openssl rand -hex 32)" --tls 1
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

## 13. V3 管理器（NW3）验收（可选，需要 NW3 客户端）

> V3 与 V2 完全隔离（服务 / 目录 / 端口均不同），可以在同一台验收机上并行执行。
> 客户端说明（实测）：Anywhere **2.3 及以下只有 NW2，不能用于本项验收**；**2.4 (401) 起只有 NW3**（该版本上 V2 链接会超时）。
> 没有 NW3 客户端时，用官方二进制自测：`nowhere-v3 probe '<vector-url>' example.com:443`。

```bash
# 1) 新建 V3 Portal（默认固定 v3.1.0）；有域名证书时直接给 --cert/--tls-key，
#    不传则自动生成持久自签 PEM（pin 永久稳定，不会随重启变化）
sudo bash nowhere-v3.sh install --version v3.1.0 --public-host <公网IP或域名>
sudo bash nowhere-v3.sh doctor
sudo bash nowhere-v3.sh links        # 输出 Vector / Egress URL（均自带 pin）
sudo bash nowhere-v3.sh telemetry    # 只读统计；NW3 没有 TUI
```

| # | 检查 | 期望 |
|---|---|---|
| 13.1 | 服务与端口 | `nowhere-v3` 为 active；`ss -lntup` 可见 TCP **和** UDP `2083`；V2 服务不受影响 |
| 13.2 | `cat /etc/nowhere-v3/url.conf` | 32 位小写 hex 密钥；`tls=2` 且 `crt` 指向 `/etc/nowhere-v3/tls/pem.*`；默认含 `morph=1` |
| 13.3 | `links` 输出 | Vector tcp / udp 原生 URL：证书在系统信任库可验证（含主机名）时**不带 pin**，否则带 64 位 `pin=`；证书不可读取时拒绝输出 |
| 13.4 | Vector 客户端 | 用 `--url-file` 安装链接文件；`curl -x socks5h://127.0.0.1:1083 https://api.ipify.org` 返回 V3 侧出口 IP |
| 13.5 | 同角色重配（`configure --key <新> --endpoint <同>`） | 重配后 `crt` 路径与 pin **不变**（PEM 复用，回归点） |
| 13.6 | 角色切换保护 | `configure --role egress ...`（不带 `--allow-role-switch`、加 `-y`）应被拒绝 |
| 13.7 | Egress（有第二台机器时） | `--out egress` Portal + egress:// URL 注册后 probe 成功；停掉 Egress 后请求失败且**不回退直连** |
| 13.8 | 卸载 | `uninstall` 保留配置；`--purge` 删除配置；V2 完全不受影响 |

---

### 13.1 v1.1.0 菜单与自更新走查

- 在测试主机运行无参数菜单：检查23项、0/q退出、无效输入与回车返回；中英文各走查一次。
- 安装/重配后 `/usr/local/bin/nh` 存在且可执行；`nh` 打开菜单、`nh status` 等参数透传；`uninstall --purge` 后移除。
- 向导选项输入编号（1/2/3）与原值均可；确认提示 `y`/`yes`/`是` 为真、`n`/`no`/`否`/回车为假。
- 断开终端/stdin：应只显示一次并退出，不循环刷屏。
- 分别通过Portal/Vector/Egress向导安装；同角色重配前后用fingerprint比较，默认pin应相同。
- 模拟错误证书或启动失败：原配置、unit、launcher与current均恢复；V1/V2目录无变化。
- `versions`应数值倒序过滤draft/prerelease，官方不足10个时只显示实际数量。
- 复制脚本测试self-update：更高版本升级、同版本不改、较低版本拒绝、空环境变量禁用、断网不破坏原文件；不得更新服务或配置。
- `language --lang en`保存后重新进入菜单；`NOWHERE_V3_LANG=zh`及`--lang en`按优先级覆盖。

### 13.2 v1.1.0 探测与隐私

- Portal（设置PUBLIC_HOST）和Vector运行`probe example.com:443`；成功0、失败非零，只显示脱敏URL与Result。
- Portal分别测试tls=2与tls=1、Morph=0/1；tls=1无TCP监听时应明确拒绝指纹核验。
- Egress发起probe应失败且说明不支持；`doctor --probe`探测失败仅警告，基础doctor语义不变。
- links应包含带pin的Vector tcp/udp、适用时Egress，以及不带pin的nowhere分享链接。
- `fingerprint 'nowhere://KEY@主机:端口?morph=0|1'`应回64位hex；非nowhere://参数、缺端口或带carrier路径会被拒；输出与报错均不含密钥（v1.2.0 起）。
- links 会自动尝试安装 qrencode（apt/dnf/yum/apk）：成功则输出二维码；无包管理器或安装失败时仅警告，链接照常输出。
- 检查status、日志与probe不泄露共享密钥或pin；generate-key、fingerprint与links为明确输出例外。
- 私有CA/自签场景手动导入客户端信任；通用分享链接本身不携带信任锚。
- 证书（可选，需真实域名）：`cert --domain <域> --cf-token-file <文件>`（或 `--http`）成功后 `/etc/nowhere-v3/tls/le.<域>/` 出现 fullchain/key，`url.conf` 指向它且为 `tls=2`；`systemctl list-timers | grep nowhere-v3-cert-renew` 可见每日续期；vector/egress 角色实例应被拒绝；Token 不出现在 acme.sh 命令行（`ps` 不可见）；acme.sh 与 `dns_cf` 插件位于 `/etc/nowhere-v3/acme`（纳入 `backup`），签发显式使用 `--server letsencrypt`。
- 备份/恢复回归（v1.5.1/1.4.1）：`backup` 目标已存在（含悬空链接）时必须拒绝覆盖；`restore` 应容忍 `manager.conf` 的整行注释、空行与键值两侧空格，并拒绝重复有效键。
- `cert-status` 回归（v1.4.1）：托管证书损坏/过期/私钥不匹配/日期异常时，仍应输出定时器状态与上次受管理结果且返回非零；自备证书应标明"不走内置定时续期"且不查询 timer。
- 内核与 Prelude 回归（v1.4.2）：`install`/`upgrade` 默认应为 **v3.1.0**；`latest-v3` 不得选中预发布（当前 v3.2.0），显式指定预发布应被拒绝；`--morph-prelude fade` 在 v3.1.0 下应写入 `NOW_MORPH_TCP_PRELUDE=fade`，指定 v3.0.0 时应拒绝且不写 unit。

### 13.3 自动化验收

```bash
bash -n nowhere-v3.sh tests/nowhere-v3.test.sh
shellcheck -S warning nowhere-v3.sh tests/nowhere-v3.test.sh
bash tests/nowhere-v3.test.sh
```

在Linux Bash 5.x + util-linux flock的非root账户执行全部沙箱测试；
测试不访问网络、不写真实服务目录。原先“无自更新URL”断言随F1改为“自更新只指向V3”；其余旧断言保留。
可选backup --restore未纳入本版；不要执行未实现的恢复命令。
真机人工走查结果由操作者填写，不以沙箱成功替代生产验收。

## 14. 清理

```bash
sudo bash nowhere-v2.sh uninstall --purge
sudo bash nowhere-v3.sh uninstall --purge
rm -rf /root/tls /root/nw-backup.tar.gz /root/nowhere-v2.sh /root/nowhere-v3.sh
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
| 13 V3 管理器（NW3） | ☐ 通过 ☐ 失败 ☐ 跳过 | 需要 NW3 客户端或官方 probe |

**环境信息（便于定位问题）**

```
发行版 / 内核 :
架构          :
bash 版本     :
脚本版本      : （grep '^readonly SCRIPT_VERSION' nowhere-v2.sh）
core 版本     : （grep '^tag:' /opt/nowhere-v2/current/RELEASE-INFO）
V3 脚本版本   : （grep '^readonly SCRIPT_VERSION' nowhere-v3.sh）
V3 core 版本  : （grep '^tag:' /opt/nowhere-v3/current/RELEASE-INFO）
```

---

## 出问题怎么办

1. 先收集：`sudo bash nowhere-v2.sh doctor`、`journalctl -u nowhere-v2 -n 100 --no-pager`
2. 保留现场：`sudo bash nowhere-v2.sh backup /root/fail-backup.tar.gz`
3. 把上面的环境信息 + 出错阶段编号 + 完整命令与输出记录下来

> 自动化测试覆盖逻辑，本清单覆盖集成。**两者都过了，才能说这个脚本"完善"。**
