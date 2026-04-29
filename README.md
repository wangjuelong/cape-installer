# cape-installer

在干净的 **Ubuntu 24.04 noble** 上一键复刻 CAPEv2 host + KVM/libvirt + 反 VM QEMU/SeaBios 栈。
专为中国网络环境优化（清华镜像硬编码，绕开 GFW 不可达的 `download.qemu.org` / `files.pythonhosted.org` / `repo.mongodb.org` / `raw.githubusercontent.com` / `github.com`）。

```
261d2d5 → cb72ae6 → 68e119d   主干 6 个 commit，2 台目标机端到端验证
                              （192.168.2.234 / 192.168.2.240）
```

---

## 1. 适用范围

### 操作系统

| 维度 | 要求 |
|---|---|
| 发行版 | **Ubuntu 24.04 noble** (`VERSION_CODENAME=noble`)，**不**支持其他版本/发行版 |
| 架构 | x86_64 |
| 内核 | 标准 Ubuntu HWE 内核（≥ 6.8），需含 KVM 模块 |

### 硬件

| 维度 | 要求 | 说明 |
|---|---|---|
| CPU | 8+ vCPU + Intel VT-x 或 AMD-V | `grep -q vmx /proc/cpuinfo` 必须命中 |
| 嵌套虚拟化 | 启用（VM-on-VM 部署时） | `cat /sys/module/kvm_intel/parameters/nested` 应为 `Y` |
| 内存 | ≥ 16 GB | 主机服务约 4 GB；剩余给客户机分析 VM |
| 磁盘 | / 可用 ≥ 50 GB | CAPEv2 + venv ≈ 1 GB；样本/快照视使用规模 |

### 网络

| 必须可达（卡死即装不上） | 备注 |
|---|---|
| `mirrors.tuna.tsinghua.edu.cn` | OS apt + MongoDB + PyPI 全走清华，**强依赖** |
| `gitlab.com` | QEMU 9.2.2 源码 archive |
| `apt.postgresql.org` | PostgreSQL 18 |
| `ppa.launchpadcontent.net` | Suricata 7.0 PPA |

| 通过镜像兜底/可选 | 失败时的兜底 |
|---|---|
| `github.com` HTTPS | 不通则 00-preflight 自动配 `gh-proxy.com` insteadOf 透明重写 |
| `raw.githubusercontent.com` | community.py 加 60s 超时跳过 |
| `download.qemu.org` | 用 GitLab archive 替代，固定不再用 |
| `pgp.mongodb.com` | vendor 本地 GPG key 优先 |
| `downloads.volatilityfoundation.org` | 默认跳过 windows.zip（21h 不可接受） |

### 软件先决条件

目标机本来不需要装任何东西，bootstrap.sh 会自动装 `make`。但如果你想纯手工，至少要：

```bash
sudo apt-get install -y make
```

---

## 2. 安装指南

### 2.1 30 秒上手（推荐）

```bash
# 1. 把 cape-installer 推到目标机
scp -r /path/to/cape-installer cape@<TARGET>:/opt/cape-installer
ssh cape@<TARGET>

# 2. 配置参数（仅 2 个）
cd /opt/cape-installer
cp config.env.sample config.env
vi config.env       # 改 SUBNET（默认 192.168.122）+ DB_PASSWORD（建议改）

# 3. 一键安装（bootstrap.sh 自动装 make + 调 make all）
sudo bash bootstrap.sh all      # 干净 noble 上 ~50 min

# 4. 装完
firefox http://<TARGET>:8000    # 看 CAPE Web UI（HTTP 200 OK）
```

### 2.2 单步 / 强制重跑

```bash
make help                                # 看所有 target

sudo make 00-preflight                   # 只跑某一步（依赖会自动跳过已完成）
sudo make 40-kvm-libvirt                 # 同上
sudo make force-50-anti-vm-qemu          # 强制重做某 stage（绕过幂等守卫）
make clean                               # 清空 logs/ state/（不影响已装组件）
```

### 2.3 安装阶段时序（240 实测）

| Stage | 耗时 | 做什么 |
|---|---|---|
| 00-preflight | 5-25s | OS/CPU/资源/网络可达探测；自动配 gh-proxy 镜像 |
| 10-mirrors | ~40s | 写 `/etc/pip.conf`、切 OS apt 镜像到 TUNA、禁用 cloud-init proxy |
| 20-host-stack | ~40 min | 跑 vendor/cape2.sh.patched all：装 PostgreSQL/MongoDB/Yara/Suricata 等 + cape user + systemd unit |
| 30-poetry-fix | ~30s | 修 .cache 权限、`poetry lock` + `poetry install` |
| 31-cape-config | <1s | 改 cuckoo.conf resultserver_ip / kvm.conf machines / mask cape* |
| 40-kvm-libvirt | ~20s | apt 装 libvirt 全栈 + 启 virbr0 + 装 libvirt-python |
| 50-anti-vm-qemu | ~6 min | 源码编译 QEMU 9.2.2 + 反 VM 补丁 |
| 51-anti-vm-seabios | ~15s | 源码编译 SeaBios 1.16.3 + 反 VM 补丁 |
| 99-smoke-test | <1s | 服务/端口/Web UI/import/virt-host-validate 自检 |
| **合计** | **~50 min** | |

---

## 3. 卸载指南

### 3.1 用法

```bash
sudo make uninstall-dry      # 先预演（强烈推荐第一次跑），不动任何东西
sudo make uninstall          # 实跑（要求输入 yes 确认）
sudo make uninstall-yes      # 实跑跳过确认（CI/批量）
sudo make u30-purge-apt      # 单步执行任一卸载 stage
```

### 3.2 默认安全网

- ✅ **自动备份** PostgreSQL `cape` 库 + MongoDB 用户库到 `/var/backups/cape-uninstall-<TS>.{sql,mongo}`
- ✅ **二次确认** prompt（`YES=1` 跳过）
- ✅ **best-effort**：u30 失败仍跑 u40~u99，最大努力清理
- ✅ **幂等**：重复跑等于空操作（已删的会被识别为 absent）
- ✅ **保护登录用户**：u70 拒绝删 UID ≥ 1000 的 OS 用户（防 SSH 锁死）

### 3.3 时序（240 实测）

| Stage | 耗时 | 做什么 |
|---|---|---|
| u00-preflight | 0s | YES=1 跳过确认；DRY_RUN=1 banner |
| u10-stop-services | 2s | 批量 stop 7 个服务（mongodb/pg 留给 u20） |
| u20-backup-data | 0s | pg_dump（mongo 无用户库时跳过 mongodump） |
| u30-purge-apt | 14s | apt purge 45 个包 + autoremove + clean |
| u40-remove-files | 1s | rm `/opt/CAPEv2` `/etc/poetry` `/data` 等 |
| u50-remove-systemd-units | 0s | rm cape*.service / mongodb.service |
| u60-revert-system-config | 0s | 还原 sysctl/limits/sudoers/pip.conf/apt sources/git insteadOf |
| u70-remove-users | 0s | userdel mongodb（cape UID<1000 守卫保护） |
| u80-clean-cron | 0s | 清 root crontab 里 cape2.sh 加的条目 |
| u99-verify | 1s | 残留检查 + 自动 timing summary |
| **合计** | **~17s** | |

详见 [docs/UNINSTALL.md](docs/UNINSTALL.md)。

---

## 4. 已固定的软件版本

> 决策见 [docs/WHY.md](docs/WHY.md)。所有版本号 **钉死**，避免上游升级时 silent 漂移。

### 主要组件

| 软件 | 版本 | 来源 | 备注 |
|---|---|---|---|
| Python | 3.12 (apt) | Ubuntu 24.04 系统包 | |
| Poetry | 2.3.4 | TUNA PyPI（vendor patch） | 跳过 install.python-poetry.org Fastly 卡死 |
| PostgreSQL | 18 | apt.postgresql.org noble-pgdg | |
| MongoDB | 8.0 | TUNA mongo 镜像（vendor patch） | GPG key vendor 在 `vendor/mongodb-server-8.0.asc` |
| libvirt | 10.0.0 (apt) | Ubuntu 24.04 系统包 | apt 装的足够，不源码重编 |
| libvirt-python | 11.9.0 (PyPI) | TUNA PyPI | 装入 `/opt/CAPEv2/.venv/` |
| QEMU | **9.2.2 (源码 + anti-VM 补丁)** | gitlab.com/qemu-project | 替代 apt 自带 8.2.2，去除 sandbox 指纹 |
| SeaBios | **1.16.3 (源码 + anti-VM 补丁)** | github.com/coreboot | 替换 `/usr/share/qemu/bios.bin` |
| Suricata | 7.0.15 | OISF PPA | 网络入侵检测 |
| Yara | latest（源码编译） | GitHub via cape2.sh | 由 git insteadOf 透传 gh-proxy |
| Volatility3 | latest（pip git） | GitHub via cape2.sh | windows.zip 默认跳过 |
| Tor | apt 默认 | Ubuntu 24.04 noble | jammy keyring 缺失，路由功能可选 |
| Mitmproxy | latest pip | TUNA PyPI | HTTPS 流量拦截分析 |

### CAPEv2 主体

| | |
|---|---|
| 源 | `https://github.com/kevoreilly/CAPEv2.git` |
| 路径 | `/opt/CAPEv2` |
| 分支 | `master`（最新） |
| Python 依赖 | `pyproject.toml` (PEP 621) + 我们追加的 `[[tool.poetry.source]]` tuna primary |

### 校验和（vendor/checksums.sh）

```
qemu-9.2.2.tar.gz       sha256 e7599083cd032a0561ad8fcba5ad182fbd97c05132abb4ca19f1b9d832eff5a2
seabios-rel-1.16.3.tar.gz sha256 1c1742a315b0c2fefa9390c8a50e2ac1a6f4806e0715aece6595eaf4477fcd8a
```

---

## 5. 添加分析客户机 (Phase C)

`cape-installer` 自动化的是 **Phase B**：host 服务栈 + KVM/libvirt + 反 VM QEMU/SeaBios。
要让 CAPE **真正分析样本**，还需要在 virbr0 上起一台 **Windows 客户机**并接入。本章给出推荐路径。

### 5.1 客户机选型

| 选项 | 优势 | 劣势 |
|---|---|---|
| **Windows 7 SP1 x64** ⭐ 推荐 | CAPE 文档默认；样本兼容性最好；体积小（~7 GB） | 微软已停止维护，无更新 |
| Windows 10 x64 | 现代样本兼容性好 | 体积大（~20 GB），更新繁多需关 |
| Windows 11 | 最新 | 资源消耗大；TPM/Secure Boot 配置复杂 |

下文以 **Win7 x64** 为例。Win10/11 思路相同，仅在反检测/资源处略调整。

### 5.2 准备 Windows ISO

```bash
# 把 ISO 放到 libvirt 默认位置
sudo mkdir -p /var/lib/libvirt/isos
sudo cp /path/to/Windows_7_x64.iso /var/lib/libvirt/isos/
sudo chown libvirt-qemu:kvm /var/lib/libvirt/isos/Windows_7_x64.iso
```

### 5.3 创建 libvirt 虚拟机

```bash
# 用 virt-install 起，名字用 cuckoo1（与 conf/kvm.conf 默认期望一致）
sudo virt-install \
  --name cuckoo1 \
  --memory 4096 \
  --vcpus 2 \
  --cpu host-passthrough \
  --disk path=/var/lib/libvirt/images/cuckoo1.qcow2,size=40,format=qcow2,bus=virtio \
  --cdrom /var/lib/libvirt/isos/Windows_7_x64.iso \
  --os-variant win7 \
  --network network=default,model=virtio \
  --graphics vnc,listen=0.0.0.0,port=5901 \
  --noautoconsole

# 用 VNC 客户端连 <TARGET>:5901 装 Windows，过程同手工装机
# 装完后：开机进入桌面，记录分配到的 IP（在 192.168.122.0/24 段内）
sudo virsh net-dhcp-leases default     # 看 cuckoo1 的 IP，比如 192.168.122.105
```

### 5.4 客户机内系统加固（关闭沙箱反检测会触发的项）

在 Windows 客户机里以管理员 PowerShell 执行：

```powershell
# 关 Defender（永久；Win10+ 需先在组策略里关 Tamper Protection）
Set-MpPreference -DisableRealtimeMonitoring $true
Set-MpPreference -DisableIOAVProtection $true

# 关 UAC（重启生效）
New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
  -Name "EnableLUA" -Value 0 -PropertyType DWord -Force

# 关防火墙
netsh advfirewall set allprofiles state off

# 关 Windows Update
Set-Service -Name wuauserv -StartupType Disabled
Stop-Service wuauserv

# 关错误报告 / 屏保 / 自动锁屏 / 主题动画（这些会"看起来像虚拟机"或干扰分析）
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
```

### 5.5 装 Python + CAPE agent.py

在客户机内：

```powershell
# 1. 装 Python（Win7 用 3.8.10 是最后兼容版本；Win10+ 用 3.11 / 3.12 都行）
#    从 python.org 下安装包；安装时勾 "Add Python to PATH"

# 2. 把 agent.py 放进客户机
#    从 host 上 wget 下来：
$agent = 'https://gh-proxy.com/https://raw.githubusercontent.com/kevoreilly/CAPEv2/master/agent/agent.py'
Invoke-WebRequest $agent -OutFile C:\agent.py

# 3. 改后缀让它无窗口运行（pythonw.exe）
move C:\agent.py C:\agent.pyw

# 4. 设置开机自启（注册表方式）
New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
  -Name 'CAPE_Agent' -Value 'C:\Windows\pyw.exe C:\agent.pyw' -PropertyType String -Force

# 5. 重启验证：reboot 后 agent.py 自启监听 8000 端口
#    回到 host 上测：
#    curl http://192.168.122.105:8000/    应返回 JSON，证明 agent 起来了
```

### 5.6 拍 clean snapshot

agent.py 验证可用后，**把客户机置回登录后的干净桌面状态**（关掉浏览器/资源管理器多余窗口），然后：

```bash
sudo virsh snapshot-create-as cuckoo1 --name clean \
  --description "first clean state with CAPE agent installed" \
  --atomic

sudo virsh snapshot-list cuckoo1     # 应看到 'clean' 那一行
```

CAPE 每次分析前会回滚到这个快照，所以**这个快照是分析的"起点"**。装坏样本不会污染。

### 5.7 在 CAPE 配置里注册客户机

```bash
sudo -u cape vi /opt/CAPEv2/conf/kvm.conf
```

把内容改成：

```ini
[kvm]
machines = cuckoo1
interface = virbr0

[cuckoo1]
label = cuckoo1                                    # 必须 = libvirt domain 名字
platform = windows
ip = 192.168.122.105                                # ↑ 5.3 看到的客户机 IP
snapshot = clean                                    # ↑ 5.6 拍的快照名
arch = x64
tags = win7,x64,cape                                # 自定义标签
resultserver_ip = 192.168.122.1                     # = host virbr0 IP
resultserver_port = 2042
```

### 5.8 启动 cape 服务

```bash
sudo systemctl unmask cape cape-processor
sudo systemctl restart cape cape-processor cape-rooter cape-web

# 看是否成功
sudo journalctl -u cape -n 30 --no-pager
sudo systemctl status cape       # 应该 active (running) 而不是 failed
```

### 5.9 验证：提交一个样本试跑

浏览器访问 `http://<TARGET>:8000/submit/`，上传一个无害测试文件（比如 `notepad.exe`），点 Analyze。

观察：
- CAPE Web UI 任务列表显示 "Pending" → "Running" → "Completed"
- 期间 `virsh domstate cuckoo1` 会变成 running
- `sudo virsh list` 看到 cuckoo1 在跑
- 任务结束后 cape 自动回滚到 `clean` 快照

成功跑完一次分析 = Phase C 接入完成。

### 5.10 常见问题

| 现象 | 原因 | 对策 |
|---|---|---|
| `virt-install` 报 `KVM is not available` | 嵌套虚拟化没开 / VT-x BIOS 没启 | 检查 `cat /sys/module/kvm_intel/parameters/nested` 和 `kvm-ok` |
| 客户机起不来，报 `unable to find file '/usr/share/qemu/bios.bin'` | stage 51 SeaBios 替换异常 | `sudo make force-51-anti-vm-seabios` 重新替换 |
| 客户机内 ping 不通 host 192.168.122.1 | virbr0 防火墙 / forwarding 没开 | `sudo iptables -L FORWARD`；检查 `/etc/sysctl.conf` 的 `net.ipv4.ip_forward=1` |
| cape 服务报 `Domain not found: 'cuckoo1'` | libvirt domain 名 ≠ kvm.conf 的 label | `sudo virsh list --all` 拿到真实名字，改 kvm.conf |
| cape 服务报 `No machines available` | machines = 空 | 改成 `machines = cuckoo1`，重启 cape |
| 任务一直 Pending | cape-rooter 没起 / agent.py 没自启 | `sudo systemctl status cape-rooter`；客户机内 `tasklist | findstr pyw` 看 agent 进程 |

---

## 6. 文档导航

| 文件 | 内容 |
|---|---|
| `README.md` | 本文：起步指南 + Phase C 客户机 |
| `docs/INSTALL.md` | 详细步骤手册（每个 stage 做了什么、怎么手动验证） |
| `docs/UNINSTALL.md` | 卸载手册（10 个 u-stage 详解 + 备份恢复） |
| `docs/TROUBLESHOOTING.md` | 已知问题 + 故障排查指引 |
| `docs/WHY.md` | 13 个关键设计决策（ADR）+ 实地验证发现 |

---

## 7. 仓库结构

```
cape-installer/
├── Makefile               # 编排（依赖图）
├── bootstrap.sh           # 入口：自动装 make 后调 make
├── config.env.sample      # 参数模板（SUBNET / DB_PASSWORD）
├── lib/common.sh          # 日志、retry、stage 包装、幂等 helper、gh_url、run/run_or_warn
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
├── vendor/                # 上游脚本快照 + 补丁 + 本地资产
│   ├── cape2.sh.patched           # 5 处 hunk
│   ├── kvm-qemu.sh.patched        # 版本快照
│   ├── pyproject-tuna-source.toml # 追加到 CAPE pyproject.toml
│   ├── checksums.sh               # QEMU/SeaBios sha256
│   └── mongodb-server-8.0.asc     # 本地 mongo GPG key
├── docs/
│   ├── INSTALL.md
│   ├── UNINSTALL.md
│   ├── TROUBLESHOOTING.md
│   └── WHY.md
├── logs/                  # 每 stage 一个 .log（自动生成）
└── state/                 # marker 文件（自动生成；含 github.env）
```
