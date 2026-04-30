# Phase C：在 Intel Mac (UTM) 上构建客户机并推送到服务器

| | |
|---|---|
| 状态 | Design 已确认（待写实现 plan） |
| 日期 | 2026-04-30 |
| 来源 | brainstorming Q1-Q4（原 Windows+VMware spec）+ 后续抛弃 VMware 改用 UTM 的会话决策 |
| 范围 | cape-installer 仓库新增 Phase C 工具链：Intel Mac + UTM 建客户机 → scp 推服务器 → 自动注册到 CAPE |
| Supersedes | [`2026-04-30-phase-c-windows-build-pipeline-design.md`](./2026-04-30-phase-c-windows-build-pipeline-design.md)（Windows+VMware 路径） |
| 上游约束 | `docs/WHY.md` ADR-Q1..Q13 + ADR-Uninstall；README §5（手动 Phase C 路径仍保留） |

---

## 1. 背景与动机

cape-installer 完成 Phase B 后必须接入一台 Windows 客户机才能真正分析样本。`README.md §5` 是直接在服务器上 `virt-install` + VNC 的手工路径，但 headless 服务器 + VNC 体验差时不实用。

之前 spec 假设有 Windows 工作站 + VMware Workstation。用户实际是 **Intel Mac + 已装 VMware Fusion**，但希望摆脱 VMware（Fusion 收费 + 需要 VMDK→qcow2 转换 + Fusion 痕迹清理）。

**最终选择 UTM**——Mac 上 QEMU 的 GUI 前端，免费、开源、与 CAPE 服务器**同 hypervisor**（同一个 QEMU），输出 qcow2 原生格式无需转换，HVF 加速接近原生速度。

## 2. 决策摘要（与 Windows+VMware spec 对照）

| 决策点 | Windows+VMware（旧） | **Mac+UTM（本 spec）** | 变化原因 |
|---|---|---|---|
| 宿主平台 | Windows 工作站 | **Intel Mac** | 用户实际只有 Mac |
| Hypervisor | VMware Workstation Pro | **UTM (QEMU 前端)** | 免费 + 同 server hypervisor + 零格式转换 |
| 客户机 OS | Win10 LTSC（不变） | Win10 LTSC | 现代样本兼容 |
| qcow2 产出 | VMDK + `qemu-img convert` | **UTM 原生 qcow2，零转换** | 同 hypervisor 直接复用 |
| 自动化深度 | docs + helper scripts（不变） | docs + helper scripts | 客户机加固 → 脚本；装机 → 手工 |
| 跨主机交接 | 单 qcow2 + sha256 | 单 qcow2 + sha256 | 不变 |
| 宿主导出脚本 | `c-host-export.ps1`（PowerShell） | **`c-host-export.sh`（Bash）** | Mac 上 Bash 更顺手 |
| 客户机内加固 | `c-guest-prep.ps1`（PowerShell） | **`c-guest-prep.ps1`（不变）** | 在 Win10 内跑，宿主无关 |
| 服务器侧 5 个 c-stage | 全部 | **全部不变** | 服务器侧与宿主无关 |
| Anti-VM 痕迹差异 | 中等（Fusion PCI ID / 注册表项） | **零**（与服务器同 QEMU emulator） | UTM 关键优势 |

## 3. 架构概览

### 3.1 双侧管线 + 单文件交接

```
[ Intel Mac (UTM) ]                               [ Ubuntu 24.04 服务器 ]
─────────────────                                 ──────────────────────
① UTM 创建 x86_64 VM（手工）
   • Legacy BIOS（不要 UEFI）
   • SATA 总线
   • e1000 网卡
   • 不装 SPICE Guest Tools
   • 装 Win10 LTSC

② c-guest-prep.ps1（在客户机内 Admin 跑，不变）
   • 关 Defender / Tamper / Update / Telemetry / SmartScreen
   • 装 Python 3.12 + 拉 agent.py + 改 .pyw + 注册启动项
   • 设静态 IP 192.168.122.105
   • shutdown /s /t 0

③ c-host-export.sh（在 Mac shell 跑）
   • 找 UTM 的 qcow2 文件
     （~/Library/Containers/com.utmapp.UTM/Data/Documents/<vm>.utm/Data/<disk>.qcow2）
   • 校验是合法 qcow2（qemu-img info）
   • shasum -a 256 → cuckoo1.qcow2.sha256
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

- **交接面 = 单文件 (.qcow2 + .sha256 sidecar)**：服务器永远不主动 ssh 回 Mac；Mac 永远不感知服务器有几个 c-stage。
- **同 hypervisor 优势**：UTM 用的就是 QEMU；Mac 上跑的客户机和服务器上跑的几乎完全等价（machine type / chipset / SATA / e1000 全部一致）。**这意味着客户机里看到的硬件指纹在 Mac 上和服务器上是一样的，anti-VM 检测的"训练环境 vs 部署环境"差异为零。**
- **零格式转换**：UTM 配置硬盘为 qcow2 时，存盘文件就是直接能给服务器用的 qcow2，无需 `qemu-img convert`（与 Fusion 路径相比省一整步 + 省一份空间）。
- **手工 vs 脚本的边界**：
  - **手工**：UTM 装机本身（一次性、易错且不值得自动化；UTM GUI 引导比命令行 QEMU 友好）
  - **脚本**：客户机内 30+ 项加固（高密度、易漏）+ Mac 侧 sha256 + scp（确定性 IO）
- **c-stage 数量 = 5（不变）**：与原 spec 完全一致。

## 4. 仓库布局：先重构再加 Phase C

### 4.1 目录重构（先做，独立 commit）

现状是所有 stage 脚本平铺在 `scripts/`（19 个 .sh 文件）。先按职责拆三个子目录，**再加** Phase C 文件——这是 Phase C 之前必须先完成的独立步骤。

**变更前（现状）：**
```
scripts/
├── 00-preflight.sh ... 99-smoke-test.sh    （9 个安装 stage）
└── u00-preflight.sh ... u99-verify.sh       （10 个卸载 stage）
```

**变更后：**
```
scripts/
├── install/
│   ├── 00-preflight.sh
│   ├── 10-mirrors.sh
│   ├── 20-host-stack.sh
│   ├── 30-poetry-fix.sh
│   ├── 31-cape-config.sh
│   ├── 40-kvm-libvirt.sh
│   ├── 50-anti-vm-qemu.sh
│   ├── 51-anti-vm-seabios.sh
│   └── 99-smoke-test.sh
└── uninstall/
    ├── u00-preflight.sh
    ├── u10-stop-services.sh
    ├── u20-backup-data.sh
    ├── u30-purge-apt.sh
    ├── u40-remove-files.sh
    ├── u50-remove-systemd-units.sh
    ├── u60-revert-system-config.sh
    ├── u70-remove-users.sh
    ├── u80-clean-cron.sh
    └── u99-verify.sh
```

**重构必改的 3 类位置：**

1. **每个 stage 脚本顶部的 source fallback**（19 处）：
   ```bash
   # 旧：scripts/<NN>.sh → ../lib = repo-root/lib
   source "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/common.sh"
   # 新：scripts/install/<NN>.sh → ../../lib = repo-root/lib
   source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
   ```
   注：当 Makefile 调用脚本时 `REPO_ROOT` 已由 Makefile 显式 export，fallback 不触发；但脚本被直接 `bash scripts/install/00-preflight.sh` 调用时 fallback 必须算对路径。

2. **Makefile 路径**（19 行）：
   ```makefile
   # 旧
   00-preflight: ; bash scripts/00-preflight.sh
   # 新
   00-preflight: ; bash scripts/install/00-preflight.sh
   ```
   卸载同理：`bash scripts/uninstall/u<NN>-<stage>.sh`。

3. **文档路径引用**：
   - `docs/INSTALL.md`、`docs/UNINSTALL.md` 里 `scripts/<NN>.sh` 形式的命令示例
   - `docs/WHY.md` 里 ADR-Q3 的仓库结构示意
   - `README.md` 第 7 节 "仓库结构" 那张文件树
   - `CLAUDE.md` 不引用具体脚本路径，无需改

**重构验收**：执行完 `git mv` + 修改后，`sudo make all` 在干净 noble 上必须**端到端不破坏跑通**（这就是重构的回归测试）。

### 4.2 Phase C 新增文件（在重构基础上）

```
cape-installer/
├── Makefile                           EDIT  + 5 个 c-stage target + 1 个 import-guest 元 target
│                                            + GUEST_QCOW2 强制参数检查
│
├── scripts/
│   ├── install/                       MOVED   （由 §4.1 重构产生，本节不再重复列出）
│   ├── uninstall/                     MOVED
│   └── guest/                         NEW DIR  （Phase C 全部新增文件集中在此）
│       ├── c10-import-guest.sh        NEW   bash, 服务器侧
│       ├── c20-define-domain.sh       NEW   bash, 服务器侧
│       ├── c30-register-kvm-conf.sh   NEW   bash, 服务器侧
│       ├── c40-smoke-guest.sh         NEW   bash, 服务器侧
│       ├── c50-snapshot-and-cape.sh   NEW   bash, 服务器侧
│       ├── c-guest-prep.ps1           NEW   PowerShell, 在 Win10 客户机内 Admin 跑
│       ├── c-host-export.sh           NEW   bash, 在 Mac 跑
│       └── domain-cuckoo1.xml.tmpl    NEW   libvirt domain XML 模板（${VAR} 占位符）
│
├── lib/
│   └── common.sh                      EDIT  + render_template()  + virsh_wait_running()
│                                            + agent_alive()       + kvm_conf_section_exists()
│
├── vendor/                            UNCHANGED  （cape2.sh.patched 等保留原位）
│
├── config.env.sample                  EDIT  + GUEST_NAME / GUEST_IP / GUEST_MAC / GUEST_RAM_MB / GUEST_VCPUS
│
└── docs/
    ├── BUILD-GUEST-ON-MAC.md          NEW   Mac (UTM) 完整手册
    ├── WHY.md                         EDIT  + ADR-Phase-C（含 UTM 抉择）+ ADR-layout-refactor（重构决策）
    ├── INSTALL.md                     EDIT  + 一句话指向 BUILD-GUEST-ON-MAC.md（路径引用同时更新到 install/）
    ├── UNINSTALL.md                   EDIT  路径引用更新到 uninstall/
    └── README.md                      EDIT  仓库结构图重画
```

### 4.3 命名约定

- `install/` / `uninstall/` / `guest/` 三个目录名简短、对称、与现有 Makefile target 命名一致（`uninstall` 已经是 target 名）
- `c-` 前缀（client/cuckoo）与 `NN-` / `uNN-` 命名空间不冲突
- `c-guest-prep.ps1` 保留 `.ps1`——它跑在 Win10 客户机内，宿主无关
- `c-host-export.sh` 用 `.sh`——它跑在 Mac shell
- `domain-cuckoo1.xml.tmpl` 放 `scripts/guest/`（不放 `vendor/`），因为它是我们写的而不是上游 vendor 资产

### 4.4 为什么 `lib/` 和 `vendor/` 不改

- `lib/common.sh` 被 install / uninstall / guest 三方共享，单一所有者无意义；移到任一子目录都会让另两方"反向引用"
- `vendor/` 当前 5 个文件全是**安装阶段**用的（cape2.sh patched / mongo GPG / pyproject 片段 / kvm-qemu / checksums）。理论上可以再拆 `vendor/install/`，但 5 个文件搬动收益小、增加层级噪音。**决定不动**——若未来 guest 阶段也产生 vendor 资产再考虑

### 4.5 文件大小预估

- 5 个 c-stage bash 共 ~400 行
- `c-guest-prep.ps1` ~150 行
- `c-host-export.sh` ~80 行（比原 PowerShell 简化：无 qemu-img convert）
- `domain-cuckoo1.xml.tmpl` ~50 行
- `BUILD-GUEST-ON-MAC.md` ~350 行
- `lib/common.sh` 增量 ~40 行

### 4.6 把 c-guest-prep.ps1 送进客户机的三选项（写在文档里）

1. **UTM ISO 挂载**（推荐）——把 `c-guest-prep.ps1` 用 `hdiutil makehybrid -o cape.iso -iso -default-volume-name CAPE <dir>` 做成 ISO，UTM 里挂上 → 客户机 D: 盘可访问。最干净，无需联网，无 Guest Tools。
2. **临时联网 + gh-proxy 拉**——客户机临时连 NAT 网络，PowerShell `Invoke-WebRequest https://gh-proxy.com/...`。快但需短暂联网。
3. **UTM SPICE 共享目录**——要装 SPICE Guest Tools，与"零工具"原则冲突，**不推荐**。

## 5. 数据契约

### 5.1 Mac ↔ 服务器跨主机契约

`c-host-export.sh` 产出 → `c10-import-guest.sh` 消费：

| 文件 | 路径（服务器） | 内容 |
|---|---|---|
| `${GUEST_NAME}.qcow2` | `/tmp/cuckoo1.qcow2`（用户传给 `GUEST_QCOW2`） | qcow2 镜像，**未压缩**，**未转换** |
| `${GUEST_NAME}.qcow2.sha256` | 同目录 | `sha256sum` 兼容格式：`<hex>  cuckoo1.qcow2` |

注意 Mac 上 sha256 命令是 `shasum -a 256`（不是 `sha256sum`）。**输出的 sidecar 文件格式必须与 Linux 的 `sha256sum -c` 兼容**——即 `<hex><两个空格><文件名>` 的纯文本格式。`shasum` 默认输出已经是这个格式，但要双空格分隔，简单 awk 整形一下。

### 5.2 VM 硬件契约（由 `vendor/domain-cuckoo1.xml.tmpl` 固化）

**与原 spec §5.2 完全一致，不变**。要点：

| 项 | 值 |
|---|---|
| machine type | `pc-i440fx-noble` |
| firmware | SeaBIOS（隐式，stage 51 替换好的 `/usr/share/qemu/bios.bin`） |
| CPU | `host-passthrough`，2 vCPU |
| RAM | 4096 MiB |
| 磁盘总线 | SATA |
| 网卡 model | `e1000` |
| 网卡 MAC | 固定 `52:54:00:CA:FE:01` |
| 网络 | `default`（virbr0） |
| 显示 | VNC :1 (5901) listen 0.0.0.0 |

**UTM 创建 VM 时要确保选项与上表一致**（UTM 的 GUI 默认大多吻合，但要手动确认 BIOS 选 Legacy 而不是 UEFI）。

### 5.3 网络契约（双保险静态 IP）

**与原 spec §5.3 完全一致**：libvirt DHCP reservation + 客户机内静态 IP。

```
                 ┌────────────────────────────────────────────────┐
                 │ libvirt default 网络 (virbr0, 192.168.122.0/24) │
                 │  192.168.122.1   ◄── host (resultserver_ip)    │
                 │  192.168.122.105 ◄── cuckoo1 (DHCP reserved   │
                 │                       AND statically set in    │
                 │                       guest)                   │
                 └────────────────────────────────────────────────┘
```

### 5.4 CAPE 配置契约（c30 注入 `kvm.conf`）

**与原 spec §5.4 完全一致**。c30 用 `crudini`（与 stage 31 一致）注入 `[cuckoo1]` section。

### 5.5 `config.env` 新增参数（含默认）

**与原 spec §5.5 完全一致**：

```bash
# === Phase C：分析客户机 ===
GUEST_NAME=cuckoo1
GUEST_IP=192.168.122.105
GUEST_MAC=52:54:00:CA:FE:01
GUEST_RAM_MB=4096
GUEST_VCPUS=2
```

`GUEST_QCOW2` 仍是 `make import-guest` 的强制入参。

## 6. 幂等性 + 错误处理

### 6.1-6.3：服务器侧 c-stage 行为

**与原 spec §6.1-§6.3 完全一致**。每个 c-stage：`stage_init` → `done_or_force <probe>` 守卫 → 业务 → `stage_done`。失败由 ERR trap 自动 tail 50 行日志。

### 6.4 跨主机错误：sha256 不匹配

c10 处理逻辑不变：sha256 不匹配 → 硬失败，提示 Mac 侧重跑 `c-host-export.sh`：

```bash
log_err "Mac 上重跑: bash scripts/c-host-export.sh -q <qcow2-path> -s <server>"
```

### 6.5 Mac 侧错误处理

`c-host-export.sh` 用 `set -eEuo pipefail`。关键步骤：

- **VM 仍在运行**：UTM 不写 `.lck` 文件，但 QEMU 进程会持有 qcow2 文件锁。检测：`pgrep -f "qemu-system.*\\b$(basename $QCOW2)\\b"` 命中 → 硬失败提示先关 UTM VM。
- **qemu-img info 校验**：拷前先 `qemu-img info "$QCOW2" | grep -q 'file format: qcow2'`，失败硬失败（防 UTM 配置成 raw 之类）
- **scp 失败 retry 3 次**：5 / 15 / 45 s backoff，与 `lib/common.sh` 的 `retry()` 语义对齐
- **客户机正在用增量快照层**：UTM 默认配置不打增量；如果用户在 UTM 拍过 snapshot，qcow2 可能成为 backing file。c-host-export.sh 检测 `qemu-img info` 输出的 `backing file:` 字段，命中则**硬失败**（提示用户在 UTM 删除快照让镜像变成 standalone）

### 6.6 客户机内 PowerShell 错误处理

**与原 spec §6.5 一致**——`c-guest-prep.ps1` 用 `$ErrorActionPreference = 'Stop'`，任一项加固失败 `exit 1` 并打印剩余清单。

### 6.7 失败回滚原则（不变）

- c20 / c30 半成功要清理（undefine / 备份恢复）
- c10 / c40 / c50 失败保留现场（让用户调试）
- 跨主机 retry 责任在 Mac 侧 `c-host-export.sh`

## 7. 验证策略

**与原 spec §7 完全一致**。

### 7.1 c40-smoke-guest（不变）
3 项必通过：domstate=running + agent.py:8000 可达 + JSON 字段对得上。120s 轮询。

### 7.2 端到端人工测试（不变）
浏览器提交 notepad.exe → Pending → Running → Completed → 自动回 clean 快照。

### 7.3 幂等性回归（不变）
第二次 `make import-guest` < 5s 全跳过。

## 8. ADR-Phase-C（要追加到 `docs/WHY.md`）

| 决策点 | 选择 | 主要理由 |
|---|---|---|
| 在 Mac 侧装机？ | Approach A：客户机内脚本化加固 + 服务器端自动注册 | 服务器 headless（Q1=A）+ 习惯 Mac VM 工具（Q1=C） |
| Win 版本？ | Win10 LTSC（Q3=B） | 现代样本兼容；LTSC 比 Pro/Home 少 bloat |
| Hypervisor？ | **UTM（不是 Fusion）** | 免费 + 与 server 同 QEMU + qcow2 原生（零转换）+ 零 anti-VM 痕迹差异 |
| 自动化深度 | docs + helper scripts（Q4=B） | 客户机加固高密度 → 脚本化；装机一次性 → 手工 |
| 静态 IP vs DHCP | 双保险（reservation + 客户机内静态） | 单点失败容忍 |
| MAC 固定 `52:54:00:CA:FE:01` | 固定 | DHCP reservation 可工作 |
| 磁盘 SATA 而非 virtio | SATA | Win10 自带 AHCI；virtio 需驱动注入 |
| 网卡 e1000 而非 virtio-net | e1000 | 同上 |
| 跨主机交接 = 单 qcow2 | 单文件 + sha256 sidecar | 极简契约，零反向 SSH |
| 快照在服务器侧拍 | 服务器侧 | libvirt 在 qcow2 元数据里管快照 |
| **抛弃 Fusion 改用 UTM** | UTM | Fusion 收费 + VMDK→qcow2 转换 + Fusion 痕迹清理；UTM 全部回避 |
| **`scripts/` 拆三个子目录** | `install/` + `uninstall/` + `guest/` | 19 个现有 stage 平铺无组织；按职责分目录便于 Phase C 加新文件而不混杂；保留 `lib/` 与 `vendor/` 不动（多方共享） |

## 9. 不在本次范围（明确不做）

- **autounattend.xml 无人值守装 Win10**（Q4=B 决定不做 C）
- **多客户机批量** (`cuckoo2`, `cuckoo3`...)：c30 的 kvm.conf 改写已支持追加，Makefile 当前只处理一个 GUEST_NAME
- **virtio-win 驱动注入路径**
- **跨服务器迁移同一 qcow2 (Approach C 模板模式)**
- **Apple Silicon Mac 支持**：Apple Silicon 上 UTM 跑 x86_64 是纯 TCG 模拟，慢到不可接受。该场景应走"服务器侧 + SSH 隧道 VNC"路径，不在本 spec 范围
- **Fusion 路径作为备选**：用户已明确抛弃。如需后续恢复，参见 superseded spec

## 10. 实施顺序提示（给后续 plan）

```
Task 0 重构  ─► Tasks 1-3 基础  ─► Tasks 4-8 c-stage  ─► Task 9 Makefile  
                  │                                                         
                  └─► Tasks 10-11 ps1+sh  ─► Tasks 12-14 docs  ─► Task 15 端到端
```

建议实施 plan 拆分为：
0. **目录重构**（独立先做）：`git mv` 19 个现有 stage 到 `scripts/install/` + `scripts/uninstall/`；改 19 个脚本顶部的 `cd "$(dirname "$0")/../.."`；改 Makefile 19 行路径；改文档引用；**`sudo make all` 端到端验证不破坏现有功能**；commit。这一步**不引入任何 Phase C 文件**。
1. **Phase C 基础**：config.env.sample + scripts/guest/domain-cuckoo1.xml.tmpl + lib/common.sh helpers
2. **服务器侧 5 个 c-stage**（c10→c50 in scripts/guest/，每个独立 commit）
3. **Makefile**：c-stage targets + import-guest 元 target + GUEST_QCOW2 校验
4. **客户机/宿主脚本**：c-guest-prep.ps1（先于 c-host-export.sh）
5. **文档**：BUILD-GUEST-ON-MAC.md + WHY.md ADR-Phase-C + WHY.md ADR-layout-refactor + INSTALL/UNINSTALL/README/CLAUDE 路径更新
6. **端到端验证**：在真 UTM Win10 客户机上跑通

## 11. 与 Windows+VMware spec 的差异总结

如果你只想看本 spec 与旧 spec 的 diff：

| 区域 | 改动 |
|---|---|
| **目录布局重构** | **新增 Task 0**：把 19 个现有 stage 拆到 `scripts/install/` + `scripts/uninstall/`；Phase C 全部新增到 `scripts/guest/` |
| 宿主平台 | Windows → Intel Mac |
| Hypervisor | VMware Workstation → UTM |
| 工作站脚本 | `c-host-export.ps1` → `c-host-export.sh`（删除 qemu-img convert 步骤） |
| 客户机加固 | `c-guest-prep.ps1` 不变（在 Win10 内跑） |
| 服务器侧 5 个 c-stage | 内容不变，**位置在 `scripts/guest/`** |
| Makefile | 不变功能但 19+5 行路径全部更新 |
| lib/common.sh helpers | 不变 |
| domain XML 模板 | 不变内容，**位置 `vendor/` → `scripts/guest/`** |
| 网络/IP/快照/kvm.conf 契约 | 不变 |
| 用户文档 | `BUILD-GUEST-ON-WINDOWS.md` → `BUILD-GUEST-ON-MAC.md` |
| ADR 多两条 | "抛弃 Fusion 改用 UTM"、"目录重构" |
