#!/usr/bin/env bash
# bootstrap.sh — 在没装 make 的纯净 Ubuntu 24.04 上引导 cape-installer
# 用法：sudo bash bootstrap.sh all
#       sudo bash bootstrap.sh 40-kvm-libvirt
# 等价于 `sudo make $@`，差别只是会先 ensure 装好 make。

set -e

if [ "$(id -u)" != "0" ]; then
  echo "需要 root：sudo bash bootstrap.sh $*"
  exit 1
fi

if ! command -v make >/dev/null 2>&1; then
  echo "[+] 装 make..."
  apt-get update -qq
  apt-get install -y -qq make
fi

cd "$(dirname "$0")"
exec make "$@"
