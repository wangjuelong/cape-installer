# openKylin 部署路径

一键把 **upstream CAPEv2**（host 服务栈：cape\*/mongo/postgres/libvirt）+ guest 自动 import
部署到 **openKylin 2.0 SP2**（jammy 基线 + kernel 6.6）目标机的 Mac-side 工具集。

实地用 192.168.1.6 / rtshield 跑通过；踩坑+修复全部记录在
[docs/INSTALL-NARRATIVE.md](docs/INSTALL-NARRATIVE.md)。

> **与父目录 cape-installer 的区别**：父目录是 Ubuntu 24.04 noble 专用、自编 KVM/SeaBIOS 反 VM、完整 Phase B+C 链；本目录是上游 cape2.sh + openKylin 适配补丁，host 用 openKylin 自带 qemu 9.0.x（不反 VM）。
> **何时用哪条**：host 是 Ubuntu 24.04 → 用父目录的 `Makefile` + `sudo make all`；host 是 openKylin / 类 jammy 国产化系统 → 用本目录的 `deploy.sh`。

---

## 0. 一句话用法

```bash
bash deploy.sh rtshield@192.168.1.6
# 30-60 min 后：
bash deploy.sh rtshield@192.168.1.6 --wait-and-finalize
# 完成后浏览器开：http://192.168.1.6:8090/
```

---

## 1. 目录结构

```
openkylin/                       # cape-installer 仓库下的 openKylin 部署子目录
├── deploy.sh                    # Phase B 入口：装 CAPEv2 host stack（一键）
├── deploy-guest.sh              # Phase C 入口：scp qcow2 + ssh-run import-guest.sh（一键 import guest）
├── README.md                    # 本文件
├── patches/
│   └── apply-patches.py         # 8 个 cape2.sh 补丁的 idempotent Python 应用器
├── scripts/
│   ├── run-cape2-base.sh        # Phase B: nohup 包装跑 cape2.sh.patched base + tee 日志
│   ├── build-venv.sh            # Phase B: cape2.sh 之后 poetry 建 .venv（P8 注释了原 buggy 行）
│   ├── post-install-fix.sh      # Phase B: 8 个 post-install 修复（详见 docs/INSTALL-NARRATIVE.md）
│   ├── smoke-test.sh            # Phase B: 6 类 PASS/FAIL 健康检查
│   ├── import-guest.sh          # Phase C: target 上跑的 5-stage 工作流（c10-c50）
│   └── domain.xml.tmpl          # Phase C: libvirt domain XML 模板（envsubst）
├── vendor/
│   └── mongodb-server-8.0.asc   # MongoDB 8.0 GPG 公钥（避开 pgp.mongodb.com 慢/被墙）
└── docs/
    ├── INSTALL-NARRATIVE.md     # 全量安装记录：环境/8 个 patch/8 个 post-fix/最终 state
    └── API-SPEC.md              # /apiv2/ 接口规范 — 82 路由 / 启用矩阵 / curl 示例
```

---

## 2. 前置要求

### Mac 上

```bash
brew install sshpass  # 密码方式 SSH（若有 SSH key 可不装）
```

### Target (openKylin 2.0)

- root 可达的 sudoer 账号（实测 rtshield）
- `/dev/kvm` 存在 + VMX/SVM flag
- `/var` 有 ≥ 30 GB free（CAPE 装出来 ~5 GB，加 mongo/postgres 数据增长用）
- 出口能到 **gh-proxy.com** 和 **mirrors.tuna.tsinghua.edu.cn**（GitHub 直连可超时）

---

## 3. 8 个 cape2.sh 补丁（patches/apply-patches.py）

| # | 修什么 | 原因 |
|---|---|---|
| P1 | `lsb_release -cs/sc/sr/rs` → 硬编码 `jammy` / `22.04` | openKylin codename = `nile`，上游 apt repo 没这个 |
| P2 | Tor 块整段 wrap `if false; then ... fi` | `deb.torproject.org` CN GFW 不可达 |
| P3 | MongoDB GPG `curl pgp.mongodb.com` → `cat vendor/mongodb-server-8.0.asc` | pgp.mongodb.com 从 CN 慢/不稳 |
| P4 | `repo.mongodb.org/apt/ubuntu` → `mirrors.tuna.tsinghua.edu.cn/mongodb/apt/ubuntu` | 加速 + 稳定性 |
| P5 | `apt.postgresql.org/pub/repos/apt/` → `mirrors.tuna.tsinghua.edu.cn/postgresql/repos/apt/` | 同上（实际 fallback 用了 openKylin 默认 PG-16） |
| P6 | `raw.githubusercontent.com/...` → `gh-proxy.com/https://raw.githubusercontent.com/...` | GitHub 直连超时 |
| P7 | install_CAPE 里 `git clone github.com/kevoreilly/CAPEv2/` → `gh-proxy.com/https://github.com/...` | 同上 |
| P8 | 注释掉 `pip install -r pyproject.toml`（这条本身就是 buggy，pip 不能读 pyproject 当 requirements 用） | 改用 poetry 单建 .venv（scripts/build-venv.sh） |

---

## 4. 8 个 post-install 修复（scripts/post-install-fix.sh）

cape2.sh.patched 跑完后还差 8 步，全部幂等：

| # | 问题 | 修法 |
|---|---|---|
| F1 | `/home/cape` 误属其他用户（实测 mongodb:mongodb） | `chown -R cape:cape /home/cape` |
| F2 | cape2.sh 的 `install_libvirt` 只 locate 不 apt-install | `apt install libvirt-dev libvirt-daemon-system libvirt-clients qemu-kvm ...` |
| F3 | cape 没加 libvirt 组（usermod 在 install_libvirt 失败后不会跑） | `usermod -aG libvirt cape` |
| F4 | cape user polkit 拿不到 libvirt（"Action ... is not registered"） | `/etc/libvirt/libvirtd.conf`：`unix_sock_group="libvirt"` + `auth_unix_rw="none"` |
| F5 | `.venv` 没建（P8 注释了原 buggy pip） | poetry config `virtualenvs.in-project=true` + `poetry install` |
| F6 | libvirt-python 未装到 .venv（cape2.sh 早于 apt install libvirt-dev） | `poetry run pip install libvirt-python==11.9.0` |
| F7 | cape DB `status_type` enum 残留（cape2.sh 跑两次时） | `DROP DATABASE cape; CREATE DATABASE cape OWNER cape;` |
| F8a-e | 启动错误链：no machines → cuckoo1 not found → resultserver bind fail → Django migrations → :8000 被 kytensor 占 → mask cape/cape-processor | virbr0 起 + 清空 kvm.conf machines + 重写 [resultserver] ip=192.168.122.1 去重 + `manage.py migrate` + cape-web 改 :8090 + mask cape/cape-processor（Phase B 惯例） |

---

## 5. Phase B 完成后的状态

```
/opt/cape-deploy/
├── CAPEv2/                          # 上游 + .venv + conf 全在此
│   ├── installer/cape2.sh.patched   # 8 patch 后的 cape2.sh
│   ├── .venv/                       # 215 Python deps（poetry 管）
│   └── conf/                        # cuckoo.conf / kvm.conf 等已调
├── patches/apply-patches.py
├── scripts/{run-cape2-base, build-venv, post-install-fix, smoke-test}.sh
├── vendor/mongodb-server-8.0.asc
└── logs/install-base.log            # cape2.sh 完整输出
```

`systemctl status`：

| 组件 | 期望 |
|---|---|
| `cape-rooter` | active |
| `cape-web` | active, 0.0.0.0:**8090** |
| `mongodb` | active, :27017 |
| `postgresql` | active, :5432 (openKylin 自带 PG-16) |
| `libvirtd` | socket-activated（按需起） |
| `cape` | **masked**（Phase B 惯例：等 Phase C 导入 guest 再 unmask） |
| `cape-processor` | **masked**（同） |

访问：**`http://<host>:8090/`**（`/accounts/login/` 应返回 HTTP 200）

---

## 6. Phase C：导入 guest（一键 import）

Phase C 自动化了 cape-installer `make import-guest` 的等价工作流，适配 `/opt/cape-deploy/` 布局：

### 6.1 涉及的 5 个内部 stage（`scripts/import-guest.sh`）

| stage | 做什么 |
|---|---|
| **c10** | qcow2 sha256 校验 + qemu-img 探测 + 拷到 `/var/lib/libvirt/images/<name>.qcow2` |
| **c20** | 渲染 libvirt domain XML（IDE 总线 + e1000 NIC + i440FX + Legacy BIOS）+ `virsh define` + DHCP reservation |
| **c30** | `crudini --set /opt/cape-deploy/CAPEv2/conf/kvm.conf` 追加 machines list + 写 `[<name>]` section（label/platform/arch/ip/tags/snapshot/resultserver_ip） |
| **c40** | `virsh start` + 轮询 `http://<ip>:8000/status` 上线（默认 120s timeout） |
| **c50** | `virsh snapshot-create-as <name> clean` + `systemctl unmask cape cape-processor` + 重启 cape* 服务 |

全幂等：可重复跑。`--force` 重渲染 domain XML。

### 6.2 一键用法（Mac 端）

```bash
# 先在 Mac UTM 装一台 guest（装机步骤参考父目录 docs/guest/*.md），导出 qcow2
# 然后:
bash deploy-guest.sh rtshield@192.168.1.6 \
  --qcow2 ~/Downloads/cuckoo2.qcow2 \
  --name cuckoo2 \
  --platform linux \
  --arch x64 \
  --tags ubuntu22,linux,x64 \
  --ram-mb 2048 \
  --vcpus 2
```

参数中 `--ip` / `--mac` 缺省按 cuckoo<N> 末尾数字自动算（`cuckoo2 → 192.168.122.106 + 52:54:00:CA:FE:02`，`cuckoo3 → .107 + ...:03`，...）。

### 6.3 仅在 target 上跑（qcow2 已推上去）

```bash
ssh rtshield@192.168.1.6
sudo bash /opt/cape-deploy/import-guest.sh \
  --qcow2 /tmp/cuckoo2.qcow2 \
  --name cuckoo2 \
  --platform linux --arch x64 \
  --tags ubuntu22,linux,x64
```

### 6.4 验证

```bash
sudo virsh list --all                                    # 应有 <name> running
curl -m 3 -s http://<guest-ip>:8000/status               # 应 200 + JSON
sudo grep '^machines' /opt/cape-deploy/CAPEv2/conf/kvm.conf  # 应含 <name>
```

浏览器 `:8090/submit/` 提交样本，Options 填 `tags=<your-tag>`。

### 6.5 装 Windows guest？

UTM 装机步骤可参考 cape-installer 仓库的 guest walkthrough（与本仓库 import-guest 流程兼容，只是 qcow2 的产出方式不同）：
- [Win10 LTSC](../docs/guest/win10-ltsc.md) / [Win7 SP1](../docs/guest/win7-sp1.md) / [Win11 LTSC](../docs/guest/win11-ltsc.md) / [Ubuntu 22.04 Server](../docs/guest/ubuntu22-server.md)

qcow2 出来后用本仓库的 `deploy-guest.sh` 导入即可。

---

## 7. 故障排查

| 症状 | 看 |
|---|---|
| `deploy.sh` 退在 Step 5 | 跑 `sshpass ... tail -n 100 /opt/cape-deploy/logs/install-base.log` 看 cape2.sh 失败原因 |
| `smoke-test.sh` 报 `:8090 NOT LISTENING` | `journalctl -u cape-web -n 30` 找异常 |
| cape user 无法 virsh | 重跑 `post-install-fix.sh`（F4 idempotent） |
| `.venv` 损坏 | `rm -rf /opt/cape-deploy/CAPEv2/.venv` + 重跑 `post-install-fix.sh`（F5 重建） |
| postgres connection refused | `systemctl status postgresql` + `sudo -u postgres psql -d cape -c '\dt'` |

完整真实踩坑记录 → [docs/INSTALL-NARRATIVE.md](docs/INSTALL-NARRATIVE.md)

`/apiv2/` 接口规范（认证模型 / 启用矩阵 / curl 例） → [docs/API-SPEC.md](docs/API-SPEC.md)
