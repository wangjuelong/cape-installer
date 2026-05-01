# INSTALL — 详细步骤手册

本文档讲清楚每个 stage 在做什么，以便你**不跑脚本也能照着 MD 一步步装出来**——脚本只是这些步骤的自动化版。

---

## 前置：什么是 cape-installer

cape-installer 把官方 [CAPEv2](https://github.com/kevoreilly/CAPEv2) 的 `installer/cape2.sh` 和 `installer/kvm-qemu.sh` 包了一层，做了 5 件事：

1. **配置中国镜像**（清华 PyPI/apt/MongoDB）
2. **修复上游脚本里的 buggy `poetry pip install` 行**
3. **绕开**几个 GFW 阻塞的下载（`download.qemu.org` → GitLab、`raw.githubusercontent.com` 跳过）
4. **修正**几个 conf 默认值（resultserver_ip、kvm.conf machines）
5. **mask** cape & cape-processor（Phase B 范围内没 guest VM，强行起会 restart loop 刷日志）

---

## 全流程时序

```
00-preflight   (~10s)   — 校验 OS / CPU / 资源 / 网络可达
10-mirrors     (~30s)   — 配清华镜像
20-host-stack  (~25min) — 跑 cape2.sh all（postgres/mongo/yara/suricata/cape）
30-poetry-fix  (~10min) — 修 venv + poetry install 装所有 Python deps
31-cape-config (~5s)    — 改 cuckoo.conf / kvm.conf / mask cape services
40-kvm-libvirt (~3min)  — apt 装 libvirt + 起 virbr0 + 装 libvirt-python
50-anti-vm-qemu (~30min)— 拉 GitLab → 重打包 → kvm-qemu.sh qemu 编译装
51-anti-vm-seabios (~5min) — 拉 GitHub → kvm-qemu.sh seabios 编译装
99-smoke-test  (~10s)   — 服务/网络/import/virt-host-validate 自检
─────────────────────────────────────────
合计                    ~75 min
```

---

## Stage 00-preflight

**做什么**：校验环境。

**关键检查**：
- `/etc/os-release` 必须 `ID=ubuntu` + `VERSION_CODENAME=noble`
- `/proc/cpuinfo` 必须含 `vmx` flag（嵌套 KVM）
- 内存 ≥ 14G、`/` 可用 ≥ 45G（留余量）
- `curl -fsSI` 探测：清华、GitHub、GitLab 都通；GFW 阻塞的 raw.githubusercontent.com / download.qemu.org 仅 warn

**手动等价**：
```bash
. /etc/os-release && [ "$VERSION_CODENAME" = "noble" ]
grep -q '^flags.*\bvmx\b' /proc/cpuinfo
df --output=avail -BG /
free -h
curl -fsSI https://mirrors.tuna.tsinghua.edu.cn/ubuntu/
```

---

## Stage 10-mirrors

**做什么**：把所有 Python / apt / Mongo 下载切到清华镜像；禁用 cloud-init 的 apt 代理（这次踩到了它 502）。

**关键文件**：
- `/etc/pip.conf` — 写入 `[global] index-url = https://pypi.tuna.tsinghua.edu.cn/simple` 等
- `/etc/environment` — 追加 `PIP_INDEX_URL` / `PIP_TRUSTED_HOST`
- `/etc/sudoers.d/99-cape-mirror` — `Defaults env_keep += "PIP_INDEX_URL ..."`（让 sudo 子进程读到）
- `/etc/apt/apt.conf.d/90curtin-aptproxy` → 重命名为 `.disabled`（cloud-init 默认装的代理 → `192.168.2.228:7890` 抖动）

**手动等价**：
```bash
sudo tee /etc/pip.conf <<EOF
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
trusted-host = pypi.tuna.tsinghua.edu.cn
EOF
sudo mv /etc/apt/apt.conf.d/90curtin-aptproxy{,.disabled} 2>/dev/null || true
sudo apt-get update
```

---

## Stage 20-host-stack

**做什么**：跑 patch 过的 `cape2.sh all`，装好 host 端整套服务。

**步骤**：
1. `git clone CAPEv2` → `/opt/CAPEv2`（**预克隆**，让我们能在 cape2.sh 跑前改 pyproject.toml）
2. `cat vendor/pyproject-tuna-source.toml >> /opt/CAPEv2/pyproject.toml` — 加清华源
3. `cp vendor/cape2.sh.patched /tmp/cape2.sh` — 上游脚本副本（已 patch）
4. 写 `/tmp/cape-config.sh`（cape2.sh source 的参数文件）
5. `sudo -E bash /tmp/cape2.sh all <SUBNET>.1`

**cape2.sh.patched 的 3 处改动**：
- L938：mongo 仓库 URL 从 `repo.mongodb.org` 换成清华
- L1383：注释掉 buggy 的 `poetry pip install -r pyproject.toml`（由 stage 30 接管）
- L1422：`community.py` 加 `timeout 60 + || true`（GitHub raw 不通会卡死）

**装完后系统多了什么**：
- apt 包：`postgresql-18`、`mongodb-org=8.0`、`suricata`、`yara`（源码编后 dpkg 装）、`tor`、几十个 dev 库
- 用户：`cape`（system，UID 自动）
- /opt/CAPEv2/：完整 CAPE repo + conf/*.conf（从 conf/default 拷的）
- systemd unit：`cape`、`cape-processor`、`cape-rooter`、`cape-web`

---

## Stage 30-poetry-fix

**做什么**：建 CAPE 的 Python venv 并装齐所有依赖。**这步是上游 cape2.sh 真正的失败点**——它那行 `poetry pip install` 是 buggy 语法，silent fail，导致 venv 不存在、cape 服务起不来。

**步骤**：
1. `chown -R cape:cape /home/cape/.cache /home/cape/.config`（cape2.sh 早期阶段以 root 写过）
2. `poetry config virtualenvs.in-project true` — venv 建在 `/opt/CAPEv2/.venv/`
3. `poetry lock --no-interaction`（pyproject 改过，lock 失效）
4. `poetry install --no-interaction --no-root`（~10min，从清华拉 ~150 个 Python 包）
5. sanity：`python -c 'import django, pymongo, ...'`

**手动等价**：
```bash
sudo chown -R cape:cape /home/cape/.cache /home/cape/.config
sudo -u cape /etc/poetry/bin/poetry config virtualenvs.in-project true
cd /opt/CAPEv2
sudo -u cape /etc/poetry/bin/poetry lock --no-interaction
sudo -u cape /etc/poetry/bin/poetry install --no-interaction --no-root
```

---

## Stage 31-cape-config

**做什么**：改 CAPE 配置文件 + mask 起不来的服务。

**改 4 处**：
1. `conf/cuckoo.conf [resultserver] ip` → `<SUBNET>.1`（默认 192.168.1.1 与 virbr0 不符 → cape 报 "Cannot assign requested address"）
2. `conf/cuckoo.conf [cuckoo] machinery` → `kvm`（已是 kvm，幂等确认）
3. `conf/kvm.conf [kvm] machines` → 空字符串（默认 `cuckoo1` 但 libvirt 里没这 domain → cape 报 "Domain not found"）
4. `systemctl mask cape cape-processor`（**没 guest 时它们必败**，restart loop 会刷死日志）

**等装完 Phase C 客户机时怎么 unmask**：
```bash
sudo systemctl unmask cape cape-processor
crudini --set /opt/CAPEv2/conf/kvm.conf kvm machines cuckoo1
# 然后写 [cuckoo1] 段
sudo systemctl start cape cape-processor
```

---

## Stage 40-kvm-libvirt

**做什么**：装 KVM + libvirt（apt 路线，**不是源码编译**），起 virbr0，装 libvirt-python 进 cape venv。

**为什么 apt 装 libvirt 而不是源码编**：上游 `kvm-qemu.sh all` 会编 libvirt 11.1 + 替换 apt 版，过程不稳，且 libvirt-python 11.9 与 apt 的 libvirt 10 已能正常工作。决策见 `docs/WHY.md` ADR-Q9 和 ADR 备注。

**步骤**：
1. `apt install qemu-kvm libvirt-daemon-system libvirt-dev bridge-utils virtinst dnsmasq`
2. `systemctl enable --now libvirtd`
3. `usermod -aG kvm,libvirt cape`
4. `virsh net-autostart default && virsh net-start default` — virbr0 = `<SUBNET>.1/24`
5. `bash /tmp/cape2.sh libvirt` — 上游 `install_libvirt` 函数会装 `libvirt-python==11.9.0` 到 cape venv
6. sanity：`python -c 'import libvirt; print(libvirt.getVersion())'`

**SUBNET ≠ 192.168.122 时的处理**：脚本会重定义 default 网络（destroy → undefine → define 新 XML）。

---

## Stage 50-anti-vm-qemu

**做什么**：源码编译 QEMU 9.2.2 with anti-VM clue patches；装为 dpkg 包 `qemu` (Custom antivm)。

**为什么不直接 wget**：上游 `download.qemu.org` 在中国直接 connection reset。改用 GitLab archive。

**关键步骤**：
1. `curl GitLab archive` → `qemu-9.2.2.tar.gz`（38 MB），sha256 验证
2. 解压 → top dir 是 `qemu-v9.2.2-<hash>/`，重命名为 `qemu-9.2.2/`
3. 重打包 `tar | xz -T0 -1 > qemu-9.2.2.tar.xz`（kvm-qemu.sh 期望此命名）
4. `bash /tmp/kvm-qemu.sh qemu`：
   - 上游 `install_qemu` 函数发现 .tar.xz 已存在 → 跳过 wget
   - `tar xf` 解压
   - `replace_qemu_clues_public` 打 anti-VM 补丁（去掉 KVM/QEMU 指纹字符串）
   - `configure --target-list=x86_64-softmmu`
   - `make -j N`
   - `checkinstall` 打成 .deb，`Description: Custom antivm qemu`
   - `dpkg -i` 装上

**编译预期**：~30 min（8 vCPU），CPU 满载。

---

## Stage 51-anti-vm-seabios

**做什么**：源码编 SeaBios 1.16.3 with anti-VM 补丁，替换 `/usr/share/qemu/bios.bin`。

**关键步骤**：
1. `curl GitHub archive` → `seabios_1.16.3.tar.gz`，sha256 验证
2. `bash /tmp/kvm-qemu.sh seabios`：
   - 解压
   - `replace_seabios_clues_public` 打 anti-VM 补丁
   - `make`（~3 min，Total size ≈ 188 KB）
   - `cp out/bios.bin /usr/share/qemu/bios.bin`
   - `cp out/bios.bin /usr/share/qemu/bios-256k.bin`
3. `touch state/51-seabios.done` — marker（用于幂等守卫）
4. `systemctl restart libvirtd` — 让新 bios 立即对新启动 VM 生效

---

## Stage 99-smoke-test

**做什么**：装完最终自检（决策 Q13=C）。**每次都跑**，无幂等守卫。

**检查项**（任一失败即 exit 1）：
1. systemd active：postgresql / mongodb / cape-rooter / cape-web / suricata / libvirtd
2. 端口监听：5432 / 27017 / 8000
3. virbr0 = `<SUBNET>.1/24`
4. `curl http://127.0.0.1:8000/` → HTTP 200
5. cape venv `import django, pymongo, libvirt, yara, capstone, pefile`
6. `virt-host-validate qemu` 前 7 项 PASS
7. `dpkg -s qemu` 描述含 `antivm`

---

## 装完之后

- 浏览器：**http://\<HOST\>:8000** 看 Web UI
- API：CAPE REST API 在同端口（路径见 `/opt/CAPEv2/web/`）
- 加 guest VM 走 Phase C，参考 [README.md](../README.md) 末尾"还差什么"

---

## 已知不会装的东西（决策有意跳过）

| 项 | 为什么 | 何时补 |
|---|---|---|
| community.py 社区签名 | GitHub raw 在中国不通 | 配 GFW 代理后手动 `cd /opt/CAPEv2 && poetry run python utils/community.py -waf -cr` |
| Volatility3 Windows 符号 | cape2.sh 路径检测 buggy | 手动 `wget` 到 `/opt/CAPEv2/.venv/lib/python3.12/site-packages/volatility3/symbols/windows/` |
| Tor jammy keyring | 上游 deb 仓库 keyring 不在 jammy | Tor 路由是可选的，不影响主流程 |
| lzip 包 | 这次踩到 502，可有可无 | `apt install lzip` |
| 客户机 Windows VM | Phase C 范围 | 见 README "还差什么" |

---

## Phase C：分析客户机接入

`make all` 跑完是 Phase B（host stack + KVM/libvirt + 反 VM）。要让 CAPE 真正分析样本，需要在 virbr0 上接入一台 Windows 客户机。两条路径：

1. **直接在服务器上 `virt-install` + VNC 装机**（默认路径，README §5 详解）
2. **Intel Mac (UTM) 构建 + `make import-guest` 自动注册**（headless 服务器推荐）—— 详见 [guest/win10-ltsc.md](guest/win10-ltsc.md)
