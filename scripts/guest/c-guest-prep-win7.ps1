# c-guest-prep-win7.ps1 — 在 Win7 SP1 客户机内以 Administrator 跑
# Win7 默认 PowerShell 2.0——本脚本兼容 PS 2.0（不依赖 Set-MpPreference / Invoke-WebRequest /
# Get-NetAdapter 等 PS 3.0+ cmdlet），改用 sc.exe / netsh / Get-WmiObject / Net.WebClient。
#
# 用途：
#   1. 关 Win7 Defender / Update / UAC / 防火墙 / 蓝屏自动重启 / 错误报告
#   2. 装 Python 3.6.8 x86 + 拉 agent.py + 改 .pyw + 注册启动项
#   3. 配静态 IP (默认 192.168.122.106 cuckoo2 网段；Win10 用 .105)
#   4. 配自动登录（HKLM\Winlogon REG_SZ 1）
#   5. shutdown /s /t 0
#
# 用法（客户机内 Admin cmd 跑——PS 2.0 不支持 -ExecutionPolicy 参数行）：
#   PowerShell.exe -ExecutionPolicy Bypass -File D:\c-guest-prep-win7.ps1 -AdminPassword cape123
#
# Win10 LTSC 不要用本脚本，用 c-guest-prep.ps1。两者 OS 检测差异大。

[CmdletBinding()]
param(
  [string]$GuestIP = '192.168.122.106',
  [string]$GatewayIP = '192.168.122.1',
  [int]$Prefix = 24,
  [string]$DnsServer = '192.168.122.1',
  [string]$AgentUrl = 'https://gh-proxy.com/https://raw.githubusercontent.com/kevoreilly/CAPEv2/master/agent/agent.py',
  # x86 Python 3.6.8——最后一个不需要 KB2533623/KB3063858 就能跑 Win7 SP1 的 Python 3
  [string]$PythonInstallerUrl = 'https://www.python.org/ftp/python/3.6.8/python-3.6.8.exe',
  [string]$AdminUser = $env:USERNAME,
  [Parameter(Mandatory=$true)]
  [string]$AdminPassword,
  [switch]$NoShutdown
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Win7 默认 TLS 1.0，python.org / GitHub 强制 TLS 1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor `
  [System.Net.ServicePointManager]::SecurityProtocol

function Step($msg) { Write-Host "[+] $msg" -ForegroundColor Cyan }
function OK($msg)   { Write-Host "[+] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Die($msg)  { Write-Host "[-] $msg" -ForegroundColor Red; exit 1 }

# ---- 0. 必须 Admin（PS 2.0 兼容写法）----
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Die '必须以 Administrator 启动 PowerShell'
}
OK 'Admin 已确认'

# ---- 0.5 OS 版本校验 ----
$os = Get-WmiObject Win32_OperatingSystem
if ($os.Version -notlike '6.1.*') {
  Die "本脚本仅适用于 Win7 SP1（实际 OS Version=$($os.Version)）。Win10 用 c-guest-prep.ps1。"
}
if ($os.ServicePackMajorVersion -lt 1) {
  Die '必须是 Win7 SP1（当前没装 SP1）'
}
OK "OS: $($os.Caption) SP$($os.ServicePackMajorVersion)"

# ---- 1. 关 Win7 自带 Defender ----
Step '关 Win7 Defender'
& sc.exe stop WinDefend 2>&1 | Out-Null
& sc.exe config WinDefend start= disabled 2>&1 | Out-Null
$defKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
if (-not (Test-Path $defKey)) { New-Item -Path $defKey -Force | Out-Null }
New-ItemProperty -Path $defKey -Name DisableAntiSpyware -Value 1 -PropertyType DWord -Force | Out-Null
OK 'Defender 服务停 + 组策略禁用'

# ---- 2. 卸 Microsoft Security Essentials（如果装了）----
Step '检查 Microsoft Security Essentials'
$mse = Get-WmiObject Win32_Product -Filter "Name like '%Security Essentials%'" -ErrorAction SilentlyContinue
if ($mse) {
  Step "卸 $($mse.Name)（约 1-2 min）"
  $mse.Uninstall() | Out-Null
  OK 'MSE 已卸载'
} else {
  OK 'MSE 未装，跳过'
}

# ---- 3. 关 Windows Update ----
Step '关 Windows Update'
& sc.exe stop wuauserv 2>&1 | Out-Null
& sc.exe config wuauserv start= disabled 2>&1 | Out-Null
$wuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
if (-not (Test-Path $wuKey)) { New-Item -Path $wuKey -Force | Out-Null }
New-ItemProperty -Path $wuKey -Name NoAutoUpdate -Value 1 -PropertyType DWord -Force | Out-Null
OK 'wuauserv 停 + NoAutoUpdate=1'

# ---- 4. 关 UAC ----
Step '关 UAC（重启生效）'
$uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
New-ItemProperty -Path $uacKey -Name EnableLUA                  -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uacKey -Name ConsentPromptBehaviorAdmin -Value 0 -PropertyType DWord -Force | Out-Null
OK 'UAC 已关'

# ---- 5. 关防火墙 ----
Step '关防火墙（所有 profile）'
& netsh advfirewall set allprofiles state off | Out-Null
OK '防火墙已关'

# ---- 6. 关错误报告 + 蓝屏自动重启 ----
Step '关错误报告 + 蓝屏不自动重启'
$werKey = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'
if (-not (Test-Path $werKey)) { New-Item -Path $werKey -Force | Out-Null }
New-ItemProperty -Path $werKey -Name Disabled -Value 1 -PropertyType DWord -Force | Out-Null
$crashKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
New-ItemProperty -Path $crashKey -Name AutoReboot -Value 0 -PropertyType DWord -Force | Out-Null
OK '错误报告关 + 蓝屏不重启'

# ---- 7. 电源永不待机 + 关睡眠 ----
Step '电源永不待机 + 关 hibernation'
& powercfg /change standby-timeout-ac 0 | Out-Null
& powercfg /change standby-timeout-dc 0 | Out-Null
& powercfg /change monitor-timeout-ac 0 | Out-Null
& powercfg /change monitor-timeout-dc 0 | Out-Null
& powercfg /h off 2>&1 | Out-Null
OK '电源已配'

# ---- 8. 装 Python 3.6.8（幂等：已装 3.6.x x86 就跳过 installer）----
# 刷新 PATH（防上轮装完 PATH 没载入）
$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + `
  [System.Environment]::GetEnvironmentVariable('Path','User')

$existingPy = & cmd /c "python --version 2>&1"
$existingArch = ''
if ($existingPy -match '^Python 3\.6\.') {
  $existingArch = & cmd /c "python -c ""import platform; print(platform.architecture()[0])"" 2>&1"
}

if ($existingPy -match '^Python 3\.6\.' -and $existingArch -eq '32bit') {
  Step "Python 已装并对（$existingPy / $existingArch），跳过安装"
} else {
  $pyExe = "$env:TEMP\python-installer.exe"
  $pyOnIso = Get-ChildItem 'D:\' -Filter 'python*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($pyOnIso) {
    Step "装 Python 3.6.8（D: 本地副本 $($pyOnIso.Name)）"
    Copy-Item $pyOnIso.FullName $pyExe -Force
  } else {
    Step "装 Python 3.6.8（联网下载，可能因 TLS 1.2 失败）"
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($PythonInstallerUrl, $pyExe)
  }

  $pyArgs = @(
    '/quiet','InstallAllUsers=1','PrependPath=1',
    'Include_test=0','Include_doc=0','Include_launcher=1'
  )
  $proc = Start-Process -FilePath $pyExe -ArgumentList $pyArgs -Wait -PassThru -NoNewWindow
  if ($proc.ExitCode -ne 0) { Die "Python 装失败 exit=$($proc.ExitCode)" }

  # 刷新 PATH（installer 写到 Machine PATH 了）
  $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine')
}

# 验证最终状态
$pyVer = & cmd /c "python --version 2>&1"
if ($pyVer -notmatch '^Python 3\.6\.') { Die "Python 不可用：$pyVer" }
$pyArch = & cmd /c "python -c ""import platform; print(platform.architecture()[0])"" 2>&1"
if ($pyArch -ne '32bit') {
  Die "Python 不是 32-bit（实际 $pyArch）。Win7 + agent.py 要 x86 Python，URL 不能带 -amd64"
}
OK "Python: $pyVer ($pyArch)"

# ---- 9. 拉 agent.py ----
$agentDst = 'C:\agent.pyw'
$agentOnIso = Get-ChildItem 'D:\' -Filter 'agent*.py' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($agentOnIso) {
  Step "拷 agent.py（D: 本地副本 $($agentOnIso.Name)）"
  Copy-Item $agentOnIso.FullName $agentDst -Force
} else {
  Step "拉 agent.py（联网下载）"
  $wc = New-Object System.Net.WebClient
  $wc.DownloadFile($AgentUrl, $agentDst)
}
if (-not (Test-Path $agentDst) -or (Get-Item $agentDst).Length -lt 1024) {
  Die "agent.py 不存在或太小：$agentDst"
}
OK "agent.pyw → $agentDst"

# ---- 10. 注册启动项（HKLM\Run，登录后触发）----
Step '注册 agent.pyw 自启动'
$pyw = (Get-Command pythonw.exe -ErrorAction Stop).Path
$runKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
New-ItemProperty -Path $runKey -Name CAPE_Agent `
  -Value "`"$pyw`" `"$agentDst`"" -PropertyType String -Force | Out-Null
OK "启动项: $pyw $agentDst"

# ---- 11. 静态 IP（用 netsh，PS 2.0 兼容）----
Step "静态 IP $GuestIP/$Prefix gw=$GatewayIP dns=$DnsServer"
# 找活跃物理网卡
$adapter = Get-WmiObject Win32_NetworkAdapter | Where-Object {
  $_.NetEnabled -eq $true -and $_.PhysicalAdapter -eq $true
} | Select-Object -First 1
if (-not $adapter) { Die '找不到活跃物理网卡' }
$adapterName = $adapter.NetConnectionID
OK "网卡: $adapterName"

# 子网掩码——目前固定 /24
$mask = '255.255.255.0'

& netsh interface ipv4 set address name=$adapterName static $GuestIP $mask $GatewayIP | Out-Null
& netsh interface ipv4 set dnsservers name=$adapterName static $DnsServer primary | Out-Null
OK "IP/网关/DNS 已配"

# ---- 12. 自动登录（关键——agent.pyw 在 HKLM\Run 必须登录后才触发）----
Step "自动登录: $AdminUser"
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
# 注意 Win7 这些值类型必须 REG_SZ（String），不是 REG_DWORD
New-ItemProperty -Path $winlogon -Name AutoAdminLogon    -Value '1'              -PropertyType String -Force | Out-Null
New-ItemProperty -Path $winlogon -Name DefaultUserName   -Value $AdminUser       -PropertyType String -Force | Out-Null
New-ItemProperty -Path $winlogon -Name DefaultPassword   -Value $AdminPassword   -PropertyType String -Force | Out-Null
New-ItemProperty -Path $winlogon -Name DefaultDomainName -Value $env:COMPUTERNAME -PropertyType String -Force | Out-Null
# 无限次自动登录（防 Windows 在某些情况下自动清空密码）
New-ItemProperty -Path $winlogon -Name AutoLogonCount    -Value 0xFFFFFFFF       -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
OK "AutoAdminLogon=1, DefaultUserName=$AdminUser"

# ---- 13. 总结 ----
Write-Host ''
Write-Host '================================================================' -ForegroundColor Green
Write-Host '              c-guest-prep-win7.ps1 全部完成' -ForegroundColor Green
Write-Host '================================================================' -ForegroundColor Green
Write-Host ''
Write-Host '下一步：'
Write-Host '  1. 60s 后 VM 自动关机（或加 -NoShutdown 跳过）'
Write-Host '  2. 在 Mac 上跑 c-host-export.sh -p /tmp/cuckoo2.qcow2 推送服务器'
Write-Host '  3. 服务器上 sudo make import-guest GUEST_QCOW2=/tmp/cuckoo2.qcow2'
Write-Host '     （记得改 config.env：GUEST_NAME=cuckoo2 / GUEST_IP=192.168.122.106 / GUEST_MAC=52:54:00:CA:FE:02）'
Write-Host ''

# ---- 14. 关机 ----
if (-not $NoShutdown) {
  Step '60s 后关机（Ctrl+C 取消）'
  Start-Sleep -Seconds 60
  & shutdown /s /t 0
}
