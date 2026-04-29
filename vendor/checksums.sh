#!/usr/bin/env bash
# vendor/checksums.sh — 钉死所有运行时下载的源码 tar 球
# 由 scripts/50-anti-vm-qemu.sh 和 51-anti-vm-seabios.sh source。
# 升级版本时：换 URL + 重跑一次 sha256sum 更新此处。

# ===== QEMU 9.2.2 (GitLab archive) =====
# 决策：上游 download.qemu.org 在中国被 reset，改用 GitLab archive（决策 Q10）。
# 注意：gitlab archive 解出来的 top-level 目录是 qemu-v9.2.2-<sha>/，stage 50 会重命名。
QEMU_VERSION="9.2.2"
QEMU_TARBALL_URL="https://gitlab.com/qemu-project/qemu/-/archive/v${QEMU_VERSION}/qemu-${QEMU_VERSION}.tar.gz"
QEMU_TARBALL_SHA256="e7599083cd032a0561ad8fcba5ad182fbd97c05132abb4ca19f1b9d832eff5a2"

# ===== SeaBios 1.16.3 (GitHub archive) =====
# GitHub archive 在中国可达。
SEABIOS_VERSION="1.16.3"
SEABIOS_TARBALL_URL="https://github.com/coreboot/seabios/archive/refs/tags/rel-${SEABIOS_VERSION}.tar.gz"
SEABIOS_TARBALL_SHA256="1c1742a315b0c2fefa9390c8a50e2ac1a6f4806e0715aece6595eaf4477fcd8a"
