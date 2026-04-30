# Phase C — Intel Mac (UTM) 构建客户机管线 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 cape-installer 仓库（1）把 19 个现有 stage 重构进 `scripts/install/` + `scripts/uninstall/`；（2）新增 Phase C 工具链——在 Intel Mac (UTM) 建 Win10 LTSC 客户机 → scp 推服务器 → `sudo make import-guest GUEST_QCOW2=...` 自动注册到 CAPE 并拍 clean 快照。

**Architecture:** Task 0 先做目录重构（`sudo make all` 端到端不破坏作为验收）；后续 Tasks 1-15 在 `scripts/guest/` 下添加 5 个 c-stage bash + 1 个 in-guest PowerShell + 1 个 Mac shell 导出脚本，全部沿用 `lib/common.sh` 现有契约。UTM 与服务器**同 hypervisor (QEMU)** → qcow2 原生输出，零格式转换，零 anti-VM 痕迹差异。

**Tech Stack:** Bash (set -eEuo pipefail) + GNU Make + crudini + envsubst + libvirt/virsh + qemu-img + UTM/QEMU + PowerShell 7+ (in-guest only)

**Spec:** [`docs/superpowers/specs/2026-04-30-phase-c-utm-mac-build-pipeline-design.md`](../specs/2026-04-30-phase-c-utm-mac-build-pipeline-design.md)

**Test environment:**
- **bash 任务**：需要一台 Phase B 已完成的 Ubuntu 24.04 noble 目标机。本地静态检查用 `bash -n` / `shellcheck`，运行验证 ssh 进目标机跑。
- **PowerShell 任务**：Mac 上 `brew install --cask powershell` 装 `pwsh` 做语法检查；端到端验证需要 UTM Win10 客户机。
- **Mac shell 任务**：直接在 Mac 上跑（c-host-export.sh）。

---

## File Structure

```
cape-installer/
├── Makefile                                EDIT  Tasks 0 + 9
├── config.env.sample                       EDIT  Task 1
├── lib/common.sh                           EDIT  Task 2 (+4 helpers)
├── scripts/
│   ├── install/                            NEW DIR  Task 0（移现有 9 个 install stage）
│   │   ├── 00-preflight.sh ... 99-smoke-test.sh
│   ├── uninstall/                          NEW DIR  Task 0（移现有 10 个 uninstall stage）
│   │   ├── u00-preflight.sh ... u99-verify.sh
│   └── guest/                              NEW DIR  Phase C
│       ├── c10-import-guest.sh             NEW   Task 4
│       ├── c20-define-domain.sh            NEW   Task 5
│       ├── c30-register-kvm-conf.sh        NEW   Task 6
│       ├── c40-smoke-guest.sh              NEW   Task 7
│       ├── c50-snapshot-and-cape.sh        NEW   Task 8
│       ├── c-guest-prep.ps1                NEW   Task 10
│       ├── c-host-export.sh                NEW   Task 11
│       └── domain-cuckoo1.xml.tmpl         NEW   Task 3
└── docs/
    ├── BUILD-GUEST-ON-MAC.md               NEW   Task 12
    ├── WHY.md                              EDIT  Tasks 0 + 13
    ├── INSTALL.md                          EDIT  Task 14
    ├── UNINSTALL.md                        EDIT  Task 14
    └── README.md                           EDIT  Tasks 0 + 14
```

每个任务一个 commit。任务内部按 "写代码 → 静态检查 → 运行验证 → 幂等回归 → commit" 五步走。

---

## Task 0：目录重构（`scripts/` → `scripts/install/` + `scripts/uninstall/`）

**Files:**
- Create: `scripts/install/`（目录）
- Create: `scripts/uninstall/`（目录）
- Move: 9 个 `scripts/*.sh` 安装 stage 到 `scripts/install/`
- Move: 10 个 `scripts/u*.sh` 卸载 stage 到 `scripts/uninstall/`
- Modify: 19 个移动后的脚本（每个文件 1 行变更：source fallback 路径 +1 级）
- Modify: `Makefile`（19 行 path）
- Modify: `README.md`（仓库结构图 §7）
- Modify: `docs/WHY.md`（ADR-Q3 的文件树 + 第 291 行 `scripts/99-smoke-test.sh` 引用）

- [ ] **Step 1：建目录 + git mv**

```bash
mkdir -p scripts/install scripts/uninstall

# 9 个安装 stage（数字开头）
git mv scripts/[0-9][0-9]-*.sh scripts/install/

# 10 个卸载 stage（u 开头）
git mv scripts/u[0-9][0-9]-*.sh scripts/uninstall/

# 验证：scripts/ 下不应再有 .sh 文件
ls scripts/*.sh 2>/dev/null && echo "FAIL: 还有 .sh 残留" || echo "OK"
ls scripts/install/ | wc -l    # 期望 9
ls scripts/uninstall/ | wc -l  # 期望 10
```

预期：`scripts/install/` 9 个文件，`scripts/uninstall/` 10 个文件，`scripts/` 自身不再有 .sh。

- [ ] **Step 2：批量改 19 个脚本顶部的 source fallback 路径**

每个脚本顶部有这一行：
```bash
source "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/common.sh"
```

要把 `cd "$(dirname "$0")/.."` 改成 `cd "$(dirname "$0")/../.."`（多一级 `..` 因为脚本下沉了一层）。

```bash
# macOS BSD sed（Linux GNU sed 版本：去掉 -i 后的 ''）
find scripts/install scripts/uninstall -name '*.sh' -print0 | \
  xargs -0 sed -i '' -e 's|"\$0")/\.\." \&\& pwd|"\$0")/../.." \&\& pwd|'

# 验证全部 19 个都改了
grep -rn 'dirname "$0"' scripts/install scripts/uninstall | grep -v '/../..'
# 期望：无输出（即所有匹配都已含 /../..）

grep -rn 'dirname "$0"' scripts/install scripts/uninstall | wc -l
# 期望：19
```

如果 `sed` 在你的环境上行为异常，**手动**用编辑器在每个文件里把 `$(dirname "$0")/..` 改成 `$(dirname "$0")/../..`。

- [ ] **Step 3：bash -n 全部 19 个脚本（语法检查）**

```bash
for f in scripts/install/*.sh scripts/uninstall/*.sh; do
  bash -n "$f" || echo "FAIL: $f"
done
echo "all OK"
```

预期：仅打印 `all OK`，无 FAIL。

- [ ] **Step 4：改 Makefile 19 行 path**

打开 `Makefile`，找到这两段：

**安装 stage 段**（约 58-66 行）。原：

```makefile
00-preflight:        ; bash scripts/00-preflight.sh
10-mirrors:          00-preflight       ; bash scripts/10-mirrors.sh
20-host-stack:       10-mirrors         ; bash scripts/20-host-stack.sh
30-poetry-fix:       20-host-stack      ; bash scripts/30-poetry-fix.sh
31-cape-config:      30-poetry-fix      ; bash scripts/31-cape-config.sh
40-kvm-libvirt:      31-cape-config     ; bash scripts/40-kvm-libvirt.sh
50-anti-vm-qemu:     40-kvm-libvirt     ; bash scripts/50-anti-vm-qemu.sh
51-anti-vm-seabios:  50-anti-vm-qemu    ; bash scripts/51-anti-vm-seabios.sh
99-smoke-test:       51-anti-vm-seabios ; bash scripts/99-smoke-test.sh
```

改为：

```makefile
00-preflight:        ; bash scripts/install/00-preflight.sh
10-mirrors:          00-preflight       ; bash scripts/install/10-mirrors.sh
20-host-stack:       10-mirrors         ; bash scripts/install/20-host-stack.sh
30-poetry-fix:       20-host-stack      ; bash scripts/install/30-poetry-fix.sh
31-cape-config:      30-poetry-fix      ; bash scripts/install/31-cape-config.sh
40-kvm-libvirt:      31-cape-config     ; bash scripts/install/40-kvm-libvirt.sh
50-anti-vm-qemu:     40-kvm-libvirt     ; bash scripts/install/50-anti-vm-qemu.sh
51-anti-vm-seabios:  50-anti-vm-qemu    ; bash scripts/install/51-anti-vm-seabios.sh
99-smoke-test:       51-anti-vm-seabios ; bash scripts/install/99-smoke-test.sh
```

**卸载 stage 段**（约 80-89 行）。原：

```makefile
u00-preflight:               ; bash scripts/u00-preflight.sh
u10-stop-services:           ; bash scripts/u10-stop-services.sh
u20-backup-data:             ; bash scripts/u20-backup-data.sh
u30-purge-apt:               ; bash scripts/u30-purge-apt.sh
u40-remove-files:            ; bash scripts/u40-remove-files.sh
u50-remove-systemd-units:    ; bash scripts/u50-remove-systemd-units.sh
u60-revert-system-config:    ; bash scripts/u60-revert-system-config.sh
u70-remove-users:            ; bash scripts/u70-remove-users.sh
u80-clean-cron:              ; bash scripts/u80-clean-cron.sh
u99-verify:                  ; bash scripts/u99-verify.sh
```

改为：

```makefile
u00-preflight:               ; bash scripts/uninstall/u00-preflight.sh
u10-stop-services:           ; bash scripts/uninstall/u10-stop-services.sh
u20-backup-data:             ; bash scripts/uninstall/u20-backup-data.sh
u30-purge-apt:               ; bash scripts/uninstall/u30-purge-apt.sh
u40-remove-files:            ; bash scripts/uninstall/u40-remove-files.sh
u50-remove-systemd-units:    ; bash scripts/uninstall/u50-remove-systemd-units.sh
u60-revert-system-config:    ; bash scripts/uninstall/u60-revert-system-config.sh
u70-remove-users:            ; bash scripts/uninstall/u70-remove-users.sh
u80-clean-cron:              ; bash scripts/uninstall/u80-clean-cron.sh
u99-verify:                  ; bash scripts/uninstall/u99-verify.sh
```

**`force-%` 规则**（约 92-93 行）。原：

```makefile
force-%:
	FORCE=1 bash scripts/$*.sh
```

改为（要在三个目录里查找匹配的脚本）：

```makefile
force-%:
	@if [ -f scripts/install/$*.sh ]; then \
	  FORCE=1 bash scripts/install/$*.sh; \
	elif [ -f scripts/uninstall/$*.sh ]; then \
	  FORCE=1 bash scripts/uninstall/$*.sh; \
	elif [ -f scripts/guest/$*.sh ]; then \
	  FORCE=1 bash scripts/guest/$*.sh; \
	else \
	  echo "未找到 stage: $*"; exit 1; \
	fi
```

`scripts/guest/` 此时还不存在，`-f` 检查会跳过——不会报错。

- [ ] **Step 5：改 README.md §7 仓库结构 + docs/WHY.md ADR-Q3 文件树 + WHY.md line 291 引用**

**README.md §7**（约 370-402 行的 ASCII 树）。把：

```
├── scripts/               # 9 个 install + 10 个 uninstall stage
│   ├── 00-preflight.sh    51-anti-vm-seabios.sh
│   ├── 10-mirrors.sh      99-smoke-test.sh
│   ├── 20-host-stack.sh   u00-preflight.sh
│   ├── 30-poetry-fix.sh   u10-stop-services.sh
│   ├── 31-cape-config.sh  u20-backup-data.sh
│   ├── 40-kvm-libvirt.sh  u30-purge-apt.sh
│   ├── 50-anti-vm-qemu.sh u40-remove-files.sh
│   │                      u50-remove-systemd-units.sh
│   │                      u60-revert-system-config.sh
│   │                      u70-remove-users.sh
│   │                      u80-clean-cron.sh
│   │                      u99-verify.sh
```

改为：

```
├── scripts/
│   ├── install/           # 9 个 install stage
│   │   ├── 00-preflight.sh
│   │   ├── 10-mirrors.sh
│   │   ├── 20-host-stack.sh
│   │   ├── 30-poetry-fix.sh
│   │   ├── 31-cape-config.sh
│   │   ├── 40-kvm-libvirt.sh
│   │   ├── 50-anti-vm-qemu.sh
│   │   ├── 51-anti-vm-seabios.sh
│   │   └── 99-smoke-test.sh
│   └── uninstall/         # 10 个 uninstall stage
│       ├── u00-preflight.sh
│       ├── u10-stop-services.sh
│       ├── u20-backup-data.sh
│       ├── u30-purge-apt.sh
│       ├── u40-remove-files.sh
│       ├── u50-remove-systemd-units.sh
│       ├── u60-revert-system-config.sh
│       ├── u70-remove-users.sh
│       ├── u80-clean-cron.sh
│       └── u99-verify.sh
```

**docs/WHY.md** 同样有 ADR-Q3 文件树要更新（搜索 `scripts/00-preflight` 找位置）。

**docs/WHY.md line 291** 把：
```
- `scripts/99-smoke-test.sh` 有 7 个检查项
```
改为：
```
- `scripts/install/99-smoke-test.sh` 有 7 个检查项
```

- [ ] **Step 6：Makefile 解析验证**

```bash
make help | head -3
# 期望打印安装目标列表，无 Makefile 错误
```

- [ ] **Step 7：在目标服务器上验证 1 个 stage 直接调用**

```bash
# 先 rsync 上去
rsync -av --exclude logs --exclude state --exclude config.env \
  ./ cape@<TARGET>:/opt/cape-installer/

# ssh 进去，跑 00-preflight（5-25s 的轻量 stage，验证 path + source fallback）
ssh cape@<TARGET>
cd /opt/cape-installer
sudo make 00-preflight
# 期望：完整跑过；logs/00-preflight.log 包含正常输出
sudo bash scripts/install/00-preflight.sh   # 直接调脚本（不走 Makefile）
# 期望：同样跑过——证明 source fallback 改对了
```

- [ ] **Step 8：（可选但推荐）在目标机跑完整 sudo make all 端到端验证**

只有在干净 noble 上才有意义。如果之前已部署，可跳过此步——`make help` + `make 00-preflight` 双双过即可视为低风险。

```bash
ssh cape@<TARGET>
cd /opt/cape-installer
sudo make clean
time sudo make all
# 期望：50 min 内全过 + 99-smoke-test 通过
```

- [ ] **Step 9：commit**

```bash
git add scripts/install scripts/uninstall Makefile README.md docs/WHY.md
# 注意：git mv 已在 Step 1 暂存，git add 把后续修改一并加进来
git status   # 检查 staged 文件清单合理
git commit -m "refactor: scripts/ 拆分为 install/ + uninstall/

19 个现有 stage 按职责分目录：
- 9 个安装 stage 移到 scripts/install/
- 10 个卸载 stage 移到 scripts/uninstall/
- 每个脚本顶部 source fallback 路径 +1 级（/.. → /../..）
- Makefile 19 行 path 全部更新
- force-% 规则扩展为 install/uninstall/guest 三目录查找
- README §7 仓库结构图重画
- docs/WHY.md ADR-Q3 文件树同步

为 Phase C（scripts/guest/）让位的预备重构。"
```

---

## Task 1：`config.env.sample` 增加 Phase C 客户机参数

**Files:**
- Modify: `config.env.sample`

- [ ] **Step 1：在文件末尾追加 Phase C 段**

打开 `config.env.sample`，在最后一行 `DB_PASSWORD=SuperPuperSecret` 之后追加：

```bash

# === Phase C：分析客户机（make import-guest 用） ===
# 客户机 libvirt domain 名 + kvm.conf section 名（保持一致）。
GUEST_NAME=cuckoo1

# 客户机静态 IP，必须在 ${SUBNET}.0/24 内（默认网段 192.168.122）。
# 客户机内 c-guest-prep.ps1 也会写死同一个 IP（双保险）。
GUEST_IP=192.168.122.105

# 客户机 MAC。前缀 52:54:00 是 libvirt 官方保留段，后 3 字节自定。
# 用于 libvirt 的 DHCP reservation（MAC→IP 绑定）。
GUEST_MAC=52:54:00:CA:FE:01

# 客户机资源（可调）。
GUEST_RAM_MB=4096
GUEST_VCPUS=2
```

- [ ] **Step 2：语法检查**

```bash
bash -n config.env.sample
make help | head -3   # Makefile 仍能 include
```

预期：两个命令都 exit 0。

- [ ] **Step 3：commit**

```bash
git add config.env.sample
git commit -m "feat(config): 加 Phase C 客户机参数 GUEST_NAME/IP/MAC/RAM/VCPUS"
```

---

## Task 2：`lib/common.sh` 增加 4 个 helper

**Files:**
- Modify: `lib/common.sh`

- [ ] **Step 1：在 `lib/common.sh` 末尾追加（`run_or_warn` 之后）**

```bash

# ===== Phase C helpers（c-stage 用）=====

# render_template <template-file>
# 用 envsubst 渲染 ${VAR} 占位符到 stdout。只展开传入白名单变量名，
# 避免 $PATH / $HOME 被意外替换进 XML。
# 用法：render_template scripts/guest/domain-cuckoo1.xml.tmpl > /tmp/domain.xml
render_template() {
  local tmpl="$1"
  [ -f "$tmpl" ] || { log_err "模板不存在: $tmpl"; return 1; }
  local whitelist='${GUEST_NAME} ${GUEST_IP} ${GUEST_MAC} ${GUEST_RAM_MB} ${GUEST_VCPUS} ${SUBNET}'
  envsubst "$whitelist" < "$tmpl"
}

# virsh_wait_running <domain> <timeout-sec>
# 轮询直到 domain state == running，或超时返回 1。
virsh_wait_running() {
  local dom="$1" timeout="${2:-60}"
  local i=0
  while [ "$i" -lt "$timeout" ]; do
    if [ "$(virsh domstate "$dom" 2>/dev/null)" = "running" ]; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# agent_alive <ip> <port>
# 单次探测：HTTP GET http://ip:port/status 必须返回合法 JSON 且 status 字段存在。
# 返回 0 表示 agent 起来了。
agent_alive() {
  local ip="$1" port="${2:-8000}"
  curl -fsS --max-time 3 "http://${ip}:${port}/status" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "status" in d else 1)' \
      2>/dev/null
}

# kvm_conf_section_exists <conf-file> <section>
# 用 crudini 探测 INI 文件中是否已有某 section。
kvm_conf_section_exists() {
  local conf="$1" section="$2"
  [ -f "$conf" ] || return 1
  crudini --get "$conf" "$section" >/dev/null 2>&1
}
```

- [ ] **Step 2：bash 语法检查 + shellcheck**

```bash
bash -n lib/common.sh
command -v shellcheck >/dev/null && shellcheck -s bash lib/common.sh || echo "shellcheck 未装，跳过"
```

- [ ] **Step 3：本地单元验证（无需服务器）**

```bash
bash -c '
  set -eEuo pipefail
  REPO_ROOT="$PWD"
  source lib/common.sh

  echo "domain=\${GUEST_NAME}, ip=\${GUEST_IP}" > /tmp/test.tmpl
  GUEST_NAME=cuckoo1 GUEST_IP=192.168.122.105 \
    render_template /tmp/test.tmpl
  rm /tmp/test.tmpl
'
```

预期 stdout：`domain=cuckoo1, ip=192.168.122.105`

- [ ] **Step 4：commit**

```bash
git add lib/common.sh
git commit -m "feat(common): 加 4 个 Phase C helper（render_template/virsh_wait_running/agent_alive/kvm_conf_section_exists）"
```

---

## Task 3：`scripts/guest/domain-cuckoo1.xml.tmpl` libvirt domain 模板

**Files:**
- Create: `scripts/guest/domain-cuckoo1.xml.tmpl`

- [ ] **Step 1：建目录 + 写模板**

```bash
mkdir -p scripts/guest
```

新建 `scripts/guest/domain-cuckoo1.xml.tmpl`，内容：

```xml
<domain type='kvm'>
  <name>${GUEST_NAME}</name>
  <memory unit='MiB'>${GUEST_RAM_MB}</memory>
  <currentMemory unit='MiB'>${GUEST_RAM_MB}</currentMemory>
  <vcpu placement='static'>${GUEST_VCPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='pc-i440fx-noble'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <pae/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='on'/>
  <clock offset='localtime'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/local/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' discard='unmap'/>
      <source file='/var/lib/libvirt/images/${GUEST_NAME}.qcow2'/>
      <target dev='sda' bus='sata'/>
    </disk>
    <controller type='sata' index='0'/>
    <interface type='network'>
      <mac address='${GUEST_MAC}'/>
      <source network='default'/>
      <model type='e1000'/>
    </interface>
    <serial type='pty'>
      <target type='isa-serial' port='0'/>
    </serial>
    <console type='pty'/>
    <input type='tablet' bus='usb'/>
    <input type='mouse' bus='ps2'/>
    <input type='keyboard' bus='ps2'/>
    <graphics type='vnc' port='5901' autoport='no' listen='0.0.0.0'/>
    <video>
      <model type='vga' vram='16384'/>
    </video>
  </devices>
</domain>
```

**关键值（不要随意改）：**
- `machine='pc-i440fx-noble'` — SeaBIOS 反 VM 补丁的目标 chipset
- `<emulator>/usr/local/bin/qemu-system-x86_64</emulator>` — 指向 stage 50 编译出的反 VM QEMU
- `bus='sata'` — Win10 自带 AHCI 驱动
- `model type='e1000'` — Win10 自带 Intel 驱动

- [ ] **Step 2：渲染后 xmllint 校验**

```bash
GUEST_NAME=cuckoo1 GUEST_IP=192.168.122.105 GUEST_MAC=52:54:00:CA:FE:01 \
  GUEST_RAM_MB=4096 GUEST_VCPUS=2 \
  envsubst '${GUEST_NAME} ${GUEST_IP} ${GUEST_MAC} ${GUEST_RAM_MB} ${GUEST_VCPUS}' \
  < scripts/guest/domain-cuckoo1.xml.tmpl \
  | xmllint --noout -
```

预期：无输出（well-formed 通过）。`xmllint` 没装就 `brew install libxml2`。

- [ ] **Step 3：commit**

```bash
git add scripts/guest/domain-cuckoo1.xml.tmpl
git commit -m "feat(guest): 加 cuckoo1 客户机 libvirt domain XML 模板（pc-i440fx + SATA + e1000）"
```

---

## Task 4：`scripts/guest/c10-import-guest.sh` 校验 + 安置 qcow2

**Files:**
- Create: `scripts/guest/c10-import-guest.sh`

- [ ] **Step 1：写脚本**

新建 `scripts/guest/c10-import-guest.sh`：

```bash
#!/usr/bin/env bash
# Stage c10-import-guest：校验 + 安置 qcow2 到 libvirt 镜像目录
# - 校验 sha256（侧文件 ${GUEST_QCOW2}.sha256 必须存在且一致）
# - 拷贝到 /var/lib/libvirt/images/${GUEST_NAME}.qcow2
# - chown libvirt-qemu:kvm
#
# 失败原则：sha256 不匹配 → 硬失败，提示 Mac 侧重传

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "c10-import-guest"

GUEST_NAME="${GUEST_NAME:-cuckoo1}"
GUEST_QCOW2="${GUEST_QCOW2:?GUEST_QCOW2 未传，必须显式指定}"
TARGET_DIR=/var/lib/libvirt/images
TARGET="$TARGET_DIR/${GUEST_NAME}.qcow2"

# ---- 幂等守卫 ----
if done_or_force \
   [ -f "$TARGET" ] \
   && [ -f "${GUEST_QCOW2}.sha256" ] \
   && (cd "$(dirname "$GUEST_QCOW2")" && sha256sum -c "$(basename "${GUEST_QCOW2}.sha256")") >/dev/null 2>&1 \
   && cmp -s "$GUEST_QCOW2" "$TARGET"; then
  echo "[~] $TARGET 已就位且哈希匹配，跳过"
  stage_done
  exit 0
fi

# ---- 1. 输入校验 ----
[ -f "$GUEST_QCOW2" ] || { echo "[-] GUEST_QCOW2 不存在: $GUEST_QCOW2"; exit 1; }
[ -f "${GUEST_QCOW2}.sha256" ] || {
  echo "[-] sha256 sidecar 不存在: ${GUEST_QCOW2}.sha256"
  echo "    Mac 上重跑 c-host-export.sh 生成 sidecar"
  exit 1
}

# ---- 2. 校验 sha256 ----
echo "[+] 校验 sha256"
if ! (cd "$(dirname "$GUEST_QCOW2")" && sha256sum -c "$(basename "${GUEST_QCOW2}.sha256")"); then
  echo "[-] sha256 不匹配——可能 scp 传坏了"
  echo "    Mac 上重跑: bash scripts/guest/c-host-export.sh -q <qcow2> -s <server>"
  exit 1
fi
echo "[✓] sha256 通过"

# ---- 3. qemu-img info 验证是合法 qcow2 ----
qemu-img info "$GUEST_QCOW2" | grep -q 'file format: qcow2' \
  || { echo "[-] $GUEST_QCOW2 不是合法 qcow2 格式"; exit 1; }
echo "[✓] qcow2 格式校验通过"

# ---- 4. 磁盘空间检查 ----
need_kb=$(qemu-img info --output=json "$GUEST_QCOW2" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["virtual-size"]//1024)')
avail_kb=$(df --output=avail "$TARGET_DIR" | tail -1)
if [ "$avail_kb" -lt "$need_kb" ]; then
  echo "[-] $TARGET_DIR 可用 ${avail_kb}KB < 需要 ${need_kb}KB"
  exit 1
fi
echo "[✓] 磁盘空间足"

# ---- 5. 安置 + chown ----
mkdir -p "$TARGET_DIR"
cp -f "$GUEST_QCOW2" "$TARGET"
chown libvirt-qemu:kvm "$TARGET"
chmod 0600 "$TARGET"
echo "[✓] 已拷贝到 $TARGET"

stage_done
```

- [ ] **Step 2：静态检查**

```bash
bash -n scripts/guest/c10-import-guest.sh
shellcheck -s bash scripts/guest/c10-import-guest.sh 2>/dev/null || true
```

- [ ] **Step 3：在目标机端到端跑（造测试 qcow2）**

```bash
# Mac 上同步：
rsync -av --exclude logs --exclude state --exclude config.env \
  ./ cape@<TARGET>:/opt/cape-installer/

# ssh：
ssh cape@<TARGET>
cd /opt/cape-installer

# 造测试 qcow2：
qemu-img create -f qcow2 /tmp/cuckoo1.qcow2 100M
(cd /tmp && sha256sum cuckoo1.qcow2 > cuckoo1.qcow2.sha256)

# 跑 c10：
sudo GUEST_NAME=cuckoo1 GUEST_QCOW2=/tmp/cuckoo1.qcow2 \
  bash scripts/guest/c10-import-guest.sh

# 验证：
sudo ls -la /var/lib/libvirt/images/cuckoo1.qcow2
```

预期：文件存在，owner libvirt-qemu:kvm，mode 0600。

- [ ] **Step 4：幂等回归**

```bash
time sudo GUEST_NAME=cuckoo1 GUEST_QCOW2=/tmp/cuckoo1.qcow2 \
  bash scripts/guest/c10-import-guest.sh
# 期望：< 1s，"已就位且哈希匹配，跳过"
```

- [ ] **Step 5：故意破坏 sha256 sidecar 验证硬失败**

```bash
echo "deadbeef  cuckoo1.qcow2" > /tmp/cuckoo1.qcow2.sha256
sudo GUEST_NAME=cuckoo1 GUEST_QCOW2=/tmp/cuckoo1.qcow2 \
  bash scripts/guest/c10-import-guest.sh
# 期望 exit != 0，日志含 "sha256 不匹配"
echo $?

# 恢复：
(cd /tmp && sha256sum cuckoo1.qcow2 > cuckoo1.qcow2.sha256)
```

- [ ] **Step 6：清理 + commit**

```bash
# 目标机清理
sudo rm /var/lib/libvirt/images/cuckoo1.qcow2 /tmp/cuckoo1.qcow2 /tmp/cuckoo1.qcow2.sha256

# Mac
chmod +x scripts/guest/c10-import-guest.sh
git add scripts/guest/c10-import-guest.sh
git commit -m "feat(c10): 校验 sha256 + 安置 qcow2 到 /var/lib/libvirt/images"
```

---

## Task 5：`scripts/guest/c20-define-domain.sh` 渲染 XML + virsh define

**Files:**
- Create: `scripts/guest/c20-define-domain.sh`

- [ ] **Step 1：写脚本**

新建 `scripts/guest/c20-define-domain.sh`：

```bash
#!/usr/bin/env bash
# Stage c20-define-domain：渲染 libvirt domain XML 并 virsh define
# - 用 lib/common.sh 的 render_template + envsubst
# - 在 default 网络追加 MAC→IP DHCP reservation
#
# 失败原则：virsh define 失败 → 删半定义 domain 重试 1 次

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "c20-define-domain"

GUEST_NAME="${GUEST_NAME:-cuckoo1}"
GUEST_IP="${GUEST_IP:-192.168.122.105}"
GUEST_MAC="${GUEST_MAC:-52:54:00:CA:FE:01}"
GUEST_RAM_MB="${GUEST_RAM_MB:-4096}"
GUEST_VCPUS="${GUEST_VCPUS:-2}"

TMPL="$REPO_ROOT/scripts/guest/domain-cuckoo1.xml.tmpl"
RENDER=/tmp/${GUEST_NAME}.domain.xml

# ---- 幂等守卫 ----
if done_or_force virsh dominfo "$GUEST_NAME" >/dev/null 2>&1; then
  echo "[~] domain $GUEST_NAME 已定义，跳过（要重渲染用 make force-c20-define-domain）"
  stage_done
  exit 0
fi

# ---- 1. 渲染 XML ----
export GUEST_NAME GUEST_IP GUEST_MAC GUEST_RAM_MB GUEST_VCPUS
render_template "$TMPL" > "$RENDER"
xmllint --noout "$RENDER" || { echo "[-] 渲染后 XML 不合法: $RENDER"; exit 1; }
echo "[✓] 渲染 → $RENDER"

# ---- 2. virsh define（带 1 次重试 + 半成功清理）----
if ! virsh define "$RENDER"; then
  echo "[!] virsh define 失败，清理后重试 1 次"
  virsh undefine "$GUEST_NAME" 2>/dev/null || true
  virsh define "$RENDER"
fi
echo "[✓] domain $GUEST_NAME 已定义"

# ---- 3. DHCP reservation ----
existing=$(virsh net-dumpxml default \
  | grep -E "<host mac=['\"]${GUEST_MAC}['\"]" || true)
if [ -n "$existing" ]; then
  virsh net-update default delete ip-dhcp-host \
    "<host mac='${GUEST_MAC}' ip='${GUEST_IP}'/>" \
    --live --config 2>/dev/null \
    || echo "[~] 旧 reservation 删除失败，继续 add"
fi

virsh net-update default add ip-dhcp-host \
  "<host mac='${GUEST_MAC}' name='${GUEST_NAME}' ip='${GUEST_IP}'/>" \
  --live --config

echo "[✓] DHCP reservation: $GUEST_MAC → $GUEST_IP"

stage_done
```

- [ ] **Step 2：静态检查**

```bash
bash -n scripts/guest/c20-define-domain.sh
shellcheck -s bash scripts/guest/c20-define-domain.sh 2>/dev/null || true
```

- [ ] **Step 3：在目标机端到端跑**

```bash
# Mac：rsync 同上
# 目标机：
ssh cape@<TARGET>
cd /opt/cape-installer

# 先准备 qcow2 占位
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/cuckoo1.qcow2 100M

# 跑 c20
sudo bash scripts/guest/c20-define-domain.sh

# 验证
sudo virsh dominfo cuckoo1
sudo virsh net-dumpxml default | grep "52:54:00:CA:FE:01"
```

预期：`virsh dominfo cuckoo1` 显示 State: shut off；`virsh net-dumpxml default` 含 host mac 行。

- [ ] **Step 4：幂等回归 + force 测试**

```bash
time sudo bash scripts/guest/c20-define-domain.sh
# 期望 < 1s，"已定义，跳过"

sudo FORCE=1 bash scripts/guest/c20-define-domain.sh
# 期望：force 跳守卫，virsh define 报已存在 → 触发清理重试
```

- [ ] **Step 5：清理 + commit**

```bash
# 目标机清理
sudo virsh net-update default delete ip-dhcp-host \
  "<host mac='52:54:00:CA:FE:01' name='cuckoo1' ip='192.168.122.105'/>" \
  --live --config 2>/dev/null || true
sudo virsh undefine cuckoo1 2>/dev/null || true
sudo rm /var/lib/libvirt/images/cuckoo1.qcow2 2>/dev/null || true

# Mac
chmod +x scripts/guest/c20-define-domain.sh
git add scripts/guest/c20-define-domain.sh
git commit -m "feat(c20): 渲染 libvirt domain XML + virsh define + DHCP reservation"
```

---

## Task 6：`scripts/guest/c30-register-kvm-conf.sh` 注入 cuckoo1 到 kvm.conf

**Files:**
- Create: `scripts/guest/c30-register-kvm-conf.sh`

- [ ] **Step 1：写脚本**

新建 `scripts/guest/c30-register-kvm-conf.sh`：

```bash
#!/usr/bin/env bash
# Stage c30-register-kvm-conf：把 cuckoo1 注册到 /opt/CAPEv2/conf/kvm.conf
# - [kvm] machines 追加（不覆盖，保留可能已有的 cuckoo2/3...）
# - 写 [${GUEST_NAME}] section 全部字段
# - 改之前先备份到 kvm.conf.bak.<TS>
#
# 用 crudini，与 stage 31-cape-config 一致

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "c30-register-kvm-conf"

GUEST_NAME="${GUEST_NAME:-cuckoo1}"
GUEST_IP="${GUEST_IP:-192.168.122.105}"
SUBNET="${SUBNET:-192.168.122}"

CONF=/opt/CAPEv2/conf/kvm.conf
CRUDINI=$(command -v crudini)

[ -f "$CONF" ] || { echo "[-] $CONF 不存在——CAPE 还没装好"; exit 1; }

# ---- 幂等守卫 ----
if done_or_force kvm_conf_section_exists "$CONF" "$GUEST_NAME"; then
  echo "[~] [$GUEST_NAME] section 已存在于 $CONF，跳过"
  stage_done
  exit 0
fi

# ---- 1. 备份 ----
ts=$(date +%Y%m%d-%H%M%S)
cp "$CONF" "${CONF}.bak.${ts}"
echo "[✓] 备份 → ${CONF}.bak.${ts}"

# ---- 2. [kvm] machines 追加 ----
current=$(sudo -u cape "$CRUDINI" --get "$CONF" kvm machines 2>/dev/null || echo "")
if [ -z "$current" ]; then
  new="$GUEST_NAME"
else
  if echo ",$current," | grep -q ",${GUEST_NAME},"; then
    new="$current"
  else
    new="${current},${GUEST_NAME}"
  fi
fi
sudo -u cape "$CRUDINI" --set "$CONF" kvm machines "$new"
sudo -u cape "$CRUDINI" --set "$CONF" kvm interface virbr0
echo "[✓] [kvm] machines = $new"

# ---- 3. 写 [GUEST_NAME] section ----
sudo -u cape "$CRUDINI" --set "$CONF" "$GUEST_NAME" label "$GUEST_NAME"
sudo -u cape "$CRUDINI" --set "$CONF" "$GUEST_NAME" platform windows
sudo -u cape "$CRUDINI" --set "$CONF" "$GUEST_NAME" ip "$GUEST_IP"
sudo -u cape "$CRUDINI" --set "$CONF" "$GUEST_NAME" snapshot clean
sudo -u cape "$CRUDINI" --set "$CONF" "$GUEST_NAME" arch x64
sudo -u cape "$CRUDINI" --set "$CONF" "$GUEST_NAME" tags "win10ltsc,x64,cape"
sudo -u cape "$CRUDINI" --set "$CONF" "$GUEST_NAME" resultserver_ip "${SUBNET}.1"
sudo -u cape "$CRUDINI" --set "$CONF" "$GUEST_NAME" resultserver_port 2042
echo "[✓] [$GUEST_NAME] section 写入完成"

stage_done
```

- [ ] **Step 2：静态检查**

```bash
bash -n scripts/guest/c30-register-kvm-conf.sh
shellcheck -s bash scripts/guest/c30-register-kvm-conf.sh 2>/dev/null || true
```

- [ ] **Step 3：端到端运行（前提：stage 20-host-stack 已跑过 → kvm.conf 存在）**

```bash
ssh cape@<TARGET>
cd /opt/cape-installer

sudo cat /opt/CAPEv2/conf/kvm.conf
sudo bash scripts/guest/c30-register-kvm-conf.sh
sudo cat /opt/CAPEv2/conf/kvm.conf
```

预期 `kvm.conf` 含 `[kvm] machines = cuckoo1` + `[cuckoo1]` 全 8 字段。

- [ ] **Step 4：幂等回归**

```bash
time sudo bash scripts/guest/c30-register-kvm-conf.sh
# 期望 < 1s，"已存在...跳过"
ls /opt/CAPEv2/conf/kvm.conf.bak.* | wc -l
# 期望 = 1（不增长）
```

- [ ] **Step 5：清理 + commit**

```bash
# 目标机：恢复
ssh cape@<TARGET> 'sudo cp /opt/CAPEv2/conf/kvm.conf.bak.* /opt/CAPEv2/conf/kvm.conf && sudo rm /opt/CAPEv2/conf/kvm.conf.bak.*'

# Mac
chmod +x scripts/guest/c30-register-kvm-conf.sh
git add scripts/guest/c30-register-kvm-conf.sh
git commit -m "feat(c30): 用 crudini 注入 cuckoo1 到 /opt/CAPEv2/conf/kvm.conf"
```

---

## Task 7：`scripts/guest/c40-smoke-guest.sh` 启 VM + 验证 agent.py

**Files:**
- Create: `scripts/guest/c40-smoke-guest.sh`

- [ ] **Step 1：写脚本**

新建 `scripts/guest/c40-smoke-guest.sh`：

```bash
#!/usr/bin/env bash
# Stage c40-smoke-guest：启 VM + 验证 agent.py 8000 端口可达
# - virsh start
# - virsh_wait_running 60s
# - agent_alive 轮询 120s（24 次 × 5s）
# - 失败 → dump XML + 提示 VNC 5901
#
# 管线内置的"真"验证关卡。失败要中止 import-guest。

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "c40-smoke-guest"

GUEST_NAME="${GUEST_NAME:-cuckoo1}"
GUEST_IP="${GUEST_IP:-192.168.122.105}"

# ---- 幂等守卫 ----
if done_or_force \
   [ "$(virsh domstate "$GUEST_NAME" 2>/dev/null)" = "running" ] \
   && agent_alive "$GUEST_IP" 8000; then
  echo "[~] $GUEST_NAME running 且 agent.py:8000 可达，跳过"
  stage_done
  exit 0
fi

# ---- 1. 启动 ----
state=$(virsh domstate "$GUEST_NAME" 2>/dev/null || echo "undefined")
case "$state" in
  running) echo "[✓] domain 已 running" ;;
  "shut off"|paused) virsh start "$GUEST_NAME"; echo "[✓] virsh start" ;;
  *) echo "[-] domain 状态异常: $state"; exit 1 ;;
esac

# ---- 2. 等 domain running ----
if ! virsh_wait_running "$GUEST_NAME" 60; then
  echo "[-] 等 60s 仍不是 running 状态："
  virsh domstate "$GUEST_NAME"
  echo "[!] 当前 XML：" && virsh dumpxml "$GUEST_NAME"
  exit 1
fi
echo "[✓] domain running"

# ---- 3. 轮询 agent.py（120s = 24 × 5s） ----
echo "[+] 轮询 agent.py（最长 120s）"
for i in $(seq 1 24); do
  if agent_alive "$GUEST_IP" 8000; then
    echo "[✓] agent.py 已就绪（第 $((i*5))s）"
    stage_done
    exit 0
  fi
  printf '.'
  sleep 5
done
echo

# ---- 失败 ----
echo "[-] 120s 内 agent.py 未响应 http://${GUEST_IP}:8000/status"
echo "[!] 排查清单："
echo "    1. VNC 连 <TARGET>:5901 看 Win10 是否登录到桌面"
echo "    2. 客户机内 'tasklist | findstr pyw' 看 agent 进程"
echo "    3. 客户机内 'ipconfig' 看 IP 是不是 ${GUEST_IP}"
echo "    4. 客户机内 'curl http://${GUEST_IP}:8000/' 自测 agent"
exit 1
```

- [ ] **Step 2：静态检查**

```bash
bash -n scripts/guest/c40-smoke-guest.sh
shellcheck -s bash scripts/guest/c40-smoke-guest.sh 2>/dev/null || true
```

- [ ] **Step 3：冒烟（无客户机时验证脚本能正确失败）**

```bash
ssh cape@<TARGET> "cd /opt/cape-installer && \
  sudo GUEST_NAME=fake-domain GUEST_IP=192.168.122.99 \
  bash scripts/guest/c40-smoke-guest.sh"
# 期望 exit != 0，日志含 "domain 状态异常: undefined"
```

- [ ] **Step 4：完整端到端测试推迟到 Task 15**

c40 真正能验证 agent.py 必须有真 Win10 客户机。Task 15 会做。

- [ ] **Step 5：commit**

```bash
chmod +x scripts/guest/c40-smoke-guest.sh
git add scripts/guest/c40-smoke-guest.sh
git commit -m "feat(c40): 启 VM + 轮询 agent.py 120s + 失败排查指引"
```

---

## Task 8：`scripts/guest/c50-snapshot-and-cape.sh` 拍快照 + unmask cape

**Files:**
- Create: `scripts/guest/c50-snapshot-and-cape.sh`

- [ ] **Step 1：写脚本**

新建 `scripts/guest/c50-snapshot-and-cape.sh`：

```bash
#!/usr/bin/env bash
# Stage c50-snapshot-and-cape：拍 clean 快照 + 解 mask cape*
# - virsh snapshot-create-as --atomic clean
# - systemctl unmask cape cape-processor
# - systemctl restart cape cape-processor cape-rooter cape-web
# - 确认 cape.service active

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "c50-snapshot-and-cape"

GUEST_NAME="${GUEST_NAME:-cuckoo1}"
SNAPSHOT_NAME=clean

# ---- 幂等守卫 ----
has_snapshot() {
  virsh snapshot-list "$GUEST_NAME" --name 2>/dev/null | grep -qx "$SNAPSHOT_NAME"
}
cape_unmasked() {
  ! systemctl is-enabled cape 2>/dev/null | grep -q masked
}
if done_or_force has_snapshot && cape_unmasked && service_active cape; then
  echo "[~] 快照 $SNAPSHOT_NAME 存在 + cape active，跳过"
  stage_done
  exit 0
fi

# ---- 1. 拍快照 ----
if ! has_snapshot; then
  echo "[+] 拍快照 $SNAPSHOT_NAME（atomic）"
  virsh snapshot-create-as "$GUEST_NAME" \
    --name "$SNAPSHOT_NAME" \
    --description "first clean state with CAPE agent" \
    --atomic
  echo "[✓] 快照已拍"
else
  echo "[~] 快照 $SNAPSHOT_NAME 已存在"
fi
virsh snapshot-list "$GUEST_NAME"

# ---- 2. 解 mask cape & cape-processor ----
echo "[+] unmask cape cape-processor"
systemctl unmask cape cape-processor 2>/dev/null || true
systemctl daemon-reload

# ---- 3. restart cape 全家 ----
echo "[+] restart cape 全家"
systemctl restart cape cape-processor cape-rooter cape-web

# ---- 4. 确认 active ----
sleep 3
for svc in cape cape-processor cape-rooter cape-web; do
  if systemctl is-active --quiet "$svc"; then
    echo "[✓] $svc active"
  else
    echo "[!] $svc 未 active"
    journalctl -u "$svc" -n 30 --no-pager
    exit 1
  fi
done

echo "[✓] Phase C 完成。浏览器访问 http://<TARGET>:8000/submit/ 提交样本测试。"
stage_done
```

- [ ] **Step 2：静态检查**

```bash
bash -n scripts/guest/c50-snapshot-and-cape.sh
shellcheck -s bash scripts/guest/c50-snapshot-and-cape.sh 2>/dev/null || true
```

- [ ] **Step 3：完整端到端验证推迟到 Task 15**

- [ ] **Step 4：commit**

```bash
chmod +x scripts/guest/c50-snapshot-and-cape.sh
git add scripts/guest/c50-snapshot-and-cape.sh
git commit -m "feat(c50): 拍 clean 快照 + unmask cape* + restart 验证"
```

---

## Task 9：`Makefile` 加 c-stage targets + import-guest 元 target

**Files:**
- Modify: `Makefile`

- [ ] **Step 1：在 `UNINSTALL_STAGES :=` 之后追加 C_STAGES**

打开 `Makefile`，找到 `UNINSTALL_STAGES := \` 段（约 41 行）。在它的结束行 `u99-verify` 之后（即 `.PHONY:` 行之前）追加：

```makefile

C_STAGES := \
  c10-import-guest \
  c20-define-domain \
  c30-register-kvm-conf \
  c40-smoke-guest \
  c50-snapshot-and-cape
```

- [ ] **Step 2：把 `.PHONY:` 行扩展**

把现有 `.PHONY: all clean help force-% uninstall uninstall-dry uninstall-yes $(STAGES) $(UNINSTALL_STAGES)` 改成：

```makefile
.PHONY: all clean help force-% uninstall uninstall-dry uninstall-yes import-guest $(STAGES) $(UNINSTALL_STAGES) $(C_STAGES)
```

- [ ] **Step 3：在卸载 stage 块之后插入 c-stage 编排**

在 `u99-verify: ; bash scripts/uninstall/u99-verify.sh` 那行之后、`force-%:` 那行之前插入：

```makefile

# ----- Phase C：客户机导入 -----
# import-guest 必须传 GUEST_QCOW2=/path/to.qcow2
ifneq ($(filter import-guest $(C_STAGES),$(MAKECMDGOALS)),)
ifeq ($(GUEST_QCOW2),)
$(error 必须传 GUEST_QCOW2: sudo make import-guest GUEST_QCOW2=/tmp/cuckoo1.qcow2)
endif
ifeq ($(wildcard $(GUEST_QCOW2)),)
$(error GUEST_QCOW2 文件不存在: $(GUEST_QCOW2))
endif
endif

import-guest: $(C_STAGES)

c10-import-guest:                                  ; bash scripts/guest/c10-import-guest.sh
c20-define-domain:    c10-import-guest             ; bash scripts/guest/c20-define-domain.sh
c30-register-kvm-conf: c20-define-domain           ; bash scripts/guest/c30-register-kvm-conf.sh
c40-smoke-guest:      c30-register-kvm-conf        ; bash scripts/guest/c40-smoke-guest.sh
c50-snapshot-and-cape: c40-smoke-guest             ; bash scripts/guest/c50-snapshot-and-cape.sh
```

- [ ] **Step 4：在 `help` target 加 Phase C 段**

找到 `help:` target 内的 echo 列表（约 99-115 行）。在 `@echo "其他："` 之前插入：

```makefile
	@echo "Phase C 客户机："
	@echo "  sudo make import-guest GUEST_QCOW2=/path/to.qcow2"
	@echo "                                # 校验 + 注册 + 启 VM + 拍快照 + unmask cape"
	@echo "  sudo make c<NN>-<stage>       # 单步：c10-import-guest / c20-define-domain / ..."
	@echo ""
```

在末尾 `$(foreach s,$(UNINSTALL_STAGES),...)` 之后追加：

```makefile
	@$(foreach s,$(C_STAGES),echo "  phase-c:  $(s)";)
```

- [ ] **Step 5：Makefile 解析 + GUEST_QCOW2 强校验**

```bash
make help | grep -E '(import-guest|phase-c)'
# 期望：3+ 行命中

# 不传 GUEST_QCOW2 应硬失败
ssh cape@<TARGET> "cd /opt/cape-installer && sudo make import-guest 2>&1 | head -3"
# 期望：Makefile error "必须传 GUEST_QCOW2: ..."

# 传不存在的文件应硬失败
ssh cape@<TARGET> "cd /opt/cape-installer && sudo make import-guest GUEST_QCOW2=/nonexistent.qcow2 2>&1 | head -3"
# 期望：Makefile error "GUEST_QCOW2 文件不存在"
```

- [ ] **Step 6：commit**

```bash
git add Makefile
git commit -m "feat(make): 加 5 个 c-stage target + import-guest 元 target + GUEST_QCOW2 强校验"
```

---

## Task 10：`scripts/guest/c-guest-prep.ps1` 客户机内加固

**Files:**
- Create: `scripts/guest/c-guest-prep.ps1`

> 这一步只能在真 Win10 客户机内端到端验证，本地只做语法检查。

- [ ] **Step 1：写脚本**

新建 `scripts/guest/c-guest-prep.ps1`：

```powershell
# c-guest-prep.ps1 — 在 Win10 LTSC 客户机内以 Administrator 跑
# 用途：
#   1. 关 Defender / Tamper / SmartScreen / Update / Telemetry / UAC / Firewall
#   2. 装 Python 3.12 + 拉 agent.py + 改 .pyw + 注册启动项
#   3. 配静态 IP (默认 192.168.122.105/24, gw 192.168.122.1)
#   4. shutdown /s /t 0
#
# 用法（客户机内 Admin PowerShell）：
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   .\c-guest-prep.ps1

[CmdletBinding()]
param(
  [string]$GuestIP = '192.168.122.105',
  [string]$GatewayIP = '192.168.122.1',
  [int]$Prefix = 24,
  [string]$DnsServer = '192.168.122.1',
  [string]$AgentUrl = 'https://gh-proxy.com/https://raw.githubusercontent.com/kevoreilly/CAPEv2/master/agent/agent.py',
  [string]$PythonInstallerUrl = 'https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe',
  [switch]$NoShutdown
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Step($msg) { Write-Host "[+] $msg" -ForegroundColor Cyan }
function OK($msg)   { Write-Host "[✓] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Die($msg)  { Write-Host "[-] $msg" -ForegroundColor Red; exit 1 }

# ---- 0. 必须 Admin ----
$isAdmin = ([Security.Principal.WindowsPrincipal] `
  [Security.Principal.WindowsIdentity]::GetCurrent() `
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Die '必须以 Administrator 启动 PowerShell' }
OK 'Admin 已确认'

# ---- 1. 关 Defender 实时保护 ----
Step '关 Defender 实时保护'
Set-MpPreference -DisableRealtimeMonitoring $true       -ErrorAction SilentlyContinue
Set-MpPreference -DisableIOAVProtection      $true       -ErrorAction SilentlyContinue
Set-MpPreference -DisableBehaviorMonitoring  $true       -ErrorAction SilentlyContinue
Set-MpPreference -DisableBlockAtFirstSeen    $true       -ErrorAction SilentlyContinue
Set-MpPreference -DisableScriptScanning      $true       -ErrorAction SilentlyContinue
Set-MpPreference -DisableArchiveScanning     $true       -ErrorAction SilentlyContinue
Set-MpPreference -SubmitSamplesConsent       NeverSend   -ErrorAction SilentlyContinue
OK 'Defender 实时保护已关'

# ---- 2. 关 Tamper Protection ----
Step '关 Tamper Protection'
$tamperKey = 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features'
if (-not (Test-Path $tamperKey)) { New-Item -Path $tamperKey -Force | Out-Null }
New-ItemProperty -Path $tamperKey -Name TamperProtection -Value 0 -PropertyType DWord -Force | Out-Null
OK 'Tamper Protection 已关'

# ---- 3. 关 Defender 整体（组策略）----
Step '关 Defender 整体（组策略）'
$defGpoKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
if (-not (Test-Path $defGpoKey)) { New-Item -Path $defGpoKey -Force | Out-Null }
New-ItemProperty -Path $defGpoKey -Name DisableAntiSpyware           -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $defGpoKey -Name DisableRoutinelyTakingAction -Value 1 -PropertyType DWord -Force | Out-Null
OK '组策略禁用 Defender'

# ---- 4. 关 SmartScreen ----
Step '关 SmartScreen'
$ssKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'
New-ItemProperty -Path $ssKey -Name SmartScreenEnabled -Value 'Off' -PropertyType String -Force | Out-Null
$ssGpo = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
if (-not (Test-Path $ssGpo)) { New-Item -Path $ssGpo -Force | Out-Null }
New-ItemProperty -Path $ssGpo -Name EnableSmartScreen -Value 0 -PropertyType DWord -Force | Out-Null
OK 'SmartScreen 已关'

# ---- 5. 关 Windows Update ----
Step '关 Windows Update'
Set-Service wuauserv -StartupType Disabled
Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
$wuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
if (-not (Test-Path $wuKey)) { New-Item -Path $wuKey -Force | Out-Null }
New-ItemProperty -Path $wuKey -Name NoAutoUpdate -Value 1 -PropertyType DWord -Force | Out-Null
OK 'Windows Update 已关'

# ---- 6. 关遥测 ----
Step '关遥测'
$telKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
if (-not (Test-Path $telKey)) { New-Item -Path $telKey -Force | Out-Null }
New-ItemProperty -Path $telKey -Name AllowTelemetry -Value 0 -PropertyType DWord -Force | Out-Null
Set-Service DiagTrack         -StartupType Disabled -ErrorAction SilentlyContinue
Stop-Service DiagTrack        -Force -ErrorAction SilentlyContinue
Set-Service dmwappushservice  -StartupType Disabled -ErrorAction SilentlyContinue
Stop-Service dmwappushservice -Force -ErrorAction SilentlyContinue
OK '遥测已关'

# ---- 7. 关 UAC ----
Step '关 UAC（重启生效）'
$uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
New-ItemProperty -Path $uacKey -Name EnableLUA                  -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uacKey -Name ConsentPromptBehaviorAdmin -Value 0 -PropertyType DWord -Force | Out-Null
OK 'UAC 已关'

# ---- 8. 关防火墙 ----
Step '关防火墙'
netsh advfirewall set allprofiles state off | Out-Null
OK '防火墙已关'

# ---- 9. 电源 / 错误报告 / 蓝屏自动重启 ----
Step '电源永不待机 + 关错误报告 + 关蓝屏重启'
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change monitor-timeout-ac 0
powercfg /change monitor-timeout-dc 0
powercfg /h off
$werKey = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'
New-ItemProperty -Path $werKey -Name Disabled -Value 1 -PropertyType DWord -Force | Out-Null
$crashKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
New-ItemProperty -Path $crashKey -Name AutoReboot -Value 0 -PropertyType DWord -Force | Out-Null
OK '电源 / 错误报告 / 蓝屏配置完成'

# ---- 10. 装 Python 3.12 ----
Step "装 Python 3.12（$PythonInstallerUrl）"
$pyExe = "$env:TEMP\python-installer.exe"
Invoke-WebRequest -Uri $PythonInstallerUrl -OutFile $pyExe -UseBasicParsing
Start-Process -FilePath $pyExe -ArgumentList @(
  '/quiet','InstallAllUsers=1','PrependPath=1',
  'Include_test=0','Include_doc=0','Include_launcher=1'
) -Wait -NoNewWindow
$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine')
$pyVer = & python --version 2>&1
if ($pyVer -notmatch '^Python 3\.12\.') { Die "Python 装失败：$pyVer" }
OK "Python: $pyVer"

# ---- 11. 拉 agent.py ----
Step "拉 agent.py（$AgentUrl）"
$agentDst = 'C:\agent.pyw'
Invoke-WebRequest -Uri $AgentUrl -OutFile $agentDst -UseBasicParsing
if (-not (Test-Path $agentDst) -or (Get-Item $agentDst).Length -lt 1024) {
  Die "agent.py 下载失败：$agentDst 不存在或太小"
}
OK "agent.pyw → $agentDst"

# ---- 12. 注册启动项 ----
Step '注册 agent.pyw 自启动'
$pyw = (Get-Command pythonw.exe -ErrorAction Stop).Source
$runKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
New-ItemProperty -Path $runKey -Name CAPE_Agent `
  -Value "`"$pyw`" `"$agentDst`"" -PropertyType String -Force | Out-Null
OK "启动项已注册：$pyw $agentDst"

# ---- 13. 配静态 IP ----
Step "配静态 IP $GuestIP/$Prefix gw=$GatewayIP dns=$DnsServer"
$adapter = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
if (-not $adapter) { Die '找不到 Up 状态的物理网卡' }

Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue `
  | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue

New-NetIPAddress `
  -InterfaceIndex $adapter.ifIndex `
  -IPAddress $GuestIP `
  -PrefixLength $Prefix `
  -DefaultGateway $GatewayIP | Out-Null

Set-DnsClientServerAddress `
  -InterfaceIndex $adapter.ifIndex `
  -ServerAddresses $DnsServer

OK "静态 IP 配置完成（adapter: $($adapter.Name)）"

# ---- 14. 总结 ----
Write-Host ''
Write-Host '================================================================' -ForegroundColor Green
Write-Host '              c-guest-prep.ps1 全部完成' -ForegroundColor Green
Write-Host '================================================================' -ForegroundColor Green
Write-Host ''
Write-Host '下一步：'
Write-Host '  1. （可选）关闭浏览器、资源管理器多余窗口，把客户机置回干净桌面状态'
Write-Host '  2. 关机：shutdown /s /t 0 （或加 -NoShutdown 跳过）'
Write-Host '  3. 在 Mac 上跑 scripts/guest/c-host-export.sh 推送服务器'
Write-Host ''

# ---- 15. 关机 ----
if (-not $NoShutdown) {
  Step '60s 后关机（Ctrl+C 取消）'
  Start-Sleep -Seconds 60
  shutdown /s /t 0
}
```

- [ ] **Step 2：本地 PowerShell 语法检查（macOS）**

```bash
# 装 pwsh：brew install --cask powershell （如还没装）
pwsh -NoProfile -NonInteractive -Command "
  \$tokens = \$null; \$errs = \$null
  [System.Management.Automation.Language.Parser]::ParseFile(
    '$(pwd)/scripts/guest/c-guest-prep.ps1', [ref]\$tokens, [ref]\$errs)
  if (\$errs.Count -gt 0) { \$errs | ForEach-Object { Write-Host \$_ }; exit 1 }
  Write-Host 'OK: 0 syntax errors'
"
```

预期：`OK: 0 syntax errors`

- [ ] **Step 3：commit**

```bash
git add scripts/guest/c-guest-prep.ps1
git commit -m "feat(c-guest-prep): Win10 LTSC 客户机内加固 + agent.py 注入 + 静态 IP"
```

---

## Task 11：`scripts/guest/c-host-export.sh` Mac 上转换+推送

**Files:**
- Create: `scripts/guest/c-host-export.sh`

**职责**：在 Intel Mac shell 跑。校验 UTM 出来的 qcow2 是合法格式 + 无 backing file → 算 sha256 → scp + retry 推送。**无 qemu-img convert**（UTM 直接出 qcow2）。

- [ ] **Step 1：写脚本**

新建 `scripts/guest/c-host-export.sh`：

```bash
#!/usr/bin/env bash
# c-host-export.sh — 在 Intel Mac 上跑：校验 UTM qcow2 + 推送 CAPE 服务器
# 用途：UTM 客户机关机后，把 qcow2 文件 + sha256 sidecar 推到服务器
# 前置：
#   - UTM 客户机内已跑过 c-guest-prep.ps1 + 已关机
#   - Mac 上装了 qemu-img: brew install qemu
#   - Mac 上 ssh 能免密连服务器（或交互输入密码）

set -eEuo pipefail

# Defaults
SERVER=
SERVER_USER=cape
SERVER_PATH=/tmp/cuckoo1.qcow2
QCOW2=
SCP_RETRIES=3

usage() {
  cat <<EOF
用法: bash c-host-export.sh -q <qcow2> -s <server> [-u <user>] [-p <remote-path>]

参数:
  -q  本地 qcow2 路径（UTM VM 的磁盘文件）
  -s  CAPE 服务器地址（必填）
  -u  服务器用户（默认 cape）
  -p  服务器目标路径（默认 /tmp/cuckoo1.qcow2）

定位 UTM qcow2:
  默认 UTM 把 VM 存在
  ~/Library/Containers/com.utmapp.UTM/Data/Documents/<VM>.utm/Data/<disk>.qcow2

  Finder 中右键 .utm 文件 → "显示包内容" 进入 Data 目录定位 qcow2
EOF
}

while getopts "q:s:u:p:h" opt; do
  case "$opt" in
    q) QCOW2=$OPTARG ;;
    s) SERVER=$OPTARG ;;
    u) SERVER_USER=$OPTARG ;;
    p) SERVER_PATH=$OPTARG ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

# Color logging
C_CYN=$'\033[36m'; C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_YLW=$'\033[33m'; C_RST=$'\033[0m'
log()  { printf '%s[+]%s %s\n' "$C_CYN" "$C_RST" "$*" >&2; }
ok()   { printf '%s[✓]%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[-]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# ---- 1. 参数校验 ----
[ -n "$QCOW2"  ] || { usage; die '缺 -q <qcow2>'; }
[ -n "$SERVER" ] || { usage; die '缺 -s <server>'; }
[ -f "$QCOW2"  ] || die "qcow2 不存在: $QCOW2"

# ---- 2. qemu-img 必须存在 ----
command -v qemu-img >/dev/null \
  || die "找不到 qemu-img。装：brew install qemu"
ok "qemu-img: $(qemu-img --version | head -1)"

# ---- 3. 检查 qcow2 合法格式 ----
log '校验 qcow2 格式'
qemu-img info "$QCOW2" | grep -q 'file format: qcow2' \
  || die "$QCOW2 不是合法 qcow2"
ok 'qcow2 格式 OK'

# ---- 4. 检查无 backing file ----
if qemu-img info "$QCOW2" | grep -q '^backing file:'; then
  die "$QCOW2 有 backing file（来自 UTM 快照）。在 UTM 删除快照让镜像 standalone 后重试"
fi
ok '无 backing file 依赖'

# ---- 5. 检查 VM 没在跑 ----
if pgrep -f "qemu-system-x86_64.*$(basename "$QCOW2")" >/dev/null; then
  die 'VM 仍在运行——UTM 里关闭客户机后重试'
fi
ok 'VM 未运行'

# ---- 6. 算 sha256 sidecar ----
log '算 sha256'
sha256_file="${QCOW2}.sha256"
shasum -a 256 "$QCOW2" \
  | awk -v f="$(basename "$QCOW2")" '{print $1"  "f}' \
  > "$sha256_file"
hash=$(awk '{print $1}' "$sha256_file")
ok "sha256: $hash"

# ---- 7. scp + retry ----
remote_qcow2="${SERVER_USER}@${SERVER}:${SERVER_PATH}"
remote_sha="${SERVER_USER}@${SERVER}:${SERVER_PATH}.sha256"

scp_with_retry() {
  local src=$1 dst=$2 delay=5
  local i
  for i in $(seq 1 "$SCP_RETRIES"); do
    log "scp $src → $dst （第 $i/$SCP_RETRIES 次）"
    if scp "$src" "$dst"; then
      return 0
    fi
    if [ "$i" -lt "$SCP_RETRIES" ]; then
      warn "scp 失败，${delay}s 后重试"
      sleep "$delay"
      delay=$((delay * 3))
    fi
  done
  return 1
}

scp_with_retry "$QCOW2"      "$remote_qcow2" || die 'scp qcow2 失败'
scp_with_retry "$sha256_file" "$remote_sha"  || die 'scp sha256 失败'
ok '推送完成'

# ---- 8. 总结 ----
cat <<EOF

================================================================
              c-host-export.sh 完成
================================================================

下一步在服务器上跑：
  ssh ${SERVER_USER}@${SERVER}
  cd /opt/cape-installer
  sudo make import-guest GUEST_QCOW2=${SERVER_PATH}
EOF
```

- [ ] **Step 2：本地静态检查（Mac）**

```bash
bash -n scripts/guest/c-host-export.sh
shellcheck -s bash scripts/guest/c-host-export.sh 2>/dev/null || true

# 帮助打印检查
bash scripts/guest/c-host-export.sh -h | head -5
```

预期：`bash -n` 通过；`-h` 打印用法。

- [ ] **Step 3：（无客户机时）伪装个 qcow2 测各种校验**

```bash
# 造合法 qcow2
qemu-img create -f qcow2 /tmp/test.qcow2 100M

# 缺 -s 应失败
bash scripts/guest/c-host-export.sh -q /tmp/test.qcow2 2>&1 | head -3
# 期望：含 "缺 -s"

# 错误格式（raw）应失败
qemu-img create -f raw /tmp/test.raw 100M
bash scripts/guest/c-host-export.sh -q /tmp/test.raw -s fake.example.com 2>&1 | head -5
# 期望：含 "不是合法 qcow2"

rm /tmp/test.qcow2 /tmp/test.raw
```

- [ ] **Step 4：commit**

```bash
chmod +x scripts/guest/c-host-export.sh
git add scripts/guest/c-host-export.sh
git commit -m "feat(c-host-export): Mac 上校验 UTM qcow2 + sha256 + scp 推送"
```

---

## Task 12：`docs/BUILD-GUEST-ON-MAC.md` Mac (UTM) 完整手册

**Files:**
- Create: `docs/BUILD-GUEST-ON-MAC.md`

- [ ] **Step 1：写文档**

新建 `docs/BUILD-GUEST-ON-MAC.md`：

````markdown
# 在 Intel Mac (UTM) 上构建 CAPE 分析客户机

本文是 cape-installer Phase C 的**操作手册**。当 CAPE 服务器是 headless（仅 SSH，无 GUI）时使用。

完成后产出：服务器上 `cuckoo1` 客户机注册到 CAPE，能跑样本分析。

> **前提**：服务器已成功跑过 `sudo make all`（Phase B 完成）。
> **平台前提**：**Intel Mac**（Apple Silicon 因 x86_64 模拟过慢不在本路径范围）

---

## 0. 总览

```
[ Intel Mac (UTM) ]                              [ Ubuntu CAPE 服务器 ]
─────────────────                                ──────────────────────
① UTM 装 Win10 LTSC（手工，一次性）
② c-guest-prep.ps1（客户机内 Admin）
③ c-host-export.sh（Mac shell）              ──▶  /tmp/cuckoo1.qcow2(.sha256)
                                                  ④ sudo make import-guest \
                                                       GUEST_QCOW2=/tmp/cuckoo1.qcow2
                                                  ⑤ 浏览器交付样本测试
```

---

## 1. 先决条件

### 1.1 Mac 工作站

```bash
# 装 UTM（QEMU 的 Mac GUI 前端）
brew install --cask utm

# 装 qemu-img（c-host-export.sh 校验用）
brew install qemu

# 装 PowerShell（用于本地语法检查脚本，可选）
brew install --cask powershell

# 验证 ssh + scp（macOS 自带）
which scp ssh
```

### 1.2 客户机 ISO

下载 **Windows 10 LTSC 2021 x64**（推荐 LTSC 而不是 Pro/Home）。LTSC 没 Edge / Cortana / Store / Xbox 等 bloat，反检测脚本要做的事少很多。

ISO 来源：微软 VLSC、MSDN、企业试用渠道。

### 1.3 服务器侧

```bash
ssh cape@<TARGET>
cd /opt/cape-installer
sudo make help | grep import-guest    # 期望命中
```

---

## 2. UTM 装 Win10 LTSC

### 2.1 创建 VM

打开 UTM → "Create a New Virtual Machine" → **Virtualize**（不是 Emulate）→ **Windows**：

| 选项 | 值 | 备注 |
|---|---|---|
| Boot ISO Image | 选你的 Win10 LTSC ISO | |
| Hardware → Memory | 4096 MB | 与 `GUEST_RAM_MB` 默认一致 |
| Hardware → CPU Cores | 2 | 与 `GUEST_VCPUS` 默认一致 |
| Storage | 40 GB | qcow2 实际用 5-15 GB |
| Shared Directory | **不勾** | 不要 SPICE Tools |
| Summary → Save | Name = `Win10LTSC-CAPE` | |

创建后**先不要启动**——再修两个关键设置：

**Settings → System** → "BIOS" 或 "Firmware":
- **必选 Legacy BIOS**（不要 UEFI 也不要 UEFI+SecureBoot）
- 否则反 VM SeaBIOS 不兼容

**Settings → QEMU** → "Arguments":
- 移除任何 `-cdrom` 之外的 SPICE / 共享相关参数

### 2.2 装 Windows

启动 VM → 走标准 Win10 装机流程：
- 语言、键盘选默认
- 选 Custom Install → 选磁盘
- 不要联网（创建本地账户）
- 装到桌面后**不要装任何 Tools**

### 2.3 把 c-guest-prep.ps1 送进客户机

推荐方法：**做 ISO 挂载**

```bash
# Mac 上：
mkdir -p /tmp/cape-iso
cp scripts/guest/c-guest-prep.ps1 /tmp/cape-iso/
hdiutil makehybrid -o /tmp/cape.iso -iso -default-volume-name CAPE /tmp/cape-iso
```

UTM → Settings → 加 CD/DVD 设备 → 挂 `/tmp/cape.iso` → 客户机里 D: 盘可见。

### 2.4 跑 c-guest-prep.ps1

客户机内以 **Administrator** 启动 PowerShell（开始菜单 → 右键 PowerShell → 以管理员运行）：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
D:\c-guest-prep.ps1

# 默认 IP 192.168.122.105。要换：
# D:\c-guest-prep.ps1 -GuestIP 192.168.122.106
```

脚本会跑 5-10 分钟，然后**自动关机**（等 60s 给你 Ctrl+C 取消的机会）。

---

## 3. 转推送到服务器

UTM 关机后，**找到 qcow2 文件**：

```bash
# 默认位置（Finder 中右键 .utm 文件 → 显示包内容）
ls ~/Library/Containers/com.utmapp.UTM/Data/Documents/Win10LTSC-CAPE.utm/Data/
# 期望：看到一个 *.qcow2 文件
```

跑导出脚本：

```bash
cd /path/to/cape-installer
bash scripts/guest/c-host-export.sh \
  -q ~/Library/Containers/com.utmapp.UTM/Data/Documents/Win10LTSC-CAPE.utm/Data/<UUID>.qcow2 \
  -s <SERVER-IP>
```

脚本完成后会打印**服务器上下一步的命令**。

---

## 4. 服务器侧导入

```bash
ssh cape@<TARGET>
cd /opt/cape-installer
sudo make import-guest GUEST_QCOW2=/tmp/cuckoo1.qcow2
```

约 2-3 分钟跑完 5 个 c-stage：

| Stage | 做什么 |
|---|---|
| c10-import-guest | 校验 sha256 + 拷贝到 `/var/lib/libvirt/images/cuckoo1.qcow2` |
| c20-define-domain | 渲染 libvirt XML + `virsh define` + DHCP reservation |
| c30-register-kvm-conf | crudini 写 `/opt/CAPEv2/conf/kvm.conf [cuckoo1]` |
| c40-smoke-guest | `virsh start` + 轮询 agent.py:8000（最长 120s） |
| c50-snapshot-and-cape | `virsh snapshot-create-as clean` + unmask + restart cape |

---

## 5. 验证

```bash
sudo virsh list --all              # cuckoo1 应是 "running"
sudo virsh snapshot-list cuckoo1   # 应含 "clean"
sudo systemctl status cape         # active
curl http://192.168.122.105:8000/  # 应返回 JSON
```

端到端样本：浏览器 `http://<TARGET>:8000/submit/` 上传 notepad.exe。预期 Pending → Running → Completed（约 30s）。

---

## 6. 故障排查

| 现象 | 原因 | 对策 |
|---|---|---|
| c10 报 "sha256 不匹配" | scp 中途出错 | Mac 上重跑 `c-host-export.sh` |
| c-host-export 报 "有 backing file" | UTM 拍过快照 | UTM 里删除快照让镜像 standalone |
| c20 报 "virsh define 失败" | XML 渲染异常 / domain 残留 | `cat /tmp/cuckoo1.domain.xml`；`sudo make force-c20-define-domain` |
| c40 120s agent 不响应 | 客户机 IP 没起 / agent 没自启 / Defender 未关 | VNC 5901 看客户机；`tasklist | findstr pyw` |
| 客户机起不来报 `bios.bin` | stage 51 SeaBIOS 替换异常 | `sudo make force-51-anti-vm-seabios` |
| 任务一直 Pending | cape-rooter 没起 / agent 不在 | `sudo systemctl status cape-rooter` |

---

## 7. 重做与多客户机

### 7.1 改 c-guest-prep.ps1 后只重做客户机

UTM 里把 VM 滚回到 c-guest-prep.ps1 之前的状态（建议在 Win10 装完时拍 UTM 快照），重跑 ps1 → 重跑 c-host-export.sh → 服务器 `sudo make force-c10-import-guest GUEST_QCOW2=...` 强制覆盖 qcow2。

### 7.2 加第二台 cuckoo2（未来）

未来扩展。目前 Makefile 只处理一个 GUEST_NAME。手工方式：在 `config.env` 改 `GUEST_NAME=cuckoo2 GUEST_IP=192.168.122.106 GUEST_MAC=52:54:00:CA:FE:02` 后重跑 `make import-guest`，c30 会把 cuckoo2 追加到 `[kvm] machines`。
````

- [ ] **Step 2：commit**

```bash
git add docs/BUILD-GUEST-ON-MAC.md
git commit -m "docs(BUILD-GUEST-ON-MAC): Mac UTM 完整 Phase C 操作手册"
```

---

## Task 13：`docs/WHY.md` 加 ADR-Phase-C + ADR-layout-refactor

**Files:**
- Modify: `docs/WHY.md`

- [ ] **Step 1：在 WHY.md 末尾追加两条 ADR**

打开 `docs/WHY.md`，在文件末尾追加：

```markdown

---

## ADR-layout-refactor：scripts/ 拆 install/ + uninstall/ + guest/（2026-04-30 追加）

**上下文**：原来 19 个 stage 平铺在 `scripts/`，加 Phase C 又要新增 8 个文件——不分目录会变成 27 个文件混杂，维护和查找都吃力。

**选择**：`scripts/install/`（9 个安装 stage）+ `scripts/uninstall/`（10 个卸载 stage）+ `scripts/guest/`（Phase C 全部新增）。

**备选**：
- A 留原状不重构 — 27 个文件混杂
- B 按 phase 分（phase-b-install / phase-b-uninstall / phase-c）— 命名长，"phase" 概念用户不熟
- C 按文件类型（bash/ powershell/ template/）— 反模式："变更一起的东西放一起"原则

**理由**：
- `install/` + `uninstall/` 与现有 Makefile target 命名一致
- `guest/` 与 libvirt/CAPE 术语一致（guest VM）
- `lib/` + `vendor/` 不动——多方共享，单一所有者无意义
- `domain-cuckoo1.xml.tmpl` 放 `scripts/guest/` 而不是 `vendor/`（它是我们写的，不是上游 vendor 资产）

**影响**：
- 19 个现有脚本 git mv，每个改 1 行 source fallback 路径（`/..` → `/../..`）
- Makefile 19 行 path 全改 + force-% 规则扩展为三目录查找
- README.md 仓库结构图重画
- 本文件 ADR-Q3 的文件树同步更新

---

## ADR-Phase-C：Intel Mac (UTM) 构建客户机管线（2026-04-30 追加）

**上下文**：cape-installer 完成 Phase B 后必须接入一台 Windows 客户机才能真正分析样本。`README §5` 是直接在服务器 `virt-install` + VNC 的手工路径，但当：
- 服务器是 headless（仅 SSH，无显示器）
- 操作者只有 Mac

VNC 装 Win10 体验差，每次都要在 5901 拉桌面装系统、敲数十项反检测策略，效率低且易漏。

**选择**：**Approach A on Intel Mac with UTM**——客户机内脚本化加固 + 服务器端自动注册 + 跨主机交接靠单 qcow2 + sha256。详见 spec [`docs/superpowers/specs/2026-04-30-phase-c-utm-mac-build-pipeline-design.md`](superpowers/specs/2026-04-30-phase-c-utm-mac-build-pipeline-design.md)。

**备选**：
- B：Mac + VMware Fusion — 收费 + VMDK→qcow2 转换 + Fusion 痕迹清理（用户已抛弃）
- C：服务器侧 + SSH 隧道 VNC — 仅当 Mac 是 Apple Silicon 时才必走这条
- D：autounattend.xml 全自动 — 实施成本高，回报低（只装 1-2 台时）

**理由**：
- **UTM 与服务器同 hypervisor (QEMU)**——qcow2 原生输出，零格式转换；anti-VM 痕迹差异为零
- 把"高密度高重复"的客户机内加固 30+ 项**脚本化**（c-guest-prep.ps1）
- 把"一次性、易错"的 Windows 装机**保留手工**（UTM GUI 装机一次完事）
- 跨主机交接 = 单 qcow2 + sha256 sidecar，零反向 SSH

**影响**：
- 新增 `scripts/guest/` 含 5 个 c-stage bash + 1 个 in-guest PowerShell + 1 个 Mac shell + 1 个 XML 模板
- `Makefile` 加 `import-guest` target + `GUEST_QCOW2` 强校验
- `lib/common.sh` 加 4 个 helper（`render_template` / `virsh_wait_running` / `agent_alive` / `kvm_conf_section_exists`）
- `config.env.sample` 加 5 个 GUEST_* 参数
- 新增 `docs/BUILD-GUEST-ON-MAC.md`

**关键技术决策**：

| 决策点 | 选择 | 理由 |
|---|---|---|
| Win 版本 | Win10 LTSC | 现代样本兼容；LTSC 比 Pro/Home 少 bloat |
| Hypervisor | UTM（不 Fusion） | 免费 + 同 server hypervisor + qcow2 原生 |
| 自动化深度 | docs + helper scripts | 客户机加固高密度脚本化；装机一次性手工 |
| IP 策略 | 双保险（DHCP reservation + 客户机内静态） | 单点失败容忍 |
| MAC | 固定 `52:54:00:CA:FE:01` | DHCP reservation 可工作 |
| 磁盘 SATA / 网卡 e1000 | SATA + e1000 | Win10 自带驱动；virtio 需注入 |
| 跨主机交接 | 单 qcow2 + sha256 sidecar | 极简契约 |
| 快照在哪拍 | 服务器侧（c50） | libvirt 在 qcow2 元数据里管 |

**已知不在范围**：
- autounattend.xml 无人值守装 Win10
- 多客户机批量（cuckoo2/3...）：c30 已支持追加，但 Makefile 当前只处理一个 GUEST_NAME
- virtio-win 驱动注入路径
- Apple Silicon Mac 支持（x86_64 模拟过慢）
- Fusion 路径（已明确抛弃）
```

- [ ] **Step 2：检查 markdown**

```bash
command -v markdownlint >/dev/null && markdownlint docs/WHY.md || echo "skip"
```

- [ ] **Step 3：commit**

```bash
git add docs/WHY.md
git commit -m "docs(WHY): 加 ADR-layout-refactor + ADR-Phase-C（UTM Mac 路径）"
```

---

## Task 14：`README.md` / `docs/INSTALL.md` / `docs/UNINSTALL.md` / `CLAUDE.md` 加指针

**Files:**
- Modify: `README.md`
- Modify: `docs/INSTALL.md`
- Modify: `docs/UNINSTALL.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1：README.md "5. 添加分析客户机 (Phase C)" 节加指针**

打开 `README.md`，找到 `## 5. 添加分析客户机 (Phase C)` 那行。在它之后、在 `cape-installer 自动化的是 **Phase B**...` 之前插入：

```markdown
> **如果你的服务器是 headless 且你只有 Mac**——本仓库提供
> 一条**在 Intel Mac (UTM) 构建 + scp 推服务器自动注册**的更便捷路径。详见
> [docs/BUILD-GUEST-ON-MAC.md](docs/BUILD-GUEST-ON-MAC.md)。
>
> 本节剩余内容是直接在服务器上 `virt-install` 的手工路径。两条路径并存，按需挑选。

```

- [ ] **Step 2：README.md 第 6 节 "文档导航" 表格加一行**

在 `WHY.md` 那行之前插入：

```markdown
| `docs/BUILD-GUEST-ON-MAC.md` | 在 Intel Mac (UTM) 构建客户机推送服务器（Phase C 替代路径） |
```

- [ ] **Step 3：docs/INSTALL.md 末尾加段**

打开 `docs/INSTALL.md`，在文件末尾追加：

```markdown

---

## Phase C：分析客户机接入

`make all` 跑完是 Phase B（host stack + KVM/libvirt + 反 VM）。要让 CAPE 真正分析样本，需要在 virbr0 上接入一台 Windows 客户机。两条路径：

1. **直接在服务器上 `virt-install` + VNC 装机**（默认路径，README §5 详解）
2. **Intel Mac (UTM) 构建 + `make import-guest` 自动注册**（headless 服务器推荐）—— 详见 [BUILD-GUEST-ON-MAC.md](BUILD-GUEST-ON-MAC.md)
```

- [ ] **Step 4：docs/UNINSTALL.md 路径检查（一般无需改）**

`docs/UNINSTALL.md` 通常引用 stage 名（`u30-purge-apt`）而不是路径，但 grep 一下确认：

```bash
grep -n 'scripts/' docs/UNINSTALL.md
```

如果有 `scripts/u<NN>-*.sh` 形式的引用，替换为 `scripts/uninstall/u<NN>-*.sh`。**没有则跳过此 step。**

- [ ] **Step 5：CLAUDE.md 加 import-guest + Phase C 段**

打开 `CLAUDE.md`。

**修改 1**：在 "Common commands" 段，找到 `make help` 那行，在它之前插入：

```markdown
sudo make import-guest GUEST_QCOW2=...   # Phase C: register a pre-built Win10 qcow2 as cuckoo1
sudo make c<NN>-<stage>                # Phase C single stage (c10/c20/c30/c40/c50)
```

**修改 2**：在 "Architecture / Stage orchestration" 段，install/uninstall chain 之后追加：

```markdown
- **Phase C (client guest):** `c10-import-guest → c20-define-domain → c30-register-kvm-conf → c40-smoke-guest → c50-snapshot-and-cape`. Triggered by `sudo make import-guest GUEST_QCOW2=...`. Requires Phase B (`make all`) to have completed. The Mac-side workflow (manual UTM Win10 install + 1 PowerShell in-guest + 1 Mac shell export script) is documented in `docs/BUILD-GUEST-ON-MAC.md`.
```

**修改 3**：CLAUDE.md 中如有 `scripts/<NN>.sh` 形式的路径引用，更新为 `scripts/install/<NN>.sh` 或 `scripts/uninstall/u<NN>.sh`：

```bash
grep -n 'scripts/[0-9u]' CLAUDE.md
```

如果有命中，按规则替换；没有则跳过。

- [ ] **Step 6：检查链接**

```bash
grep -n "BUILD-GUEST-ON-MAC" README.md docs/INSTALL.md CLAUDE.md
# 期望命中至少 3 行
```

- [ ] **Step 7：commit**

```bash
git add README.md docs/INSTALL.md docs/UNINSTALL.md CLAUDE.md
git commit -m "docs: README/INSTALL/UNINSTALL/CLAUDE.md 加 BUILD-GUEST-ON-MAC.md 指针 + 路径更新"
```

---

## Task 15：完整端到端验证

**前置**：Tasks 0-14 全部完成且 commit。**这是验收。**

不写代码——按 `docs/BUILD-GUEST-ON-MAC.md` 操作。

- [ ] **Step 1：Mac 上 UTM 装 Win10 LTSC + c-guest-prep.ps1 跑通**

按 §2 走完。VM 关机后**找到 qcow2 路径**。

- [ ] **Step 2：scp 推服务器**

```bash
bash scripts/guest/c-host-export.sh \
  -q ~/Library/Containers/com.utmapp.UTM/Data/Documents/Win10LTSC-CAPE.utm/Data/<UUID>.qcow2 \
  -s <TARGET>
```

预期：服务器上 `/tmp/cuckoo1.qcow2(.sha256)` 落地。

- [ ] **Step 3：服务器一键导入**

```bash
ssh cape@<TARGET>
cd /opt/cape-installer
time sudo make import-guest GUEST_QCOW2=/tmp/cuckoo1.qcow2
```

预期：5 个 c-stage 顺序通过，总用时 < 5 min。

- [ ] **Step 4：状态验证**

```bash
sudo virsh list --all
sudo virsh snapshot-list cuckoo1     # 期望含 "clean"
sudo systemctl status cape           # active
curl http://192.168.122.105:8000/    # 期望 JSON
```

- [ ] **Step 5：端到端样本测试**

浏览器 `http://<TARGET>:8000/submit/` 上传 `notepad.exe`，点 Analyze。

观察：
- Pending → Running（< 5s）→ Completed（< 1 min）
- `sudo virsh list` 期间 cuckoo1 running
- 任务结束后自动回 clean 快照
- Web UI 任务页面有 behavior log

- [ ] **Step 6：幂等回归**

```bash
time sudo make import-guest GUEST_QCOW2=/tmp/cuckoo1.qcow2
# 期望 < 5s（5 个 stage 全跳过）
```

- [ ] **Step 7：tag release**

```bash
git tag -a phase-c-v1 -m "Phase C: Intel Mac (UTM) 构建客户机管线（端到端验证通过）"
# git push --tags 仅在用户要求 push 时执行
```

---

## Self-Review Checklist

| Spec 段落 | Plan 任务 | 状态 |
|---|---|---|
| §1 背景与动机 | 上下文 | — |
| §2 决策摘要 (Q1-Q4 + UTM 决策) | Task 13 ADR | ✓ |
| §3.1 双侧管线图 | Task 12 §0 总览图 | ✓ |
| §3.2 关键架构选择（4 项） | 所有 c-stage 引用 lib/common.sh 现有契约 | ✓ |
| §4.1 目录重构详情 | **Task 0**（19 个 git mv + 19 个脚本顶部 fallback + 19 行 Makefile + 文档树重画） | ✓ |
| §4.2 Phase C 新增 9 文件 | Tasks 1-12 | ✓ |
| §4.3 命名约定 | Task 0 + Tasks 4-11 文件名 | ✓ |
| §4.4 lib/ vendor/ 不动 | Task 0 不动；Task 13 ADR-layout-refactor 记录 | ✓ |
| §4.6 c-guest-prep 进客户机 3 选项 | Task 12 §2.3 文档化（推荐 ISO 挂载） | ✓ |
| §5.1 Mac↔server 跨主机契约 | Task 4 (c10) + Task 11 (c-host-export) sha256 兼容 | ✓ |
| §5.2 VM 硬件契约 9 项 | Task 3 domain XML 模板 | ✓ |
| §5.3 双保险静态 IP | Task 5 c20 + Task 10 c-guest-prep New-NetIPAddress | ✓ |
| §5.4 kvm.conf 注入 | Task 6 c30 用 crudini，含追加而非覆盖 | ✓ |
| §5.5 config.env 5 参数 | Task 1 全部加上 | ✓ |
| §6.1 c-stage 幂等探测 | Task 4-8 每个有 done_or_force + 具体探针 | ✓ |
| §6.2 FORCE=1 行为 | Task 5 c20 force 测试 | ✓ |
| §6.3 跨 stage 状态保护 | 守卫检系统真相，不用 marker | ✓ |
| §6.4 sha256 不匹配硬失败 | Task 4 c10 + Task 4 Step 5 故意破坏验证 | ✓ |
| §6.5 Mac 侧错误处理（无 backing file 检查） | Task 11 含 backing file 检查 + retry | ✓ |
| §6.6 客户机内 PowerShell ErrorActionPreference | Task 10 含 | ✓ |
| §6.7 失败回滚原则 | Task 5 c20 半成功清理；其他 fail-保留 | ✓ |
| §7.1 c40 集成测试 3 项 | Task 7 c40 完整实现 | ✓ |
| §7.2 端到端人工测试 | Task 15 §5 详解 | ✓ |
| §7.3 幂等性回归 | Task 15 §6 + 各 stage 内置 | ✓ |
| §8 ADR 11 行 | Task 13 完整复制 | ✓ |
| §9 不在范围 | Task 13 ADR 末尾列出 | ✓ |
| §10 实施顺序 | Tasks 0-15 严格按此顺序 | ✓ |
| §11 与旧 spec 差异 | Task 0 是 diff 的核心：Task 4-8 路径 scripts/guest/；Task 11 改为 .sh；Task 12 改为 BUILD-GUEST-ON-MAC.md | ✓ |

**Placeholder scan**：
- Task 7 / Task 8 显式标注"端到端验证推迟到 Task 15"——这是有意的依赖标记，c40/c50 真正验证必须有真客户机
- 无 "TBD" / "implement later" / "fill in details"
- 所有代码块都是完整代码

**Type/symbol 一致性**：
- 4 个 helper 名（render_template / virsh_wait_running / agent_alive / kvm_conf_section_exists）Task 2 定义后 Tasks 4-8 一致引用
- `GUEST_NAME / GUEST_IP / GUEST_MAC / GUEST_RAM_MB / GUEST_VCPUS` 在 Task 1 定义，Tasks 3-9 一致
- `GUEST_QCOW2` 是 Makefile 入参（Task 9 校验）+ c10 消费（Task 4）+ c-host-export 产出（Task 11），三处对得上
- 5 个 c-stage 名（c10-c50）Tasks 4-9 + Task 12-14 全部一致
- 路径 `scripts/guest/` 在 Tasks 3-11 + Makefile (Task 9) + 文档 (Task 12) 一致使用
- `crudini` 用法与现有 `scripts/install/31-cape-config.sh` 模式一致

**Scope check**：单个 plan 含目录重构（Task 0）+ Phase C（Tasks 1-15）。Task 0 在原则上是独立子项目，但范围小（仅文件移动 + 路径修正）+ Phase C 强依赖（必须先重构才能加 `scripts/guest/`），合并到一个 plan 更符合实施顺序。

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-30-phase-c-utm-mac-build-pipeline.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
