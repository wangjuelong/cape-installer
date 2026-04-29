# TROUBLESHOOTING

收录在 192.168.2.234 实地部署时踩到的所有坑 + 对策。
按"症状"快速查找。

---

## 通用故障定位流程

```bash
# 1. 看哪个 stage 失败
ls -lt logs/*.log | head -5
# 2. 看那个 stage 的最后 50 行（脚本崩溃时也会自动 tail 给你）
tail -50 logs/<stage>.log
# 3. 重做该 stage（依赖会自动跳过已完成的）
sudo make <stage>
# 4. 不行就强制重做
sudo make force-<stage>
# 5. 真不行就 nuclear option（清干净重来）
make clean && sudo make all
```

---

## 网络类

### `Failed to fetch ... 502 Bad Gateway`

**原因**：cloud-init 给 Ubuntu 24.04 装了默认 apt 代理 `192.168.2.228:7890`（在 `/etc/apt/apt.conf.d/90curtin-aptproxy`），代理本身偶发 502。

**对策**：stage 10-mirrors 已自动把它重命名为 `.disabled`。如果发现没禁掉：
```bash
sudo mv /etc/apt/apt.conf.d/90curtin-aptproxy{,.disabled}
sudo apt-get update
```

---

### `mongodb.service: status=217/USER` / mongod 启不来 / 端口 27017 不监听

**原因 1**：cape2.sh 的 `curl https://pgp.mongodb.com/server-8.0.asc` 在网络抖动时**写空 keyring 文件而不报错**，apt 拒绝 mongo 仓库 → mongodb-org 没装 → 没 mongodb 用户。

**对策**：cape-installer vendor 了一份本地 GPG key（`vendor/mongodb-server-8.0.asc`），cape2.sh.patched 优先使用本地版本，避免下载失败。手动恢复：
```bash
sudo gpg --dearmor -o /etc/apt/keyrings/mongo.gpg --yes < /opt/cape-installer/vendor/mongodb-server-8.0.asc
sudo apt-get update
sudo apt-get install -y mongodb-org
```

**原因 2**：cape2.sh 把 `chown /data` 写进 `@reboot` crontab，从未重启 → /data/db 仍由 root 拥有 → mongodb 用户写不了 → mongod 启动失败 status=100。

**对策**：stage 20 已加补救逻辑。手动恢复：
```bash
sudo mkdir -p /data/db /data/configdb
sudo chown -R mongodb:mongodb /data
sudo systemctl reset-failed mongodb
sudo systemctl restart mongodb
```

---

### `python3 - 卡住几分钟，进度文件 0 byte`

**原因**：Poetry installer 内部用 pip 从 `files.pythonhosted.org` 下包，该域名在中国直连大概率超时。

**对策**：stage 10-mirrors 已写 `/etc/pip.conf` 指清华。如果还卡：
```bash
# 检查 pip 真的读到镜像了
pip3 config list
# 应看到：global.index-url='https://pypi.tuna.tsinghua.edu.cn/simple'
# 还要确认 sudo 子进程能读到（env_keep）
sudo -n bash -c 'echo $PIP_INDEX_URL'
```

如果 sudo 子进程没读到 → 检查 `/etc/sudoers.d/99-cape-mirror` 是否存在。

---

### `download.qemu.org: Connection reset by peer`

**原因**：QEMU 官网在中国被 reset。

**对策**：stage 50 已硬编码用 GitLab archive 替代。脚本里**绝不会**直接连 download.qemu.org。

---

### `community.py 卡 30 分钟没响应`

**原因**：`utils/community.py` 走 `raw.githubusercontent.com` 拉社区签名规则，该域名在中国完全不通。

**对策**：vendor/cape2.sh.patched 已加 `timeout 60 ... || true`。装完后想补，需配 GFW 代理：
```bash
# 假设你有 socks5 代理 127.0.0.1:1080
export ALL_PROXY=socks5://127.0.0.1:1080
cd /opt/CAPEv2
sudo -u cape -E poetry run python utils/community.py -waf -cr
```

---

### `MongoDB 下载 30 KB/s`

**原因**：`repo.mongodb.org` 走 CloudFront，国内速度极慢。

**对策**：vendor/cape2.sh.patched 第 938 行已把仓库换成 `mirrors.tuna.tsinghua.edu.cn/mongodb`。校验：
```bash
cat /etc/apt/sources.list.d/mongodb.list
# 应该是 https://mirrors.tuna.tsinghua.edu.cn/mongodb/apt/ubuntu noble/mongodb-org/8.0 multiverse
```

---

## CAPE 启动失败类

### `cape.service: virtualenv: error: argument dest: the destination . is not write-able at /home/cape/.cache/pypoetry`

**原因**：cape2.sh 早期阶段用 root 跑过 poetry，把 `/home/cape/.cache/pypoetry` 目录变成 root 所有；后续 cape 用户跑 poetry 没法写。

**对策**：stage 30 已自动 `chown -R cape:cape /home/cape/.cache /home/cape/.config`。手动：
```bash
sudo chown -R cape:cape /home/cape/.cache /home/cape/.config
sudo systemctl restart cape
```

---

### `lib.cuckoo.common.exceptions.CuckooStartupError: The 'libvirt-python' library is required`

**原因**：libvirt-python 没装进 cape venv（cape2.sh 在 libvirt apt 包没装时跑 install_libvirt → headers 找不到 → 跳过）。

**对策**：stage 40 在装完 libvirt-dev 后专门跑了一次 `cape2.sh libvirt`。手动：
```bash
sudo -E bash /opt/cape-installer/vendor/cape2.sh.patched libvirt 192.168.122.1
sudo -u cape /opt/CAPEv2/.venv/bin/python -c 'import libvirt; print(libvirt.getVersion())'
sudo systemctl restart cape
```

---

### `CuckooStartupError: Error checking snapshot state for VM 'cuckoo1'. Domain not found`

**原因**：`/opt/CAPEv2/conf/kvm.conf` 默认 `machines = cuckoo1`，但 libvirt 里没 cuckoo1 这个 domain（你还没建 guest）。

**对策**：stage 31 已经把 machines 设为空。要起 cape，先建 guest VM 再加回（Phase C）。

---

### `CuckooCriticalError: No machines available`

**原因**：machines 列表空但 cape 仍在跑。Phase B 范围内 cape 服务**应该是 mask 状态**。

**对策**：
```bash
sudo systemctl mask cape cape-processor
```

等装完 Phase C guest VM，把 cuckoo1 写进 `kvm.conf` 后再 unmask。

---

### `CuckooCriticalError: Unable to bind ResultServer on 192.168.1.1:2042`

**原因**：`conf/cuckoo.conf [resultserver] ip` 默认 `192.168.1.1`，与 virbr0 的 `192.168.122.1` 不符。

**对策**：stage 31 已自动改。手动：
```bash
sudo -u cape crudini --set /opt/CAPEv2/conf/cuckoo.conf resultserver ip 192.168.122.1
sudo systemctl restart cape
```

---

## PostgreSQL / 数据库类

### `psycopg2.errors.UniqueViolation: duplicate key ... pg_type_typname_nsp_index. Key (typname, typnamespace)=(status_type, 2200) already exists.`

**原因**：cape / cape-processor / cape-web 同时启动，并发执行 `CREATE TYPE status_type AS ENUM`，竞态。

**对策（核选项）**：drop + recreate 数据库：
```bash
sudo systemctl stop cape cape-processor cape-rooter cape-web
sudo -u postgres psql -c 'DROP DATABASE IF EXISTS cape;'
sudo -u postgres psql -c 'CREATE DATABASE cape OWNER cape;'
sudo systemctl start cape   # 等 cape 把 schema 建好
sleep 8
sudo systemctl start cape-processor cape-rooter cape-web
```

---

## QEMU / SeaBios 编译类

### `make: *** [build-seabios-config-seabios-128k] Error 2`

**原因**：QEMU 自带的 SeaBios 子构建（`roms/seabios/`）需要 git submodule，GitLab archive **没有** submodule 内容。

**对策**：**这个错误是无害的**——上游 QEMU 主体仍能编译成功，bios.bin 我们用 stage 51 单独编。日志后面应该有 `[+] Patched, compiled and installed`。如果没有，则真的失败了。

---

### `gpg: can't hash datafile: No data` / `[-] Download qemu-9.2.2 failed`

**原因**：`download.qemu.org` reset，QEMU 源码 wget 失败。

**对策**：stage 50 已经预先把 GitLab archive 重打包放到 /tmp/qemu-9.2.2.tar.xz。如果你手动跑 `kvm-qemu.sh qemu` 不经过 cape-installer：
```bash
# 自己拉 GitLab + 重打包
curl -fL -o /tmp/qemu.tgz 'https://gitlab.com/qemu-project/qemu/-/archive/v9.2.2/qemu-9.2.2.tar.gz'
cd /tmp && tar xzf qemu.tgz && mv qemu-v9.2.2-* qemu-9.2.2
tar c qemu-9.2.2 | xz -T0 -1 > qemu-9.2.2.tar.xz
rm -rf qemu-9.2.2 qemu.tgz
sudo bash kvm-qemu.sh qemu
```

---

### Web UI 8000 无响应

**原因**：cape-web 没起 / Werkzeug 起得慢 / 端口冲突。

**诊断**：
```bash
sudo systemctl status cape-web
sudo journalctl -u cape-web -n 30
sudo ss -tlnp | grep 8000
```

**常见对策**：`sudo systemctl restart cape-web`，等 ~10 秒。

---

## libvirt 类

### `error: Failed to start network default: network is already active`

**无害警告**：脚本 `virsh net-start default` 在网络已 active 时报这条。脚本继续。

---

### `virbr0` 没有 IP

**原因**：default 网络没启动 / `dnsmasq` 起不来。

**对策**：
```bash
sudo virsh net-info default
sudo virsh net-start default
sudo systemctl restart libvirtd
ip a show virbr0
```

---

### libvirtd `inactive (dead)`

**正常情况**：libvirtd 是 socket-activated。第一次访问 libvirt API（如 `virsh list`）会自动起。

**强制起**：
```bash
sudo systemctl start libvirtd
```

---

## 完全重装

如果一切都乱了，想从头来：

```bash
# 1. 停所有服务
sudo systemctl stop cape cape-processor cape-rooter cape-web suricata libvirtd mongod postgresql

# 2. 卸载 apt 包
sudo apt-get purge -y mongodb-org\* postgresql-18 suricata libvirt-daemon-system qemu

# 3. 删数据
sudo rm -rf /opt/CAPEv2 /var/lib/mongodb /var/lib/postgresql /etc/poetry /home/cape

# 4. 删用户
sudo userdel -r cape 2>/dev/null

# 5. 删 apt 仓库
sudo rm -f /etc/apt/sources.list.d/{mongodb,pgdg,tor,suricata}.list

# 6. 清 cape-installer state
cd /opt/cape-installer && make clean

# 7. 重跑
sudo make all
```

---

## 怎么读 stage 日志

每个 stage 的日志在 `logs/<stage>.log`。结构：

```
===== 2026-04-28T18:30:00+0000 start =====
[stdout/stderr 业务输出]
===== 2026-04-28T19:05:23+0000 done =====
```

失败时脚本会自动 `tail -n 50 logs/<stage>.log` 给你看。日志会**保留**（不会被 stage_done 清掉），方便事后查。
