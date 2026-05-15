# 安装过程实录 — upstream CAPEv2 on openKylin 2.0 SP2

> **目标机**：192.168.1.6 / rtshield / OpenKylin 2.0 SP2 (codename: nile, kernel 6.6.0-19-generic, jammy base)
> **日期**：2026-05-15
> **结果**：Phase B host 服务栈全部 active；浏览器可访问 `http://192.168.1.6:8090/`

这份文档记录**实地踩到的每一个问题 + 怎么修的**，未来再装时按这条路径走最稳。

---

## 0. 侦察：目标机基线

第一步 SSH 进去看 7 项：

```bash
sshpass -p '12345678' ssh rtshield@192.168.1.6 '
  cat /etc/os-release
  uname -a
  id; df -h /opt /home /var
  echo password | sudo -S -k whoami
  curl -m 5 -sI https://github.com/ ;
  curl -m 5 -sI https://gh-proxy.com/
  curl -m 5 -sI https://mirrors.tuna.tsinghua.edu.cn/
  ls /dev/kvm; grep -E "vmx|svm" /proc/cpuinfo | head -1
  free -h; nproc
'
```

发现：

| 项 | 值 | 影响 |
|---|---|---|
| OS | openKylin 2.0 SP2 (nile) | **不在 cape2.sh 支持列表**（只识别 Ubuntu 18/20/22/24 codename） |
| kernel | 6.6.0-19-generic | OK |
| jammy base | 确认（`bedrock.list` 指向 jammy 上游） | 可把 nile 当 jammy 对待 |
| rtshield | uid=1000, 在 sudo / kvm 组 | 可 sudo（密码方式 `echo pw \| sudo -S`） |
| /var | 98G / 73G free | CAPE 装 ~5G，足够 |
| /home | 721G / 683G free | 备用 |
| GitHub 直连 | **TIMEOUT** | CN GFW，必须走 gh-proxy |
| gh-proxy.com | 200 OK 0.8s | 可用 |
| TUNA mirror | 200 OK 0.13s | 可用 |
| /dev/kvm | 存在，crw-rw---- root:kvm | KVM 可用 |
| VMX/SVM flag | 在 | 硬件虚拟化 OK |
| RAM/CPU | 15G / 8 cores | 够 |

**结论**：可装，但需要 (a) 让 cape2.sh 把 openKylin 认成 jammy，(b) CN 镜像替换，(c) gh-proxy 包装 GitHub URL。

---

## 1. /opt/cape-deploy 单目录布局

按用户要求"单独目录"：

```
/opt/cape-deploy/                  # 整个部署只用这一个目录
├── CAPEv2/                        # clone 自上游，也是 CAPE_ROOT
├── patches/apply-patches.py       # 我们的 patcher
├── scripts/{run-cape2-base, build-venv, post-install-fix, smoke-test}.sh
├── vendor/mongodb-server-8.0.asc  # 本地 GPG key
└── logs/install-base.log
```

**关键**：通过 `CAPE_ROOT=/opt/cape-deploy/CAPEv2` 环境变量让 cape2.sh 把 CAPE 装到这里，而不是默认的 `/opt/CAPEv2`。

---

## 2. cape2.sh 的 8 个补丁（patches/apply-patches.py）

clone upstream CAPEv2 via `gh-proxy.com`：

```bash
git clone --depth 50 https://gh-proxy.com/https://github.com/kevoreilly/CAPEv2.git
```

HEAD 当时是 `dd36c30`。然后 Python patcher 改 8 处：

### P1 codename `nile` → `jammy`

```python
text = text.replace('"$(lsb_release -cs)"', '"jammy"')
text = text.replace('$(lsb_release -cs)', 'jammy')
text = text.replace('$(lsb_release -sc)', 'jammy')
text = text.replace('$(lsb_release -sr)', '22.04')
```

为什么：openKylin 的 `lsb_release -cs` 返回 `nile`，cape2.sh 把这字符串往 `https://repo.mongodb.org/apt/ubuntu/dists/nile/...` 拼，404。

### P2 Tor 块 wrap `if false; then ... fi`

```python
tor_start = text.find("    # https://www.torproject.org/docs/debian.html.en")
tor_end_marker = "    sudo systemctl start tor\n"
# 找到块边界，包裹整段
```

为什么：`wget https://deb.torproject.org/...` 在 CN 永挂（不仅慢，TCP 连不上）。Tor 功能 sandbox 也用不上（malware 出网走 Tor 是高级 use case，不阻塞 Phase B）。

### P3 MongoDB GPG 用本地副本

```python
text = text.replace(
    'sudo curl -fsSL "https://pgp.mongodb.com/server-${MONGO_VERSION}.asc" | sudo gpg --dearmor -o /etc/apt/keyrings/mongo.gpg --yes',
    f'sudo install -d -m 0755 /etc/apt/keyrings && sudo cat {MONGO_KEY} | sudo gpg --dearmor -o /etc/apt/keyrings/mongo.gpg --yes'
)
```

为什么：`pgp.mongodb.com` 从 CN 慢，且 cape2.sh 没 retry。预先下载到 `vendor/mongodb-server-8.0.asc` 本地读。

### P4 MongoDB repo → TUNA

```python
text = text.replace(
    'https://repo.mongodb.org/apt/ubuntu',
    'https://mirrors.tuna.tsinghua.edu.cn/mongodb/apt/ubuntu'
)
```

### P5 Postgres repo → TUNA

```python
text = text.replace(
    'http://apt.postgresql.org/pub/repos/apt/',
    'https://mirrors.tuna.tsinghua.edu.cn/postgresql/repos/apt/'
)
```

**实地发现**：P5 后 TUNA 这个路径 **404**（没有 `jammy-pgdg` 套件）。但 apt-get 反而走了 openKylin 自带的 PG-16（`16+257-ok1`），效果一样。所以 P5 实际是"无用但无害"。

### P6 raw.githubusercontent → gh-proxy

```python
text = re.sub(
    r'(?<!gh-proxy\.com/)https://raw\.githubusercontent\.com/',
    'https://gh-proxy.com/https://raw.githubusercontent.com/',
    text
)
```

Lookbehind `(?<!gh-proxy\.com/)` 防止已经 prefix 过的 URL 被双重替换。

### P7 install_CAPE 内 git clone → gh-proxy

```python
text = text.replace(
    'git clone https://github.com/kevoreilly/CAPEv2/ "$CAPE_ROOT"',
    'git clone https://gh-proxy.com/https://github.com/kevoreilly/CAPEv2/ "$CAPE_ROOT"  # CN PATCH'
)
```

实际上 `CAPE_ROOT=/opt/cape-deploy/CAPEv2` 已经预 clone 过，cape2.sh 会跳过这条。但 idempotent。

### P8 注释掉 buggy `pip install -r pyproject.toml`

```python
text = text.replace(
    'sudo -u ${USER} bash -c "export PYTHON_KEYRING_BACKEND=keyring.backends.null.Keyring; CRYPTOGRAPHY_DONT_BUILD_RUST=1 $PYTHON_MGR pip install -r pyproject.toml"',
    '# CN PATCH: disabled — pip cannot read pyproject.toml as requirements; venv built separately after install\n    # sudo ...'
)
```

为什么：`pip install -r pyproject.toml` 是上游的 bug —— pip 把 pyproject.toml 当 requirements.txt 来读，会失败（pyproject 是 TOML 不是 requirements 格式）。改用 `scripts/build-venv.sh` 跑 `poetry install`。

---

## 3. 跑 cape2.sh.patched base（实际 30-50 min）

```bash
setsid env CAPE_ROOT=/opt/cape-deploy/CAPEv2 \
  nohup bash cape2.sh.patched base >> /opt/cape-deploy/logs/install-base.log 2>&1 < /dev/null &
```

`setsid` 把进程脱离 controlling tty，`nohup` 忽略 SIGHUP，`< /dev/null` 关 stdin。这样 SSH 断了进程继续跑。

期间日志里出现的几类警告（**可忽略**）：

- `Error: GDBus.Error:org.freedesktop.DBus.Error.TimedOut: Failed to activate service 'org.freedesktop.PackageKit'` — apt-get 试图通过 PackageKit 装包，PackageKit 不响应。apt-get 自己继续装包成功。
- `Error: Timeout was reached` — 跟上面一组，10+ 次但不影响安装结果。
- `dpkg: libssl3t64 ...` — openKylin 用了 t64 后缀（time_t 64-bit transition 来自 Ubuntu noble 反向移植），跟 jammy 的 `libssl3` 名字不一样但功能一致。

期间日志里出现的关键日志：

```
[+] Installing dependencies
[+] Installing PostgreSQL
[+] Installing MongoDB
[+] Installing CAPEv2
[+] Installing libvirt-python      ← 这里会 fail（见 F2/F6）
[-] libvirt headers not found, skipping libvirt-python installation.
[+] Installing yara-python
[+] Installing Yara
[+] Installing systemd configuration
[+] Installing Suricata
[+] cape2.sh - Done
```

`[-] libvirt headers not found` 是预期的 —— cape2.sh 的 `install_libvirt` 函数只 `locate libvirt.pc`，不 apt-install libvirt 包。这是 F2 要补的。

---

## 4. cape2.sh.patched 跑完后的 8 个 post-install 修复

每个 fix 都是真实踩出来的。`scripts/post-install-fix.sh` 把这 8 步打包成幂等脚本。

### F1 — `/home/cape` 误属 mongodb:mongodb

```bash
$ ls -ld /home/cape
drwxr-x--- 3 mongodb mongodb 4096 May 15 02:34 /home/cape
```

**症状**：cape services 启动后卡在 `activating` 状态。

**原因**：cape2.sh 创建 cape 用户、又装了 mongodb，某个步骤 chown 错。可能是 mongodb 包 postinst 抢了 /home/cape（mongodb 的 datadir 默认在 /var/lib 但 postinst 可能 chown 了不该 chown 的）。

**修法**：`chown -R cape:cape /home/cape`。生效后 cape 进程能正常写 home 下的 poetry 缓存。

### F2 — install_libvirt 只 locate 不 apt-install

cape2.sh 的 `install_libvirt`：

```bash
function install_libvirt() {
    echo '[+] Installing libvirt-python'
    sudo apt-get install -y locate && sudo updatedb
    temp_libvirt_so_path=$(locate libvirt-qemu.so | head -n1 | awk '{print $1;}')
    temp_export_path=$(locate libvirt.pc | head -n1 | awk '{print $1;}')

    if [ -z "$temp_libvirt_so_path" ] || [ -z "$temp_export_path" ]; then
        echo "[-] libvirt headers not found, skipping libvirt-python installation."
        return
    fi
    # ... pip install libvirt-python ...
}
```

**这函数假设 libvirt-dev 已经装了**。但 dependencies() 里没装。所以 locate 找不到 `libvirt.pc`，函数 return，连 `usermod -aG libvirt cape` 都没跑。

**修法**：

```bash
apt install -y --no-install-recommends \
  libvirt-dev libvirt-daemon-system libvirt-clients \
  qemu-kvm qemu-utils bridge-utils virtinst libxml2-utils
systemctl enable --now libvirtd
```

### F3 — cape 没加 libvirt 组

F2 的连锁：install_libvirt 在 locate 失败时提前 return，`usermod -aG libvirt cape` 没跑。

**修法**：`usermod -aG libvirt cape`。

### F4 — cape user 通 libvirt polkit 报 "Action ... is not registered"

```
error: failed to connect to the hypervisor
error: error from service: GDBus.Error:org.freedesktop.PolicyKit1.Error.Failed:
       Action org.libvirt.unix.manage is not registered
```

polkit action 文件实际存在（`/usr/share/polkit-1/actions/org.libvirt.unix.policy`），但 cape user 通过 sudo 之后不是 polkit 认可的 session，polkit 拒绝。

**修法**：直接绕过 polkit，用 libvirt group 通过 unix socket 授权：

```bash
# /etc/libvirt/libvirtd.conf
unix_sock_group = "libvirt"
unix_sock_rw_perms = "0770"
auth_unix_rw = "none"        # 不再走 polkit
```

`systemctl restart libvirtd` 后 cape user `virsh -c qemu:///system list` 通。

### F5 — `.venv` 没建

P8 注释了 cape2.sh 里那条 buggy 的 `pip install -r pyproject.toml`，所以 cape 仓库下没有 .venv，systemd 服务起不来。

**修法**：用 poetry 建（`scripts/build-venv.sh`）：

```bash
sudo -u cape -H bash -c "
  cd /opt/cape-deploy/CAPEv2
  /etc/poetry/bin/poetry config virtualenvs.in-project true --local
  /etc/poetry/bin/poetry install --no-interaction --no-root --no-ansi
"
```

实际跑了 215 个 packages，~10 min（poetry.lock 给好了，TUNA pip 源走 https://pypi.tuna.tsinghua.edu.cn/simple 在 cape2.sh dependencies 阶段已经写进 pip.conf）。

### F6 — libvirt-python 还得单装

cape2.sh 的 install_libvirt 失败导致 libvirt-python 没装进 venv。CAPE 启动会 `import libvirt`。

**修法**：

```bash
sudo -u cape -H bash -c "
  cd /opt/cape-deploy/CAPEv2
  /etc/poetry/bin/poetry run pip install libvirt-python==11.9.0
"
```

11.9.0 是 cape2.sh 的 `LIB_VERSION` 变量值。这版与 openKylin 2.0 的 libvirt 9.10.0 ABI 兼容。

### F7 — cape DB `status_type` enum 残留

第一次启 cape 报：

```
CuckooDatabaseError: Unable to create or connect to database:
duplicate key value violates unique constraint "pg_type_typname_nsp_index"
DETAIL:  Key (typname, typnamespace)=(status_type, 2200) already exists.
[SQL: CREATE TYPE status_type AS ENUM (...)]
```

原因：cape2.sh 的 install_CAPE 跑过 init 但没建完 tables（只 enum 建了），第二次 cape 启动想再 CREATE TYPE 就崩。

**修法**：

```bash
sudo -u postgres psql -c "DROP DATABASE IF EXISTS cape;"
sudo -u postgres psql -c "CREATE DATABASE cape OWNER cape;"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE cape TO cape;"
```

之后启 cape 让它 SQLAlchemy 自己 init schema。

### F8 — 启动错误链：5 个连续问题

**F8.1 No machines available**

```
CuckooCriticalError: No machines available
```

cape2.sh 默认 kvm.conf 列了 `cuckoo1` 但 libvirt 里没这 domain。

修法：清空 machines list：

```bash
sed -i "s|^machines.*=.*|machines =|" /opt/cape-deploy/CAPEv2/conf/kvm.conf
```

**F8.2 Domain not found: cuckoo1**（同根因）

清空 machines 后还是报，因为有 `[cuckoo1]` section 残留。最干净的做法：mask cape + cape-processor 直到 Phase C 导入真实 guest。**Phase C 之后**（跑过 [`scripts/import-guest.sh`](../scripts/import-guest.sh) 或 Mac 端 [`deploy-guest.sh`](../deploy-guest.sh)）这两个服务会被 unmask + 重启，进入正常工作状态。

**F8.3 ResultServer bind 192.168.1.1:2042 失败**

cape2.sh 默认 IFACE_IP=192.168.1.1，cuckoo.conf [resultserver] ip 也被写成这个。但 host 没这地址。

修法：起 libvirt default network（virbr0 = 192.168.122.1/24）+ cuckoo.conf [resultserver] ip 改成 192.168.122.1。

**F8.4 Duplicate `ip` key**

第一次 sed 注入的时候用了 awk 错误 block 匹配，把 4 个 key 重复加在 [resultserver] section 顶部，但原本就有。configparser 严格模式拒绝 duplicate。

修法（在 post-install-fix.sh 用 Python）：去重 + 强制 `ip = 192.168.122.1`：

```python
out, in_rs, seen = [], False, set()
for ln in lines:
    if ln.startswith('['):
        in_rs = ln.strip() == '[resultserver]'
        seen = set()
    if in_rs:
        m = re.match(r'^(ip|port|force_port|pool_size)\s*=', ln)
        if m and m.group(1) in seen: continue
        if m: seen.add(m.group(1))
    out.append(ln)
```

**F8.5 cape-web 端口 8000 被 kytensor 占**

```
Address already in use
Port 8000 is in use by another program.
```

`kytensor` 是 openKylin 的 LLM 推理服务（看 dpkg: kytensor-server, kytensor-llm, ...），自动启动绑 127.0.0.1:8000。

修法：cape-web 改 :8090：

```bash
sed -i "s|0.0.0.0:8000|0.0.0.0:8090|" /lib/systemd/system/cape-web.service
systemctl daemon-reload
```

也可以反过来禁 kytensor，但 8090 改一行更稳。

**F8 番外：Django 42 unapplied migrations**

cape-web 抱怨：

```
You have 42 unapplied migration(s) ... admin, auth, authtoken, contenttypes, sessions, sites, socialaccount, users
Run 'python manage.py migrate' to apply them.
```

修法（在 post-install-fix.sh）：

```bash
sudo -u cape -H bash -c "
  cd /opt/cape-deploy/CAPEv2/web
  /etc/poetry/bin/poetry run python manage.py migrate --noinput
"
```

---

## 5. 最终 smoke test 结果

```
=== A. systemd services ===
[✓] cape-rooter active
[✓] cape-web active
[✓] mongodb active
[✓] postgresql active
[✓] libvirtd active
[✓] cape masked (Phase B 惯例)
[✓] cape-processor masked (Phase B 惯例)

=== B. listening ports ===
[✓] :8090 (cape-web)
[✓] :27017 (mongo)
[✓] :5432 (pg)

=== C. HTTP self-test ===
[✓] GET / → 200
[✓] GET /accounts/login/ → 200

=== D. libvirt usable as cape ===
[✓] cape → virsh list OK

=== E. virt-host-validate ===
[✓] virt-host-validate qemu — no FAIL

=== F. venv imports ===
py    : 3.12.2
yara  : 4.5.1
django: 5.1.14
sql   : 2.0.41
mongo : 4.11
pg    : 2.9.10
[✓] all .venv imports OK

PASS: 12    FAIL: 0
```

`/opt/cape-deploy/` 占盘 **947 MB**（不含 PG/Mongo datadir，那些在 `/var/lib/`）。

---

## 6. 总耗时分布（实测）

| 阶段 | 耗时 |
|---|---|
| SSH 侦察 | 1 min |
| /opt/cape-deploy 创建 + clone CAPEv2 via gh-proxy | 30 sec |
| 写 apply-patches.py + 验证 8 patch 落盘 | 1 min |
| 准备 vendor/mongodb GPG key（从我自己 cape-installer repo 拉） | 5 sec |
| 写 run-cape2-base.sh + build-venv.sh + scp 到 target | 30 sec |
| **cape2.sh.patched base 跑（detached）** | **~22 min** |
| audit 发现 8 个 post-install 问题 | 10 min |
| 应用 F1-F8 修复 | 10 min |
| 跑 build-venv.sh (poetry install 215 deps) | ~8 min |
| 装 libvirt-python | 30 sec |
| smoke test PASS | 1 min |

总计 **~55 min**。post-install fix 的 10 min audit 是因为是首次踩，有了 `post-install-fix.sh` 之后下次 30 sec 跑完。

---

## 7. 如果再装一次（理论时间 ~35 min）

```bash
# Mac 上
brew install sshpass
git clone <cape-installer repo>
cd cape-installer/openkylin
bash deploy.sh rtshield@<host>          # ~3 min（scp + patch + clone + 启动 cape2.sh detached）

# 等 cape2.sh 跑（~22 min）
sshpass -p '<pw>' ssh <user>@<host> 'tail -f /opt/cape-deploy/logs/install-base.log'

# 然后一行收尾
bash deploy.sh rtshield@<host> --wait-and-finalize   # post-fix + smoke
```

或省事直接 `bash deploy.sh ... --wait-and-finalize` 一条命令把所有 6 步串完（阻塞）。

---

## 7.5 Phase C 设计要点（`scripts/import-guest.sh`）

Phase C 不属于"踩坑实录"——脚本是基于 cape-installer 已有的 c10-c50 stage 经验直接写的，没在实地踩出新坑。但有几个**与 Phase B 衔接相关的关键决策**值得记下：

### 与父目录（noble 路径）的差异

| 维度 | 父目录 cape-installer（noble） | 本目录 openkylin |
|---|---|---|
| CAPE_ROOT | `/opt/CAPEv2` | `/opt/cape-deploy/CAPEv2` |
| stage 框架 | `lib/common.sh` + Makefile + 单独 .sh per stage | 单脚本 5 段（c10-c50） + 函数化 step/ok/warn/die |
| 反 VM QEMU | 自编 9.2.2 + SeaBIOS 1.16.3 补丁 | openKylin 自带 qemu 9.0.x（**不反 VM**——样本能看出是 QEMU） |
| domain XML 模板 | `domain-cuckoo1.xml.tmpl` | `domain.xml.tmpl`（结构等价） |
| systemd cape 服务 unmask 时机 | c50 阶段 | c50 阶段（一致） |

### 与 Phase B 衔接的依赖

import-guest.sh 假设 Phase B 已完成：
- `/etc/poetry/bin/poetry` 存在
- `/opt/cape-deploy/CAPEv2/.venv` 存在
- `/opt/cape-deploy/CAPEv2/conf/kvm.conf` 存在（cape2.sh 装好后生成）
- `libvirtd` active 且 `virsh net-info default` 显示 active（post-install-fix F2/F4/F8a 已配好）
- `cape` / `cape-processor` 当前 masked（post-install-fix F8e）—— c50 反向解除

如果跑 `import-guest.sh` 前 Phase B 没完成，会在 c30 的 `kvm.conf 不存在` 处 die。

### 默认参数推导规则

- `--name` 缺省：从 qcow2 文件名 basename（仅当形如 `cuckoo<N>.qcow2`）
- `--ip` 缺省：`192.168.122.{104 + N}`（cuckoo1→.105 / cuckoo2→.106 / ...）
- `--mac` 缺省：`52:54:00:CA:FE:{N:02d}`
- 这个映射跟父目录 [docs/guest/](../../docs/guest/) 下 Win10/Win7/Win11/Ubuntu22 walkthrough 顶部"总览"段的 cuckoo→IP→MAC 表完全对齐，方便交叉使用

### 幂等性边界

- c10 同样大小的 qcow2 不重拷（`--force` 覆盖）
- c20 domain 已定义不重 define（`--force` undefine+define）
- c30 machines list 已含 name 不重复加；section 用 `crudini --set`（覆盖单字段，多次跑收敛到相同结果）
- c40 已 running 跳过 start；轮询 :8000 直到 200 或 timeout
- c50 snapshot `clean` 已存在不重拍；服务 unmask 已 unmask 不重做

可以反复跑同一条命令而不破坏状态——典型场景：c40 timeout（agent.py 起不来），修 guest 内 cape-agent.service 后重跑，从 c10 开始全过，但前 3 个 stage 都跳过，只重跑 c40+c50。

---

## 8. 不在 Phase B 范围的事

- **Phase C 客户机导入**：现已在本目录实现，入口脚本 [`scripts/import-guest.sh`](../scripts/import-guest.sh)（target 上跑）+ [`deploy-guest.sh`](../deploy-guest.sh)（Mac 上一键）。用法见 [../README.md](../README.md) "Phase C：导入 guest" 段。
- Phase C 客户机的 qcow2 装机流程（UTM-on-Mac 装 Windows/Linux guest 的步骤），见父目录 [docs/guest/](../../docs/guest/)（win10-ltsc / win7-sp1 / win11-ltsc / ubuntu22-server 四份 walkthrough）。
- 反 VM QEMU + SeaBIOS：本仓库**未**自编（用 openKylin 自带 qemu 9.0.x）。要反 VM 抗检测请用 cape-installer 的 stage 50/51。
- Suricata 配置：cape2.sh 装了 suricata 但没配 rules；要用 IDS 看 cape-installer 或上游 cape2.sh 的 install_suricata
- Tor 出网：P2 跳过了 Tor，cape 不能 Tor route。要这功能需要走 obfs4bridge 或 V2Ray 这类绕墙路。
