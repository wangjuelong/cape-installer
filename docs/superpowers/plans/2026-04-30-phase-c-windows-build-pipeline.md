# Phase C — Windows 工作站构建客户机管线 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 cape-installer 仓库新增 Phase C 工具链——在 Windows 工作站建 Win10 LTSC 客户机 → 转 qcow2 → scp 推服务器 → `sudo make import-guest GUEST_QCOW2=...` 自动注册到 CAPE 并拍 clean 快照。

**Architecture:** 双侧管线（2 个 PowerShell 脚本 + 5 个服务器侧 c-stage bash 脚本）通过单一 qcow2 文件 + sha256 sidecar 跨主机交接。完全沿用 `lib/common.sh` 的 `stage_init/done_or_force/retry` 现有契约；用 `crudini` 改 `kvm.conf`（与 stage 31 一致）；libvirt domain 用 `envsubst` 模板渲染。

**Tech Stack:** Bash (set -eEuo pipefail) + GNU Make + crudini + envsubst + libvirt/virsh + PowerShell 7+ + qemu-img.

**Spec:** `docs/superpowers/specs/2026-04-30-phase-c-windows-build-pipeline-design.md`

**Test environment:**
- **bash 任务**：需要一台已成功跑过 `sudo make all` 的 Ubuntu 24.04 noble 目标机（参考仓库历史 234/240）。本地静态检查用 `shellcheck`、`bash -n`，运行验证 ssh 进目标机跑。
- **PowerShell 任务**：需要装有 PowerShell 7+ 的 macOS（`brew install --cask powershell`）做语法检查；端到端验证需要 Windows 工作站 + VMware。
- **可选**：本地 `bats` 装上能多一层单元测试（不强制，仓库现状无 bats）。

---

## File Structure（任务边界）

```
cape-installer/
├── config.env.sample              EDIT  Task 1
├── lib/common.sh                  EDIT  Task 2 (+4 helpers)
├── vendor/domain-cuckoo1.xml.tmpl NEW   Task 3
├── scripts/
│   ├── c10-import-guest.sh        NEW   Task 4
│   ├── c20-define-domain.sh       NEW   Task 5
│   ├── c30-register-kvm-conf.sh   NEW   Task 6
│   ├── c40-smoke-guest.sh         NEW   Task 7
│   ├── c50-snapshot-and-cape.sh   NEW   Task 8
│   ├── c-guest-prep.ps1           NEW   Task 10
│   └── c-host-export.ps1          NEW   Task 11
├── Makefile                       EDIT  Task 9
├── docs/
│   ├── BUILD-GUEST-ON-WINDOWS.md  NEW   Task 12
│   ├── WHY.md                     EDIT  Task 13 (ADR-Phase-C)
│   ├── INSTALL.md                 EDIT  Task 14
│   └── README.md                  EDIT  Task 14
```

每个任务一个 commit。任务内部按 "写代码 → 静态检查 → （服务器侧）运行验证 → 幂等回归 → commit" 五步走。

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

- [ ] **Step 2：语法检查（make 能解析就 OK）**

```bash
bash -n config.env.sample          # bash syntax check
make help | head -3                # 确保 Makefile 仍能 include
```

预期：两个命令都 exit 0；`make help` 仍打印安装目标列表。

- [ ] **Step 3：commit**

```bash
git add config.env.sample
git commit -m "feat(config): 加 Phase C 客户机参数 GUEST_NAME/IP/MAC/RAM/VCPUS"
```

---

## Task 2：`lib/common.sh` 增加 4 个 helper

**Files:**
- Modify: `lib/common.sh`

需求来自 spec §4：`render_template` / `virsh_wait_running` / `agent_alive` / `kvm_conf_section_exists`。

- [ ] **Step 1：写 helpers 到 `lib/common.sh` 末尾（`run_or_warn` 之后）**

打开 `lib/common.sh`，在文件末尾（`run_or_warn` 函数定义之后）追加：

```bash

# ===== Phase C helpers（c-stage 用）=====

# render_template <template-file>
# 用 envsubst 渲染 ${VAR} 占位符到 stdout。只展开传入的白名单变量名，
# 避免 $PATH / $HOME 之类被意外替换进 XML。
# 用法：render_template vendor/domain-cuckoo1.xml.tmpl > /tmp/domain.xml
render_template() {
  local tmpl="$1"
  [ -f "$tmpl" ] || { log_err "模板不存在: $tmpl"; return 1; }
  # 白名单：所有 GUEST_* 加 SUBNET（XML 模板中允许出现的变量）
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

预期：两个命令都 exit 0。

- [ ] **Step 3：本地单元验证（无需服务器）**

```bash
# 模拟 source common.sh 后调用 helpers
bash -c '
  set -eEuo pipefail
  REPO_ROOT="$PWD"
  source lib/common.sh

  # render_template：建临时模板
  echo "domain=\${GUEST_NAME}, ip=\${GUEST_IP}" > /tmp/test.tmpl
  GUEST_NAME=cuckoo1 GUEST_IP=192.168.122.105 \
    render_template /tmp/test.tmpl

  # 期望输出：domain=cuckoo1, ip=192.168.122.105
  rm /tmp/test.tmpl
'
```

预期 stdout：`domain=cuckoo1, ip=192.168.122.105`。

- [ ] **Step 4：commit**

```bash
git add lib/common.sh
git commit -m "feat(common): 加 4 个 Phase C helper（render_template/virsh_wait_running/agent_alive/kvm_conf_section_exists）"
```

---

## Task 3：`vendor/domain-cuckoo1.xml.tmpl` libvirt domain 模板

**Files:**
- Create: `vendor/domain-cuckoo1.xml.tmpl`

- [ ] **Step 1：写模板**

新建文件 `vendor/domain-cuckoo1.xml.tmpl`，内容：

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

**关键值（与 spec §5.2 对齐，不要随意改）：**
- `machine='pc-i440fx-noble'` — SeaBIOS 反 VM 补丁的目标 chipset
- `<emulator>/usr/local/bin/qemu-system-x86_64</emulator>` — 指向 stage 50 编译出的反 VM QEMU（不是 apt 自带的 `/usr/bin/qemu-system-x86_64`）
- `bus='sata'` — Win10 自带 AHCI 驱动
- `model type='e1000'` — Win10 自带 Intel 驱动
- `port='5901' autoport='no'` — 与 README §5 文档约定一致

- [ ] **Step 2：用 xmllint 校验模板渲染后是 well-formed XML（本地）**

```bash
GUEST_NAME=cuckoo1 GUEST_IP=192.168.122.105 GUEST_MAC=52:54:00:CA:FE:01 \
  GUEST_RAM_MB=4096 GUEST_VCPUS=2 \
  envsubst '${GUEST_NAME} ${GUEST_IP} ${GUEST_MAC} ${GUEST_RAM_MB} ${GUEST_VCPUS}' \
  < vendor/domain-cuckoo1.xml.tmpl \
  | xmllint --noout -
```

预期：无输出（well-formed 通过）。如果 xmllint 没装：`brew install libxml2`。

- [ ] **Step 3：commit**

```bash
git add vendor/domain-cuckoo1.xml.tmpl
git commit -m "feat(vendor): 加 cuckoo1 客户机 libvirt domain XML 模板（pc-i440fx + SATA + e1000）"
```

---

## Task 4：`scripts/c10-import-guest.sh` 校验 + 安置 qcow2

**Files:**
- Create: `scripts/c10-import-guest.sh`

**职责**：把用户在 `GUEST_QCOW2` 指向的文件，校验 sha256 后拷贝到 `/var/lib/libvirt/images/${GUEST_NAME}.qcow2`。

- [ ] **Step 1：写脚本**

新建 `scripts/c10-import-guest.sh`：

```bash
#!/usr/bin/env bash
# Stage c10-import-guest：校验 + 安置 qcow2 到 libvirt 镜像目录
# - 校验 sha256（侧文件 ${GUEST_QCOW2}.sha256 必须存在且一致）
# - 拷贝到 /var/lib/libvirt/images/${GUEST_NAME}.qcow2
# - chown libvirt-qemu:kvm
#
# 失败原则：sha256 不匹配 → 硬失败，提示 Windows 侧重传

source "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/common.sh"
stage_init "c10-import-guest"

GUEST_NAME="${GUEST_NAME:-cuckoo1}"
GUEST_QCOW2="${GUEST_QCOW2:?GUEST_QCOW2 未传，必须显式指定}"
TARGET_DIR=/var/lib/libvirt/images
TARGET="$TARGET_DIR/${GUEST_NAME}.qcow2"

# ---- 幂等守卫 ----
# 已就位 + sha256 与新源一致 → 跳过
if done_or_force \
   [ -f "$TARGET" ] \
   && [ -f "${GUEST_QCOW2}.sha256" ] \
   && (cd "$(dirname "$GUEST_QCOW2")" && sha256sum -c "${GUEST_QCOW2}.sha256") >/dev/null 2>&1 \
   && cmp -s "$GUEST_QCOW2" "$TARGET"; then
  echo "[~] $TARGET 已就位且哈希匹配，跳过"
  stage_done
  exit 0
fi

# ---- 1. 输入校验 ----
[ -f "$GUEST_QCOW2" ] || { echo "[-] GUEST_QCOW2 不存在: $GUEST_QCOW2"; exit 1; }
[ -f "${GUEST_QCOW2}.sha256" ] || {
  echo "[-] sha256 sidecar 不存在: ${GUEST_QCOW2}.sha256"
  echo "    Windows 工作站重跑 c-host-export.ps1 生成 sidecar"
  exit 1
}

# ---- 2. 校验 sha256 ----
echo "[+] 校验 sha256"
if ! (cd "$(dirname "$GUEST_QCOW2")" && sha256sum -c "$(basename "${GUEST_QCOW2}.sha256")"); then
  echo "[-] sha256 不匹配——可能 scp 传坏了"
  echo "    Windows 工作站重跑: pwsh scripts/c-host-export.ps1 -Server <ip>"
  exit 1
fi
echo "[✓] sha256 通过"

# ---- 3. qemu-img info 验证是合法 qcow2 ----
qemu-img info "$GUEST_QCOW2" | grep -q 'file format: qcow2' \
  || { echo "[-] $GUEST_QCOW2 不是合法 qcow2 格式"; exit 1; }
echo "[✓] qcow2 格式校验通过"

# ---- 4. 磁盘空间检查（虚拟大小 + 安全余量） ----
need_kb=$(qemu-img info --output=json "$GUEST_QCOW2" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["virtual-size"]//1024)')
avail_kb=$(df --output=avail "$TARGET_DIR" | tail -1)
if [ "$avail_kb" -lt "$need_kb" ]; then
  echo "[-] $TARGET_DIR 可用 ${avail_kb}KB < 需要 ${need_kb}KB"
  exit 1
fi
echo "[✓] 磁盘空间足（avail=${avail_kb}KB, need=${need_kb}KB）"

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
bash -n scripts/c10-import-guest.sh
command -v shellcheck >/dev/null && shellcheck -s bash scripts/c10-import-guest.sh
```

预期：exit 0。

- [ ] **Step 3：在目标服务器上端到端跑（需先把仓库 push 上去）**

```bash
# 在 Mac 上：
rsync -av --exclude logs --exclude state --exclude config.env \
  ./ cape@<TARGET>:/opt/cape-installer/

# ssh 到目标机：
ssh cape@<TARGET>
cd /opt/cape-installer

# 先造一个测试 qcow2（不需要真 Windows）
qemu-img create -f qcow2 /tmp/cuckoo1.qcow2 100M
(cd /tmp && sha256sum cuckoo1.qcow2 > cuckoo1.qcow2.sha256)

# 跑 c10
sudo GUEST_NAME=cuckoo1 GUEST_QCOW2=/tmp/cuckoo1.qcow2 \
  bash scripts/c10-import-guest.sh

# 期望：[✓] 已拷贝到 /var/lib/libvirt/images/cuckoo1.qcow2
sudo ls -la /var/lib/libvirt/images/cuckoo1.qcow2
```

预期：文件存在，owner libvirt-qemu:kvm，mode 0600。

- [ ] **Step 4：幂等回归**

```bash
# 第二次跑应秒过守卫
time sudo GUEST_NAME=cuckoo1 GUEST_QCOW2=/tmp/cuckoo1.qcow2 \
  bash scripts/c10-import-guest.sh
# 期望：< 1s，日志含 "已就位且哈希匹配，跳过"
```

- [ ] **Step 5：故意破坏 sidecar 验证硬失败**

```bash
echo "deadbeef  cuckoo1.qcow2" > /tmp/cuckoo1.qcow2.sha256
sudo GUEST_NAME=cuckoo1 GUEST_QCOW2=/tmp/cuckoo1.qcow2 \
  bash scripts/c10-import-guest.sh
# 期望 exit != 0，日志含 "sha256 不匹配"
echo $?
```

恢复：`(cd /tmp && sha256sum cuckoo1.qcow2 > cuckoo1.qcow2.sha256)`

- [ ] **Step 6：清理 + commit**

```bash
# 清理目标机：
sudo rm /var/lib/libvirt/images/cuckoo1.qcow2 /tmp/cuckoo1.qcow2 /tmp/cuckoo1.qcow2.sha256

# Mac 本地：
chmod +x scripts/c10-import-guest.sh
git add scripts/c10-import-guest.sh
git commit -m "feat(c10): 校验 sha256 + 安置 qcow2 到 /var/lib/libvirt/images"
```

---

## Task 5：`scripts/c20-define-domain.sh` 渲染 XML + virsh define

**Files:**
- Create: `scripts/c20-define-domain.sh`

**职责**：用 `render_template` 渲染 `vendor/domain-cuckoo1.xml.tmpl` → `virsh define` → `virsh net-update` 写 DHCP reservation。

- [ ] **Step 1：写脚本**

新建 `scripts/c20-define-domain.sh`：

```bash
#!/usr/bin/env bash
# Stage c20-define-domain：渲染 libvirt domain XML 并 virsh define
# - 用 lib/common.sh 的 render_template + envsubst
# - 在 default 网络追加 MAC→IP DHCP reservation
#
# 失败原则：virsh define 失败 → 删半定义 domain 重试 1 次

source "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/common.sh"
stage_init "c20-define-domain"

GUEST_NAME="${GUEST_NAME:-cuckoo1}"
GUEST_IP="${GUEST_IP:-192.168.122.105}"
GUEST_MAC="${GUEST_MAC:-52:54:00:CA:FE:01}"
GUEST_RAM_MB="${GUEST_RAM_MB:-4096}"
GUEST_VCPUS="${GUEST_VCPUS:-2}"

TMPL="$REPO_ROOT/vendor/domain-cuckoo1.xml.tmpl"
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
# 已存在则先删除避免 net-update 重复注入失败
existing=$(virsh net-dumpxml default \
  | grep -E "<host mac=['\"]${GUEST_MAC}['\"]" || true)
if [ -n "$existing" ]; then
  virsh net-update default delete ip-dhcp-host \
    "<host mac='${GUEST_MAC}' ip='${GUEST_IP}'/>" \
    --live --config 2>/dev/null \
    || echo "[~] 旧 reservation 删除失败（可能格式略不同），继续 add"
fi

virsh net-update default add ip-dhcp-host \
  "<host mac='${GUEST_MAC}' name='${GUEST_NAME}' ip='${GUEST_IP}'/>" \
  --live --config

echo "[✓] DHCP reservation: $GUEST_MAC → $GUEST_IP"

stage_done
```

- [ ] **Step 2：静态检查**

```bash
bash -n scripts/c20-define-domain.sh
shellcheck -s bash scripts/c20-define-domain.sh 2>/dev/null || true
```

- [ ] **Step 3：rsync 到目标机 + 端到端跑**

```bash
# Mac 上：
rsync -av --exclude logs --exclude state --exclude config.env \
  ./ cape@<TARGET>:/opt/cape-installer/

# 目标机上 root：
ssh cape@<TARGET>
cd /opt/cape-installer

# 先确保 c10 已经把 /var/lib/libvirt/images/cuckoo1.qcow2 搞好（或临时 touch）
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/cuckoo1.qcow2 100M

# 跑 c20
sudo bash scripts/c20-define-domain.sh

# 验证
sudo virsh dominfo cuckoo1
sudo virsh net-dumpxml default | grep "52:54:00:CA:FE:01"
```

预期：
- `virsh dominfo cuckoo1` 显示 State: shut off
- `virsh net-dumpxml default` 含 `<host mac='52:54:00:CA:FE:01' ... ip='192.168.122.105'/>`

- [ ] **Step 4：幂等回归 + force 测试**

```bash
# 第二次秒过
time sudo bash scripts/c20-define-domain.sh
# 期望 < 1s，日志含 "已定义，跳过"

# 强制重做（删了重新 define）
sudo FORCE=1 bash scripts/c20-define-domain.sh
# 期望：先打印 "已定义" 但 force 跳守卫；virsh define 报"已存在"，触发清理重试
sudo virsh dominfo cuckoo1
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
chmod +x scripts/c20-define-domain.sh
git add scripts/c20-define-domain.sh
git commit -m "feat(c20): 渲染 libvirt domain XML + virsh define + DHCP reservation"
```

---

## Task 6：`scripts/c30-register-kvm-conf.sh` 注入 cuckoo1 到 kvm.conf

**Files:**
- Create: `scripts/c30-register-kvm-conf.sh`

**职责**：用 `crudini`（与 stage 31 一致）写 `[cuckoo1]` section 到 `/opt/CAPEv2/conf/kvm.conf`，并把 `[kvm] machines` 里加上 cuckoo1（保留可能存在的其他客户机）。

- [ ] **Step 1：写脚本**

新建 `scripts/c30-register-kvm-conf.sh`：

```bash
#!/usr/bin/env bash
# Stage c30-register-kvm-conf：把 cuckoo1 注册到 /opt/CAPEv2/conf/kvm.conf
# - 在 [kvm] machines 追加（不是覆盖，保留可能已有的 cuckoo2/3...）
# - 写 [${GUEST_NAME}] section 全部字段
# - 改之前先备份到 kvm.conf.bak.<TS>
#
# 用 crudini，与 stage 31-cape-config 一致

source "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/common.sh"
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

# ---- 2. [kvm] machines 追加 GUEST_NAME ----
# 现有值（可能是空、单值、或逗号分隔多个）
current=$(sudo -u cape "$CRUDINI" --get "$CONF" kvm machines 2>/dev/null || echo "")
if [ -z "$current" ]; then
  new="$GUEST_NAME"
else
  # 已含 GUEST_NAME 就不重复加
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
bash -n scripts/c30-register-kvm-conf.sh
shellcheck -s bash scripts/c30-register-kvm-conf.sh 2>/dev/null || true
```

- [ ] **Step 3：端到端运行（需要 stage 20-host-stack 已经在目标机跑过 → /opt/CAPEv2/conf/kvm.conf 存在）**

```bash
# rsync 同上
ssh cape@<TARGET>
cd /opt/cape-installer

# 看现状
sudo cat /opt/CAPEv2/conf/kvm.conf

# 跑 c30
sudo bash scripts/c30-register-kvm-conf.sh

# 验证
sudo cat /opt/CAPEv2/conf/kvm.conf
ls -la /opt/CAPEv2/conf/kvm.conf.bak.* | tail -1
```

预期 `kvm.conf` 内含：
```
[kvm]
machines = cuckoo1
interface = virbr0

[cuckoo1]
label = cuckoo1
platform = windows
ip = 192.168.122.105
snapshot = clean
arch = x64
tags = win10ltsc,x64,cape
resultserver_ip = 192.168.122.1
resultserver_port = 2042
```

- [ ] **Step 4：幂等回归**

```bash
time sudo bash scripts/c30-register-kvm-conf.sh
# 期望 < 1s，"已存在于 ... 跳过"，不再生成新 .bak
ls -la /opt/CAPEv2/conf/kvm.conf.bak.* | wc -l
# 期望 = 1（不增长）
```

- [ ] **Step 5：清理 + commit**

```bash
# 目标机：恢复 kvm.conf
ssh cape@<TARGET> 'sudo cp /opt/CAPEv2/conf/kvm.conf.bak.* /opt/CAPEv2/conf/kvm.conf && sudo rm /opt/CAPEv2/conf/kvm.conf.bak.*'

# Mac
chmod +x scripts/c30-register-kvm-conf.sh
git add scripts/c30-register-kvm-conf.sh
git commit -m "feat(c30): 用 crudini 注入 cuckoo1 到 /opt/CAPEv2/conf/kvm.conf"
```

---

## Task 7：`scripts/c40-smoke-guest.sh` 启 VM + 验证 agent.py

**Files:**
- Create: `scripts/c40-smoke-guest.sh`

**职责**：`virsh start` → 用 `virsh_wait_running` 等 60s domain running → 用 `agent_alive` 轮询 120s agent 8000 端口 → 失败时 dump XML + 提示 VNC 5901 调试。

- [ ] **Step 1：写脚本**

新建 `scripts/c40-smoke-guest.sh`：

```bash
#!/usr/bin/env bash
# Stage c40-smoke-guest：启 VM + 验证 agent.py 8000 端口可达
# - virsh start
# - virsh_wait_running 60s
# - agent_alive 轮询 120s（24 次 × 5s）
# - 失败 → dump XML + 提示 VNC 5901
#
# 失败原则：管线内置的"真"验证关卡。失败要中止 import-guest。

source "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/common.sh"
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

# ---- 1. 启动（如果不在跑） ----
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
echo "    3. 客户机内 PowerShell 看启动项: Get-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'"
echo "    4. 客户机内 'ipconfig' 看 IP 是不是 ${GUEST_IP}"
echo "    5. 客户机内 'curl http://${GUEST_IP}:8000/' 自测 agent"
exit 1
```

- [ ] **Step 2：静态检查**

```bash
bash -n scripts/c40-smoke-guest.sh
shellcheck -s bash scripts/c40-smoke-guest.sh 2>/dev/null || true
```

- [ ] **Step 3：c40 真测试需要真 Win10 客户机，先做**冒烟**（无客户机时验证脚本不挂）

```bash
# 目标机：
ssh cape@<TARGET> "cd /opt/cape-installer && \
  sudo GUEST_NAME=fake-domain GUEST_IP=192.168.122.99 bash scripts/c40-smoke-guest.sh"
# 期望 exit != 0，日志含 "domain 状态异常: undefined"
echo $?
```

- [ ] **Step 4：完整端到端测试推迟到 Task 10/11/12 之后**

c40 真正能验证 agent.py 必须有真 Win10 客户机 + agent.py 装好。这一步留个 marker，在 Task 12 文档完成后做完整端到端：

> **TODO（Task 14 完成后）**：在真 Win10 客户机上验证 c40 走完整路径成功。

- [ ] **Step 5：commit**

```bash
chmod +x scripts/c40-smoke-guest.sh
git add scripts/c40-smoke-guest.sh
git commit -m "feat(c40): 启 VM + 轮询 agent.py 120s + 失败排查指引"
```

---

## Task 8：`scripts/c50-snapshot-and-cape.sh` 拍 clean 快照 + 解 mask cape

**Files:**
- Create: `scripts/c50-snapshot-and-cape.sh`

**职责**：`virsh snapshot-create-as --atomic clean` → `systemctl unmask cape cape-processor` → restart cape 服务 → 确认 active。

- [ ] **Step 1：写脚本**

新建 `scripts/c50-snapshot-and-cape.sh`：

```bash
#!/usr/bin/env bash
# Stage c50-snapshot-and-cape：拍 clean 快照 + 解 mask cape*
# - virsh snapshot-create-as --atomic clean
# - systemctl unmask cape cape-processor
# - systemctl restart cape cape-processor cape-rooter cape-web
# - 确认 cape.service active
#
# 前置假设：c40 已确认 agent.py:8000 可达（domain 处于 running + 干净状态）

source "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/common.sh"
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
  echo "[~] 快照 $SNAPSHOT_NAME 已存在 + cape 已 active，跳过"
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
bash -n scripts/c50-snapshot-and-cape.sh
shellcheck -s bash scripts/c50-snapshot-and-cape.sh 2>/dev/null || true
```

- [ ] **Step 3：完整端到端测试推迟到 Task 14 之后**

c50 真正成功必须有 c40 通过的真客户机（snapshot-create-as 在 running domain 上才有意义）。

> **TODO（Task 14 完成后）**：完整端到端测试时验证。

- [ ] **Step 4：commit**

```bash
chmod +x scripts/c50-snapshot-and-cape.sh
git add scripts/c50-snapshot-and-cape.sh
git commit -m "feat(c50): 拍 clean 快照 + unmask cape* + restart 验证 active"
```

---

## Task 9：`Makefile` 加 c-stage targets + import-guest 元 target

**Files:**
- Modify: `Makefile`

- [ ] **Step 1：编辑 Makefile**

打开 `Makefile`，做 3 处修改：

**修改 1**：在 `UNINSTALL_STAGES :=` 块之后追加 c-stages 列表（约 51 行后）：

```makefile

C_STAGES := \
  c10-import-guest \
  c20-define-domain \
  c30-register-kvm-conf \
  c40-smoke-guest \
  c50-snapshot-and-cape
```

**修改 2**：把 `.PHONY:` 行改为包含 c-stages 和 `import-guest`（约 53 行）。把：

```makefile
.PHONY: all clean help force-% uninstall uninstall-dry uninstall-yes $(STAGES) $(UNINSTALL_STAGES)
```

改为：

```makefile
.PHONY: all clean help force-% uninstall uninstall-dry uninstall-yes import-guest $(STAGES) $(UNINSTALL_STAGES) $(C_STAGES)
```

**修改 3**：在卸载 stage 块之后（`u99-verify:` 那行下面，`force-%:` 那行之前）插入 c-stage 编排：

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

c10-import-guest:                                  ; bash scripts/c10-import-guest.sh
c20-define-domain:    c10-import-guest             ; bash scripts/c20-define-domain.sh
c30-register-kvm-conf: c20-define-domain           ; bash scripts/c30-register-kvm-conf.sh
c40-smoke-guest:      c30-register-kvm-conf        ; bash scripts/c40-smoke-guest.sh
c50-snapshot-and-cape: c40-smoke-guest             ; bash scripts/c50-snapshot-and-cape.sh
```

**修改 4**：在 `help` target 的 echo 列表中加 import-guest（约 109 行 `@echo "其他："` 之前）：

```makefile
	@echo "Phase C 客户机："
	@echo "  sudo make import-guest GUEST_QCOW2=/path/to.qcow2"
	@echo "                                # 校验 + 注册 + 启 VM + 拍快照 + unmask cape"
	@echo "  sudo make c<NN>-<stage>       # 单步：c10-import-guest / c20-define-domain / ..."
	@echo ""
```

**修改 5**：在帮助末尾的 stage 列表 foreach 后追加 C_STAGES（约 115 行）：

```makefile
	@$(foreach s,$(C_STAGES),echo "  phase-c:  $(s)";)
```

- [ ] **Step 2：检查 Makefile 解析**

```bash
make help                          # 应打印新加的 Phase C 段
make help | grep import-guest      # 期望命中
```

- [ ] **Step 3：在目标机验证 GUEST_QCOW2 强校验**

```bash
ssh cape@<TARGET>
cd /opt/cape-installer

# 不传 GUEST_QCOW2 应硬失败
sudo make import-guest 2>&1 | head -3
# 期望：Makefile error "必须传 GUEST_QCOW2: ..."

# 传不存在的文件应硬失败
sudo make import-guest GUEST_QCOW2=/nonexistent/file.qcow2 2>&1 | head -3
# 期望：Makefile error "GUEST_QCOW2 文件不存在: /nonexistent/file.qcow2"
```

- [ ] **Step 4：单 stage 调用语义验证**

```bash
sudo make c10-import-guest 2>&1 | head -3
# 期望：仍要求 GUEST_QCOW2（因为 c10-import-guest 在 $(C_STAGES) 列表里）
```

- [ ] **Step 5：commit**

```bash
git add Makefile
git commit -m "feat(make): 加 5 个 c-stage target + import-guest 元 target + GUEST_QCOW2 强校验"
```

---

## Task 10：`scripts/c-guest-prep.ps1` 客户机内加固 + agent.py 注入

**Files:**
- Create: `scripts/c-guest-prep.ps1`

**职责**：在 Win10 LTSC 客户机内以 Administrator 跑。30+ 项加固 + Python 3.12 安装 + agent.py 注入 + 静态 IP 配置 + 关机。

> 这一步只能在真 Win10 客户机内跑，本地只做语法检查。

- [ ] **Step 1：写脚本**

新建 `scripts/c-guest-prep.ps1`：

```powershell
# c-guest-prep.ps1 — 在 Win10 LTSC 客户机内以 Administrator 跑
# 用途：
#   1. 关 Defender / Tamper Protection / SmartScreen / Update / Telemetry / UAC / Firewall
#   2. 装 Python 3.12 + 拉 agent.py + 改 .pyw + 注册启动项
#   3. 配静态 IP (默认 192.168.122.105/24, gw 192.168.122.1)
#   4. shutdown /s /t 0
#
# 用法（客户机内 Admin PowerShell）：
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   .\c-guest-prep.ps1
#
# 参数（可覆盖默认）：
#   .\c-guest-prep.ps1 -GuestIP 192.168.122.106 -GatewayIP 192.168.122.1

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
Set-MpPreference -DisableRealtimeMonitoring $true        -ErrorAction SilentlyContinue
Set-MpPreference -DisableIOAVProtection      $true        -ErrorAction SilentlyContinue
Set-MpPreference -DisableBehaviorMonitoring  $true        -ErrorAction SilentlyContinue
Set-MpPreference -DisableBlockAtFirstSeen    $true        -ErrorAction SilentlyContinue
Set-MpPreference -DisableScriptScanning      $true        -ErrorAction SilentlyContinue
Set-MpPreference -DisableArchiveScanning     $true        -ErrorAction SilentlyContinue
Set-MpPreference -SubmitSamplesConsent       NeverSend    -ErrorAction SilentlyContinue
OK 'Defender 实时保护已关'

# ---- 2. 关 Tamper Protection（LTSC 通过注册表）----
Step '关 Tamper Protection'
$tamperKey = 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features'
if (-not (Test-Path $tamperKey)) { New-Item -Path $tamperKey -Force | Out-Null }
New-ItemProperty -Path $tamperKey -Name TamperProtection -Value 0 -PropertyType DWord -Force | Out-Null
OK 'Tamper Protection 已关（注册表）'

# ---- 3. 关 Defender 整体（组策略路径，重启永久生效）----
Step '关 Defender 整体（组策略）'
$defGpoKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
if (-not (Test-Path $defGpoKey)) { New-Item -Path $defGpoKey -Force | Out-Null }
New-ItemProperty -Path $defGpoKey -Name DisableAntiSpyware     -Value 1 -PropertyType DWord -Force | Out-Null
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
Set-Service DiagTrack -StartupType Disabled -ErrorAction SilentlyContinue
Stop-Service DiagTrack -Force -ErrorAction SilentlyContinue
Set-Service dmwappushservice -StartupType Disabled -ErrorAction SilentlyContinue
Stop-Service dmwappushservice -Force -ErrorAction SilentlyContinue
OK '遥测已关'

# ---- 7. 关 UAC ----
Step '关 UAC（重启生效）'
$uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
New-ItemProperty -Path $uacKey -Name EnableLUA          -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uacKey -Name ConsentPromptBehaviorAdmin -Value 0 -PropertyType DWord -Force | Out-Null
OK 'UAC 已关'

# ---- 8. 关防火墙 ----
Step '关防火墙'
netsh advfirewall set allprofiles state off | Out-Null
OK '防火墙已关'

# ---- 9. 电源 / 屏保 / 错误报告 ----
Step '电源永不待机 + 关错误报告 + 关睡眠'
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change monitor-timeout-ac 0
powercfg /change monitor-timeout-dc 0
powercfg /h off
$werKey = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'
New-ItemProperty -Path $werKey -Name Disabled -Value 1 -PropertyType DWord -Force | Out-Null
OK '电源 + 错误报告设置完成'

# ---- 10. 关蓝屏自动重启（让样本能稳定 crash 给分析）----
Step '关蓝屏自动重启'
$crashKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
New-ItemProperty -Path $crashKey -Name AutoReboot -Value 0 -PropertyType DWord -Force | Out-Null
OK '蓝屏不再自动重启'

# ---- 11. 装 Python 3.12 ----
Step "装 Python 3.12（$PythonInstallerUrl）"
$pyExe = "$env:TEMP\python-installer.exe"
Invoke-WebRequest -Uri $PythonInstallerUrl -OutFile $pyExe -UseBasicParsing
Start-Process -FilePath $pyExe -ArgumentList @(
  '/quiet',
  'InstallAllUsers=1',
  'PrependPath=1',
  'Include_test=0',
  'Include_doc=0',
  'Include_launcher=1'
) -Wait -NoNewWindow
$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine')
$pyVer = & python --version 2>&1
if ($pyVer -notmatch '^Python 3\.12\.') { Die "Python 装失败：$pyVer" }
OK "Python: $pyVer"

# ---- 12. 拉 agent.py ----
Step "拉 agent.py（$AgentUrl）"
$agentDst = 'C:\agent.pyw'
Invoke-WebRequest -Uri $AgentUrl -OutFile $agentDst -UseBasicParsing
if (-not (Test-Path $agentDst) -or (Get-Item $agentDst).Length -lt 1024) {
  Die "agent.py 下载失败：$agentDst 不存在或太小"
}
OK "agent.pyw → $agentDst"

# ---- 13. 注册启动项（Run 注册表）----
Step '注册 agent.pyw 自启动'
$pyw = (Get-Command pythonw.exe -ErrorAction Stop).Source
$runKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
New-ItemProperty -Path $runKey -Name CAPE_Agent `
  -Value "`"$pyw`" `"$agentDst`"" -PropertyType String -Force | Out-Null
OK "启动项已注册：$pyw $agentDst"

# ---- 14. 配静态 IP ----
Step "配静态 IP $GuestIP/$Prefix gw=$GatewayIP dns=$DnsServer"
$adapter = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
if (-not $adapter) { Die '找不到 Up 状态的物理网卡' }

# 清掉旧 IP / 路由
Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue `
  | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue

New-NetIPAddress `
  -InterfaceIndex $adapter.ifIndex `
  -IPAddress $GuestIP `
  -PrefixLength $Prefix `
  -DefaultGateway $GatewayIP `
  | Out-Null

Set-DnsClientServerAddress `
  -InterfaceIndex $adapter.ifIndex `
  -ServerAddresses $DnsServer

OK "静态 IP 配置完成（adapter: $($adapter.Name)）"

# ---- 15. 总结 ----
Write-Host ''
Write-Host '================================================================' -ForegroundColor Green
Write-Host '              c-guest-prep.ps1 全部完成' -ForegroundColor Green
Write-Host '================================================================' -ForegroundColor Green
Write-Host ''
Write-Host "下一步："
Write-Host "  1. （可选）关闭浏览器、资源管理器多余窗口，把客户机置回干净桌面状态"
Write-Host "  2. 关机：shutdown /s /t 0 （或加 -NoShutdown 跳过）"
Write-Host "  3. 在 Windows 工作站宿主跑 c-host-export.ps1 转 qcow2 + 推服务器"
Write-Host ''

# ---- 16. 关机 ----
if (-not $NoShutdown) {
  Step '60s 后关机（Ctrl+C 取消）'
  Start-Sleep -Seconds 60
  shutdown /s /t 0
}
```

- [ ] **Step 2：本地 PowerShell 语法检查（macOS 上需要 `pwsh`）**

```bash
# 装 pwsh：brew install --cask powershell （或 brew install powershell）
pwsh -NoProfile -NonInteractive -Command "
  \$tokens = \$null; \$errs = \$null
  [System.Management.Automation.Language.Parser]::ParseFile(
    '$(pwd)/scripts/c-guest-prep.ps1', [ref]\$tokens, [ref]\$errs)
  if (\$errs.Count -gt 0) { \$errs | ForEach-Object { Write-Host \$_ }; exit 1 }
  Write-Host 'OK: 0 syntax errors'
"
```

预期输出：`OK: 0 syntax errors`

- [ ] **Step 3：commit**

```bash
git add scripts/c-guest-prep.ps1
git commit -m "feat(c-guest-prep): Win10 LTSC 客户机内加固 + agent.py 注入 + 静态 IP"
```

> **注**：真客户机端到端验证留到 Task 14 完成后做完整 Phase C 跑通时。

---

## Task 11：`scripts/c-host-export.ps1` 工作站宿主：转 qcow2 + scp

**Files:**
- Create: `scripts/c-host-export.ps1`

**职责**：在 Windows 工作站宿主跑。`qemu-img convert` VMDK→qcow2 → 写 sha256 sidecar → scp + retry 推送服务器。

- [ ] **Step 1：写脚本**

新建 `scripts/c-host-export.ps1`：

```powershell
# c-host-export.ps1 — 在 Windows 工作站宿主跑
# 用途：把 VMware 关机后的 VMDK 转成 qcow2 + sha256，scp 推送到 CAPE 服务器。
#
# 前置：
#   - 客户机内已跑过 c-guest-prep.ps1 + 已正常关机
#   - 工作站装了 qemu-img（QEMU for Windows 安装包自带）
#   - 工作站装了 OpenSSH client（Win10/11 默认有 scp.exe）
#
# 用法：
#   pwsh .\c-host-export.ps1 `
#     -VmxPath 'D:\VMs\Win10LTSC\Win10LTSC.vmx' `
#     -Server <CAPE-server-ip> `
#     -ServerUser cape

[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$VmxPath,
  [Parameter(Mandatory)] [string]$Server,
  [string]$ServerUser    = 'cape',
  [string]$ServerPath    = '/tmp/cuckoo1.qcow2',
  [string]$GuestName     = 'cuckoo1',
  [string]$WorkDir       = "$env:TEMP\cape-export",
  [string]$QemuImgPath   = 'qemu-img',
  [int]$ScpRetries       = 3
)

$ErrorActionPreference = 'Stop'

function Step($m) { Write-Host "[+] $m" -ForegroundColor Cyan }
function OK($m)   { Write-Host "[✓] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[-] $m" -ForegroundColor Red; exit 1 }

# ---- 1. 找 VMDK ----
$vmDir = Split-Path -Parent $VmxPath
$vmdks = Get-ChildItem -Path $vmDir -Filter '*.vmdk' `
  | Where-Object { $_.Name -notmatch '-s\d+\.vmdk$' -and $_.Name -notmatch '\.lck' }
if ($vmdks.Count -eq 0) { Die "在 $vmDir 找不到主 VMDK 文件（看是不是 split disk 没合并）" }
if ($vmdks.Count -gt 1) {
  Warn "找到多个 VMDK，使用第一个: $($vmdks[0].FullName)"
}
$srcVmdk = $vmdks[0].FullName
OK "源 VMDK: $srcVmdk"

# ---- 2. 检查 VMX 状态——必须关机 ----
$vmxLck = Test-Path "$VmxPath.lck"
if ($vmxLck) {
  Warn "$VmxPath.lck 存在——VM 可能还在运行/挂起"
  Warn '请在 VMware 里完全关机（Power Off，不是 Suspend），再重跑此脚本'
  Die  '客户机未关机，中止'
}
OK 'VM 已关机（无 .lck）'

# ---- 3. 找 qemu-img ----
try {
  $qemuVer = & $QemuImgPath --version 2>&1 | Select-Object -First 1
} catch {
  Die "找不到 qemu-img。装 QEMU for Windows（https://qemu.weilnetz.de/w64/）后重试，或显式传 -QemuImgPath"
}
OK "qemu-img: $qemuVer"

# ---- 4. 准备工作目录 ----
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
$dstQcow2  = Join-Path $WorkDir "$GuestName.qcow2"
$dstSha256 = "$dstQcow2.sha256"

# ---- 5. 转 qcow2 ----
Step "转 qcow2: $dstQcow2"
& $QemuImgPath convert -O qcow2 -p $srcVmdk $dstQcow2
if ($LASTEXITCODE -ne 0) { Die "qemu-img convert 失败 (exit=$LASTEXITCODE)" }
$qcow2Mb = [math]::Round((Get-Item $dstQcow2).Length / 1MB, 1)
OK "qcow2 写入完成（$qcow2Mb MB）"

# ---- 6. 生成 sha256 sidecar ----
Step '算 sha256'
$hash = (Get-FileHash -Path $dstQcow2 -Algorithm SHA256).Hash.ToLower()
"$hash  $GuestName.qcow2" | Out-File -FilePath $dstSha256 -Encoding ascii -NoNewline
OK "sha256: $hash"

# ---- 7. scp 推送（retry 3 次，5/15/45s backoff） ----
$scpRemote     = "${ServerUser}@${Server}:$ServerPath"
$scpRemoteSha  = "${ServerUser}@${Server}:${ServerPath}.sha256"

function Try-Scp([string]$src, [string]$dst, [int]$retries) {
  $delay = 5
  for ($i = 1; $i -le $retries; $i++) {
    Step "scp $src → $dst （第 $i/$retries 次）"
    & scp $src $dst
    if ($LASTEXITCODE -eq 0) { return $true }
    if ($i -lt $retries) {
      Warn "scp 失败 exit=$LASTEXITCODE，${delay}s 后重试"
      Start-Sleep -Seconds $delay
      $delay = $delay * 3
    }
  }
  return $false
}

if (-not (Try-Scp $dstQcow2 $scpRemote $ScpRetries))     { Die 'scp qcow2 失败' }
if (-not (Try-Scp $dstSha256 $scpRemoteSha $ScpRetries)) { Die 'scp sha256 失败' }
OK "已推送到 ${Server}:${ServerPath}（含 .sha256 sidecar）"

# ---- 8. 总结 + 服务器侧下一步命令提示 ----
Write-Host ''
Write-Host '================================================================' -ForegroundColor Green
Write-Host '          c-host-export.ps1 全部完成' -ForegroundColor Green
Write-Host '================================================================' -ForegroundColor Green
Write-Host ''
Write-Host "服务器 $Server 上跑："
Write-Host "  ssh ${ServerUser}@${Server}"
Write-Host "  cd /opt/cape-installer"
Write-Host "  sudo make import-guest GUEST_QCOW2=$ServerPath"
Write-Host ''
```

- [ ] **Step 2：本地 PowerShell 语法检查**

```bash
pwsh -NoProfile -NonInteractive -Command "
  \$tokens = \$null; \$errs = \$null
  [System.Management.Automation.Language.Parser]::ParseFile(
    '$(pwd)/scripts/c-host-export.ps1', [ref]\$tokens, [ref]\$errs)
  if (\$errs.Count -gt 0) { \$errs | ForEach-Object { Write-Host \$_ }; exit 1 }
  Write-Host 'OK: 0 syntax errors'
"
```

预期：`OK: 0 syntax errors`

- [ ] **Step 3：本地 dry-run 验证（macOS / Linux 上 mock）**

```bash
# 在 Mac 上简单跑一下参数解析（必失败但 -? 帮助应能打印）
pwsh -File scripts/c-host-export.ps1 -? 2>&1 | head -10
```

- [ ] **Step 4：commit**

```bash
git add scripts/c-host-export.ps1
git commit -m "feat(c-host-export): qemu-img convert VMDK→qcow2 + sha256 + scp retry"
```

---

## Task 12：`docs/BUILD-GUEST-ON-WINDOWS.md` 完整 Windows 端手册

**Files:**
- Create: `docs/BUILD-GUEST-ON-WINDOWS.md`

- [ ] **Step 1：写文档**

新建 `docs/BUILD-GUEST-ON-WINDOWS.md`：

````markdown
# 在 Windows 工作站构建 CAPE 分析客户机

本文是 cape-installer Phase C 的**操作手册**。当 CAPE 服务器是 headless（仅 SSH，无 GUI），通过 VNC 装 Windows 体验差时使用。

完成后产出：服务器上 `cuckoo1` 客户机注册到 CAPE，能跑样本分析。

> **前提**：服务器已成功跑过 `sudo make all`（Phase B 完成，KVM/libvirt + 反 VM QEMU/SeaBios 就绪）。

---

## 0. 总览

```
[ Windows 工作站 ]                                [ Ubuntu CAPE 服务器 ]
─────────────────                                 ──────────────────────
① VMware Workstation 装 Win10 LTSC（手工）
② c-guest-prep.ps1 (客户机内 Admin)
③ c-host-export.ps1 (工作站宿主)            ──▶  /tmp/cuckoo1.qcow2(.sha256)
                                                  ④ sudo make import-guest \
                                                       GUEST_QCOW2=/tmp/cuckoo1.qcow2
                                                  ⑤ 浏览器交付样本测试
```

---

## 1. 先决条件

### 1.1 工作站

| 软件 | 版本 | 装在哪 |
|---|---|---|
| **VMware Workstation Pro / Player** | 15+ | 你的 Windows 工作站 |
| **PowerShell 7+** | 7.x | `winget install Microsoft.PowerShell` 或 https://github.com/PowerShell/PowerShell/releases |
| **QEMU for Windows** | 9.x（要含 `qemu-img.exe`） | 下载 https://qemu.weilnetz.de/w64/ 装到 `C:\Program Files\qemu` 并把目录加到 PATH |
| **OpenSSH client** | Win10/11 自带；要 `scp.exe` 在 PATH | "应用 → 可选功能 → 添加 OpenSSH 客户端" |

### 1.2 客户机 ISO

下载 **Windows 10 LTSC 2021 x64**（推荐 LTSC 而不是 Pro/Home）—— LTSC 没 Edge / Cortana / Store / Xbox 等 bloat，反检测脚本要做的事少很多。

ISO 来源（任选其一）：
- 微软 VLSC 渠道
- 微软 VLSC 试用版（90 天）
- MSDN

### 1.3 服务器侧准备

```bash
ssh cape@<TARGET>
cd /opt/cape-installer
ls -la  # 确认仓库在
sudo make help | grep import-guest  # 期望命中 import-guest target
```

---

## 2. 在 VMware 装 Win10 LTSC

### 2.1 创建 VM

1. VMware → File → New Virtual Machine → Custom (advanced) → Next
2. **Hardware compatibility**: Workstation 16/17 都行
3. **Guest OS install**: 选 ISO 文件 → 选 Win10 LTSC ISO
4. **Easy Install**: **取消勾选**（我们要手工装，不让 VMware 自动装 Tools）
5. **Guest OS**: Microsoft Windows → Windows 10 x64
6. **Name**: `Win10LTSC-CAPE`，路径选合适位置（D:\VMs\Win10LTSC-CAPE\ 之类）
7. **Firmware**: **必选 BIOS（Legacy），不要选 UEFI** —— SeaBIOS 反 VM 补丁不兼容 UEFI
8. **Processors**: 2 cores
9. **Memory**: 4096 MB（与 `GUEST_RAM_MB` 默认一致；后续可改）
10. **Network**: NAT（装机阶段需要联网装 Python；装完会切到 host-only 风格）
11. **I/O Controller**: LSI Logic SAS（**不要选** Paravirtual SCSI——它需要 VMware Tools 驱动）
12. **Disk type**: **SATA**（与服务器端 libvirt domain XML 一致）
13. **Disk**: 40 GB，**Store as a single file**（不要选 split into multiple files——`qemu-img` 处理单文件 VMDK 最干净）
14. Finish

### 2.2 装 Windows

1. 按正常 Windows 装机流程过：选语言 → 同意许可 → Custom install → 选磁盘 → 装
2. 安装到桌面后：**先不要装 VMware Tools**（提示窗口直接关掉）
3. 创建本地账户（不联网，跳过微软账户登录）
4. 登录到桌面

### 2.3 把 c-guest-prep.ps1 送进客户机

三选一（按推荐度排序）：

#### 方法 A：通过 VMware ISO 挂载（推荐）

1. 工作站宿主上把 `scripts/c-guest-prep.ps1` 打包到一个 ISO：
   ```powershell
   # PowerShell on Windows host
   New-Item -Type Directory C:\temp\cape-iso
   Copy-Item scripts\c-guest-prep.ps1 C:\temp\cape-iso\
   # 用 PowerISO / OSCDIMG 之类工具做成 ISO
   oscdimg.exe -n C:\temp\cape-iso C:\temp\cape.iso
   ```
2. VMware → VM Settings → CD/DVD → 挂 `C:\temp\cape.iso`
3. 客户机内 `D:\c-guest-prep.ps1` 即可访问

#### 方法 B：临时联网 + gh-proxy 拉

客户机 NAT 网络下，PowerShell：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Invoke-WebRequest `
  https://gh-proxy.com/https://raw.githubusercontent.com/<your-repo>/cape-installer/main/scripts/c-guest-prep.ps1 `
  -OutFile c-guest-prep.ps1
```

#### 方法 C：VMware 拖放 ❌ 不推荐

需要装 VMware Tools——与"不装 Tools"原则冲突。

### 2.4 在客户机内跑 c-guest-prep.ps1

以 **Administrator** 启动 PowerShell（开始菜单 → PowerShell → 右键"以管理员身份运行"）：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
cd D:\        # 或脚本所在目录
.\c-guest-prep.ps1

# 默认 IP 192.168.122.105。要换其他 IP：
# .\c-guest-prep.ps1 -GuestIP 192.168.122.106
```

脚本会跑约 5-10 分钟，自动：
1. 关 Defender / Tamper / SmartScreen / Update / Telemetry / UAC / Firewall
2. 装 Python 3.12
3. 拉 agent.py 到 `C:\agent.pyw`
4. 注册启动项
5. 配静态 IP `192.168.122.105/24` gw `192.168.122.1`
6. 60 s 后关机（Ctrl+C 取消）

**全部跑完后客户机会自动关机**——这正是 Step 3 转 qcow2 需要的状态。

---

## 3. 转 qcow2 + 推送服务器

工作站宿主 PowerShell（**不需要 Admin**）：

```powershell
cd <仓库根>\cape-installer
pwsh .\scripts\c-host-export.ps1 `
  -VmxPath 'D:\VMs\Win10LTSC-CAPE\Win10LTSC-CAPE.vmx' `
  -Server  192.168.2.234 `
  -ServerUser cape

# 默认推到 /tmp/cuckoo1.qcow2，要改：
#   -ServerPath /var/tmp/myguest.qcow2
```

脚本会：
1. 校验 VM 已关机（无 `.vmx.lck`）
2. `qemu-img convert -O qcow2 -p` 把 VMDK 转 qcow2（约 5-15 GB，~3-10 min）
3. 算 SHA256 写 sidecar
4. scp 推送到服务器（千兆内网 ~1 min；retry 3 次）

完成后脚本会打印**下一步执行的服务器命令**。

---

## 4. 服务器侧导入

按 c-host-export.ps1 提示的命令在服务器上跑：

```bash
ssh cape@192.168.2.234
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

### 5.1 服务侧 sanity

```bash
sudo virsh list --all              # cuckoo1 应是 "running"
sudo virsh snapshot-list cuckoo1   # 应显示 "clean"
sudo systemctl status cape         # active
curl http://192.168.122.105:8000/  # 应返回 JSON
```

### 5.2 端到端：交付样本

```bash
# 浏览器：http://<TARGET>:8000/submit/
#   随便上传一个无害 EXE（notepad.exe / putty.exe）
#   点 Analyze
```

观察：
- Web UI 任务列表 Pending → Running → Completed（约 30s）
- `sudo virsh list` 期间 cuckoo1 running
- 任务结束后 cuckoo1 自动回滚到 clean 快照

任务完成 + 自动回滚 = Phase C 通了。

---

## 6. 故障排查

| 现象 | 原因 | 对策 |
|---|---|---|
| c10 报 "sha256 不匹配" | scp 中途有传输错误 | Windows 工作站重跑 `c-host-export.ps1` |
| c20 报 "virsh define 失败" | XML 渲染异常 / domain 残留 | `cat /tmp/cuckoo1.domain.xml` 看渲染结果；`sudo virsh undefine cuckoo1` 清残留后 `make force-c20-define-domain` |
| c40 120s 后 agent 不响应 | 客户机 IP 没起来 / agent 没自启 / Defender 没关干净 | VNC 5901 看客户机内部；`tasklist | findstr pyw`；`ipconfig` |
| 客户机起不来报 `bios.bin` | stage 51 SeaBIOS 替换异常 | `sudo make force-51-anti-vm-seabios` |
| 任务一直 Pending | cape-rooter 没起 / agent 不在 | `sudo systemctl status cape-rooter`；客户机内查 agent 进程 |

---

## 7. 重做与多客户机

### 7.1 改 c-guest-prep.ps1 后只重做客户机

VMware 里把 VM 滚回到 c-guest-prep.ps1 之前的快照（你应该在装完 Windows 时拍一个），重跑 ps1 → 重跑 c-host-export.ps1 → 服务器 `sudo make force-c10-import-guest GUEST_QCOW2=...` 强制重新覆盖 qcow2。

### 7.2 加第二台 cuckoo2

未来支持（spec §9 列为不在本次范围）。手工方式：在 `config.env` 改 `GUEST_NAME=cuckoo2 GUEST_IP=192.168.122.106 GUEST_MAC=52:54:00:CA:FE:02` 后重跑 `make import-guest`，c30 会把 cuckoo2 追加到 `[kvm] machines` 列表（不覆盖 cuckoo1）。
````

- [ ] **Step 2：markdown 校验（链接 / 缩进）**

```bash
# 在 Mac 上打开预览自检：
open docs/BUILD-GUEST-ON-WINDOWS.md
# 或用 markdownlint 如果装了
command -v markdownlint >/dev/null && markdownlint docs/BUILD-GUEST-ON-WINDOWS.md || echo "markdownlint 未装，跳过"
```

- [ ] **Step 3：commit**

```bash
git add docs/BUILD-GUEST-ON-WINDOWS.md
git commit -m "docs(BUILD-GUEST-ON-WINDOWS): Windows 工作站完整手册（Phase C 操作手册）"
```

---

## Task 13：`docs/WHY.md` 追加 ADR-Phase-C

**Files:**
- Modify: `docs/WHY.md`

- [ ] **Step 1：在 WHY.md 末尾追加 ADR**

打开 `docs/WHY.md`，在文件末尾（"后续可考虑的演进"小节之后）追加：

```markdown

---

## ADR-Phase-C：Windows 工作站构建客户机管线（2026-04-30 追加）

**上下文**：cape-installer 完成 Phase B 后，要让 CAPE 真正能分析样本就必须在 virbr0 上接入一台 Windows 客户机。原 README §5 文档了**在服务器上用 `virt-install` + VNC** 装 Windows 的手工路径，但当：
- 服务器是 headless（仅 SSH，无显示器）
- 操作者习惯 Windows 上的 VMware Workstation 工具链

VNC 装 Windows 体验差，每次都要在 5901 拉桌面装系统、敲数十项反检测策略，效率低且易漏。

**选择**：**Approach A**——客户机内脚本化加固 + 服务器端自动注册（详见 spec `docs/superpowers/specs/2026-04-30-phase-c-windows-build-pipeline-design.md`）。

**备选**：
- B 纯手工 Windows 端（README 加章节）：客户机加固 30+ 项，每装一台都要重做，一致性差
- C 全自动（autounattend.xml + 自动转换/推送）：实施成本高，回报低（只装 1-2 台时）

**理由**：
- 把"高密度高重复"的客户机内加固 30+ 项**脚本化**（c-guest-prep.ps1）
- 把"一次性、易错"的 Windows 装机**保留手工**（VMware 装机一次完事）
- 跨主机交接 = 单 qcow2 + sha256 sidecar，零反向 SSH
- 服务器侧用 5 个 c-stage 沿用现有 `00-99` 安装栈的所有契约（lib/common.sh、stage_init/done_or_force/retry）

**影响**：
- 新增 5 个 c-stage 脚本（c10-c50）+ 2 个 PowerShell 脚本（c-guest-prep / c-host-export）
- `Makefile` 加 `import-guest` target + `GUEST_QCOW2` 强校验
- `lib/common.sh` 加 4 个 helper（`render_template` / `virsh_wait_running` / `agent_alive` / `kvm_conf_section_exists`）
- `vendor/domain-cuckoo1.xml.tmpl` libvirt domain XML 模板
- 新增文档 `docs/BUILD-GUEST-ON-WINDOWS.md`
- README + INSTALL 加指针

**关键技术决策（来自 brainstorming Q1-Q4）**：

| 决策点 | 选择 | 理由 |
|---|---|---|
| Win 版本 | Win10 LTSC（不是 Win7、不是 Pro/Home） | 现代样本兼容；LTSC 比 Pro/Home 少 bloat |
| Hypervisor | VMware Workstation（不是 QEMU for Win/VirtualBox/Hyper-V） | GUI 体验最好；VMDK→qcow2 一行 `qemu-img convert` 转换 |
| 自动化深度 | docs + helper scripts（不是纯文档、不是全自动） | 客户机加固高密度 → 脚本化；装机一次性 → 手工 |
| 静态 IP vs DHCP | 双保险（DHCP reservation + 客户机内静态） | 单点失败容忍 |
| MAC | 固定 `52:54:00:CA:FE:01`（libvirt 前缀） | DHCP reservation 可工作 |
| 磁盘 SATA 而非 virtio | SATA | Win10 自带 AHCI；virtio 需 virtio-win 驱动注入 |
| 网卡 e1000 而非 virtio-net | e1000 | 同上 |
| 跨主机交接 | 单 qcow2 + sha256 sidecar | 极简契约，零反向 SSH |
| 快照在哪拍 | 服务器侧（c50） | libvirt 在 qcow2 元数据里管快照，工作站拍的没用 |

**已知不在本次范围**（写明避免范围蔓延）：
- autounattend.xml 无人值守装 Win10
- 多客户机批量（cuckoo2/3...）：c30 已支持追加，但 Makefile 当前只处理一个 GUEST_NAME
- virtio-win 驱动注入路径
- 跨服务器迁移同一 qcow2（Approach C 模板模式）

来源：spec `docs/superpowers/specs/2026-04-30-phase-c-windows-build-pipeline-design.md` + brainstorming 会话 Q1-Q4 + §1-§5。
```

- [ ] **Step 2：lint markdown（如果有 markdownlint）**

```bash
command -v markdownlint >/dev/null && markdownlint docs/WHY.md || echo "skip"
```

- [ ] **Step 3：commit**

```bash
git add docs/WHY.md
git commit -m "docs(WHY): 加 ADR-Phase-C（Windows 工作站构建客户机管线决策）"
```

---

## Task 14：`docs/INSTALL.md` + `README.md` + `CLAUDE.md` 加指针

**Files:**
- Modify: `docs/INSTALL.md`
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1：编辑 README.md "5. 添加分析客户机 (Phase C)" 节，前置一段指针**

打开 `README.md`，找到 `## 5. 添加分析客户机 (Phase C)` 那行，在它之后、在 `cape-installer 自动化的是 **Phase B**...` 之前插入：

```markdown
> **如果你的服务器是 headless（无 GUI），用 VNC 装 Windows 太慢/卡**——本仓库提供
> 一条**在 Windows 工作站构建 + scp 推服务器自动注册**的更便捷路径。详见
> [docs/BUILD-GUEST-ON-WINDOWS.md](docs/BUILD-GUEST-ON-WINDOWS.md)。
>
> 本节剩余内容是直接在服务器上 `virt-install` 的手工路径。两条路径并存，按需挑选。

```

- [ ] **Step 2：编辑 README.md 第 6 节"文档导航"加一行**

在文档导航表格里，在 `WHY.md` 那行之前插入：

```markdown
| `docs/BUILD-GUEST-ON-WINDOWS.md` | 在 Windows 工作站构建客户机推送服务器（Phase C 替代路径） |
```

- [ ] **Step 3：编辑 docs/INSTALL.md 末尾加一段指针**

打开 `docs/INSTALL.md`，在文件末尾追加：

```markdown

---

## Phase C：分析客户机接入

`make all` 跑完是 Phase B（host stack + KVM/libvirt + 反 VM）。要让 CAPE 真正分析样本，需要在 virbr0 上接入一台 Windows 客户机。两条路径：

1. **直接在服务器上 `virt-install` + VNC 装机**（默认路径，README §5 详解）
2. **在 Windows 工作站构建 + `make import-guest` 自动注册**（headless 服务器推荐）—— 详见 [BUILD-GUEST-ON-WINDOWS.md](BUILD-GUEST-ON-WINDOWS.md)
```

- [ ] **Step 4：编辑 CLAUDE.md "Common commands" 段加 import-guest**

打开根目录 `CLAUDE.md`，找到 `make help                              # list all targets / stages` 那行，**在它之前**插入：

```markdown
sudo make import-guest GUEST_QCOW2=...   # Phase C: register a pre-built Win10 qcow2 as cuckoo1
sudo make c<NN>-<stage>                # Phase C single stage (c10/c20/c30/c40/c50)
```

并在 "Architecture / Stage orchestration" 段的 install/uninstall chain 之后追加：

```markdown
- **Phase C (client guest):** `c10-import-guest → c20-define-domain → c30-register-kvm-conf → c40-smoke-guest → c50-snapshot-and-cape`. Triggered by `sudo make import-guest GUEST_QCOW2=...`. Requires that `make all` (Phase B) has completed. The Windows-side workflow (manual VMware install + 2 PowerShell scripts) is documented in `docs/BUILD-GUEST-ON-WINDOWS.md`.
```

- [ ] **Step 5：检查链接**

```bash
# 在 Mac 上：
grep -n "BUILD-GUEST-ON-WINDOWS" README.md docs/INSTALL.md CLAUDE.md
# 期望命中至少 3 条
```

- [ ] **Step 6：commit**

```bash
git add README.md docs/INSTALL.md CLAUDE.md
git commit -m "docs: 在 README/INSTALL/CLAUDE.md 加 BUILD-GUEST-ON-WINDOWS.md 指针"
```

---

## Task 15：完整端到端验证（在真客户机上跑通）

**前置**：Tasks 1-14 全部完成且 commit。**这是验收**。

不写代码——这是验收脚本，所有命令分别在 Windows 工作站和服务器上跑。

- [ ] **Step 1：Windows 工作站建客户机**

按 `docs/BUILD-GUEST-ON-WINDOWS.md` §2 走完：
1. VMware 装 Win10 LTSC（legacy BIOS / SATA / 不装 Tools）
2. 客户机内 `c-guest-prep.ps1` 跑通
3. VM 关机

- [ ] **Step 2：转 qcow2 + 推服务器**

```powershell
pwsh .\scripts\c-host-export.ps1 `
  -VmxPath 'D:\VMs\Win10LTSC-CAPE\Win10LTSC-CAPE.vmx' `
  -Server <TARGET> -ServerUser cape
```

预期：`/tmp/cuckoo1.qcow2(.sha256)` 在服务器上。

- [ ] **Step 3：服务器一键导入**

```bash
ssh cape@<TARGET>
cd /opt/cape-installer
time sudo make import-guest GUEST_QCOW2=/tmp/cuckoo1.qcow2
```

预期：5 个 c-stage 顺序通过，总用时 < 5 min（其中 c40 等 agent 启动占大头）。

- [ ] **Step 4：状态验证**

```bash
sudo virsh list --all
sudo virsh snapshot-list cuckoo1     # 期望含 "clean"
sudo systemctl status cape           # active
curl http://192.168.122.105:8000/    # 期望 JSON
```

- [ ] **Step 5：端到端样本测试**

浏览器 http://<TARGET>:8000/submit/ 上传 `notepad.exe`，点 Analyze。

观察：
- Pending → Running（< 5 s）→ Completed（< 1 min）
- `sudo virsh list` 期间 cuckoo1 running
- 任务结束后 cuckoo1 自动回到 clean 快照
- Web UI 任务页面有 behavior log

- [ ] **Step 6：幂等回归**

```bash
# 第二次 import-guest 应秒过
time sudo make import-guest GUEST_QCOW2=/tmp/cuckoo1.qcow2
# 期望 < 5 s（5 个 stage 全跳过）
```

- [ ] **Step 7：tag release**

成功后给本次工作打标签：

```bash
git tag -a phase-c-v1 -m "Phase C: Windows 工作站构建客户机管线（端到端验证通过）"
git push --tags  # 仅当用户要求 push 时
```

---

## Self-Review Checklist（writing-plans skill 要求）

我对照 spec 检查计划：

| Spec 段落 | Plan 任务 | 状态 |
|---|---|---|
| §1 背景与动机 | (上下文，不需任务) | — |
| §2 决策摘要 (Q1-Q4) | Task 13 ADR-Phase-C 表格 | ✓ |
| §3.1 双侧管线图 | Task 12 README §"总览" + 文档 §0 | ✓ |
| §3.2 关键架构选择（4 项） | 所有 c-stage 都引用 lib/common.sh 现有契约；命名一致 | ✓ |
| §4 仓库新增文件清单 (10 项) | Tasks 1-12 + 14（10 个 deliverable） | ✓ |
| §4.3 c-guest-prep.ps1 进客户机 3 选项 | Task 12 §2.3 文档化 | ✓ |
| §5.1 PowerShell↔bash 文件契约 | Task 4 c10 校验 sha256 + Task 11 c-host-export 写 sidecar | ✓ |
| §5.2 VM 硬件契约 9 项 | Task 3 domain XML 模板（machine/CPU/RAM/disk/NIC/MAC/net/display/boot 全覆盖） | ✓ |
| §5.3 双保险静态 IP | Task 5 c20 写 DHCP reservation + Task 10 c-guest-prep 客户机内 New-NetIPAddress | ✓ |
| §5.4 kvm.conf 注入 | Task 6 c30 用 crudini，含追加而非覆盖逻辑 | ✓ |
| §5.5 config.env 5 个新参数 | Task 1 全部加上 | ✓ |
| §6.1 c-stage 幂等探测表 | Task 4-8 每个 stage 都有 `done_or_force` + 具体探针 | ✓ |
| §6.2 FORCE=1 行为 | Task 5 c20 步骤 4 演示 force 重做 | ✓ |
| §6.3 跨 stage 状态保护 | 守卫检系统真相，不用 marker—— Task 4-8 一致 | ✓ |
| §6.4 sha256 不匹配硬失败 | Task 4 c10 + Task 5 故意破坏 sidecar 测试 | ✓ |
| §6.5 PowerShell 错误处理 | Task 11 try/catch + scp retry；Task 10 ErrorActionPreference=Stop | ✓ |
| §6.6 失败回滚原则 | Task 5 c20 半成功清理；其他 stage 失败保留现场 | ✓ |
| §7.1 c40 集成测试 3 项 | Task 7 c40 完整实现 domstate + agent_alive 轮询 + JSON 字段验证 | ✓ |
| §7.2 端到端人工测试 | Task 15 §5 详解 | ✓ |
| §7.3 幂等性回归 | Task 15 §6 + 各 stage 内置 idempotency 测试 | ✓ |
| §8 ADR 表 | Task 13 完整复制 | ✓ |
| §9 不在本次范围 | Task 13 ADR 末尾列出 | ✓ |
| §10 实施顺序提示 | Task 1-15 严格按 spec §10 顺序（基础 → c-stage → Makefile → PS → 文档 → 验收） | ✓ |

**Placeholder scan**：
- 有 1 处显式 TODO（Task 7 c40 端到端验证推迟到 Task 15）—— 这是有意的依赖标记，不是计划缺失，因为 c40 真正能验证必须有真客户机
- 有 1 处显式 TODO（Task 8 c50 同理）
- 无 "TBD" / "implement later" / "fill in details"
- 所有代码块都是完整代码（无 `# similar to above`）

**Type/symbol 一致性**：
- 4 个 helper 命名 (`render_template`、`virsh_wait_running`、`agent_alive`、`kvm_conf_section_exists`) 在 Task 2 定义后，在 Task 4-8 调用处全部对得上
- `GUEST_NAME / GUEST_IP / GUEST_MAC / GUEST_RAM_MB / GUEST_VCPUS` 在 Task 1 定义后，Task 3-9 全部一致引用
- `GUEST_QCOW2` 是 Makefile 入参，Task 9 校验、Task 4 消费、Task 11 PowerShell 产出，三处对得上
- 5 个 c-stage 名字（c10-c50）在 Tasks 4-9、Task 12-14 全部一致
- `crudini` 用法与现有 `scripts/31-cape-config.sh` 模式完全一致（`sudo -u cape "$CRUDINI" --set ...`）

**Scope check**：单个 plan 覆盖一个清晰的子系统（Phase C 客户机管线），无须再分拆。所有 deliverable 在同一个语义单元里互相依赖，不能独立交付。

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-30-phase-c-windows-build-pipeline.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
