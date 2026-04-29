# cape-installer

在干净的 **Ubuntu 24.04 noble** 上一键复刻 CAPEv2 host + KVM/libvirt + 反 VM QEMU/SeaBios 栈。
专为中国网络环境优化（清华镜像硬编码，绕开 GFW 不可达的 `download.qemu.org` / `files.pythonhosted.org` / `repo.mongodb.org` / `raw.githubusercontent.com`）。

---

## 适用范围

| 维度 | 要求 |
|---|---|
| OS | Ubuntu 24.04 noble x86_64 |
| CPU | 8+ vCPU + VT-x（嵌套虚拟化） |
| 内存 | ≥ 16 GB |
| 磁盘 | / ≥ 50 GB 可用 |
| 网络 | 能访问 GitHub / GitLab / `mirrors.tuna.tsinghua.edu.cn` |

不支持：其他发行版、其他架构、无嵌套虚拟化的环境。

---

## 30 秒上手

```bash
# 1. 把 cape-installer 推到目标机
scp -r /path/to/cape-installer cape@<TARGET>:/opt/cape-installer
ssh cape@<TARGET>

# 2. 配置参数
cd /opt/cape-installer
cp config.env.sample config.env
vi config.env       # 改 SUBNET（可选） / DB_PASSWORD（建议改）

# 3. 一键（推荐：bootstrap.sh 会自动装 make 后调 make）
sudo bash bootstrap.sh all      # 全套 ~60-90 min

# 或手动两步：
sudo apt-get install -y make
sudo make all

# 4. 装完
firefox http://<TARGET>:8000
```

**自动处理 GitHub 不可达**：00-preflight 会探测 `github.com` 是否可访问；不通则自动配 `git config --system url.gh-proxy.insteadOf` 走镜像（如 240 这种环境）。无需用户操心。

---

## 已固定的软件版本（决策见 docs/WHY.md）

| 软件 | 版本 | 来源 |
|---|---|---|
| Python | 3.12 (apt) | Ubuntu 24.04 系统 |
| Poetry | 2.3.4 | `install.python-poetry.org` |
| PostgreSQL | 18 | `apt.postgresql.org` |
| MongoDB | 8.0 | 清华镜像 |
| libvirt-daemon | 10.0 (apt) | Ubuntu 24.04 |
| libvirt-python | 11.9.0 (PyPI) | 清华 PyPI |
| QEMU | 9.2.2 (源码编译，反 VM) | GitLab archive |
| SeaBios | 1.16.3 (源码编译，反 VM) | GitHub archive |
| Suricata | 7.0 | OISF PPA |
| Yara | 上游 latest（源码编译） | GitHub via cape2.sh |
| CAPEv2 | latest master | GitHub via cape2.sh |

---

## 单步 / 强制重跑

```bash
# 看可用 stage
make help

# 只重做某一步（依赖会自动跳过已完成的）
sudo make 40-kvm-libvirt

# 强制重做（绕过幂等守卫）
sudo make force-50-anti-vm-qemu

# 清空日志和 state
make clean
```

## 卸载

详见 [docs/UNINSTALL.md](docs/UNINSTALL.md)。

```bash
sudo make uninstall-dry      # 先预演（推荐）
sudo make uninstall          # 实跑（要求输入 yes 确认）
sudo make uninstall-yes      # 实跑跳过确认
```

卸载会**自动 pg_dump + mongodump** 到 `/var/backups/cape-uninstall-<TS>.{sql,mongo}`，不丢数据。完整范围：停服务 → apt purge 所有相关包 → rm 数据目录 → 还原 sysctl/sudoers/pip 镜像/git insteadOf 等系统改动 → 删 cape/mongodb 用户 → 清 cron。

---

## 装完 host 栈之后还差什么（Phase C）

`cape-installer` 仅做 **Phase B**：host + KVM + 反 VM。**不含** Windows 客户机。
完整跑 CAPE 分析样本还需：

1. 在 virbr0 上起一台 Windows VM
2. 客户机内装 [CAPE agent.py](https://github.com/kevoreilly/CAPEv2/blob/master/agent/agent.py) 并设为开机自启
3. 关 Defender / UAC / 防火墙
4. `virsh snapshot-create-as cuckoo1 --name clean`
5. 在 `/opt/CAPEv2/conf/kvm.conf` 配 `[cuckoo1]` 段
6. `sudo systemctl unmask cape cape-processor && sudo systemctl start cape cape-processor`

---

## 文档导航

| 文件 | 内容 |
|---|---|
| `README.md` | 本文，起步指南 |
| `docs/INSTALL.md` | 详细步骤手册（每个 stage 做了什么、怎么手动验证） |
| `docs/UNINSTALL.md` | 卸载手册（10 个 u-stage 详解 + 备份恢复） |
| `docs/TROUBLESHOOTING.md` | 已知问题 + 故障排查指引 |
| `docs/WHY.md` | 13 个关键设计决策（ADR）+ 实地验证发现 |

---

## 仓库结构

```
cape-installer/
├── Makefile               # 编排（依赖图）
├── config.env.sample      # 参数模板
├── lib/common.sh          # 日志、retry、stage 包装、幂等 helper
├── scripts/               # 9 个 stage 脚本
│   ├── 00-preflight.sh
│   ├── 10-mirrors.sh
│   ├── 20-host-stack.sh
│   ├── 30-poetry-fix.sh
│   ├── 31-cape-config.sh
│   ├── 40-kvm-libvirt.sh
│   ├── 50-anti-vm-qemu.sh
│   ├── 51-anti-vm-seabios.sh
│   └── 99-smoke-test.sh
├── vendor/                # 上游脚本快照 + 补丁
│   ├── cape2.sh.patched
│   ├── kvm-qemu.sh.patched
│   ├── pyproject-tuna-source.toml
│   └── checksums.sh       # QEMU/SeaBios sha256
├── docs/
│   ├── INSTALL.md
│   ├── TROUBLESHOOTING.md
│   └── WHY.md
├── logs/                  # 每 stage 一个 .log（自动生成）
└── state/                 # marker 文件（自动生成）
```
