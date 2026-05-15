# 在 Intel Mac (UTM) 上构建 CAPE Win11 x64 客户机

> **状态**：基于 [win10-ltsc.md](./win10-ltsc.md) 的踩坑结论 + Win11 24H2 的 install/OOBE bypass 补丁。
> 与 Win10 LTSC 共用大部分流程；本文只详细写**Win11 特有**的差异点（TPM/Secure Boot/UEFI bypass、OOBE 跳本地账号、Smart App Control、VBS）。
>
> 强烈推荐 **Windows 11 IoT Enterprise LTSC 2024** —— 不带 Copilot/Edge/Cortana，最贴近 sandbox 用途。
> 普通 Win11 Pro 24H2 也可，但要再多跑几条 debloat 命令。
>
> Linux 客户机走 [ubuntu22-server.md](./ubuntu22-server.md)（22.04 Server，cuckoo4，systemd + netplan）。

---

## 0. 总览与关键差异

```
[ Intel Mac (UTM 4.7.5) ]                         [ Ubuntu 24.04 CAPE 服务器 ]
─────────────────────                             ──────────────────────────
①  UTM 装 Win11 LTSC（关键设置同 Win10：i440FX + Legacy BIOS + IDE + e1000）
   + Win11 特有：装机阶段绕 TPM/SB/RAM 检查 + OOBE 跳微软账号
②  cp -cR 备份 .utm 包
③  Mac 上构建三件套 ISO（c-guest-prep.ps1 + Python x86 + agent.py）
④  Win11 内手工关 4 项 Defender + Smart App Control → 跑 c-guest-prep.ps1
⑤  reboot 验证 auto-login + agent.py 自启
⑥  关机后 c-host-export.sh -p /tmp/cuckoo3.qcow2 推送
                                                    ⑦  改 config.env：cuckoo3 / 192.168.122.107 / MAC ...:03
                                                    ⑧  sudo make import-guest GUEST_QCOW2=/tmp/cuckoo3.qcow2
                                                    ⑨  浏览器 :8000/submit/ 提交（tags=win11 选 cuckoo3）
```

### 与 Win10 LTSC 的关键差异

| 维度 | Win10 LTSC ([win10-ltsc.md](./win10-ltsc.md)) | Win11 IoT LTSC 2024（本文） |
|---|---|---|
| **OS 版本号** | 10.0.19044+ | **10.0.26100.x**（24H2 内核） |
| **官方硬件门槛** | 无 | TPM 2.0 + Secure Boot + UEFI + 4 GB + 64 GB + 受支持 CPU |
| **CAPE 走哪条路** | 直跑 | **必须 bypass**（Shift+F10 + LabConfig 注册表） |
| **OOBE 本地账号** | "Domain join instead" 入口可用 | **bypassnro.cmd 已被删**（24H2）；用 `start ms-cxh:localonly` |
| **Smart App Control** | 无 | **有**（22000+），需手工或 GPO 关 |
| **VBS / HVCI** | 默认关 | **默认开**（如硬件支持），需关 |
| **Defender Tamper Protection** | 有 | 有（同 Win10，必须 GUI 关） |
| **PowerShell 默认** | 5.1 | 5.1（同） |
| **Python** | 3.12.7 x86 | **3.12.7 x86**（同） |
| **自动化脚本** | `c-guest-prep.ps1` | **直接复用 `c-guest-prep.ps1`**（兼容；本文 §5.4 列差异处理） |
| **客户机默认值** | cuckoo1 / .105 / `...:01` | **cuckoo3 / 192.168.122.107 / `52:54:00:CA:FE:03`** |
| **需要的内存** | 4096 MB | **4096 MB 起步**（更低会被 OOBE 拒） |
| **磁盘大小** | 40 GB | **64 GB 起步**（24H2 占用更大） |

### 何时该用 Win11？

| 样本类型 | 优先 Win11 | 优先 Win10 |
|---|---|---|
| 现代 .NET / Win11-specific API 样本 | ⭐⭐⭐ | |
| 检测 Win11 anti-VM 字符串的样本 | ⭐⭐⭐ | |
| Smart App Control / WDAC bypass 样本 | ⭐⭐⭐ | |
| 老样本（2015-2020） | | ⭐ |
| 大部分恶意软件（2020-2025） | ⭐⭐ | ⭐⭐⭐ |
| Office 宏样本 | ⭐⭐（Office 2021/2024） | ⭐⭐ |

---

## 1. Mac 工作站准备（同 Win10）

```bash
brew install --cask utm                # UTM 4.7.5+
brew install qemu sshpass
```

ISO：下载 **Windows 11 IoT Enterprise LTSC 2024 x64**（约 5.0 GB）到 `~/Downloads/Win11IoTLTSC2024_x64.iso`。

| 来源 | 备注 |
|---|---|
| 微软 VLSC（企业批量授权） | LTSC 唯一官方渠道 |
| 微软评估中心（90 天试用） | https://www.microsoft.com/evalcenter — 有 LTSC IoT 入口 |
| MSDN/VS 订阅 | 永久 ISO 下载 |

> **不推荐** Win11 Pro 24H2 ISO：bloat 太多（Copilot / Outlook new / Teams 等），c-guest-prep.ps1 跑完后还要再删一堆 AppX。LTSC 一步到位。

---

## 2. UTM 装 Win11 LTSC——逐页向导

### 2.1 New VM 向导（7 页，与 Win10 几乎相同）

| 页 | 选/填 | ⚠️ 重点 |
|---|---|---|
| 1. Start | **Virtualize** | |
| 2. Operating System | **Windows** | |
| 3. Windows | Boot ISO Image：选 Win11 ISO<br>**4 个 checkbox 全部不勾** | 尤其 "Install Windows 10 or higher" — **不勾**！勾了会强制 UEFI + TPM 2.0 emulation，反 VM 补丁失效 |
| 4. Hardware | Memory `4096 MB`（最低，6144 更顺）<br>CPU Cores `2`<br>Hardware OpenGL Acceleration：不勾 | |
| 5. Storage | `64 GB`（Win11 24H2 占用大于 Win10） | qcow2 实占 15-25 GB |
| 6. Shared Directory | 跳过 | |
| 7. Summary | Name `Win11LTSC-CAPE`<br>Open VM Settings：勾 | |

### 2.2 Settings 9 个 pane（**与 Win10 完全相同**）

| Pane | 设置 |
|---|---|
| **System** | System = `Standard PC (i440FX + PIIX, 1996)`（不是 q35） |
| **QEMU → Tweaks** | UEFI Boot ❌；Use Hypervisor ✅；Use Local Time for Base Clock ✅；PS/2 Controller ✅ |
| **Drives** | 主盘 Interface = **IDE**；CD-ROM Interface = IDE |
| **Network** | Network Mode = `Shared Network`；**Emulated Network Card = `Intel Gigabit Ethernet (e1000)`** |
| **Sharing** | None / 全部不勾 |
| **Display** | virtio-vga；GL Acceleration ❌ |

→ Save。

### 2.3 启动 + 装 Win11——**关键的 2 个 bypass**

启动 VM → SeaBIOS 黑屏几秒 → "Press any key to boot from CD" → 任意键。

#### 2.3.1 第一个 bypass — 装机时跳过 TPM/SB/RAM/CPU 检查

走到 "**This PC can't run Windows 11**" 报错页时（Win11 24H2 装机器一定会卡这里，因为 SeaBIOS 不带 TPM/UEFI）：

1. **`Shift + F10`** → 弹出 cmd
2. 输 `regedit` → 回车
3. 定位 `HKEY_LOCAL_MACHINE\SYSTEM\Setup`
4. 右键 `Setup` → New → Key → 命名 **`LabConfig`**
5. 在 `LabConfig` 下右键 → New → DWORD (32-bit) Value，建 5 个：

   | Name | Value |
   |---|---|
   | `BypassTPMCheck` | `1` |
   | `BypassSecureBootCheck` | `1` |
   | `BypassRAMCheck` | `1` |
   | `BypassStorageCheck` | `1` |
   | `BypassCPUCheck` | `1` |

6. 关 regedit + cmd
7. 报错页点 ← (Back) → 重新进 "Install now"

> **为什么？** Win11 装机器会校验 TPM 2.0、Secure Boot、UEFI、CPU 系列、RAM 大小。SeaBIOS Legacy + 我们故意不开 TPM 全部不满足。`LabConfig` 注册表是 Microsoft 官方支持的 [unsupported install path](https://learn.microsoft.com/en-us/windows/whats-new/windows-11-requirements)（用于内部测试），不会触发后续 OS 报错。

#### 2.3.2 装机正流程

- Language/Keyboard：随便
- Install now → "I don't have a product key" → **Windows 11 IoT Enterprise LTSC**
- 同意 EULA → **Custom: Install Windows only (advanced)**
- 选 64 GB 未分配空间 → Next（自动分区，约 12-18 min，会自动重启 2 次）

### 2.4 OOBE——**第二个 bypass（24H2 删了 bypassnro）**

进入 OOBE 后走到 "**Let's connect you to a network**"（"让我们连接到网络"）页面：

1. **`Shift + F10`** → 弹出 cmd
2. 输入：

   ```
   start ms-cxh:localonly
   ```

3. 回车 → 弹一个本地账号创建窗口 → 输：

   | 字段 | 值 |
   |---|---|
   | Username | **`John`**（必须 ASCII！避开 cape/analyst/sandbox/vm/test 反 VM 关键词） |
   | Password | **`cape123`**（与 c-guest-prep.ps1 的 -AdminPassword 一致） |
   | Confirm | `cape123` |
   | 3 个安全问题 | 随便填（Q1=`a`、Q2=`b`、Q3=`c` 即可） |

4. 点 Next → OOBE 自动跳过 "登微软账号" 整段

> **背景**：Win11 24H2（build 26100+）删了 `OOBE\bypassnro.cmd`（之前 22H2/23H2 都有这条命令解锁本地账号）。`ms-cxh:localonly` 是 24H2 起替代 entry —— 触发新 OOBE 子流的 "本地账号" 分支。亲测 LTSC 2024 / Pro 24H2 都通。
>
> **fallback**：如果 `start ms-cxh:localonly` 在你拉到的特定 build 失效（极少数 Insider preview），改用 `oobe\bypassnro.cmd`（22H2/23H2）或断网（拔虚拟网线 → Settings → Network → 暂时切到 None → 桌面后切回 Shared）。

继续 OOBE：
- Privacy 6 个开关 → 全部 **Off**
- "Customize your experience" → 全 **不勾**（LTSC 应该不出这页）

桌面就绪后：
- ✅ 不点任何 UTM "Install drivers" 弹窗

### 2.5 装机后 sanity check

开始菜单 → 输 `powershell` → 右键 → **以管理员身份运行**：

```powershell
# 一次性 6 项检查（Win11 多查 1 项 build）
Write-Host "=== 1. OS ==="; (Get-CimInstance Win32_OperatingSystem).Caption
Write-Host "=== 2. Build ==="; [Environment]::OSVersion.Version
Write-Host "=== 3. BIOS ==="; (Get-CimInstance Win32_BIOS).Manufacturer
Write-Host "=== 4. NIC ==="; Get-NetAdapter | Select Name, InterfaceDescription, Status
Write-Host "=== 5. Network ==="; Test-NetConnection 8.8.8.8 -InformationLevel Quiet
Write-Host "=== 6. User ==="; whoami; $env:USERPROFILE
```

**期望：**
- §1 含 `Windows 11 IoT Enterprise LTSC` 或 `Windows 11`
- §2 Major=10, Minor=0, **Build ≥ 26100**
- §3 含 `SeaBIOS`
- §4 InterfaceDescription 含 `Intel(R) PRO/1000` 或 `82540EM`
- §5 = `True`
- §6 用户名 + USERPROFILE **必须全 ASCII**

任一不对 → §11 故障排查。

---

## 3. 拍 `.utm` 备份（同 Win10）

VM 关机（开始 → Power → Shut down）：

```bash
VM_DIR=~/Library/Containers/com.utmapp.UTM/Data/Documents
cp -cR "$VM_DIR/Win11LTSC-CAPE.utm" "$VM_DIR/Win11LTSC-CAPE-clean.utm"
ls -la "$VM_DIR" | grep Win11
```

**回滚**：删原 .utm，cp -cR clean.utm 覆盖回来。详见 [win10-ltsc.md §3](./win10-ltsc.md#3-拍-utm-备份用-cp--cr不用-utm-snapshot-manager)。

---

## 4. Mac 上构建三件套 ISO

```bash
cd ~/github/cape-installer

rm -rf /tmp/cape-win11-iso /tmp/cape-win11.iso
mkdir -p /tmp/cape-win11-iso

# (a) c-guest-prep.ps1（直接复用 Win10 版！与 Win11 LTSC 24H2 完全兼容）
cp scripts/guest/c-guest-prep.ps1 /tmp/cape-win11-iso/

# (b) Python 3.12.7 x86（与 Win10 同 — 3.12 支持 Win11 24H2）
curl -L -o /tmp/cape-win11-iso/python-3.12.7.exe \
  https://www.python.org/ftp/python/3.12.7/python-3.12.7.exe

# (c) agent.py
curl -L -o /tmp/cape-win11-iso/agent.py \
  https://gh-proxy.com/https://raw.githubusercontent.com/kevoreilly/CAPEv2/master/agent/agent.py

ls -lah /tmp/cape-win11-iso/
# 期望 3 文件

# 验证 BOM + x86
hexdump -C /tmp/cape-win11-iso/c-guest-prep.ps1 | head -1   # 期望 ef bb bf
file /tmp/cape-win11-iso/python-3.12.7.exe                  # 期望 PE32（不是 PE32+）

# 三格式 ISO
hdiutil makehybrid -o /tmp/cape-win11.iso \
  -iso -joliet -udf \
  -default-volume-name CAPEW11 \
  /tmp/cape-win11-iso

ls -lh /tmp/cape-win11.iso
```

---

## 5. 切 CD-ROM → 启动 → Win11 特有的"4 关 + 2 关"

### 5.1 切 CD-ROM

VM Stopped → UTM Settings → Drives → CD-ROM → Path → Browse → `/tmp/cape-win11.iso` → Save。

### 5.2 启动 + 登录

启动 VM → 自动登录到桌面（OOBE 时设的密码）→ "此电脑" 应看到 **D: CAPEW11**（含 3 个文件）。

### 5.3 手工关 4 项 Defender（**与 Win10 完全相同**）

```
开始 → 设置 → Privacy & security → Windows Security
  → Open Windows Security
    → Virus & threat protection
      → Manage settings：
        - Real-time protection → Off
        - Cloud-delivered protection → Off
        - Automatic sample submission → Off
        - Tamper Protection → Off
```

每个开关切换都弹 UAC，点"是"。详细原理见 [win10-ltsc.md §5.3](./win10-ltsc.md#53-手工关-4-项-defender关键脚本无法自动化做)。

### 5.4 Win11 特有：再关 2 项（Smart App Control + VBS/HVCI）

#### 5.4.1 Smart App Control（Win11 才有）

```
Windows Security → App & browser control
  → Smart app control settings
    → 选 "Off"
```

> **关键**：Smart App Control 一旦关掉**不能再开**（除非全新装系统）—— 这是 Microsoft 故意设计的，避免恶意软件偷偷开关。本场景下永久关掉正是我们要的。

GUI 关完后，PowerShell（Admin）兜底加 GPO 持久化：

```powershell
# 同时在 GPO 层禁用，扛重启
$smartApp = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
if (-not (Test-Path $smartApp)) { New-Item -Path $smartApp -Force | Out-Null }
Set-ItemProperty -Path $smartApp -Name VerifiedAndReputablePolicyState -Value 0 -Type DWord
```

#### 5.4.2 VBS / HVCI（虚拟机化安全 / Memory Integrity）

```
Windows Security → Device security → Core isolation
  → Memory integrity → Off
```

或 PowerShell（Admin）：

```powershell
# Memory Integrity (HVCI)
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' `
  -Name Enabled -Value 0 -Type DWord -Force

# VBS 整体
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' `
  -Name EnableVirtualizationBasedSecurity -Value 0 -Type DWord -Force

bcdedit /set hypervisorlaunchtype off
```

> **为什么必须关？** VBS 把 Defender / 反病毒 callback 移到独立的虚拟化保护层（VTL1），普通 Administrator 改不了 Defender 的注入 hook —— c-guest-prep.ps1 后续步骤会失败。同时 VBS 本身也是反 VM 信号（嵌套虚拟化在 SeaBIOS Legacy 下不真实）。
>
> **重启生效**——下面 §5.5 跑 PS1 完成后会重启，到时一并生效。

### 5.5 验证 6 项都关了

```powershell
Get-MpComputerStatus | Select-Object IsTamperProtected, RealTimeProtectionEnabled
# 期望：False / False

(Get-CimInstance -Namespace root/Microsoft/Windows/DeviceGuard -ClassName Win32_DeviceGuard).VirtualizationBasedSecurityStatus
# 期望：0（Disabled）—— 重启后才会变
```

任一项不是预期的 → 回 §5.3 / §5.4 重做。

---

## 6. 跑 c-guest-prep.ps1（与 Win10 完全相同的命令）

开始 → 输 `powershell` → 右键 → **以管理员身份运行**：

```powershell
chcp 65001
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# 验证 D:
Get-ChildItem D:\
# UDF 应显示长名：c-guest-prep.ps1 / python-3.12.7.exe / agent.py

# AdminPassword 必传
D:\c-guest-prep.ps1 -AdminPassword cape123 -GuestIP 192.168.122.107
```

> **注意** `-GuestIP 192.168.122.107` —— Win11 是 cuckoo3，不是 cuckoo1 的 .105！

### 6.1 预期完整输出（关键行）

与 Win10 [§6.1](./win10-ltsc.md#61-预期完整输出关键行) 完全相同；只有 IP 不同。最后两段：

```
[+] 配静态 IP 192.168.122.107/24 gw=192.168.122.1
[✓] 静态 IP 配置完成
[+] 配自动登录: John
[✓] AutoAdminLogon=1, DefaultUserName=John
[+] 把网络 profile 强制设为 Private + 禁弹新网络提示
[✓] 所有网卡 profile = Private，新网络提示已禁

================================================================
              c-guest-prep.ps1 全部完成
================================================================

[+] 60s 后关机（Ctrl+C 取消）
```

让 60s 倒计时跑完 → VM 自动 `shutdown /s /t 0`。

### 6.2 倒计时期间快速验证（可选）

```powershell
python -c "import platform; print(platform.architecture())"
# ('32bit', 'WindowsPE')

ipconfig | Select-String "IPv4"
# 192.168.122.107

# Win11 特有：再确认 SAC + VBS 都 OFF
Get-MpComputerStatus | Select IsTamperProtected, RealTimeProtectionEnabled
# False, False
```

---

## 7. **关键验证**：reboot 测自动登录 + agent.py 自启

VM 关机后再启动一次（**普通启动，不再跑 PS1**）。

预期：
1. SeaBIOS 黑屏几秒
2. Win11 启动画面
3. **自动登录到桌面**（不停在登录界面）
4. 30 秒内 pythonw.exe 在后台启起来

桌面就绪等 30 秒，PowerShell（不需 Admin）：

```powershell
Get-Process pythonw | Format-Table Id, ProcessName, Path
Get-NetTCPConnection -LocalPort 8000 -State Listen
Invoke-WebRequest http://127.0.0.1:8000/status -UseBasicParsing | Select StatusCode, Content
```

3 项都成功 = 完美：
- pythonw 进程 1 个
- 8000 端口 LISTEN
- HTTP 200 + JSON 含 `"status": "init"`

OK → `shutdown /s /t 0` 关机。

---

## 8. Mac 推送 qcow2 到 CAPE 服务器（注意 `-p /tmp/cuckoo3.qcow2`）

VM 完全 Stopped 后：

```bash
cd ~/github/cape-installer

VM_DIR=~/Library/Containers/com.utmapp.UTM/Data/Documents/Win11LTSC-CAPE.utm/Data
SRC=$(ls -1 "$VM_DIR"/*.qcow2 | head -1)
echo "qcow2: $SRC"
ls -lh "$SRC"
# 期望 15-25 GB（Win11 24H2 比 Win10 大）

# 注意 -p /tmp/cuckoo3.qcow2（与 cuckoo1/2 区分！）
bash scripts/guest/c-host-export.sh \
  -q "$SRC" \
  -s <CAPE 服务器 IP> \
  -u <服务器用户名> \
  -p /tmp/cuckoo3.qcow2
```

---

## 9. 服务器端 import-guest（**改 config.env 切到 cuckoo3**）

```bash
ssh <user>@<server>
cd /opt/cape-installer

# 1. 备份当前 config.env
sudo cp config.env config.env.before-cuckoo3.bak

# 2. 改成 cuckoo3 的参数
sudo sed -i \
  -e 's/^GUEST_NAME=.*/GUEST_NAME=cuckoo3/' \
  -e 's/^GUEST_IP=.*/GUEST_IP=192.168.122.107/' \
  -e 's/^GUEST_MAC=.*/GUEST_MAC=52:54:00:CA:FE:03/' \
  -e 's/^GUEST_TAGS=.*/GUEST_TAGS=win11,x64,cape/' \
  -e 's/^GUEST_RAM_MB=.*/GUEST_RAM_MB=4096/' \
  config.env

# 3. 验证
grep -E '^GUEST_(NAME|IP|MAC|TAGS|RAM_MB)=' config.env
# 期望：cuckoo3 / .107 / CA:FE:03 / win11,x64,cape / 4096

# 4. import-guest
sudo make import-guest GUEST_QCOW2=/tmp/cuckoo3.qcow2

# 5. 装完恢复
sudo cp config.env.before-cuckoo3.bak config.env
```

3 台都活：

```bash
sudo virsh list --all
# cuckoo1 / cuckoo2 / cuckoo3

curl http://192.168.122.105:8000/status   # Win10
curl http://192.168.122.106:8000/status   # Win7
curl http://192.168.122.107:8000/status   # Win11

sudo journalctl -u cape -n 5 --no-pager | grep -i "loaded.*machine"
# 期望：Loaded 3 machines

sudo grep '^machines' /opt/CAPEv2/conf/kvm.conf
# 期望：machines = cuckoo1,cuckoo2,cuckoo3
```

---

## 10. 端到端样本测试（指定 Win11 客户机）

浏览器：`http://<server>:8000/submit/`

上传无害 EXE → 在 "Options" 填：

```
tags=win11
```

CAPE 优先选 cuckoo3（Win11）执行。

观察：
- 任务列表 Pending → Running → Completed
- `sudo virsh list` 期间 cuckoo3 运行
- 任务结束后 cuckoo3 自动回 clean 快照

---

## 11. 故障排查（Win11 特有）

### Win11 装机阶段

| 症状 | 原因 | 修法 |
|---|---|---|
| "This PC can't run Windows 11" 卡死 | 没做 §2.3.1 LabConfig bypass | Shift+F10 → regedit → 加 5 个 DWORD → Back → Install now 重试 |
| LabConfig bypass 后还卡 "checking your PC" | 极少见，TPM emulation 还在路径里 | UTM Settings → QEMU → Tweaks → 确认 UEFI Boot 取消勾选 + 没勾任何 TPM 相关 |
| OOBE "Let's connect to a network" 没法跳过 | 24H2 删了 bypassnro.cmd | Shift+F10 → `start ms-cxh:localonly`（**24H2 唯一可靠路径**）；fallback：UTM Settings 临时切 Network Mode = None 强制断网 |
| OOBE 进了登微软账号页就回不去 | bypass 错过了 | UTM Power Off → 删 .utm → 用 §3 的 clean 包恢复 → 从 §2.3 重来 |

### Win11 运行阶段

| 症状 | 原因 | 修法 |
|---|---|---|
| Smart App Control 关了又自己开 | Win11 SAC 关掉**永不能再开**——不会自己开。如果还显示 On = §5.4.1 GUI 步骤没生效 | 确认 GUI 看到 "Off" + GPO 写入 `VerifiedAndReputablePolicyState=0` |
| pythonw 跑了但 8000 端口没起 | VBS 还在拦截网络 socket | §5.4.2 重新关 VBS + HVCI；reboot；`bcdedit /enum {current}` 应该看不到 `hypervisorlaunchtype` 或值 = `Off` |
| reboot 后停在登录界面（蓝紫色而非传统）| Win11 的 PIN/Hello 强制 | 加注册表禁 PIN：`reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v AllowDomainPINLogon /t REG_DWORD /d 0 /f` 后重启 |
| Defender Tamper Protection 显示 "Some settings are managed by your organization" 但状态还是 On | LTSC 的 GPO 显示有别于 Pro，但 IsTamperProtected 才是真值 | 看 `Get-MpComputerStatus`：IsTamperProtected=False 就是 OFF（GUI 提示是 LTSC 误导）|
| Recall (24H2) 占内存 | LTSC 不带 Recall，无需操作。Pro 24H2 才有 | Settings → Privacy → Recall & snapshots → Off |

### 服务器侧（同 Win10/Win7，不重复）

详见 [win10-ltsc.md §11 服务器侧](./win10-ltsc.md#服务器侧)。

---

## 12. 多客户机扩展提示

### 12.1 cuckoo1+2+3 三机并存（典型 CAPE 部署）

通过 §9 的 sed 改 `config.env` 后跑 `import-guest`，c30-register-kvm-conf.sh 用 **追加** 写法（commit b6db122 + d90cc73），不会覆盖之前的 cuckoo1/cuckoo2 段。

提交样本时按 tags 选机器：

| tags | 选哪台 |
|---|---|
| `win10ltsc` 或 `win10` | cuckoo1 |
| `win7` | cuckoo2 |
| `win11` | cuckoo3 |
| `office`（如装了）| 对应快照 |
| 不填 | CAPE 轮询/优先级算法选 |

### 12.2 Win11 + Office 2024 loadout

服务器上：
```bash
sudo virsh start cuckoo3
# VNC 5901 进 Win11，装 Office 2024 LTSC
sudo virsh snapshot-create-as cuckoo3 office "Win11 + Office 2024"
```

样本提交用 `tags=win11,office` 选这快照。

### 12.3 Win11 ARM64？

UTM 在 Intel Mac 上**只能跑 x86_64**（ARM64 客户机需 emulate 模式，~10× 慢）。如果要测 ARM64 Win11 样本，得换 Apple Silicon Mac + UTM Apple Virtualization 后端。本仓库 Phase B 的 KVM/libvirt 也只配了 x86_64 path，扩 ARM 要重做相当大一部分。当前不在 scope。

---

## 13. （可选）写专用 `c-guest-prep-win11.ps1`

目前直接复用 `c-guest-prep.ps1`（Win10 脚本）+ §5.4 手工关 SAC/VBS 即可。

如果未来要把 Win11 这两步也自动化（Smart App Control + VBS），可以 fork `c-guest-prep.ps1` → `c-guest-prep-win11.ps1`，在 Step 1（关 Defender）后加：

```powershell
# Smart App Control（仅 Win11 22000+，Win10 上跑会写到一个空 key 不影响）
Step '关 Smart App Control（Win11）'
$sac = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
if (-not (Test-Path $sac)) { New-Item -Path $sac -Force | Out-Null }
Set-ItemProperty -Path $sac -Name VerifiedAndReputablePolicyState -Value 0 -Type DWord
OK 'Smart App Control 已关'

# VBS / HVCI
Step '关 VBS + HVCI（Win11 默认开）'
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' `
  -Name Enabled -Value 0 -Type DWord -Force
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' `
  -Name EnableVirtualizationBasedSecurity -Value 0 -Type DWord -Force
& bcdedit /set hypervisorlaunchtype off | Out-Null
OK 'VBS + HVCI 已关（重启生效）'
```

并且在 OS 检测分支里仅当 `[Environment]::OSVersion.Version.Build -ge 22000` 才执行（避免 Win10 上 noop 浪费时间）。

PR 进来时记得：
- 加 GUEST_TAGS 默认 `win11,x64,cape`（仅当 GUEST_NAME 含 win11）
- README 文档更新
- 写 ADR（参考 docs/WHY.md ADR-Phase-C 风格）

---

## 附：关键 commit 速查（同 Win10/Win7 共享）

详见 [win10-ltsc.md 附录](./win10-ltsc.md#附关键-commit-速查) —— 服务器侧修复 / Python x86 / BOM / IDE bus / domain XML 等踩坑都共用。

Win11 特有目前没有新 commit（脚本与 Win10 共用），未来若加 `c-guest-prep-win11.ps1` 再补本节。
