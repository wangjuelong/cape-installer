# 在 Intel Mac (UTM) 上构建 CAPE 分析客户机——实地通过版

> **状态**：本文档基于 2026-04-30 的真实部署（192.168.1.6 测试机）走通，包含所有踩坑修复。
> 直接照本走应能一次性跑通。

---

## 0. 总览

```
[ Intel Mac (UTM 4.7.5) ]                         [ Ubuntu 24.04 CAPE 服务器 ]
─────────────────────                             ──────────────────────────
①  UTM 装 Win10 LTSC（手工，关键设置必须对）
②  cp -cR 备份 .utm 包（防 PS1 跑挂）
③  Mac 上构建三件套 ISO（PS1 + Python x86 + agent.py）
④  Win10 内手工关 4 项 Defender → 跑 c-guest-prep.ps1
⑤  reboot 验证 auto-login + agent.py 自启
⑥  关机后 c-host-export.sh + scp 推送            ──▶  /tmp/cuckoo1.qcow2(.sha256)
                                                    ⑦  sudo make import-guest
                                                       GUEST_QCOW2=/tmp/cuckoo1.qcow2
                                                    ⑧  浏览器 :8000/submit/ 测试样本
```

**关键决策（不要绕过）：**
- Win10 LTSC 2021 x64（不要 Pro/Home）
- UTM 选 **Virtualize 模式**（Intel Mac HVF 加速）
- **Legacy BIOS** 不要 UEFI（SeaBIOS 反 VM 补丁要求）
- **i440FX 机型**（不要 q35）
- **IDE 总线 + e1000 网卡**（Win10 内建驱动 + UTM 4.x GUI 不支持 SATA）
- **不装 SPICE/VMware Tools**（避免 anti-VM 痕迹）
- **Python x86**（CAPE agent.py 强制要求 32-bit）

---

## 1. Mac 工作站准备

```bash
# UTM
brew install --cask utm
defaults read /Applications/UTM.app/Contents/Info.plist CFBundleShortVersionString
# 期望：4.7.5 或更高

# qemu-img + sshpass（c-host-export.sh / 推送服务器用）
brew install qemu sshpass

# PowerShell（可选，用来本地语法检查 .ps1）
brew install --cask powershell
```

ISO：下载 **Windows 10 Enterprise LTSC 2021 x64** 到 `~/Downloads/Win10LTSC2021_x64.iso`。

---

## 2. UTM 装 Win10 LTSC——逐页向导（重点：默认设置都得改）

### 2.1 New VM 向导（7 页）

UTM 主界面 → 左上角 **+** → Create a New Virtual Machine：

| 页 | 选/填 | ⚠️ 注意 |
|---|---|---|
| **1. Start** | **Virtualize** | 不要 Emulate（会慢 5-10×） |
| **2. Operating System** | **Windows** | |
| **3. Windows** | Boot ISO Image：选 ISO 文件<br>**Import VHDX Image：不勾**<br>**Install drivers and SPICE tools：不勾**<br>**Install Windows 10 or higher：不勾** | 勾这一项会强制 UEFI + TPM 2.0 + Secure Boot——锁死后改不回来 |
| **4. Hardware** | Memory `4096 MB`<br>CPU Cores `2`<br>Hardware OpenGL Acceleration：不勾 | |
| **5. Storage** | Size `40 GB` | qcow2 稀疏，实占 5-15 GB |
| **6. Shared Directory** | 跳过 | Shared 依赖 SPICE Tools，违反"不装 Tools" |
| **7. Summary** | Name `Win10LTSC-CAPE`<br>**Open VM Settings：勾** | 进 Settings 改 9 个关键 pane |

### 2.2 Settings 9 个 pane（**全部要确认**）

#### 2.2.1 System
| 字段 | 值 | 备注 |
|---|---|---|
| Architecture | x86_64 | Intel Mac 默认 |
| **System** | **`Standard PC (i440FX + PIIX, 1996)`** | 默认是 q35——**必须改**！SeaBIOS 反 VM 补丁是为 i440fx 准备的 |
| Memory | 4096 MB | 已是 |
| CPU | Default | |
| CPU Cores | 2 | 已是 |
| Force Multicore | ✅ 勾 | |

#### 2.2.2 QEMU（Tweaks 区——关键）
| 字段 | 值 |
|---|---|
| **UEFI Boot** | ❌ **必须取消勾选** |
| Use Hypervisor | ✅ 勾（HVF 加速） |
| Use Local Time for Base Clock | ✅ 勾 |
| RNG Device | ✅ 勾（默认） |
| Balloon Device | ✅ 勾（默认） |
| PS/2 Controller | ✅ 勾 |

> 没看到 UEFI Boot 这个 checkbox？说明你 §2.1 的"Install Windows 10 or higher"勾上了——UEFI 锁死。**回去删 VM 重做向导**。

#### 2.2.3 Input
默认即可。USB Sharing 不勾。

#### 2.2.4 Sharing
| 字段 | 值 |
|---|---|
| Directory Share Mode | None |
| Clipboard Sharing | ❌ 不勾 |

#### 2.2.5 Display
| 字段 | 值 |
|---|---|
| Emulated Display Card | virtio-vga（默认即可，仅装机用） |
| GL Acceleration | ❌ 不勾 |

#### 2.2.6 **Network**（关键）
| 字段 | 值 |
|---|---|
| Network Mode | `Shared Network`（装机阶段需要联网，后续 c-guest-prep.ps1 会改静态 IP） |
| **Emulated Network Card** | **`Intel Gigabit Ethernet (e1000)`** |
| MAC Address | 自动 |

> 默认是 `virtio-net-pci`——**必须改成 e1000**！Win10 自带 Intel 82540EM 驱动；virtio 需要 virtio-win 驱动注入。

#### 2.2.7 Sound
默认即可。

#### 2.2.8 **Drives**（关键）
应有 2 个 drive：

**主磁盘（40 GB qcow2）：**
| 字段 | 值 |
|---|---|
| **Interface** | **`IDE`** |
| Bus Number | 0 |
| Removable | ❌ |

> UTM 4.x GUI 不暴露 SATA——只能选 IDE。Win10 内建 PIIX IDE 驱动，性能差异对 CAPE 短任务无影响。

**CD-ROM（装机 ISO）：**
| 字段 | 值 |
|---|---|
| Interface | IDE |
| Removable | ✅（装完后会换成 cape.iso） |
| Image Type | CD/DVD (ISO) |

→ 全部确认后点 **Save**。

### 2.3 启动 + 装机

**启动验证 BIOS 模式正确**：UTM 主界面双击 VM 启动，应看到：
```
SeaBIOS (version rel-1.16.x) ...   ← 黑底白字几秒
Press any key to boot from CD or DVD ...
```

> 如果看到 UTM logo / EFI Shell / "no bootable device" → §2.2.2 UEFI Boot 没关干净。

按任意键进 Win10 装机，按标准流程：
- Language/Keyboard：随便
- Install Now → "I don't have a product key" → **Windows 10 Enterprise LTSC**
- 同意 EULA → **Custom: Install Windows only (advanced)**
- 选 40 GB 未分配空间 → Next（自动分区，约 10-15 min 装机自动重启数次）

### 2.4 OOBE（首次开机配置）

| 字段 | 推荐 | ⚠️ |
|---|---|---|
| Region/Keyboard | 你需要的 | |
| 网络 → Sign-in options → **Domain join instead** | 创建本地账户 | 不要登微软账户 |
| **Username** | **`John`** | **必须 ASCII**！避开 `cape`/`analyst`/`sandbox`/`vm` 等关键词（反 VM 样本会查） |
| **Password** | **`cape123`** | 与 c-guest-prep.ps1 的 `-AdminPassword` 一致 |
| Privacy 6 个开关 | 全部关 | |
| Cortana | Not now | |

桌面就绪后：
- ✅ 不点任何 UTM "Install drivers" 弹窗
- ✅ 出现"是否允许网络发现" → **选是 (Yes)**

### 2.5 装机后 sanity check

开始菜单 → PowerShell → 右键 **以管理员身份运行**：

```powershell
# 一次性 5 项检查
Write-Host "=== 1. OS ==="; (Get-CimInstance Win32_OperatingSystem).Caption
Write-Host "=== 2. BIOS ==="; (Get-CimInstance Win32_BIOS).Manufacturer
Write-Host "=== 3. NIC ==="; Get-NetAdapter | Select Name, InterfaceDescription, Status
Write-Host "=== 4. Network ==="; Test-NetConnection 8.8.8.8 -InformationLevel Quiet
Write-Host "=== 5. User ==="; whoami; $env:USERPROFILE
```

**期望：**
- §1 含 `Windows 10 Enterprise LTSC`
- §2 含 `SeaBIOS`
- §3 InterfaceDescription 含 `Intel(R) PRO/1000` 或 `82540EM`
- §4 = `True`
- §5 用户名 + USERPROFILE **必须全 ASCII**

任一不对，去 §11 故障排查找症状。

---

## 3. 拍 `.utm` 备份（用 cp -cR，不用 UTM Snapshot Manager）

> **背景**：UTM 4.7.5 的 Snapshot Manager 对 Virtualize 模式 VM 不稳定（常常隐藏 / 灰掉）。直接复制整个 .utm 包最稳。

VM 关机（开始 → Power → Shut down，必须完全关机不是 Sleep）。

```bash
# Mac 终端
VM_DIR=~/Library/Containers/com.utmapp.UTM/Data/Documents

# APFS clone（瞬间完成，不占额外磁盘）
cp -cR "$VM_DIR/Win10LTSC-CAPE.utm" "$VM_DIR/Win10LTSC-CAPE-clean.utm"

ls -la "$VM_DIR" | grep Win10LTSC
# 期望两条：原 .utm + clean .utm
```

**回滚方法**（万一 PS1 跑挂或 VM 状态被搞坏）：
```bash
rm -rf "$VM_DIR/Win10LTSC-CAPE.utm"
cp -cR "$VM_DIR/Win10LTSC-CAPE-clean.utm" "$VM_DIR/Win10LTSC-CAPE.utm"
killall UTM 2>/dev/null; sleep 2; open -a UTM
```

---

## 4. Mac 上构建三件套 ISO（一次离线 + 长文件名）

### 4.1 准备文件

```bash
cd ~/github/cape-installer

# 确认拿到最新 commits
git log --oneline -5 scripts/guest/c-guest-prep.ps1

rm -rf /tmp/cape-iso /tmp/cape.iso
mkdir -p /tmp/cape-iso

# (a) c-guest-prep.ps1（带 UTF-8 BOM——commit 0568850）
cp scripts/guest/c-guest-prep.ps1 /tmp/cape-iso/

# (b) Python x86 装包（注意 URL 不带 -amd64 后缀！）
curl -L -o /tmp/cape-iso/python-3.12.7.exe \
  https://www.python.org/ftp/python/3.12.7/python-3.12.7.exe

# (c) agent.py
curl -L -o /tmp/cape-iso/agent.py \
  https://gh-proxy.com/https://raw.githubusercontent.com/kevoreilly/CAPEv2/master/agent/agent.py

ls -lah /tmp/cape-iso/
# 期望 3 文件：c-guest-prep.ps1 ~12 KB，python-3.12.7.exe ~25 MB，agent.py ~30 KB
```

### 4.2 验证 BOM 与 x86

```bash
# BOM 验证（中文系统 PS 5.1 解析需要）
hexdump -C /tmp/cape-iso/c-guest-prep.ps1 | head -1
# 期望开头：ef bb bf

# x86 装包验证（agent.py 强制 32-bit）
file /tmp/cape-iso/python-3.12.7.exe
# 期望：含 "PE32 executable"，不是 "PE32+"
```

### 4.3 三格式 ISO（保留长文件名）

```bash
# -iso + -joliet + -udf：Win10 优先 UDF，长文件名保留
hdiutil makehybrid -o /tmp/cape.iso \
  -iso -joliet -udf \
  -default-volume-name CAPE \
  /tmp/cape-iso

ls -lh /tmp/cape.iso
# 期望 ~25-30 MB
```

> **为什么三格式？** 默认 `-iso` 用 ISO 9660，把 `python-3.12.7.exe` 压缩成 `PYTHON-3127.EXE`（多 dot 不允许）。UDF 保留原名。脚本里 glob 匹配 `python*.exe` 兜底，但 UDF 保留长名更可读（commit 9349c4b + 7bc50fa）。

---

## 5. UTM 切 CD-ROM 到 cape.iso → 启动 → 手工关 4 项 Defender

### 5.1 切 CD-ROM

VM 必须 Stopped（如果还在跑就 §3.1 的 Shut down）。

UTM 主界面 → 选 VM → ⌘, 进 Settings → **Drives** → CD-ROM 条目 → **Path → Browse → `/tmp/cape.iso`** → Save。

### 5.2 启动 + 用 OOBE 设的密码登录

启动 VM → Win10 桌面 → "此电脑" 应看到 **D: CAPE** 卷（含 3 个文件）。

### 5.3 手工关 4 项 Defender（**关键**——脚本无法自动化做）

```
开始 → 设置 (⚙) → 更新和安全 → Windows 安全中心
  → 点 "打开 Windows 安全中心"
    → 病毒和威胁防护（左侧栏）
      → 病毒和威胁防护设置 → 管理设置（蓝链接）：
        - 实时保护 → 关
        - 云提供的保护 → 关
        - 自动提交样本 → 关
        - 篡改防护 → 关
```

> **为什么必须手工？** Win10 LTSC 的 Tamper Protection 通过 OS 内核级保护 (`wdfilter.sys`) 锁定 `HKLM\Defender\Features` 注册表 ACL——**任何程序**（哪怕 Administrator + UAC 关了）都不能直接关。只有 Windows Security GUI 通过特权 API 能改。c-guest-prep.ps1 的 Tamper 段已加 graceful skip（commit cc25a2e），检测到 ACL 锁就跳过——但**前提是 IsTamperProtected = False**，需手工关。

每个开关切换时都会弹 UAC，点"是"。

切完确认：
```powershell
# Admin PowerShell
Get-MpComputerStatus | Select-Object IsTamperProtected, RealTimeProtectionEnabled
# 期望：IsTamperProtected=False, RealTimeProtectionEnabled=False
```

---

## 6. 跑 c-guest-prep.ps1

开始菜单 → PowerShell → **右键以管理员身份运行**：

```powershell
# 中文系统必须！否则 [✓] 等 Unicode 符号会乱码
chcp 65001

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# 验证 D: 三件套
Get-ChildItem D:\
# UDF 应显示长名：c-guest-prep.ps1 / python-3.12.7.exe / agent.py

# AdminPassword 必传，与 §2.4 OOBE 设的密码一致
D:\c-guest-prep.ps1 -AdminPassword cape123
```

### 6.1 预期完整输出（关键行）

```
[+] Admin 已确认
[+] 关 Defender 实时保护（运行时 + GPO 持久化）
[✓] Defender 实时保护 + 云查询已关（运行时 + GPO 双层）          ← commit 7bc50fa
[+] 关 Tamper Protection
[✓] Tamper Protection 已是 OFF（注册表受 ACL 锁定但 IsTamperProtected=False，跳过）   ← commit cc25a2e
[+] 关 Defender 整体（组策略）
[✓] 组策略禁用 Defender
... （Step 4-9：SmartScreen / Update / Telemetry / UAC / 防火墙 / 电源）
[+] 装 Python 3.12（D: 本地副本 python-3.12.7.exe，无需联网）       ← commit 4473f01 + 9ce0aa7
[✓] Python: Python 3.12.7 (32bit)                                    ← 32bit 必须！
[+] 拷 agent.py（D: 本地副本 agent.py，无需联网）
[✓] agent.pyw → C:\agent.pyw
[+] 注册 agent.pyw 自启动
[✓] 启动项已注册：C:\Program Files (x86)\Python312\pythonw.exe C:\agent.pyw
[+] 配静态 IP 192.168.122.105/24 gw=192.168.122.1
[✓] 静态 IP 配置完成
[+] 配自动登录: John                                                  ← commit 784233c
[✓] AutoAdminLogon=1, DefaultUserName=John
[+] 把网络 profile 强制设为 Private + 禁弹新网络提示
[✓] 所有网卡 profile = Private，新网络提示已禁

================================================================
              c-guest-prep.ps1 全部完成
================================================================

[+] 60s 后关机（Ctrl+C 取消）
```

### 6.2 倒计时期间 sanity check（可选，新开 PowerShell）

```powershell
python -c "import platform; print(platform.architecture())"
# ('32bit', 'WindowsPE')

(Get-Command pythonw.exe).Source
# 含 (x86)

ipconfig | Select-String "IPv4"
# 192.168.122.105
```

让 60s 倒计时跑完 → VM 自动 `shutdown /s /t 0`。

---

## 7. **关键验证**：reboot 测自动登录 + agent.py 自启

VM 关机后再启动一次（UTM 主界面双击）——**普通启动，不再跑 PS1**。

预期：
1. SeaBIOS 黑屏几秒
2. **自动登录**——直接进桌面，不停在登录界面
3. 30 秒内 pythonw.exe 在后台启起来

桌面就绪等 30 秒，PowerShell（不需 Admin）：

```powershell
Get-Process pythonw | Format-Table Id, ProcessName, Path
Get-NetTCPConnection -LocalPort 8000 -State Listen
Invoke-WebRequest http://127.0.0.1:8000/status -UseBasicParsing | Select StatusCode, Content
```

**3 项都成功** = 完美：
- pythonw 进程 1 个
- 8000 端口 LISTEN
- HTTP 200 + JSON 含 `"status": "init"`

如果失败：
- 没自动登录 → 检查 `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon` 的 `AutoAdminLogon` / `DefaultPassword`
- agent.py 没起 → `python C:\agent.pyw` 跑看错误（`pythonw` 不输出错误）

确认 OK → `shutdown /s /t 0` 关机。

---

## 8. Mac 端推送 qcow2 到 CAPE 服务器

VM 完全关机后（UTM 显示 Stopped）：

```bash
cd ~/github/cape-installer

# 找 qcow2
VM_DIR=~/Library/Containers/com.utmapp.UTM/Data/Documents/Win10LTSC-CAPE.utm/Data
SRC=$(ls -1 "$VM_DIR"/*.qcow2 | head -1)
echo "qcow2: $SRC"
ls -lh "$SRC"
# 期望 5-15 GB

# 推送
# 注意 -u <user>：CAPE 服务器默认 cape 用户，但测试机可能是 ubuntu / 别的
# 注意 -p <remote-path>：默认 /tmp/cuckoo1.qcow2
bash scripts/guest/c-host-export.sh \
  -q "$SRC" \
  -s <CAPE 服务器 IP> \
  -u <服务器登录用户名>  # cape / ubuntu / 你的用户
```

> 如果服务器要密码：脚本会等 ssh 提示。或者前置 `SSHPASS=<密码> sshpass -e bash scripts/guest/c-host-export.sh ...` 自动化。

预期输出：
```
[✓] qcow2 格式 OK
[✓] 无 backing file 依赖
[✓] VM 未运行
[✓] sha256: <hash>
[+] scp 1/3 ...
[✓] 推送完成

下一步在服务器上跑：
  ssh <user>@<server>
  cd /opt/cape-installer
  sudo make import-guest GUEST_QCOW2=/tmp/cuckoo1.qcow2
```

---

## 9. 服务器端 `make import-guest`

**前提**：服务器已跑过 `sudo make all`（Phase B 完成）+ 仓库在 `/opt/cape-installer`。

```bash
ssh <user>@<服务器>
cd /opt/cape-installer
sudo make import-guest GUEST_QCOW2=/tmp/cuckoo1.qcow2
```

5 个 c-stage 自动跑：

| Stage | 做什么 | 时长 |
|---|---|---|
| **c10-import-guest** | sha256 校验 + 拷到 `/var/lib/libvirt/images/cuckoo1.qcow2` | 30s-2min |
| **c20-define-domain** | 渲染 IDE+e1000 XML → `virsh define` → DHCP reservation | 1s |
| **c30-register-kvm-conf** | crudini 写 `[kvm] machines=cuckoo1` + `[cuckoo1]` 全字段 | 1s |
| **c40-smoke-guest** | `virsh start` → 轮询 agent.py 8000 端口（最长 120s） | 30-120s |
| **c50-snapshot-and-cape** | 拍 `clean` 快照 + unmask cape* + restart 服务 | 5s |

**c40 是关键**——agent.py 必须响应 `http://192.168.122.105:8000/status` 才算成功。

---

## 10. 端到端样本测试（Task 15）

服务器上：

```bash
# 验证 4 个 cape 服务全 active
for svc in cape cape-processor cape-rooter cape-web; do
  sudo systemctl is-active --quiet $svc && echo "✅ $svc" || echo "❌ $svc"
done

# 验证 cape 看到 cuckoo1
sudo journalctl -u cape -n 5 --no-pager | grep -i "loaded.*machine\|waiting.*tasks"
# 期望含 "Loaded 1 machine" + "Waiting for analysis tasks"

# 验证 agent.py 通
curl http://192.168.122.105:8000/status
```

浏览器：**`http://<服务器 IP>:8000/submit/`** → 上传无害 EXE（如 `notepad.exe` / `putty.exe`）→ 点 Analyze。

观察：
- Pending → Running（< 5s）→ Completed（< 1 min）
- `sudo virsh list` 期间 cuckoo1 状态 running
- 任务结束后 `sudo virsh snapshot-current cuckoo1` 显示 `clean`
- Web UI 任务详情页有 behavior log（进程 / 文件 / 注册表事件）

任务完成 + 自动回滚 = **Phase C 端到端 PASSED**。

---

## 11. 故障排查（症状 → 修法 → commit 引用）

### Mac/UTM 侧

| 症状 | 原因 | 修法 |
|---|---|---|
| 启动看不到 SeaBIOS | UEFI Boot 没关 | Settings → QEMU → Tweaks → 取消 UEFI Boot |
| Win10 装机看不到磁盘 | Drive Interface 是 VirtIO | Settings → Drives → 主盘 Interface = IDE |
| Win10 装完没网卡 | NIC 是 virtio-net | Settings → Network → Card = Intel Gigabit Ethernet (e1000) |
| 反 VM 失效 | Machine type 是 q35 | Settings → System → "Standard PC (i440FX..." |
| `D:\c-guest-prep.ps1` 报"没有结束符"+ 中文乱码 | PS1 文件无 UTF-8 BOM，中文系统 PS 5.1 用 GBK 解码 | 重做 ISO，验证 `hexdump -C` 开头 `ef bb bf`（commit 0568850） |
| `[+] 关 Tamper Protection` 报"不允许所请求的注册表访问权" | Tamper Protection 还是 ON | §5.3 GUI 手工关 4 项后重跑（commit cc25a2e graceful skip） |
| `python C:\agent.pyw` 报 "python3x86! not x64" | 装了 x64 Python | 卸 x64 装 x86（URL 不带 -amd64，commit 9ce0aa7） |
| `Test-Path D:\python-3.12.7.exe` 为 False | ISO 9660 文件名压缩成 `PYTHON-3127.EXE` | 重做 ISO 用 `-iso -joliet -udf` 三格式（commit 9349c4b 已加 glob 兜底） |
| `c-host-export.sh` 报"有 backing file" | UTM 拍过快照让 qcow2 链接化 | 用 §3 的 cp -cR 备份替代 UTM 快照；或 `qemu-img convert -O qcow2 -p $src /tmp/standalone.qcow2` 输出独立副本 |
| reboot 后停在登录界面 | 自动登录没配 | `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon` 的 `AutoAdminLogon` 应是 `1`（commit 784233c） |

### 服务器侧

| 症状 | 原因 | 修法 |
|---|---|---|
| `sudo make all` 卡在 20-host-stack 永挂 | cape2.sh 的 Tor wget 在 CN GFW 永挂 | 已在 vendor/cape2.sh.patched 跳过整段（commit 85c6d3b） |
| 30-poetry-fix 报 "Permission denied: /home/ubuntu" | 仓库放在 `/home/<user>/`，cape 用户进不去 | 移到 `/opt/cape-installer`：`sudo mv /home/<user>/cape-installer /opt/ && sudo chown -R <user>:<user> /opt/cape-installer && sudo chmod 755 /opt/cape-installer` |
| 40-kvm-libvirt 报 "/opt/CAPEv2/.venv/bin/python: command not found" | poetry 把 venv 装到 cache 路径 | 已在 30-poetry-fix.sh 加自动 symlink（commit 94c7e88）：`actual_venv=$(poetry env info --path); ln -sf $actual_venv /opt/CAPEv2/.venv` |
| c20 报 "Cannot check QEMU binary /usr/local/bin/..." | domain XML emulator 路径错 | 已修：`/usr/bin/qemu-system-x86_64`（commit 5488e11） |
| c20 报 "does not support machine type 'pc-i440fx-noble'" | 自编 QEMU 不识 Ubuntu alias | 已修：machine = `pc`（commit 8ab25e3） |
| c30 跑成功但 cape.service 报 "No machines available" | upstream 默认 kvm.conf 自带示例 [cuckoo1] section，老 guard 误判已配置 | 已修：guard 加 machines + snapshot 双检查（commit d90cc73）；手工救：`sudo make force-c30-register-kvm-conf` |
| `c-host-export.sh` scp 报 "Permission denied" | 服务器 ssh 用户不是默认 `cape` | 加 `-u <实际用户>` 参数 |

### 完整 commit 历史

```bash
git log --oneline 7fc1081..HEAD scripts/ vendor/
```

每个 commit 的 message 都解释了"踩了什么坑 + 怎么修 + 为什么"。

---

## 12. 多客户机扩展（未来）

当前 plan 的 Makefile 只处理一个 GUEST_NAME（默认 cuckoo1）。要加 `cuckoo2` (Win7) / `cuckoo3` (Win10 office loadout)：

### 12.1 同 OS 多 loadout（推荐，复用 base VM）

不需要新 VM——在 cuckoo1 上装额外软件后拍 libvirt 内部快照：

```bash
# 服务器上
sudo virsh start cuckoo1
# 通过 VNC 5901 远程进 Win10，装 Office / Adobe / etc.
sudo virsh snapshot-create-as cuckoo1 office "with Office 2021"
sudo virsh snapshot-create-as cuckoo1 browser "with Chrome + Java"
sudo virsh snapshot-list cuckoo1   # 期望多个 snapshot

# 在 kvm.conf 里 [cuckoo1] 改 snapshot=clean 为某 tag 配置；
# 或加 [cuckoo1_office] section 用同 label 但 snapshot=office
```

### 12.2 全新客户机（不同 OS）

按本文 §1-§9 重做一遍，改：
- `config.env`：`GUEST_NAME=cuckoo2`，`GUEST_IP=192.168.122.106`，`GUEST_MAC=52:54:00:CA:FE:02`
- ISO 同名（cape.iso 内容不变）
- VM 名：`Win7-CAPE` / `Win11-CAPE`
- 服务器侧 `make import-guest GUEST_QCOW2=/tmp/cuckoo2.qcow2`
- c30 已支持追加（不会覆盖 cuckoo1）

---

## 附：关键 commit 速查

| commit | 内容 |
|---|---|
| `784233c` | c-guest-prep.ps1 加自动登录 + 网络 Private |
| `0568850` | c-guest-prep.ps1 加 UTF-8 BOM |
| `cc25a2e` | Tamper Protection 注册表 ACL 锁定时优雅跳过 |
| `7bc50fa` | Defender GPO 持久化（重启后实时保护仍 OFF） |
| `9ce0aa7` | Python 3.12.7 改 x86（去掉 -amd64） |
| `4473f01` | D: ISO 本地副本优先（避免静态 IP 后断网下载失败） |
| `9349c4b` | D: 文件 glob 匹配（容忍 ISO 9660 改名） |
| `9717c23` | 磁盘总线 SATA → IDE（UTM 4.x GUI 没 SATA） |
| `85c6d3b` | cape2.sh 跳过 Tor 段（CN GFW 不可达） |
| `94c7e88` | 30-poetry-fix venv symlink 兜底 |
| `5488e11` | domain XML emulator 路径 /usr/local/bin → /usr/bin |
| `8ab25e3` | machine type pc-i440fx-noble → pc |
| `d90cc73` | c30 guard 加 machines + snapshot 双检查 |

`git log --oneline | grep -E "fix\\(|feat\\(c-"` 看完整修改链。
