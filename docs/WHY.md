# WHY — 设计决策日志

cape-installer 的设计是 2026-04-28 brainstorming 13 个 Q&A 的产物。
本文档把每个决策展开 ADR（Architectural Decision Record）格式，便于新成员理解"为什么这么写"。

格式：每条决策 = `上下文 / 选择 / 备选 / 理由 / 影响`。

---

## ADR-Q1：受众范围 = 私有团队 + 多机批量

**上下文**：刚在 192.168.2.234 实地部署完，要写文档/脚本沉淀。
受众可能是：(a) 自用复盘 (b) 团队内部多人多机 (c) 公开开源 (d) 自用 + 多机批量。

**选择**：(d) 自用 + 多机批量。

**备选**：公开开源——但需要兼容海外网络模式，README/文档要双倍工作量。

**理由**：
- 中国网络优化可硬编码（清华源、跳过 GitHub raw 等），简化巨多
- 多机批量 → 需要 SUBNET / DB_PASSWORD 参数化
- 不需要兼容海外网络

**影响**：
- 清华镜像写死，不做 fallback
- `config.env` 仅暴露两个参数

---

## ADR-Q2：覆盖范围 = Phase B（host + KVM + 反 VM），不含 Windows guest

**上下文**：完整 CAPE 链 = host 服务 + hypervisor + Windows 客户机 + 配置串联。
脚本要装到哪一层。

**选择**：Phase B（host stack + libvirt + virbr0 + 反 VM QEMU/SeaBios）。

**备选**：
- 仅 host（不装反 VM）
- 含 Windows guest（自动起 ISO + agent.py + 快照）
- 仅文档

**理由**：
- 与本次 192.168.2.234 实地部署一致，可验证
- Windows guest 自动化需要 unattended.xml + Windows ISO + 复杂 PowerShell，工作量翻几倍
- 反 VM QEMU/SeaBios 是 CAPE 的核心价值（防样本检测沙箱），值得自动化
- guest 阶段 (Phase C) 可后续追加，不阻塞当前

**影响**：
- cape & cape-processor service 在 stage 31 被 mask（没 guest 时启动会失败）
- README "Phase C" 段落给出手动建 guest 的步骤

---

## ADR-Q3：组织形式 = 分阶段多脚本 + Makefile

**上下文**：脚本可以单文件、模块化、Ansible playbook 或文档+脚本镜像。

**选择**：B 模块化（9 个 stage 脚本 + Makefile 编排）。

**备选**：
- 单文件 install.sh（最简单）
- Ansible playbook（声明式）
- 单脚本+独立 Markdown 文档

**理由**：
- 实地部署踩了 5 类网络问题，单文件挂了从头跑代价巨大
- Make `.PHONY` 目标天然支持单步重跑（`make 40-kvm-libvirt`）
- 依赖关系在 Makefile 一眼看清（链式 `00 → 10 → 20 → ...`）
- 不依赖 Ansible / Python（目标机干净 Ubuntu 即可）

**影响**：
- 9 个独立脚本 ≈ 700 LoC
- 必须保证 stage 之间幂等性（不能假设上一步已经"刚刚"做完）
- `lib/common.sh` 复用 stage 通用逻辑（日志、retry、守卫 helper）

---

## ADR-Q4：参数化范围 = 最小（SUBNET + DB_PASSWORD）

**上下文**：批量部署需要换什么？

**选择**：A 最小化（仅 SUBNET 和 DB_PASSWORD）。

**备选**：B 中等（+ CAPE 用户名 + 安装路径 + 反 VM 开关）；C 重度（+ 镜像可选 + 代理 + conf 模板）。

**理由**：
- 多机部署主要变化是网段和密码
- 用户名/路径换了几乎没意义（CAPE 默认就是 cape + /opt/CAPEv2）
- 镜像 fallback 是炫技——清华是稳定的，没必要写 USTC fallback
- 反 VM 是 Phase B 必装，不该开关

**影响**：
- `config.env` 只有两行
- 不支持环境变量覆盖（`SUBNET=10.0.0 ./run` 不工作）— OQ2 决定

---

## ADR-Q5：幂等性 = 完全幂等（系统状态探测）

**上下文**：脚本可能因网络瞬断/手工修改/系统升级被多次跑。

**选择**：A 完全幂等（每步前用 `dpkg -s`、`id`、`systemctl is-active` 等探测系统真相）。

**备选**：
- B `.done` marker（信任脚本自己的笔记）
- C 全新安装（检测到旧状态就 wipe）
- D `set -e` 直接挂

**理由**：
- 用户偏好 Ansible 风格（不信脚本自己的记忆）
- 假阳性（手工卸包后 marker 还在）会导致诡异错误
- 写守卫的额外 LoC 可接受（每步 ~5 行 `if done_or_force ... ; then return; fi`）

**影响**：
- `lib/common.sh` 提供大量 helper：`pkg_installed`、`venv_ready`、`net_active`、`file_sha_ok`、`user_in_group` 等
- `FORCE=1` 环境变量用 `done_or_force` helper 绕过守卫
- Makefile 提供 `force-<stage>` 目标

---

## ADR-Q6：错误处理 = set -e + 网络/apt 自动重试

**上下文**：实地部署踩了 5+ 类瞬断（502、conn reset、超时）。

**选择**：B `set -e` + 所有 curl/wget/apt-get 包 retry-with-exponential-backoff。

**备选**：
- A 直接挂（依赖 Q5 幂等兜底）
- C + 镜像 fallback（清华 → USTC → 官方）
- D best-effort（非关键失败不挂）

**理由**：
- 重试 3 次 + 5/15/30s backoff 能挡住 95% 的瞬断
- 镜像 fallback 太复杂，本次 deploy 没出现需要 fallback 的场景
- best-effort 分类容易出错，目前仅 community.py 一个非关键操作（在 vendor patch 里单独处理）

**影响**：
- `lib/common.sh` 有 `retry()` 函数
- 所有 curl/wget/apt-get 都用 `retry 3 5 cmd`

---

## ADR-Q7：交付方式 = 本地 git + scp 推送

**上下文**：脚本 + 文档怎么到目标机。

**选择**：A 本地 Git repo + scp 推 `/opt/cape-installer/`。

**备选**：
- B 私有 Git server
- C 内部 HTTP 镜像 + tar.gz
- D 远程编排（在 Mac 一条命令搞定）

**理由**：
- 私有团队 ≠ 公司级，没必要搭 Git server
- 远程编排（D）需要写 deploy.sh，复杂度增加
- scp + ssh 在 → 任何人电脑上都直接能用

**影响**：
- 不写 `make push HOST=...` helper（OQ4 决定）
- README 给出 scp 命令样例

---

## ADR-Q8：运行身份 = root（sudo make all）

**上下文**：脚本要不要自己处理 sudo。

**选择**：A 必须 `sudo make all`，Makefile 顶部检测 EUID。

**备选**：
- B cape 用户身份 + 临时 NOPASSWD sudoers（这次手动做的）
- C cape + sudo timestamp 续期
- D 两阶段（bootstrap → cape 用户跑主安装）

**理由**：
- 多机部署时操作员通常已经 root（直接登 root 或带 sudo 别名）
- B/C/D 都需要假设 cape 用户已存在 → 反过来需要先创建 cape，回到鸡生蛋问题
- 简单粗暴最实用

**影响**：
- Makefile 第一行 `ifneq ($(shell id -u),0)` 强制
- 脚本内部需要做 cape 用户的事时用 `sudo -u cape ...`

---

## ADR-Q9：上游脚本处理 = Vendor 打补丁的快照

**上下文**：上游 `cape2.sh` / `kvm-qemu.sh` 有 bug 且会随时变。

**选择**：B Vendor 一份打过补丁的快照在 `vendor/` 目录。

**备选**：
- A 完全跳过 cape2.sh，自己 bash 写
- C 运行时 `wget upstream + sed`
- D 混合（自己写一部分，调用一部分）

**理由**：
- 自己写 = 重复 cape2.sh 1900 行的工作（postgres conf、systemd unit、yara 编译…），收益不值
- 运行时 sed 太脆弱（上游随时改，sed pattern 会 miss）
- Vendor 锁版本 = 可审计、可读、改一次定死

**影响**：
- `vendor/cape2.sh.patched` 有 3 处 hunk：mongo URL → 清华、注释 buggy poetry pip 行、community.py 加 timeout
- `vendor/kvm-qemu.sh.patched` 当前**无 patch**（原样 vendor 作为版本快照）
- 上游升级时手动三向合并

---

## ADR-Q10：源码 tar 球 = 运行时拉 GitLab/GitHub + sha256

**上下文**：QEMU 38 MB / SeaBios <1 MB 源码怎么交付。

**选择**：B 运行时拉 + sha256 校验。

**备选**：
- A vendor 进 repo（Git LFS）
- C B + 内部 HTTP 镜像 fallback
- D 混合（assets/ 优先，否则拉）

**理由**：
- 拉一次 ~17 秒（GitLab 中国带宽 1-3 MB/s），不算慢
- repo 干净，不用 LFS
- sha256 可保证版本一致性（GitLab archive 是确定性的）
- 内部 HTTP 镜像 fallback 实际很少需要

**影响**：
- `vendor/checksums.sh` 钉死 URL + sha256
- 升级版本时：换版本号 + 重跑一次 `sha256sum` 更新 hash

---

## ADR-Q11：日志 = 每步独立日志 + 失败自动 tail

**上下文**：实地部署日志 600 KB+ 找关键事件难。

**选择**：D 每 stage 一个 `logs/<stage>.log` + 失败时自动 `tail -50` 到终端。

**备选**：
- A stdout 全输出
- B per-step 文件 + 终端只打摘要
- C B + 彩色进度条

**理由**：
- 平时干净（终端只打 `[+] start / [✓] done / [!] warn`）
- 挂了立刻有上下文（不用手动 `cat logs/...`）
- 完整日志保留，事后可深挖
- 不用花精力做彩色进度条 / TUI

**影响**：
- `lib/common.sh` 的 `stage_init` 把 stdout/stderr 重定向到 stage 日志
- ERR trap 调 `stage_fail` 打 last 50 lines 到原 stderr

---

## ADR-Q12：文档 = 4 文件结构 (README + INSTALL + TROUBLESHOOTING + WHY)

**上下文**：要"配套部署文档"，怎么组织。

**选择**：D（4 个独立 MD）。

**备选**：A 单 README、B 三文件、C per-stage MD。

**理由**：
- README 是首屏（30 秒上手）
- INSTALL 是手册（不跑脚本也能照着装）
- TROUBLESHOOTING 是查错（按症状索引）
- WHY 是 ADR（决策追溯）— 新成员看一遍就懂整套设计
- per-stage MD 与脚本镜像，维护两份内容容易飘逸

**影响**：
- 4 份文档共 ~1100 行 MD
- WHY.md 就是本文件（ADR 总集）

---

## ADR-Q13：smoke test = service + 网络 + import + virt-host-validate

**上下文**：装完最后要验证什么。

**选择**：C application-level（systemd + 端口 + virbr0 + curl Web UI + venv import + virt-host-validate）。

**备选**：A 仅 service / B + 网络 / D + DB 实操读写。

**理由**：
- A/B 挡不住"装包了但 venv 损坏"或"libvirt 没启用 KVM"这类坑
- D 写 SQL/JS 性价比不高（DB 起来了就基本能用）
- C 是踩过的坑的最小集合（这次 import libvirt 失败 / virbr0 IP 不符 / Web UI 不响应都被覆盖）

**影响**：
- `scripts/install/99-smoke-test.sh` 有 7 个检查项
- 任一失败 → exit 1，整个 `make all` 失败

---

## OQ-1 ~ OQ-4：Open Questions 决议

| 项 | 决定 |
|---|---|
| OQ1 仓库名 | `cape-installer` |
| OQ2 环境变量覆盖 config.env？ | 否，仅读 config.env |
| OQ3 失败保留中间状态？ | 是（不清 logs/ 不清 state/） |
| OQ4 `make push` helper？ | 否，让用户自己 scp |

---

## 验证发现（2026-04-28，在 192.168.2.240 上）

实地在新机器跑 `make all` 暴露了 4 个真实 bug，前 2 个原版就有：

| # | 问题 | 修复 |
|---|---|---|
| 1 | 全新机器没装 `make` | `bootstrap.sh` 自动装 make 后调 make |
| 2 | 240 GFW 抖动期 github.com HTTPS 完全不通 | 00-preflight 自动探测 + `git config --system url.gh-proxy.com.insteadOf` 透明重写 |
| 3 | cape2.sh 的 `curl pgp.mongodb.com` 失败时**写 0 字节空 keyring 不报错** → apt 拒绝仓库 → mongodb-org 没装 → 没 mongodb 用户 → systemd 217/USER | vendor 本地 mongo key 优先 + 失败检测 + retry |
| 4 | cape2.sh 把 `chown /data` 写进 `@reboot` cron，从未重启 → mongodb 写不了 /data/db | stage 20 末尾补 chown + restart |

community.py 60s 超时跳过的 patch（写脚本时凭 234 经验加的）在 240 上验证有效——避免了 21 分钟卡死。

## ADR-Uninstall：一键卸载（2026-04-29 追加）

**上下文**：cape-installer 改动了主机大量系统状态（apt 包、systemd unit、sysctl、limits、sudoers、pip 镜像、git insteadOf、3 个用户、cron、/data 数据目录）。手动卸载难以保证清干净，会留下半残状态。

**选择**：**Scope C 全清** + 默认行为（自动 pg_dump/mongodump、`--yes` 跳确认、`--dry-run` 预演）+ 镜像安装风格的 10 个 `u00`-`u99` stage 脚本。

**备选**：
- A 轻量（只删 /opt/CAPEv2，保留 apt 包） — 用例窄
- B 常规（A + apt purge，但保留 sysctl/limits 注入） — 半干净状态难维护
- D 核弹（C + 自动重启） — 用户不一定接受

**理由**：
- C 是"回到几乎纯净 Ubuntu"的最干净状态，给批量部署后清场最省心
- 自动备份兜底（`/var/backups/cape-uninstall-<TS>.{sql,mongo}`）让"误删"代价降到可恢复
- DRY_RUN 解决"我怕跑错"的心理障碍
- 镜像安装风格让 "u30 失败可单独重跑" 等运维操作直觉化
- 镜像 `Makefile` 模式：`force-<stage>` 不需要（卸载默认就是幂等的，重跑只是空操作）

**影响**：
- 新增 10 个 stage 脚本（`u00`-`u99`）
- `Makefile` 增加 `uninstall` / `uninstall-dry` / `uninstall-yes` target
- `lib/common.sh` 加 `run` 和 `run_or_warn`（DRY_RUN 包装）
- 新增 `docs/UNINSTALL.md`
- `Makefile` root 检查改成对 `help`/`clean`/`uninstall-dry` 豁免

**已知边界**：
- sysctl 改动 sed 删了 `/etc/sysctl.conf` 里的行，但**当前内核运行时**值不会回滚 → u99 提示用户 reboot
- `apparmor` 对 tcpdump 用 `aa-disable` 改过，u60 不强行 enforce 回去（怕影响别的进程）
- 部分 `/etc/needrestart/needrestart.conf` 改动 best-effort 回退
- /tmp 残留按知名命名清，没列全的会被系统 tmpfs 清空兜底

**240 上的卸载验证发现（2026-04-29）**：
1. **u70 自删登录用户**（**严重**）：旧版 u70 无差别 `userdel -r cape`。但 240 的 cape 是 UID 1000 的 OS 登录用户（不是 cape2.sh 系统用户），删了 `/home/cape` 里的 SSH key → 锁死 240 SSH。修复：u70 加 `UID < 1000` 守卫，OS 登录用户跳过；u00 在 `SUDO_USER` 是即将被删的用户时打警告。
2. **u30 dpkg-query 在 set -E 下因未匹配 pattern 触发 ERR trap**（中等）：`set +e` 不抑制 ERR trap，得显式 `|| true`。修复：`list_installed()` 包装函数显式 `|| true`。
3. **240 在 uninstall 中重启**（待复盘）：完整跑 uninstall-yes 后 ping 不通，疑似 apt autoremove 顺手 purge 了某 init 关键包，或 systemd 被改坏导致 reboot。等机器回来再现场看。

---

## 后续可考虑的演进（非本次范围）

- **Phase C**：Windows guest VM 自动化（unattended.xml + agent.py 自动注入 + 快照）
- **Phase D**：高可用（distributed CAPE，多 worker）
- **海外网络兼容模式**：`config.env` 加 `MIRROR_REGION=cn|intl`，区分镜像选择
- **Ansible 化**：把 stage 脚本改成 Ansible role（如团队规模继续扩大）
