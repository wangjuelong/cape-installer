# UNINSTALL — 一键卸载手册

把 cape-installer 装下的所有东西从目标机彻底清掉，回到几乎纯净的 Ubuntu 24.04 状态。

---

## 一句话用法

```bash
cd /opt/cape-installer
sudo make uninstall-dry      # 先预演（强烈推荐第一次跑这个）
sudo make uninstall          # 实跑（会要求输入 yes 确认）
sudo make uninstall-yes      # 实跑且跳过确认（CI / 批量用）
```

---

## ⚠️ 不可逆动作清单

| # | 动作 | 数据风险 |
|---|---|---|
| 1 | 停 `cape*`、`mongodb`、`postgresql`、`suricata`、`libvirtd` | 无 |
| 2 | **`pg_dump cape` → `/var/backups/cape-uninstall-<TS>.sql`** | 自动备份 |
| 3 | **`mongodump` → `/var/backups/cape-uninstall-<TS>.mongo/`** | 自动备份 |
| 4 | `apt purge` mongodb-org / postgresql-18 / suricata / yara / qemu* / libvirt* / tor / mitmproxy / qemu (Custom antivm) / de4dot | apt 数据目录被 purge 带走 |
| 5 | `rm -rf` /opt/CAPEv2 /etc/poetry /data /opt/PolarProxy /opt/mitmproxy | 没备份的话**永久丢失**所有分析记录、conf 改动、自训练 yara 规则 |
| 6 | `rm -rf` /var/lib/{postgresql,mongodb,suricata} /var/log/{mongodb,postgresql,suricata} | 残留数据彻底清 |
| 7 | 删 systemd unit：cape*.service、mongodb.service、enable-transparent-huge-pages.service | 无 |
| 8 | 还原 /etc/sysctl.conf、/etc/security/limits.conf、/etc/sudoers.d/{cape,ip_netns,tcpdump,99-cape-mirror}、/etc/pip.conf、/etc/environment、apt sources & keyrings、git insteadOf | 恢复系统状态 |
| 9 | 删用户：`cape`（连同 `/home/cape`）、`mongodb` | `/home/cape` 下任何 ssh key / 自定义文件**永久丢失** |
| 10 | 清 root crontab 里 cape2.sh 加的条目 | 无 |

---

## 阶段细节

```
u00-preflight              ~5s    确认 + dry-run 设置
u10-stop-services          ~10s   停服务
u20-backup-data            ~30s   pg_dump + mongodump 到 /var/backups/
u30-purge-apt              ~2 min apt purge cape 装的所有包
u40-remove-files           ~5s    rm /opt/CAPEv2 等
u50-remove-systemd-units   ~2s    rm /lib/systemd/system/cape*.service
u60-revert-system-config   ~5s    sed /etc/sysctl.conf 等
u70-remove-users           ~3s    userdel -r cape, userdel -r mongodb
u80-clean-cron             ~2s    crontab 过滤
u99-verify                 ~5s    残留检查
─────────────────────────────────────────
合计                       ~3 min
```

---

## DRY_RUN 模式

`sudo make uninstall-dry` 会把每个会执行的命令打印为 `[DRY-RUN] <命令>` 行，**完全不动系统**。强烈推荐先 dry-run 一次确认要做的事。

```
[DRY-RUN] systemctl stop cape
[DRY-RUN] systemctl stop mongodb
[DRY-RUN] apt-get purge -y --auto-remove qemu de4dot mongodb-org* ...
[DRY-RUN] rm -rf /opt/CAPEv2
[DRY-RUN] rm -rf /etc/poetry
[DRY-RUN] sed -i '/fs.file-max/d' /etc/sysctl.conf
[DRY-RUN] userdel -r cape
...
```

---

## 单步卸载

每个 stage 都可独立运行：

```bash
sudo make u30-purge-apt          # 只跑 apt purge，不动其他
sudo make u20-backup-data        # 只跑备份
sudo make u99-verify             # 残留检查（任何时刻都可跑）
```

---

## 备份恢复

如果你后悔了（或装到一半想重来），用备份恢复：

```bash
# PostgreSQL
sudo apt install -y postgresql-18      # 先把 pg 装回来
sudo -u postgres createdb cape
sudo -u postgres psql cape < /var/backups/cape-uninstall-<TS>.sql

# MongoDB
sudo apt install -y mongodb-org        # 装回来
mongorestore /var/backups/cape-uninstall-<TS>.mongo/
```

---

## 关于 sysctl 的"软重启"

u60 用 `sed` 删了 `/etc/sysctl.conf` 里 cape2.sh 注入的几行，**但运行中的内核参数不会立刻还原**（如 `net.ipv4.ip_forward=1` 仍生效到下次重启）。

要彻底还原：

```bash
sudo reboot
```

或手动：

```bash
sudo sysctl -p /etc/sysctl.conf
```

但这只是把 `/etc/sysctl.conf` 里**剩下**的值应用一遍。已删除的 key 不会被自动设回 default。如果你介意，重启最干净。

---

## u99-verify 输出示例

```
==== 残留检查 ====
  [✓] 用户 cape 已删
  [✓] 用户 mongodb 已删
  [✓] /opt/CAPEv2 已删
  [✓] /etc/poetry 已删
  [✓] /data/db 已删
  ...
  [✓] apt 包 mongodb-org 已 purge
  [✓] apt 包 postgresql-18 已 purge
  ...

==== 备份文件位置 ====
-rw-r--r-- 1 root root  12K  Apr 28 16:34 /var/backups/cape-uninstall-20260428-163400.sql

[✓✓✓] 卸载完成，无残留

建议：sudo reboot   # 让 sysctl 改动彻底失效
```

---

## 故障排查

### `userdel: cape mail spool (...) not found`

**无害警告**：cape 没用过 mail，没有 spool 文件可删。继续。

### `userdel: user cape is currently used by process N`

某 cape 进程没杀干净，userdel 拒绝。手动 `sudo pkill -9 -u cape`，再跑 `sudo make u70-remove-users`。

### `apt-get purge` 报 "Package qemu is a virtual package"

**已处理**：apt 的 `qemu` 是虚拟包名，但 cape-installer 装的 `qemu` 是 dpkg/checkinstall 产物（有具体 binary），purge 时 apt 会找到正确目标。如果你看到 "is a virtual package" 然后跳过，验证一下：
```bash
dpkg -l | grep -E '^ii  qemu '
```
如果还在，手动：`sudo dpkg --purge qemu`。

### 卸载后 `make all` 不能直接重装

**正常**：环境干净了之后，`bootstrap.sh` + `make all` 应当像在新机器上一样从头跑。如果失败，先 `sudo make clean && sudo make 00-preflight`。
