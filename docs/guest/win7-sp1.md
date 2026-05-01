# 在 Intel Mac (UTM) 上构建 CAPE Win7 SP1 x64 客户机

> **状态**：基于 2026-05-01 实地配置（手工版）+ `scripts/guest/c-guest-prep-win7.ps1` 自动化版。
> Win7 已 EOL（2020-01-14），**配置上比 Win10 简单很多**——没 Tamper Protection / SmartScreen / Cortana / Telemetry 这一堆。
>
> 本文是 [win10-ltsc.md](./win10-ltsc.md)（Win10 LTSC）的 Win7 平行版。

---

## 0. 总览与关键差异

```
[ Intel Mac (UTM 4.7.5) ]                         [ Ubuntu 24.04 CAPE 服务器 ]
─────────────────────                             ──────────────────────────
①  UTM 装 Win7 SP1 x64（关键设置同 Win10：i440FX + Legacy BIOS + IDE + e1000 + 不装 Tools）
②  cp -cR 备份 .utm 包
③  Mac 上构建三件套 ISO（c-guest-prep-win7.ps1 + Python 3.6.8 x86 + agent.py）
④  Win7 内手工关 Defender 等（脚本里也做）→ 跑 c-guest-prep-win7.ps1
⑤  reboot 验证 auto-login + agent.py 自启
⑥  关机后 c-host-export.sh -p /tmp/cuckoo2.qcow2 推送
                                                    ⑦  改 config.env：cuckoo2 / 192.168.122.106 / MAC ...:02
                                                    ⑧  sudo make import-guest GUEST_QCOW2=/tmp/cuckoo2.qcow2
                                                    ⑨  浏览器 :8000/submit/ 提交（tags=win7 选 cuckoo2）
```

### 与 Win10 LTSC 的关键差异

| 维度 | Win10 LTSC（[win10-ltsc.md](./win10-ltsc.md)） | Win7 SP1 x64（本文） |
|---|---|---|
| **OS 版本号** | 10.0.19044+ | **6.1.7601** (RTM 是 7600，必须 SP1) |
| **Python 版本** | 3.12.7 x86 | **3.6.8 x86**（最后一个不需 KB2533623/KB3063858 的 Python 3） |
| **PowerShell 默认** | 5.1 内置 | **2.0**（很多现代 cmdlet 不可用） |
| **Tamper Protection** | 有，必须 GUI 关 | 没有（Win10 1903+ 引入） |
| **SmartScreen** | 有 | 没有（Win8+ 引入） |
| **Cortana / Telemetry** | 有 | 没有 |
| **MSE / Defender** | 集成 Defender（强） | Defender 弱（anti-spyware）+ MSE 可选独立产品 |
| **Network Discovery 提示** | 弹窗 | OOBE 时选 Home/Work/Public |
| **微软账户** | 强推 | 没这概念 |
| **EOL** | 2026 仍支持 | **2020-01-14 已 EOL** |
| **自动化脚本** | `c-guest-prep.ps1` | **`c-guest-prep-win7.ps1`**（PS 2.0 兼容版） |
| **客户机默认值** | cuckoo1 / 192.168.122.105 / `52:54:00:CA:FE:01` | **cuckoo2 / 192.168.122.106 / `52:54:00:CA:FE:02`** |
| **需要的内存** | 4096 MB | 2048 MB 即可 |
| **磁盘大小** | 40 GB | 30 GB |

### Win7 何时该用？

| 样本类型 | 优先 Win7 | 优先 Win10 |
|---|---|---|
| 老样本 / 教学样例 | ⭐⭐⭐ | |
| 大部分恶意软件（2020-2025） | ✅ | ✅ |
| 现代 .NET / 反 EDR 样本 | | ⭐⭐⭐ |
| Defender Evasion 测试 | （Win7 Defender 太弱） | ⭐⭐⭐ |
| 浏览器漏洞 / Java 老版 | ⭐⭐（IE/Java/Flash 老版） | （Win10 都禁了） |
| Office 宏样本 | ⭐⭐（+ Office 2010/2013） | ⭐⭐ |

---

## 1. Mac 工作站准备（同 Win10）

```bash
brew install --cask utm                # UTM 4.7.5+
brew install qemu sshpass              # qemu-img + scp 自动化
```

---

## 2. UTM 装 Win7 SP1 x64

### 2.1 ISO 来源

Win7 SP1 ISO 微软已不官方供应（EOL 后下架）。

**关键**：文件名必须含 `_with_sp1_` 或 `_sp1_` 字样——RTM（无 SP1）的 ISO 装出来 OS 版本是 6.1.7600，Python 3.6+ 都装不上。

| 来源 | 备注 |
|---|---|
| 微软 VLSC（企业批量授权） | 最稳定 |
| MSDN 订阅 | 历史 ISO 可下 |
| `archive.org` | `https://archive.org/download/microsoft-windows-7-ultimate-x64-iso` 等历史快照 |

**推荐版本**：`Windows 7 Ultimate SP1 x64` 或 `Windows 7 Enterprise SP1 x64`（约 3.1 GB）。文件名例：

```
en_windows_7_ultimate_with_sp1_x64_dvd_u_677332.iso
```

下载到 `~/Downloads/Win7SP1_x64.iso`。

### 2.2 UTM 向导（7 页——和 Win10 一样的关键设置）

| 页 | 选/填 | ⚠️ 与 Win10 一致 |
|---|---|---|
| 1. Start | **Virtualize** | |
| 2. Operating System | **Windows** | |
| 3. Windows | Boot ISO Image：选 Win7 SP1 ISO<br>**所有 4 个 checkbox 都不勾** | "Install Windows 10 or higher" 不勾 |
| 4. Hardware | Memory `2048 MB`（Win7 比 Win10 省）<br>CPU Cores `2`<br>Hardware OpenGL Acceleration：不勾 | |
| 5. Storage | `30 GB`（Win7 比 Win10 小） | qcow2 实占 5-10 GB |
| 6. Shared Directory | 跳过 | |
| 7. Summary | Name `Win7-CAPE`<br>Open VM Settings：勾 | |

### 2.3 Settings 9 个 pane（**与 Win10 完全相同**）

| Pane | 设置 |
|---|---|
| **System** | System = `Standard PC (i440FX + PIIX, 1996)`（不是 q35） |
| **QEMU → Tweaks** | UEFI Boot ❌；Use Hypervisor ✅；Use Local Time for Base Clock ✅ |
| **Drives** | 主盘 Interface = **IDE**；CD-ROM Interface = IDE |
| **Network** | Network Mode = `Shared Network`；**Emulated Network Card = `Intel Gigabit Ethernet (e1000)`** |
| **Sharing** | None / 全部不勾 |

→ Save。

### 2.4 启动 + 装 Win7

启动 VM → 应看到 SeaBIOS 黑屏几秒 → "Press any key to boot from CD" → 任意键。

Win7 装机：
- Language to install / Keyboard：随便
- **Install now**
- Product key：**取消勾选 "Automatically activate"** → 输入密钥或跳过
- I accept → **Custom (advanced)**
- 选未分配空间 → Next（自动分区，约 8-12 min，比 Win10 快）

### 2.5 OOBE（Win7 比 Win10 简单）

| 字段 | 推荐 |
|---|---|
| Username | **`John`**（必须 ASCII） |
| Computer name | `WIN7-CAPE` |
| Password | `cape123` |
| Confirm | `cape123` |
| Hint | `cape` |
| Product key activation | "Automatically activate" 取消勾 → Next |
| Windows Update settings | **"Ask me later"** |
| Time zone | 你的 |
| **Network location** | **Home network** ⭐（最像真实用户环境） |

桌面就绪 → 关掉 Action Center 警告弹窗。

### 2.6 sanity check（PowerShell 2.0）

开始 → 输 `powershell` → 右键 → Run as administrator：

```powershell
# 1. OS 是 SP1
Get-WmiObject Win32_OperatingSystem | Select Caption, Version, ServicePackMajorVersion
# 期望：Caption 含 "Windows 7"，Version=6.1.7601，ServicePackMajorVersion=1

# 2. 网卡是 e1000
Get-WmiObject Win32_NetworkAdapter | Where { $_.NetEnabled -eq $true } | Select Name, NetConnectionID
# 期望：Name 含 "Intel(R) PRO/1000" 或 "82540EM"

# 3. 网络通
ping -n 2 8.8.8.8

# 4. PowerShell 版本（默认 2.0）
$PSVersionTable.PSVersion
# 期望：Major=2

# 5. 用户名 + 路径
whoami
$env:USERPROFILE
# 期望：全 ASCII，比如 WIN7-CAPE\John + C:\Users\John
```

**任一项不对**：
- §1 Version=6.1.7600 → ISO 是 RTM 没 SP1，必须重装含 SP1 的 ISO
- §2 网卡不是 Intel/82540EM → 检查 Settings → Network → Card = Intel Gigabit Ethernet (e1000)
- §3 不通 → Settings → Network → Mode = Shared Network
- §5 含中文 → OOBE 用了中文用户名，要么重装要么建新 ASCII 账户切换

---

## 3. 拍 `.utm` 备份（同 Win10）

```bash
# Mac 终端，VM 必须 Stopped
VM_DIR=~/Library/Containers/com.utmapp.UTM/Data/Documents
cp -cR "$VM_DIR/Win7-CAPE.utm" "$VM_DIR/Win7-CAPE-clean.utm"
```

---

## 4. Mac 上构建三件套 ISO（**注意 Python 是 3.6.8 x86**）

```bash
cd ~/github/cape-installer

rm -rf /tmp/cape-win7-iso /tmp/cape-win7.iso
mkdir -p /tmp/cape-win7-iso

# (a) c-guest-prep-win7.ps1（带 BOM——commit d4fe5df）
cp scripts/guest/c-guest-prep-win7.ps1 /tmp/cape-win7-iso/

# (b) Python 3.6.8 x86（**注意：3.6.8 不是 3.7/3.8**——后两者要 KB2533623/KB3063858 不在你 ISO 里）
curl -L -o /tmp/cape-win7-iso/python-3.6.8.exe \
  https://www.python.org/ftp/python/3.6.8/python-3.6.8.exe

# (c) agent.py
curl -L -o /tmp/cape-win7-iso/agent.py \
  https://gh-proxy.com/https://raw.githubusercontent.com/kevoreilly/CAPEv2/master/agent/agent.py

ls -lah /tmp/cape-win7-iso/
# 期望 3 文件：c-guest-prep-win7.ps1 ~10 KB / python-3.6.8.exe ~30 MB / agent.py ~30 KB

file /tmp/cape-win7-iso/python-3.6.8.exe
# 期望含 "PE32 executable"（不是 PE32+）

# 三格式 ISO（保留长文件名）
hdiutil makehybrid -o /tmp/cape-win7.iso \
  -iso -joliet -udf \
  -default-volume-name CAPEW7 \
  /tmp/cape-win7-iso

ls -lh /tmp/cape-win7.iso
```

---

## 5. UTM 切 CD-ROM → 启动 → 跑 PS1

### 5.1 切 CD-ROM

VM Stopped → UTM Settings → Drives → CD-ROM 条目 → **Path → Browse → `/tmp/cape-win7.iso`** → Save。

### 5.2 启动 + 用 OOBE 设的密码登录

Win7 启动 → 桌面 → 打开计算机 → 应看到 **CAPEW7 (D:)** 卷（含 3 个文件）。

### 5.3 跑 c-guest-prep-win7.ps1

> **注意 Win7 PS 2.0 不支持 `Set-ExecutionPolicy -Scope Process`**——直接在 cmd 里加 `-ExecutionPolicy Bypass`：

开始菜单 → 输 `cmd` → 右键 → **以管理员身份运行**：

```cmd
PowerShell.exe -ExecutionPolicy Bypass -File D:\c-guest-prep-win7.ps1 -AdminPassword cape123
```

### 5.4 预期完整输出（关键行）

```
[+] Admin 已确认
[+] OS: Microsoft Windows 7 Ultimate SP1
[+] 关 Win7 Defender
[+] Defender 服务停 + 组策略禁用
[+] 检查 Microsoft Security Essentials
[+] MSE 未装，跳过                                ← 或显示卸载（如果装了）
[+] 关 Windows Update
[+] wuauserv 停 + NoAutoUpdate=1
[+] 关 UAC（重启生效）
[+] UAC 已关
[+] 关防火墙（所有 profile）
[+] 防火墙已关
[+] 关错误报告 + 蓝屏不自动重启
[+] 错误报告关 + 蓝屏不重启
[+] 电源永不待机 + 关 hibernation
[+] 电源已配
[+] 装 Python 3.6.8（D: 本地副本 python-3.6.8.exe）
[+] Python: Python 3.6.8 (32bit)                 ← 关键：32bit
[+] 拷 agent.py（D: 本地副本 agent.py）
[+] agent.pyw → C:\agent.pyw
[+] 注册 agent.pyw 自启动
[+] 启动项: C:\Program Files (x86)\Python36-32\pythonw.exe C:\agent.pyw
[+] 静态 IP 192.168.122.106/24 gw=192.168.122.1 dns=192.168.122.1
[+] 网卡: Local Area Connection
[+] IP/网关/DNS 已配
[+] 自动登录: John
[+] AutoAdminLogon=1, DefaultUserName=John

================================================================
              c-guest-prep-win7.ps1 全部完成
================================================================

[+] 60s 后关机（Ctrl+C 取消）
```

约 5-8 分钟跑完。让 60s 倒计时跑完，VM 自动关机。

### 5.5 60s 倒计时期间快速验证（可选）

新开 cmd（不需 admin）：

```cmd
python --version
:: 期望：Python 3.6.8

python -c "import platform; print(platform.architecture())"
:: 期望：('32bit', 'WindowsPE')

ipconfig | find "IPv4"
:: 期望：192.168.122.106

reg query "HKLM\Software\Microsoft\Windows\CurrentVersion\Run" /v CAPE_Agent
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon
:: 期望：CAPE_Agent 含 pythonw + agent.pyw；AutoAdminLogon REG_SZ 1

dir C:\agent.pyw
```

---

## 6. **关键验证**：reboot 测自动登录 + agent.py 自启

VM 关机后再启动一次（**普通启动，不再跑 PS1**）：

预期：
1. SeaBIOS 黑屏几秒
2. Win7 启动画面
3. **自动登录到桌面**（不停在登录界面）
4. 30 秒内 pythonw.exe 在后台启起来

桌面就绪等 30 秒，cmd（不需 admin）：

```cmd
:: 1. pythonw 进程
tasklist /fi "imagename eq pythonw.exe"
:: 期望：1 行含 pythonw.exe + PID

:: 2. 8000 端口 LISTENING
netstat -ano | find ":8000"
:: 期望：State=LISTENING

:: 3. HTTP 自测（Win7 默认无 curl，用 PowerShell）
powershell -c "(New-Object Net.WebClient).DownloadString('http://127.0.0.1:8000/status')"
:: 期望：JSON 含 "status": "init"
```

3 项都成功 → 完美：

```cmd
shutdown /s /t 0
```

如果失败：
- 没自动登录 → §10 故障排查 / `reg query ... AutoAdminLogon` 必须 `REG_SZ 1`（不是 REG_DWORD）
- pythonw 没起 → 手工 `python C:\agent.pyw` 看错误

---

## 7. Mac 推送 qcow2 到 CAPE 服务器（注意 `-p /tmp/cuckoo2.qcow2`）

VM 完全 Stopped 后：

```bash
cd ~/github/cape-installer

VM_DIR=~/Library/Containers/com.utmapp.UTM/Data/Documents/Win7-CAPE.utm/Data
SRC=$(ls -1 "$VM_DIR"/*.qcow2 | head -1)
echo "qcow2: $SRC"
ls -lh "$SRC"
# 期望 5-10 GB（Win7 比 Win10 小很多）

# 注意 -p /tmp/cuckoo2.qcow2（与 cuckoo1 区分！）
bash scripts/guest/c-host-export.sh \
  -q "$SRC" \
  -s <CAPE 服务器 IP> \
  -u <服务器用户名> \
  -p /tmp/cuckoo2.qcow2
```

---

## 8. 服务器端 import-guest（**改 config.env 切到 cuckoo2**）

```bash
ssh <user>@<server>
cd /opt/cape-installer

# 1. 备份当前 config.env（cuckoo1 的）
sudo cp config.env config.env.cuckoo1.bak

# 2. 改成 cuckoo2 的参数
sudo sed -i \
  -e 's/^GUEST_NAME=cuckoo1/GUEST_NAME=cuckoo2/' \
  -e 's/^GUEST_IP=192\.168\.122\.105/GUEST_IP=192.168.122.106/' \
  -e 's/^GUEST_MAC=52:54:00:CA:FE:01/GUEST_MAC=52:54:00:CA:FE:02/' \
  config.env

# 3. 验证
grep -E '^GUEST_(NAME|IP|MAC)=' config.env
# 期望：cuckoo2 / .106 / CA:FE:02

# 4. import-guest
sudo make import-guest GUEST_QCOW2=/tmp/cuckoo2.qcow2

# 5. 装完恢复 config.env 到 cuckoo1（避免下次混淆）
sudo cp config.env.cuckoo1.bak config.env
```

5 个 c-stage 跑完后两台都活：

```bash
sudo virsh list --all
# 期望：cuckoo1 + cuckoo2 都 running

curl http://192.168.122.105:8000/status   # cuckoo1 Win10
curl http://192.168.122.106:8000/status   # cuckoo2 Win7

sudo journalctl -u cape -n 5 --no-pager | grep -i "loaded.*machine"
# 期望：Loaded 2 machines

sudo grep '^machines' /opt/CAPEv2/conf/kvm.conf
# 期望：machines = cuckoo1,cuckoo2
```

---

## 9. 端到端样本测试（指定 Win7 客户机）

浏览器：`http://<server>:8000/submit/`

上传无害 EXE → 在 "Options" 填：

```
tags=win7
```

CAPE 会优先选 cuckoo2（Win7）执行。

观察：
- 任务列表 Pending → Running → Completed
- `sudo virsh list` 期间 cuckoo2 运行
- 任务结束后 cuckoo2 自动回 clean 快照

---

## 10. 故障排查

### Win7 + Python 装不上

| 报错 | 原因 | 修法 |
|---|---|---|
| `Setup Failed: Windows 7 Service Pack 1 and all applicable updates are required to install Python 3.x` | 装的不是 SP1，或缺 KB2533623/KB3063858 | 先 `ver` 确认是 6.1.7601；如果是，**改用 Python 3.6.8**（不检查 KB）；如果不是 6.1.7601 必须重装含 SP1 的 ISO |

### Auto-login 失效

| 现象 | 原因 | 修法 |
|---|---|---|
| `reg query AutoAdminLogon` 显示 `REG_DWORD 0x0` | 之前用错类型写过 | 直接重写：`reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 1 /f`（**必须 REG_SZ**，Win7 严格要求） |
| 重启停在登录界面 | DefaultPassword 与实际不符 | 重写 `DefaultPassword` 为实际 OOBE 密码 |
| 加域后失效 | DefaultDomainName 错 | `reg add ... /v DefaultDomainName /t REG_SZ /d %COMPUTERNAME% /f` |

### PowerShell 2.0 cmdlet 缺失

| cmdlet | Win7 有？ | 替代方案 |
|---|---|---|
| `Set-MpPreference` | ❌（Win8.1+） | `sc.exe stop WinDefend` + 注册表组策略 |
| `Get-NetAdapter` | ❌（Win8+） | `Get-WmiObject Win32_NetworkAdapter` |
| `New-NetIPAddress` | ❌（Win8+） | `netsh interface ipv4 set address` |
| `Set-NetConnectionProfile` | ❌ | OOBE 时选 Home network |
| `Invoke-WebRequest` | ❌（PS 3.0+） | `New-Object Net.WebClient` + TLS 1.2 |

c-guest-prep-win7.ps1 全部用兼容写法处理。

### TLS 1.2 / HTTPS 下载

| 现象 | 原因 | 修法 |
|---|---|---|
| `New-Object Net.WebClient` 下载 python.org 失败 | Win7 默认 SSL/TLS 1.0，python.org 强制 TLS 1.2 | 脚本顶部已加 `[System.Net.ServicePointManager]::SecurityProtocol = [Tls12]`；如果还失败：用 D: ISO 本地副本（不联网） |

---

## 11. 多客户机扩展提示

### 11.1 软件 loadout 在 cuckoo2（Win7）上加 Office

CAPE 经典组合：Win7 + Office 2010/2013（兼容大量历史 DOC/XLS 宏样本）。

服务器上：
```bash
sudo virsh start cuckoo2
# 通过 VNC 5901 远程进 Win7 装 Office 2013（用 ISO 装）
sudo virsh snapshot-create-as cuckoo2 office "Win7 + Office 2013"
sudo virsh snapshot-list cuckoo2  # 期望多个 snapshot
```

CAPE 提交时用 `tags=win7,office` 选这个快照。

### 11.2 多 Win7 客户机（cuckoo3、cuckoo4...）

按本文 §1-§8 重做，改：
- `Win7-CAPE` → `Win7-2-CAPE`
- 服务器 config.env：`GUEST_NAME=cuckoo3 / GUEST_IP=192.168.122.107 / GUEST_MAC=52:54:00:CA:FE:03`
- Mac PS1 参数：`-AdminPassword <你设的> -GuestIP 192.168.122.107`

---

## 附：关键 commit 速查

| commit | 内容 |
|---|---|
| `d4fe5df` | c-guest-prep-win7.ps1 PS 2.0 兼容自动化 |
| `0568850` | UTF-8 BOM（c-guest-prep.ps1 加，本文件同样原因加） |
| `9349c4b` | D: 文件 glob 匹配（容忍 ISO 9660 改名） |
| `4473f01` | D: ISO 本地副本优先（避免静态 IP 后断网） |
| `9717c23` | 磁盘总线 IDE（UTM 4.x GUI 没 SATA） |

更多踩坑记录见 `win10-ltsc.md` §11——大部分服务器侧问题（Tor / poetry venv / domain XML / c30 guard 等）Win7 / Win10 共用，本文不重复。
