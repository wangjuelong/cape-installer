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
