# c-guest-prep.ps1 — 在 Win10 LTSC 客户机内以 Administrator 跑
# 用途：
#   1. 关 Defender / Tamper / SmartScreen / Update / Telemetry / UAC / Firewall
#   2. 装 Python 3.12 + 拉 agent.py + 改 .pyw + 注册启动项
#   3. 配静态 IP (默认 192.168.122.105/24, gw 192.168.122.1)
#   4. 配自动登录（agent.py 注册在 HKLM\Run，需要用户登录后才触发）
#   5. 网络 profile 强制 Private + 禁弹"新网络"提示
#   6. shutdown /s /t 0
#
# 用法（客户机内 Admin PowerShell）：
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   .\c-guest-prep.ps1 -AdminPassword cape123
#
# -AdminPassword 是 mandatory 的——明文写入 HKLM\...\Winlogon\DefaultPassword
# 用于自动登录。CAPE 客户机在隔离的 virbr0 网段，明文密码风险可接受。

[CmdletBinding()]
param(
  [string]$GuestIP = '192.168.122.105',
  [string]$GatewayIP = '192.168.122.1',
  [int]$Prefix = 24,
  [string]$DnsServer = '192.168.122.1',
  [string]$AgentUrl = 'https://gh-proxy.com/https://raw.githubusercontent.com/kevoreilly/CAPEv2/master/agent/agent.py',
  [string]$PythonInstallerUrl = 'https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe',
  [string]$AdminUser = $env:USERNAME,
  [Parameter(Mandatory=$true)]
  [string]$AdminPassword,
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
# 双层防御：
#   (a) Set-MpPreference 立即生效但是 session-scoped（重启后被 OS 重置 ON）
#   (b) HKLM\SOFTWARE\Policies\... GPO 持久化（重启后仍生效，扛住会重启的样本）
Step '关 Defender 实时保护（运行时 + GPO 持久化）'
# (a) 当前会话立即生效
Set-MpPreference -DisableRealtimeMonitoring $true       -ErrorAction SilentlyContinue
Set-MpPreference -DisableIOAVProtection      $true       -ErrorAction SilentlyContinue
Set-MpPreference -DisableBehaviorMonitoring  $true       -ErrorAction SilentlyContinue
Set-MpPreference -DisableBlockAtFirstSeen    $true       -ErrorAction SilentlyContinue
Set-MpPreference -DisableScriptScanning      $true       -ErrorAction SilentlyContinue
Set-MpPreference -DisableArchiveScanning     $true       -ErrorAction SilentlyContinue
Set-MpPreference -SubmitSamplesConsent       NeverSend   -ErrorAction SilentlyContinue
Set-MpPreference -MAPSReporting              0           -ErrorAction SilentlyContinue
# (b) GPO 持久化——重启后实时保护仍然 OFF
$rtpGpoKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'
if (-not (Test-Path $rtpGpoKey)) { New-Item -Path $rtpGpoKey -Force | Out-Null }
New-ItemProperty -Path $rtpGpoKey -Name DisableRealtimeMonitoring   -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $rtpGpoKey -Name DisableBehaviorMonitoring   -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $rtpGpoKey -Name DisableOnAccessProtection   -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $rtpGpoKey -Name DisableScanOnRealtimeEnable -Value 1 -PropertyType DWord -Force | Out-Null
# Spynet/MAPS GPO 也持久化关云查询
$spyGpoKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet'
if (-not (Test-Path $spyGpoKey)) { New-Item -Path $spyGpoKey -Force | Out-Null }
New-ItemProperty -Path $spyGpoKey -Name SpynetReporting       -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $spyGpoKey -Name SubmitSamplesConsent  -Value 2 -PropertyType DWord -Force | Out-Null
OK 'Defender 实时保护 + 云查询已关（运行时 + GPO 双层）'

# ---- 2. 关 Tamper Protection ----
# Defender\Features 注册表 key 由 TrustedInstaller ACL 锁定，Administrator
# 直接写常被拒绝。我们的策略：先看 IsTamperProtected 状态——如果已 False，
# 即使注册表写不进去也无所谓；只有 IsTamperProtected = True 才必须 GUI 关闭。
Step '关 Tamper Protection'
$tamperKey = 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features'
try {
  if (-not (Test-Path $tamperKey)) { New-Item -Path $tamperKey -Force -ErrorAction Stop | Out-Null }
  New-ItemProperty -Path $tamperKey -Name TamperProtection -Value 0 `
    -PropertyType DWord -Force -ErrorAction Stop | Out-Null
  OK 'Tamper Protection 注册表已写 0'
} catch {
  $isTamper = $null
  try { $isTamper = (Get-MpComputerStatus -ErrorAction Stop).IsTamperProtected } catch {}
  if ($isTamper -eq $false) {
    OK 'Tamper Protection 已是 OFF（注册表受 ACL 锁定但 IsTamperProtected=False，跳过）'
  } else {
    Warn 'Tamper Protection 注册表锁定 + 当前 ON——必须 GUI 关闭后重跑：'
    Warn '路径：开始 → 设置 → 更新和安全 → Windows 安全中心'
    Warn '     → 病毒和威胁防护 → 管理设置 → 篡改防护 → 关'
    Die  '请手工关 Tamper Protection 后重跑（前面 step 幂等无副作用）'
  }
}

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

# ---- 13.5 配自动登录 ----
# agent.py 注册在 HKLM\Run，必须有用户登录到桌面才会被触发。
# 明文密码写入 Winlogon registry——CAPE 客户机在 isolated virbr0 网段，可接受。
Step "配自动登录: $AdminUser"
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $winlogon -Name AutoAdminLogon    -Value '1'              -Type String
Set-ItemProperty -Path $winlogon -Name DefaultUserName   -Value $AdminUser       -Type String
Set-ItemProperty -Path $winlogon -Name DefaultPassword   -Value $AdminPassword   -Type String
Set-ItemProperty -Path $winlogon -Name DefaultDomainName -Value $env:COMPUTERNAME -Type String
# 确保 password 不在登录后过期清空
Set-ItemProperty -Path $winlogon -Name AutoLogonCount    -Value 0xFFFFFFFF       -Type DWord -ErrorAction SilentlyContinue
OK "AutoAdminLogon=1, DefaultUserName=$AdminUser"

# ---- 13.6 网络 profile 强制 Private + 禁"新网络"提示 ----
Step '把网络 profile 强制设为 Private + 禁弹新网络提示'
# 当前已有的网卡 profile 全部设为 Private
Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
  Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
}
# 禁弹"是否发现网络"对话框（让 Win10 默认按 Private 处理新网络，避免推到服务器后再弹）
$nnwKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff'
if (-not (Test-Path $nnwKey)) { New-Item -Path $nnwKey -Force | Out-Null }
OK '所有网卡 profile = Private，新网络提示已禁'

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
