# Phase C：在 Windows 工作站构建客户机并推送到服务器

| | |
|---|---|
| 状态 | Design 已确认（待写实现 plan） |
| 日期 | 2026-04-30 |
| 来源 | superpowers:brainstorming 会话（Q1-Q4 + §1-§5） |
| 范围 | cape-installer 仓库新增 Phase C 工具链：Windows 工作站建客户机 → 转 qcow2 → 推服务器 → 自动注册到 CAPE |
| 上游约束 | `docs/WHY.md` ADR-Q1..Q13 + ADR-Uninstall；README §5（手动 Phase C 路径仍保留） |

---

## 1. 背景与动机

cape-installer 当前只覆盖 Phase B（host stack + KVM/libvirt + 反 VM QEMU/SeaBios）。要让 CAPE 真正分析样本，必须在 virbr0 上接入一台 Windows 客户机。`README.md §5` 文档了**在服务器上用 `virt-install` + VNC** 装 Windows 的手工路径，但当：

- **服务器是 headless**（仅 SSH，无显示器）
- 操作者**习惯 Windows 上的 VMware Workstation 工具链**

VNC 装 Windows 体验差，每次都要在 5901 端口拉桌面装机器、敲数十项反检测策略，效率低且易漏。

本设计的目标是让操作者：
1. 在 Windows 工作站用 VMware **图形化装好** Win10 LTSC
2. 一条 PowerShell 在客户机内**脚本化做 30+ 项加固 + 装 agent.py**
3. 一条 PowerShell 在工作站宿主**转 qcow2 + scp 推送**
4. 在服务器跑 **`sudo make import-guest GUEST_QCOW2=...`**——剩余 5 个 stage 自动完成

## 2. 决策摘要（来自 brainstorming Q1-Q4）

| Q | 选择 | 主要理由 |
|---|---|---|
| Q1 动机 | A + C：服务器 headless，且习惯 Windows VM 工具 | VNC 装机体验差 + 工作站熟练 |
| Q2 Hypervisor | B：VMware Workstation Pro/Player | GUI 体验最好；VMDK→qcow2 一行 `qemu-img convert` 转换 |
| Q3 客户机 OS | B：Windows 10 LTSC 2019/2021 x64 | 现代样本兼容（Win7 不行）+ 比 Pro/Home 少 bloat |
| Q4 自动化深度 | B：docs + helper scripts | 装机一次性手工；30+ 项加固高密度，最值得脚本化 |
| 架构 Approach | A：客户机内脚本化加固 + 服务器端自动注册 | 跨主机契约最简（单 qcow2 + sha256），完全匹配 Q4=B |

## 3. 架构概览

### 3.1 双侧管线 + 单文件交接

```
[ Windows 工作站 ]                                [ Ubuntu 24.04 服务器 ]
─────────────────                                 ──────────────────────
① 手工 VMware 装 Win10 LTSC
   • legacy BIOS（不要 UEFI）
   • SATA / IDE 总线
   • 不装 VMware Tools

② c-guest-prep.ps1（在客户机内 Admin 跑）
   • 关 Defender / Tamper / Update / Telemetry / SmartScreen
   • 装 Python 3.12 + 拉 agent.py + 改 .pyw + 注册启动项
   • 设静态 IP 192.168.122.105
   • shutdown /s /t 0

③ c-host-export.ps1（在工作站宿主跑）
   • qemu-img convert -O qcow2 -p VMDK → cuckoo1.qcow2
   • sha256 → cuckoo1.qcow2.sha256
   • scp 推送                                    ▶ /tmp/cuckoo1.qcow2(.sha256)

                                                  ④ sudo make import-guest \
                                                         GUEST_QCOW2=/tmp/cuckoo1.qcow2
                                                     │
                                                     ├─ c10-import-guest      （校验 sha256 + 安置）
                                                     ├─ c20-define-domain     （渲染 XML + virsh define）
                                                     ├─ c30-register-kvm-conf （写 /opt/CAPEv2/conf/kvm.conf）
                                                     ├─ c40-smoke-guest       （启 VM + 轮询 agent.py 8000 端口）
                                                     └─ c50-snapshot-and-cape （拍 clean 快照 + unmask cape/cape-processor）
```

### 3.2 关键架构选择

- **交接面 = 单文件 (.qcow2 + .sha256 sidecar)**：服务器永远不主动 ssh/wsman 回 Windows；Windows 永远不感知服务器有几个 c-stage。两侧解耦到极致。
- **手工 vs 脚本的边界**：Windows 装机本身**纯手工**（一次性、易错且不值得自动化）；客户机内 30+ 项加固**纯脚本**（高密度、易漏）。
- **c-stage 数量 = 5**：拆分粒度对齐现有 `00-99` 安装脚本的颗粒（一个 stage 做一类事，单步可重跑）。
- **c-stage 串行依赖**：c10→c20→c30→c40→c50，靠 Makefile prerequisite 链；任一 stage 失败时 `make import-guest` 中止，已完成的 stage 因守卫跳过 → 修问题 → 重跑同一命令。

## 4. 仓库新增文件清单

```
cape-installer/
├── Makefile
│   └── + 5 个 c-stage target + 1 个 import-guest 元 target
│       + GUEST_QCOW2 强制参数检查
│
├── scripts/
│   ├── c10-import-guest.sh          NEW   bash, 服务器侧
│   ├── c20-define-domain.sh         NEW   bash, 服务器侧
│   ├── c30-register-kvm-conf.sh     NEW   bash, 服务器侧
│   ├── c40-smoke-guest.sh           NEW   bash, 服务器侧
│   ├── c50-snapshot-and-cape.sh     NEW   bash, 服务器侧
│   ├── c-guest-prep.ps1             NEW   PowerShell, 在 Win10 客户机内 Admin 跑
│   └── c-host-export.ps1            NEW   PowerShell, 在 Windows 工作站宿主跑
│
├── lib/
│   └── common.sh                    EDIT  + render_template()  + virsh_wait_running()
│                                          + agent_alive()       + kvm_conf_section_exists()
│
├── vendor/
│   └── domain-cuckoo1.xml.tmpl      NEW   libvirt domain XML 模板（${VAR} 占位符）
│
├── config.env.sample                EDIT  + GUEST_NAME / GUEST_IP / GUEST_MAC / GUEST_RAM_MB / GUEST_VCPUS
│
└── docs/
    ├── BUILD-GUEST-ON-WINDOWS.md    NEW   Windows 工作站侧完整手册（VMware 装机 + PS 脚本用法 + 故障排查）
    ├── WHY.md                       EDIT  + ADR-Phase-C
    └── INSTALL.md                   EDIT  + 一句话指向 BUILD-GUEST-ON-WINDOWS.md
```

### 4.1 命名约定

- `c-` 前缀（client/cuckoo）与既有 `00-99` 安装脚本、`u00-u99` 卸载脚本的命名空间不冲突。
- PowerShell 用 `c-guest-*` / `c-host-*` 显式区分"在客户机内跑"还是"在 Windows 工作站宿主跑"——这是个人在两台机器之间切换最容易搞混的点。

### 4.2 文件大小预估

- 5 个 c-stage bash 共 ~400 行（参考 `40-kvm-libvirt.sh` 体量）
- `c-guest-prep.ps1` ~150 行（30+ 项加固 + Python 装 + agent.py 注入）
- `c-host-export.ps1` ~80 行（参数校验 + qemu-img + scp + retry）
- `domain-cuckoo1.xml.tmpl` ~50 行
- `BUILD-GUEST-ON-WINDOWS.md` ~400 行（含截图位 + 故障表）
- `lib/common.sh` 增量 ~40 行

### 4.3 把 c-guest-prep.ps1 送进客户机的三选项（写在文档里让用户挑）

1. **装 Win10 时不联网，PS 脚本通过共享文件夹/USB ISO 拷进去**——最干净，推荐
2. **临时挂个 NAT 网络让客户机能 GET `https://gh-proxy.com/.../c-guest-prep.ps1`**——快但需要短暂联网
3. **VMware "拖放"功能**——要装 VMware Tools，与"不装 Tools"原则冲突，**不推荐**

## 5. 数据契约

### 5.1 PowerShell ↔ bash 跨主机契约

`c-host-export.ps1` 产出 → `c10-import-guest.sh` 消费：

| 文件 | 路径（服务器） | 内容 |
|---|---|---|
| `${GUEST_NAME}.qcow2` | `/tmp/cuckoo1.qcow2`（用户传给 `GUEST_QCOW2`） | qcow2 镜像，**未压缩**（`qemu-img convert -O qcow2`，不加 `-c`） |
| `${GUEST_NAME}.qcow2.sha256` | 同目录 | `sha256sum` 格式：`<hex>  cuckoo1.qcow2`（与 `sha256sum -c` 兼容） |

**为什么不压缩 qcow2**：压缩 qcow2 是只读的，CAPE 分析时要往里写（再靠快照回滚）。`qcow2` 自身已经是稀疏格式，10 GB Win10 一般实际只占 5-7 GB；千兆内网 ~1 min，没必要再压。

### 5.2 VM 硬件契约（由 `vendor/domain-cuckoo1.xml.tmpl` 固化）

| 项 | 值 | 为什么 |
|---|---|---|
| machine type | `pc-i440fx-noble` | SeaBIOS 1.16.3 反 VM 补丁是为 i440fx 准备的；q35 + UEFI 不通 |
| firmware | SeaBIOS（隐式，已在 `/usr/share/qemu/bios.bin`，由 stage 51 替换） | 安装阶段已搞定，XML 不显式声明 |
| CPU | `host-passthrough`，2 vCPU | 反 VM；CPUID 直透样本看不出"虚拟" |
| RAM | 4096 MiB | README §5 默认；可由 `GUEST_RAM_MB` 覆盖 |
| 磁盘总线 | **SATA**（`bus='sata'`） | Win10 自带 AHCI 驱动；virtio 需要 virtio-win 驱动注入 |
| 网卡 model | **`e1000`** | Win10 自带 Intel 82540EM 驱动；virtio-net 需驱动注入 |
| 网卡 MAC | **固定** `52:54:00:CA:FE:01` | 配 DHCP reservation 用；`52:54:00` 是 libvirt 官方前缀 |
| 网络 | `network='default'`（virbr0） | CAPE 分析网段 |
| 显示 | VNC :1（5901）listen 0.0.0.0 | 仅应急手动调试 |
| 启动顺序 | `<boot dev='hd'/>` | 装好的盘，无 CD-ROM |

### 5.3 网络契约（双保险静态 IP）

```
                 ┌──────────────────────────────────────────────┐
                 │ libvirt default 网络 (virbr0, 192.168.122.0/24)│
                 │                                              │
                 │  192.168.122.1   ◄── host (resultserver_ip)  │
                 │  192.168.122.105 ◄── cuckoo1 (DHCP reserved │
                 │                       AND statically set    │
                 │                       inside guest)         │
                 └──────────────────────────────────────────────┘
```

- **libvirt 端**：`virsh net-update default add ip-dhcp-host '<host mac="52:54:00:CA:FE:01" ip="192.168.122.105"/>'`——MAC→IP 绑定
- **客户机端**：`c-guest-prep.ps1` 在 Win10 里 `New-NetIPAddress -IPAddress 192.168.122.105 -PrefixLength 24 -DefaultGateway 192.168.122.1`——客户机自己也写死 IP

腰带 + 背带：DHCP reservation 解决"IP 漂移"，客户机内静态 IP 解决"DHCP 客户端没起来"的边缘情况。

### 5.4 CAPE 配置契约（c30 注入 `kvm.conf`）

c30 用 `configparser` 风格的原地编辑（不整段覆盖）：

```ini
[kvm]
machines = cuckoo1                         # 若已有则改为 "原值,cuckoo1"，避免覆盖以后追加的 cuckoo2
interface = virbr0

[cuckoo1]
label = cuckoo1
platform = windows
ip = 192.168.122.105                       # = $GUEST_IP
snapshot = clean
arch = x64
tags = win10ltsc,x64,cape
resultserver_ip = 192.168.122.1            # = $SUBNET.1
resultserver_port = 2042
```

c30 改之前先 `cp kvm.conf kvm.conf.bak.<TS>`，可恢复。

### 5.5 `config.env` 新增参数（含默认）

```bash
# === Phase C：分析客户机 ===
GUEST_NAME=cuckoo1                          # libvirt domain 名 + kvm.conf section 名（保持一致）
GUEST_IP=192.168.122.105                    # 必须在 ${SUBNET}.0/24 内
GUEST_MAC=52:54:00:CA:FE:01                 # libvirt 前缀（52:54:00）+ 后 3 字节自定
GUEST_RAM_MB=4096
GUEST_VCPUS=2
```

`GUEST_QCOW2` 不在 `config.env`——它是 `make import-guest` 的参数（每次可能不同路径），**Makefile 校验它必须显式传**。

## 6. 幂等性 + 错误处理

每个 c-stage 沿用 `lib/common.sh` 现有契约：`source common.sh` → `stage_init "<name>"` → 守卫探测 → 业务 → `stage_done`。失败由 `set -eEuo pipefail` + ERR trap 自动 tail 50 行日志。

### 6.1 各 stage 幂等探测 + 失败行为

| Stage | 跳过条件（已完成） | 失败行为 |
|---|---|---|
| **c10-import-guest** | `/var/lib/libvirt/images/${GUEST_NAME}.qcow2` 存在 AND `sha256sum -c` 通过 | sha256 不匹配 → 硬失败，提示重跑 `c-host-export.ps1`；磁盘空间不足 → 硬失败 |
| **c20-define-domain** | `virsh dominfo ${GUEST_NAME}` 返回 0（domain 已定义） | XML 渲染失败 → 硬失败；`virsh define` 失败 → 删除半定义 domain 后重试 1 次。模板改了想重渲染用 `make force-c20-define-domain` |
| **c30-register-kvm-conf** | `[${GUEST_NAME}]` section 已存在于 `kvm.conf` | 写入前必 `cp kvm.conf kvm.conf.bak.<TS>`；权限错（cape 用户）→ 硬失败 |
| **c40-smoke-guest** | `virsh domstate ${GUEST_NAME}` == running AND `curl -fsS http://${GUEST_IP}:8000/status` 返回 JSON | 启动失败 → 硬失败 + dump `virsh dumpxml`；agent 不响应 → 轮询 120 s 后硬失败 + 提示 VNC 5901 手动调试 |
| **c50-snapshot-and-cape** | `virsh snapshot-list ${GUEST_NAME}` 已含 `clean` AND `cape.service` 是 enabled（非 masked） | 快照创建用 `--atomic`；unmask + restart 失败 → `journalctl -u cape -n 50` 自动 tail |

### 6.2 `FORCE=1` 行为

沿用现有 `done_or_force` helper：

```bash
# c20-define-domain.sh 内部
if done_or_force virsh dominfo "$GUEST_NAME" >/dev/null 2>&1; then
  echo "[~] domain ${GUEST_NAME} 已定义，跳过"; stage_done; exit 0
fi
```

`make force-c20-define-domain` → `FORCE=1` → 守卫返回失败 → 强制重跑（先 `virsh undefine` 再 `define`）。同 install stage。

### 6.3 跨 stage 状态保护

c-stage 之间唯一共享状态是 **libvirt domain 自身**（外部存储），不需要 `state/` 目录的 marker。这是有意的：

- 用户手工 `virsh undefine cuckoo1` 后再跑 `make c20-define-domain`，会自动重建（守卫检系统真相，不检 marker）
- 用户手工 `virsh start cuckoo1` 后再跑 `make c40-smoke-guest`，不会重启它（domstate 已 running 就直接验证 agent）

### 6.4 跨主机错误：sha256 不匹配

最容易踩的坑（scp 中断 / 重传断点续传写坏）。c10 的处理：

```bash
if ! sha256sum -c "${guest_qcow2}.sha256" >/dev/null 2>&1; then
  log_err "qcow2 哈希不匹配——可能 scp 传坏了"
  log_err "Windows 工作站重跑: pwsh scripts/c-host-export.ps1 -Server <ip>"
  exit 1
fi
```

不在 c10 内部做 retry / 重传——跨主机重传该是 Windows 侧 PowerShell 的责任，避免双侧都做造成黑盒。

### 6.5 PowerShell 侧错误处理

`c-host-export.ps1` 用 `$ErrorActionPreference = 'Stop'` + 关键步骤 `try/catch`：
- `qemu-img convert` 失败 → 不删除原 VMDK，提示用户检查 VMware 是否真的关机
- `scp` 失败 → 自带 retry 3 次（5 / 15 / 45 s backoff，对齐 `common.sh` 的 `retry()` 语义）
- 网络全断 → 失败提示用户 `c-host-export.ps1 -DryRun` 先验证本地转换 OK

`c-guest-prep.ps1` 在客户机内更激进——任何一步失败都 `exit 1` 并打印剩余步骤清单，让用户决定是手动续跑还是重置 VM 重来。

### 6.6 失败回滚原则

- **c20 / c30 半成功要清理**（undefine / 备份恢复）
- **c10 / c40 / c50 失败保留现场**（让用户调试）
- 跨主机 retry 责任在 Windows 侧的 `c-host-export.ps1`，服务器侧硬失败 + 明确指示

## 7. 验证策略

仓库现状是**没有自动化测试套件**——验证 = 一次成功的端到端跑 + smoke-test 自检。Phase C 沿用同思路。

### 7.1 c40-smoke-guest 是管线内置的集成测试

c40 是 5 个 c-stage 中**唯一会失败的"真验证"**——前面 c10/c20/c30 都是确定性 IO 操作。c40 必通过的 3 项：

```bash
# 1. domain 在跑
[ "$(virsh domstate "$GUEST_NAME")" = "running" ] || fail

# 2. agent.py 8000 端口可达（最长等 120 s，agent.py 启动要等 Win10 登录 + Python autostart）
for i in {1..24}; do
  curl -fsS "http://${GUEST_IP}:8000/" >/dev/null 2>&1 && break
  sleep 5
done

# 3. agent.py 返回的 JSON 字段对得上（不是别的 HTTP 服务在那个端口）
curl -fsS "http://${GUEST_IP}:8000/status" | python3 -c \
  "import json,sys; d=json.load(sys.stdin); assert d.get('status')=='running'"
```

c40 失败 → 整个 `make import-guest` 中断；用户拿 VNC 5901 手动看客户机内部状态调试，修完后单独跑 `sudo make c40-smoke-guest` 续跑。

### 7.2 端到端人工测试（写进 BUILD-GUEST-ON-WINDOWS.md §"验证"）

```bash
# 服务器上：
firefox http://<TARGET>:8000/submit/    # 浏览器交付任务

# 上传一个无害 EXE（notepad.exe / putty.exe）
# 观察：
sudo virsh list                          # 应在 ~5 s 内看到 cuckoo1 running
sudo journalctl -fu cape                 # 看 Task X submitted, analyzing on cuckoo1
# 等 ~30 s 任务完成
# Web UI 该任务页面应有 behavior log
sudo virsh snapshot-current cuckoo1      # 应显示自动回到 clean
```

任务跑完 + 自动回滚 = Phase C 真的通了。

### 7.3 幂等性回归（手工验证清单）

```bash
# 第二次 import-guest 应几乎瞬间结束（每个 c-stage 命中守卫直接跳过）
$ time sudo make import-guest GUEST_QCOW2=/tmp/cuckoo1.qcow2
real    0m1.5s

# 强制重做 c20（重新渲染 + 重定义 domain）
$ sudo make force-c20-define-domain

# 手工 undefine 后重跑 c20
$ sudo virsh destroy cuckoo1; sudo virsh undefine cuckoo1
$ sudo make c20-define-domain                                # 应重建
```

## 8. ADR-Phase-C（要追加到 `docs/WHY.md`）

| 决策点 | 选择 | 主要理由 |
|---|---|---|
| 在 Windows 侧装机？ | A：Approach A | 服务器 headless（Q1=A）+ Windows VM 工具熟练（Q1=C） |
| Win 版本？ | Win10 LTSC（Q3=B） | 现代样本兼容；LTSC 比 Pro/Home 少 bloat |
| Hypervisor？ | VMware Workstation（Q2=B） | GUI 体验好；与目标 hypervisor 同构通过 qemu-img 转换 |
| 自动化深度 | docs + helper scripts（Q4=B） | 客户机加固高密度 → 脚本化；装机一次性 → 手工 |
| 静态 IP vs DHCP | 双保险（reservation + 客户机内静态） | 单点失败容忍 |
| MAC 固定 `52:54:00:CA:FE:01` | 固定 | DHCP reservation 可工作 |
| 磁盘 SATA 而非 virtio | SATA | Win10 自带 AHCI；virtio 需驱动注入 |
| 网卡 e1000 而非 virtio-net | e1000 | 同上 |
| 跨主机交接 = 单 qcow2 | 单文件 + sha256 sidecar | 极简契约，零反向 SSH |
| 快照在服务器侧拍 | 服务器侧 | libvirt 在 qcow2 元数据里管快照，工作站拍的没用 |

## 9. 不在本次范围（明确不做）

- **autounattend.xml 无人值守装 Win10**——Q4 已选 B 而不是 C；以后想升级到 C 再加
- **多客户机批量** (`cuckoo2`, `cuckoo3`...)——架构上 c30 的 kvm.conf 改写已支持追加，Makefile target 当前只处理一个 `GUEST_NAME`；后续要扩展时 Makefile 加循环
- **virtio-win 驱动注入路径**——除非用户报告 SATA/e1000 性能不够（实际 4K IOPS 上限对短任务影响很小）
- **跨服务器迁移同一 qcow2 (Approach C)**——A 产出的 qcow2 就是 C 的"模板"，未来零成本升级
- **服务器侧 c-stage 反向触发 Windows 侧重传**——跨主机 retry 责任纯在 Windows 侧

## 10. 实施顺序提示（给后续 plan）

依赖关系：

```
config.env.sample   ─┐
domain-xml.tmpl     ─┤
common.sh helpers   ─┤
                     ├─► c10 ─► c20 ─► c30 ─► c40 ─► c50 ─► Makefile target
                     │
c-guest-prep.ps1    ─┤
c-host-export.ps1   ─┘
                     │
                     └─► BUILD-GUEST-ON-WINDOWS.md（写在最后，引用真跑通的命令）
                         WHY.md ADR-Phase-C 追加
                         INSTALL.md 加指针
```

建议实施 plan 拆分为：
1. **基础**：config.env.sample + domain-xml.tmpl + common.sh helpers
2. **服务器侧 5 个 c-stage**（c10→c50，每个独立 commit，跑过单测才进下一个）
3. **Makefile**：c-stage target + import-guest 元 target + GUEST_QCOW2 校验
4. **PowerShell**：c-guest-prep.ps1（先于 c-host-export.ps1，因为后者依赖前者产出的关机 VM）
5. **文档**：BUILD-GUEST-ON-WINDOWS.md（真跑通后写）+ WHY.md ADR + INSTALL.md 指针
