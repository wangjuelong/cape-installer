# 在 Intel Mac (UTM) 上构建 CAPE Ubuntu 22.04 Server 客户机

> **状态**：基于已跑通的 Windows 客户机经验（[win10-ltsc.md](./win10-ltsc.md)）的 Linux 平行版。
> Ubuntu 22.04 Server 比 Windows 简单很多——没 Defender / SmartScreen / Tamper Protection / Cortana 这一堆，
> 一个 bash 脚本 `c-guest-prep-ubuntu22.sh` 就能搞定 OS 配置。
>
> 本文是 [win10-ltsc.md](./win10-ltsc.md) 的 Linux 平行版；
> Win7 走 [win7-sp1.md](./win7-sp1.md)，Win11 走 [win11-ltsc.md](./win11-ltsc.md)。

---

## 0. 总览与关键差异

```
[ Intel Mac (UTM 4.7.5) ]                         [ Ubuntu 24.04 CAPE 服务器 ]
─────────────────────                             ──────────────────────────
①  UTM 装 Ubuntu 22.04 Server（关键设置同 Windows：i440FX + Legacy BIOS + IDE + e1000）
②  cp -cR 备份 .utm 包
③  scp c-guest-prep-ubuntu22.sh → guest VM
④  guest 内 sudo bash 跑脚本（自动 shutdown）
⑤  reboot 验证 cape-agent.service 自启 + :8000 listen
⑥  关机后 c-host-export.sh -p /tmp/cuckoo2.qcow2 推送
                                                    ⑦  改 config.env：cuckoo2 / 192.168.122.106 / MAC ...:02
                                                       GUEST_PLATFORM=linux GUEST_ARCH=x64
                                                       GUEST_TAGS=ubuntu22,linux,x64
                                                    ⑧  sudo make import-guest GUEST_QCOW2=/tmp/cuckoo2.qcow2
                                                    ⑨  浏览器 :8000/submit/ 提交 ELF/.sh
                                                       Options: tags=linux
```

### 与 Windows 客户机的关键差异

| 维度 | Win10 LTSC（[win10-ltsc.md](./win10-ltsc.md)） | Ubuntu 22.04 Server（本文） |
|---|---|---|
| **OS 版本** | Win10 LTSC 2021 (10.0.19044+) | **Ubuntu 22.04.x LTS Server** (kernel 5.15+) |
| **iso 大小** | ~5 GB | **~2 GB**（server 无 GUI） |
| **磁盘** | 40 GB | **20 GB**（实占 5-8 GB） |
| **RAM** | 4096 MB | **2048 MB 够用** |
| **Python** | 必须 x86 32-bit（capemon.dll 限制） | **任意 Python 3**（agent.py 无位数检查；Linux analyzer 用 strace 不注入 DLL） |
| **agent 自启动** | 注册表 HKLM\Run + AutoAdminLogon | **systemd `cape-agent.service`** + getty@tty1 autologin |
| **静态 IP** | netsh + reg add | **netplan YAML** |
| **关 Defender / Tamper** | 4 项 GUI + GPO + 注册表 | **没有**（Ubuntu Server 无 AV） |
| **关自动更新** | wuauserv + GPO | **disable apt-daily.timer + unattended-upgrades + cloud-init 一并关** |
| **CD-ROM 三件套** | 必须（PS1 + Python.exe + agent.py） | **不需要**：直接 scp 脚本到 VM，guest 内 curl 拉 agent.py |
| **自动化脚本** | `c-guest-prep.ps1` (UTF-8 BOM PS1) | **`c-guest-prep-ubuntu22.sh`**（bash） |
| **客户机默认值** | cuckoo1 / 192.168.122.105 / `52:54:00:CA:FE:01` | **cuckoo2 / 192.168.122.106 / `52:54:00:CA:FE:02`** |
| **CAPE 分析器** | `analyzer/windows/`（capemon.dll API hook） | **`analyzer/linux/`（strace + procfs）** |
| **样本类型** | EXE/DLL/Office/JS/HTA/... | **ELF / shell / Python / .deb** |
| **EOL** | 2026 中（Win10 LTSC 2021 支持到 2027-01） | **2027-04**（Ubuntu 22.04 标准支持） |

### 何时该用 Linux 客户机？

| 样本类型 | 优先 Linux | 优先 Windows |
|---|---|---|
| Linux malware (Mirai/Mozi/XorDDoS/Gafgyt) | ⭐⭐⭐ | |
| IoT botnet 二进制 (MIPS/ARM 用户走 emulate 模式) | ⭐⭐⭐ | |
| Docker / k8s 攻击样本 | ⭐⭐⭐ | |
| 跨平台勒索（如 Python/Go 编译的） | ⭐⭐⭐（行为可能不同） | ⭐⭐ |
| 大部分恶意软件 (Win-targeted) | | ⭐⭐⭐ |
| Office 宏 / EXE / DLL | | ⭐⭐⭐ |
| 跨平台教学 / 比对分析 | ⭐⭐ | ⭐⭐ |

---

## 1. Mac 工作站准备

```bash
brew install --cask utm                # UTM 4.7.5+
brew install qemu sshpass              # qemu-img + scp 自动化
```

ISO：下载 **Ubuntu 22.04.x LTS Server amd64**（约 2 GB）到 `~/Downloads/ubuntu-22.04.5-live-server-amd64.iso`。

| 来源 | URL |
|---|---|
| 官方 | https://releases.ubuntu.com/22.04/ |
| **TUNA 镜像（CN 推荐）** | https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/22.04/ |
| Aliyun | https://mirrors.aliyun.com/ubuntu-releases/22.04/ |

> **不要 desktop 版**：装出来 ~10 GB，自带 GNOME / snap 一堆服务，sandbox 用不到反而拖。Server 版更适合自动化分析。

---

## 2. UTM 装 Ubuntu 22.04 Server——逐页向导

### 2.1 New VM 向导（7 页）

| 页 | 选/填 | ⚠️ |
|---|---|---|
| 1. Start | **Virtualize** | |
| 2. Operating System | **Linux** | |
| 3. Linux | Boot ISO Image：选 Ubuntu Server ISO<br>**Use Apple Virtualization：不勾**<br>**Use kernel image：不勾** | UTM 默认 QEMU/HVF；Apple Virtualization 后端跟 cape-installer 不兼容 |
| 4. Hardware | Memory `2048 MB`<br>CPU Cores `2`<br>Hardware OpenGL Acceleration：不勾 | |
| 5. Storage | `20 GB` | qcow2 实占 5-8 GB |
| 6. Shared Directory | 跳过 | |
| 7. Summary | Name `Ubuntu22-CAPE`<br>**Open VM Settings：勾** | |

### 2.2 Settings 7 个 pane（**与 Windows 客户机基本相同**）

| Pane | 设置 |
|---|---|
| **System** | Architecture = `x86_64`；System = `Standard PC (i440FX + PIIX, 1996)`；Force Multicore ✅ |
| **QEMU → Tweaks** | UEFI Boot ❌（i440fx + Legacy BIOS 与 cape-installer 反 VM SeaBios 链一致）；Use Hypervisor ✅；Use Local Time for Base Clock ✅ |
| **Drives** | 主盘 Interface = **IDE**；CD-ROM Interface = IDE |
| **Network** | Network Mode = `Shared Network`；**Emulated Network Card = `Intel Gigabit Ethernet (e1000)`** |
| **Sharing** | None / 全部不勾 |
| **Display** | virtio-vga；GL Acceleration ❌ |

→ Save。

> **为什么继续用 IDE + e1000 而不是 virtio？** 一致性。本仓库的 c20-define-domain 模板用 IDE + e1000；如果 guest 装时是 virtio，host 拿到的 qcow2 在 IDE 模式下可能起不来（Linux 内核 module 不在 initramfs 里）。Linux guest 用 IDE 性能稍逊但完全可用。

### 2.3 启动 + 装机

启动 → 应看到 SeaBIOS 黑屏几秒 → GRUB 启动选 **Try or Install Ubuntu Server** → Enter。

走 subiquity 安装器（半交互），关键页：

| 页 | 选 |
|---|---|
| Language | English（中文也行，但 console 阶段中文字体可能乱码） |
| Keyboard | 你的 |
| Type of install | **Ubuntu Server**（不要 minimized） |
| Network | 用默认 DHCP 装完，**装完后** c-guest-prep-ubuntu22.sh 会改静态 |
| Proxy | 空 |
| Mirror | `https://mirrors.tuna.tsinghua.edu.cn/ubuntu/`（subiquity 会探测可用） |
| Storage | **Use entire disk** + 不勾 LVM（LVM 复杂、对 sandbox 无价值） |
| Profile | Username = **`analyst`**（必须 ASCII，避开 `cape`/`vm`/`sandbox` 等反 VM 关键词）<br>Password = `cape123`<br>Server name = `ubuntu22-cape` |
| SSH | **勾 Install OpenSSH server**（让我们能 scp 进脚本） |
| Featured server snaps | **全部不勾**（用不到，少 bloat） |

装完约 8-12 min（apt-get 走 TUNA 快）。reboot 后弹 "remove media" 提示 —— UTM 会自动 eject ISO，按 Enter 继续。

### 2.4 装机后 sanity check

VM 启动到 console login，输 `analyst / cape123` 登入：

```bash
# 一次性 6 项检查
cat /etc/os-release | grep PRETTY            # 应含 Ubuntu 22.04
uname -a                                      # kernel 5.15.x-generic
ip a | grep "inet "                           # DHCP 拿到 192.168.122.x
ping -c 2 8.8.8.8                             # 通
ping -c 2 mirrors.tuna.tsinghua.edu.cn        # 通
sudo systemctl is-active ssh                  # active
```

记下 DHCP 拿到的 IP（如 192.168.122.213），下一步 scp 用。

---

## 3. 拍 `.utm` 备份（用 cp -cR，不用 UTM Snapshot Manager）

VM 关机（`sudo shutdown -h now`），Mac 终端：

```bash
VM_DIR=~/Library/Containers/com.utmapp.UTM/Data/Documents
cp -cR "$VM_DIR/Ubuntu22-CAPE.utm" "$VM_DIR/Ubuntu22-CAPE-clean.utm"
ls -la "$VM_DIR" | grep Ubuntu22
```

回滚同 [win10-ltsc.md §3](./win10-ltsc.md#3-拍-utm-备份用-cp--cr不用-utm-snapshot-manager)。

---

## 4. Mac 端把脚本送进 guest（不用 CD-ROM ISO）

VM 启动起来，确认 SSH 通：

```bash
# 装 sshpass 如还没装
brew install sshpass

# guest 装好后 DHCP 拿到的 IP，从 console "ip a" 看
GUEST_DHCP_IP=192.168.122.213   # 改成你看到的

# scp 脚本进去
cd ~/github/cape-installer
sshpass -p 'cape123' scp -o StrictHostKeyChecking=no \
  scripts/guest/c-guest-prep-ubuntu22.sh \
  analyst@$GUEST_DHCP_IP:/home/analyst/
```

> **为什么不学 Win 那套 cape.iso 三件套？** 因为 Linux 默认装了 SSH，scp 一行就到 —— 三件套 ISO 是给"装完没 SSH 的 Windows"用的解决方法，Linux 用不上。

---

## 5. guest 内跑 c-guest-prep-ubuntu22.sh

SSH 进 guest（或在 UTM console 直接操作）：

```bash
sshpass -p 'cape123' ssh -o StrictHostKeyChecking=no analyst@$GUEST_DHCP_IP \
  "sudo bash /home/analyst/c-guest-prep-ubuntu22.sh"
```

脚本里默认密码 `cape123` 用于 sudo（确保 OOBE 时设了同样的）。

### 5.1 预期完整输出（关键行）

```
[✓] OS: "Ubuntu 22.04.5 LTS"
[+] 切 apt 源 → TUNA
[✓] apt 源 = TUNA + apt-get update OK
[+] 关自动更新机制（unattended-upgrades / apt-daily / motd-news）
[✓] 自动更新已关
[+] 关 ufw
[✓] ufw off
[+] 禁用 cloud-init
[✓] cloud-init disabled（/etc/cloud/cloud-init.disabled flag）
[+] 关 snap auto-refresh
[✓] snap refresh held
[+] 装 Python3 + curl + strace（Linux analyzer 用）
[✓] Python: Python 3.10.12 | curl: 7.81.0
[+] 确认 analyst 用户存在
[✓] 用户 analyst 已存在
[+] 拉 agent.py → /home/analyst/agent.py
[✓] agent.py: 31876 bytes
[+] systemd: cape-agent.service
[✓] cape-agent.service enabled（重启后自启）
[+] netplan 静态 IP 192.168.122.106/24 gw=192.168.122.1
[✓] netplan written（NIC=enp1s0）
[+] autologin tty1 → analyst
[✓] tty1 autologin 配好

================================================================
              c-guest-prep-ubuntu22.sh 全部完成
================================================================

[+] 60s 后关机（Ctrl+C 取消）
```

### 5.2 倒计时期间快速验证（可选）

```bash
sshpass -p 'cape123' ssh analyst@$GUEST_DHCP_IP "
  python3 --version
  systemctl is-enabled cape-agent.service
  cat /etc/netplan/01-cape.yaml
  ip a | grep 'inet '
"
# 期望：Python 3.10.x / enabled / 含 192.168.122.106 / addresses 含 .106
```

让 60s 倒计时跑完 → VM 自动 `shutdown -h now`。

---

## 6. **关键验证**：reboot 测 agent.py 自启 + :8000 listen

VM 关机后再启动一次（普通启动，不再跑 prep 脚本）：

预期：
1. SeaBIOS 黑屏几秒
2. GRUB → Ubuntu 内核启动
3. **不在 console 停在 login**（getty@tty1 autologin → analyst）
4. 30 秒内 systemd 启 `cape-agent.service`，:8000 listen

通过 host 端验证（VM 现在是静态 IP 192.168.122.106）：

```bash
# host 上（CAPE 服务器或 Mac，能路由到 192.168.122.106）
sshpass -p 'cape123' ssh -o StrictHostKeyChecking=no analyst@192.168.122.106 "
  systemctl is-active cape-agent
  ss -tlnp 2>/dev/null | grep :8000
"
# 期望：active / LISTEN ... python3 ...

# 直接 curl agent
curl -s http://192.168.122.106:8000/status | head -5
# 期望：JSON 含 "status": "..."
```

如果失败：
- agent.py 没起 → `journalctl -u cape-agent -n 30` 看错误（多半 Python import 缺包，多见于 22.04 拒装 setuptools 时）
- :8000 没 listen → 手动 `python3 /home/analyst/agent.py` 跑看错
- 静态 IP 没生效 → `sudo netplan apply` 重试 / `journalctl -u systemd-networkd -n 30`

OK 后 `sudo shutdown -h now`。

---

## 7. Mac 推送 qcow2 到 CAPE 服务器（注意 `-p /tmp/cuckoo2.qcow2`）

VM 完全 Stopped 后：

```bash
cd ~/github/cape-installer

VM_DIR=~/Library/Containers/com.utmapp.UTM/Data/Documents/Ubuntu22-CAPE.utm/Data
SRC=$(ls -1 "$VM_DIR"/*.qcow2 | head -1)
echo "qcow2: $SRC"
ls -lh "$SRC"
# 期望 5-8 GB

# 注意 -p /tmp/cuckoo2.qcow2（与 cuckoo1/cuckoo3/cuckoo4 的 qcow2 区分！）
bash scripts/guest/c-host-export.sh \
  -q "$SRC" \
  -s <CAPE 服务器 IP> \
  -u <服务器用户名> \
  -p /tmp/cuckoo2.qcow2
```

---

## 8. 服务器端 import-guest（**改 config.env 切到 cuckoo2 + linux 元数据**）

```bash
ssh <user>@<server>
cd /opt/cape-installer

# 1. 备份当前 config.env
sudo cp config.env config.env.before-cuckoo2.bak

# 2. 改成 cuckoo2 + Linux 参数
sudo sed -i \
  -e 's/^GUEST_NAME=.*/GUEST_NAME=cuckoo2/' \
  -e 's/^GUEST_IP=.*/GUEST_IP=192.168.122.106/' \
  -e 's/^GUEST_MAC=.*/GUEST_MAC=52:54:00:CA:FE:02/' \
  -e 's/^GUEST_PLATFORM=.*/GUEST_PLATFORM=linux/' \
  -e 's/^GUEST_ARCH=.*/GUEST_ARCH=x64/' \
  -e 's/^GUEST_TAGS=.*/GUEST_TAGS=ubuntu22,linux,x64/' \
  -e 's/^GUEST_RAM_MB=.*/GUEST_RAM_MB=2048/' \
  config.env

# 3. 验证
grep -E '^GUEST_' config.env
# 期望：cuckoo2 / .106 / CA:FE:02 / linux / x64 / ubuntu22,linux,x64 / 2048

# 4. import-guest
sudo make import-guest GUEST_QCOW2=/tmp/cuckoo2.qcow2

# 5. 装完恢复 config.env
sudo cp config.env.before-cuckoo2.bak config.env
```

`c30-register-kvm-conf.sh` 已参数化 GUEST_PLATFORM / GUEST_ARCH / GUEST_TAGS（commit b6db122），会把 cuckoo2 段写成：

```ini
[cuckoo2]
label = cuckoo2
platform = linux
arch = x64
ip = 192.168.122.106
tags = ubuntu22,linux,x64
snapshot = clean
```

4 台 guest 全活后：

```bash
sudo virsh list --all
# 期望：cuckoo1 (Win10) / cuckoo2 (Ubuntu22) / cuckoo3 (Win7) / cuckoo4 (Win11)

curl http://192.168.122.105:8000/status   # cuckoo1 Win10
curl http://192.168.122.106:8000/status   # cuckoo2 Ubuntu22
curl http://192.168.122.107:8000/status   # cuckoo3 Win7
curl http://192.168.122.108:8000/status   # cuckoo4 Win11

sudo journalctl -u cape -n 5 --no-pager | grep -i "loaded.*machine"
# 期望：Loaded 4 machines

sudo grep '^machines' /opt/CAPEv2/conf/kvm.conf
# 期望：machines = cuckoo1,cuckoo2,cuckoo3,cuckoo4 （顺序按 import-guest 调用顺序，无强约束）
```

---

## 9. 端到端样本测试（指定 Linux 客户机）

浏览器：`http://<server>:8000/submit/`

上传无害 ELF / shell（如 `/bin/ls`、helloworld 小程序）→ 在 "Options" 填：

```
tags=linux
```

或更具体：`tags=ubuntu22,linux`。CAPE 优先选 cuckoo2。

观察：
- 任务列表 Pending → Running → Completed
- `sudo virsh list` 期间 cuckoo2 running
- 任务结束后 cuckoo2 自动回 clean 快照
- 报告里会看到 strace 跟踪的 syscalls / 文件操作 / 网络连接

> **测试样本想要无害但行为丰富**：编一个 `int main(){ system("ls /etc; curl -s example.com; sleep 5;"); }` 这种 C 程序，CAPE 会抓到 execve+网络 socket 等行为。

---

## 10. 故障排查

### Ubuntu 装机阶段

| 症状 | 原因 | 修法 |
|---|---|---|
| 装机器卡在 "Updating to the latest version of subiquity" | TUNA 镜像 + subiquity 自更新慢 | 等 5-10 min 或装机时网络选 Manual + 跳过 |
| 装完无 SSH | OOBE 时没勾 OpenSSH | guest 内 `sudo apt install openssh-server -y && sudo systemctl enable --now ssh` |
| LVM 装出来 host import 起不来 | LVM 增加 host snapshot/restore 复杂度 | OOBE Storage 页 **不勾 LVM**；如已装则重装 |
| 装完 IP 拿不到 | UTM Network 没选 Shared Network | Settings → Network → Mode = Shared Network |

### prep 脚本阶段

| 症状 | 原因 | 修法 |
|---|---|---|
| `apt-get update` 报 NO_PUBKEY | TUNA 镜像 GPG key 未同步 | guest 内 `sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys <KEY>` 或换 Aliyun 镜像 |
| `cape-agent.service` failed 立即重启 | agent.py 缺 Python 包 | `journalctl -u cape-agent -n 50` 看具体 import 错误，guest 内 pip install |
| netplan apply 报错 "No such file or directory" | 22.04 默认 NIC 名 enp1s0 / ens3 / eth0 | 脚本里 `NIC=$(ip -o link show ...)` 自动探测，但如多块 NIC 可能选错；手工指定 `NIC=ens3 sudo netplan apply` |
| cloud-init 把 netplan 又改回 DHCP | `/etc/cloud/cloud-init.disabled` flag 没生效 | 脚本里 `systemctl disable cloud-init*` —— 重启 cloud-init 应跳过；如还覆盖，`dpkg-reconfigure cloud-init` 关 dataSources |

### 验证阶段

| 症状 | 原因 | 修法 |
|---|---|---|
| reboot 后 console 停在 login | autologin override 没生效 | `sudo systemctl daemon-reload && sudo systemctl restart getty@tty1` |
| :8000 没 listen | agent.py 进程没跑 | `systemctl status cape-agent` → 看错误；手工 `python3 /home/analyst/agent.py` 看 import |
| static IP 不通 | DHCP 拿了不同地址 | `journalctl -u systemd-networkd` 看 netplan 是否真应用了；`ip a` 看实际 IP |
| 任务 stuck pending | cuckoo2 的 tags 在 kvm.conf 里没匹配 `tags=linux` | `grep -A3 cuckoo2 /opt/CAPEv2/conf/kvm.conf` 确认 tags 含 `linux` |

### 服务器侧（同 Win10/Win7/Win11 共用）

详见 [win10-ltsc.md §11 服务器侧](./win10-ltsc.md#服务器侧)。

---

## 11. 多客户机扩展提示

### 11.1 同 OS 不同 loadout（Docker、Java、apache、nginx ...）

`virsh start cuckoo2` → SSH 进去装额外软件 → `virsh snapshot-create-as cuckoo2 docker "with Docker"`。

样本提交时 `tags=ubuntu22,docker` 选这个快照。

### 11.2 多个 Linux 客户机（cuckoo5 = Ubuntu 24.04 / CentOS / Debian）

按本文 §1-§8 重做，改：
- `Ubuntu22-CAPE` → `Ubuntu24-CAPE`
- 服务器 config.env：`GUEST_NAME=cuckoo5 / GUEST_IP=192.168.122.109 / GUEST_MAC=52:54:00:CA:FE:05`
- TAGS 改 `ubuntu24,linux,x64`

### 11.3 32-bit / ARM Linux 客户机

UTM 在 Intel Mac 上 ARM 客户机需 emulate 模式（~10× 慢）。本仓库 Phase B 的 KVM/libvirt 也只配了 x86_64 path，扩 ARM 要重做较大一部分。当前不在 scope。

---

## 12. 设计取舍

### 为什么 prep 脚本是 bash 而不是 cloud-init seed ISO？

cloud-init 是 Ubuntu 官方"无人值守"方案，但：
- 启用 cloud-init 后它会覆盖很多手工配的东西（netplan、netconfig、defaults）—— 这也是 §4 必须显式 disable 它的原因
- seed-ISO 流程跟 Windows 客户机的 cape.iso 一致，但对 server 没必要（已有 SSH）
- bash 脚本透明、idempotent、易调试

### 为什么不直接装 Ubuntu Desktop？

| 维度 | Server | Desktop |
|---|---|---|
| 镜像 | ~2 GB | ~5 GB |
| 装完 qcow2 | 5-8 GB | 15-20 GB |
| 启动到 idle | ~15 sec | ~40 sec |
| 内存 idle | 200 MB | 1.5+ GB |
| snap 数量 | 0（手工装才有） | 10+（snap firefox/store/...） |
| GNOME 等 | 无 | 全套 |
| 对 sandbox 价值 | **完全足够** | **几乎无加成**（除非样本明确攻 X11） |

如果你的样本明确针对 Linux Desktop（如 Wayland exploit / X11 keylogger），那就换 Desktop。一般 Linux malware（IoT/Docker/Server-targeted）用 Server 就够。

### 为什么继续 SeaBIOS + Legacy BIOS + i440FX？

跟 cape-installer 的反 VM SeaBIOS 补丁（stage 51）链一致。如果用 q35 + UEFI + virtio，反 VM 链失效。Linux 在 IDE + e1000 下完全可用，性能差异对短任务（30s-5min）无影响。

---

## 附：关键 commit 速查（与 Windows 客户机共用）

| commit | 内容 |
|---|---|
| `b6db122` | c30 加 GUEST_PLATFORM/ARCH/TAGS 参数化（Linux guest 需要） |
| `9717c23` | 磁盘总线 SATA → IDE |
| `85c6d3b` | cape2.sh 跳过 Tor 段（CN GFW） |
| `94c7e88` | 30-poetry-fix venv symlink 兜底 |
| `5488e11` | domain XML emulator 路径 /usr/local/bin → /usr/bin |
| `8ab25e3` | machine type pc-i440fx-noble → pc |
| `d90cc73` | c30 guard 加 machines + snapshot 双检查 |

更多见 `win10-ltsc.md` §13 附录 + git log。
