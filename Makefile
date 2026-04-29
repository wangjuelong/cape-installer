# cape-installer — 在干净 Ubuntu 24.04 noble 上一键复刻 CAPEv2 host + KVM + 反 VM 栈
# 入口：sudo make all
# 单步：sudo make 40-kvm-libvirt
# 强制：sudo make force-50-anti-vm-qemu （绕过幂等守卫）

SHELL := /bin/bash
.SHELLFLAGS := -eEuo pipefail -c

# 必须 root
ifneq ($(shell id -u),0)
$(error 必须 sudo 运行：sudo make $(MAKECMDGOALS))
endif

# 加载用户参数（SUBNET / DB_PASSWORD），不存在就用 sample 默认
ifneq ($(wildcard config.env),)
include config.env
else
include config.env.sample
endif
export

REPO_ROOT := $(shell pwd)
export REPO_ROOT

STAGES := \
  00-preflight \
  10-mirrors \
  20-host-stack \
  30-poetry-fix \
  31-cape-config \
  40-kvm-libvirt \
  50-anti-vm-qemu \
  51-anti-vm-seabios \
  99-smoke-test

.PHONY: all clean help force-% $(STAGES)

all: $(STAGES)

# ----- 各 stage 串行依赖 -----
00-preflight:        ; bash scripts/00-preflight.sh
10-mirrors:          00-preflight       ; bash scripts/10-mirrors.sh
20-host-stack:       10-mirrors         ; bash scripts/20-host-stack.sh
30-poetry-fix:       20-host-stack      ; bash scripts/30-poetry-fix.sh
31-cape-config:      30-poetry-fix      ; bash scripts/31-cape-config.sh
40-kvm-libvirt:      31-cape-config     ; bash scripts/40-kvm-libvirt.sh
50-anti-vm-qemu:     40-kvm-libvirt     ; bash scripts/50-anti-vm-qemu.sh
51-anti-vm-seabios:  50-anti-vm-qemu    ; bash scripts/51-anti-vm-seabios.sh
99-smoke-test:       51-anti-vm-seabios ; bash scripts/99-smoke-test.sh

# 强制重做某 stage（绕过幂等守卫）
force-%:
	FORCE=1 bash scripts/$*.sh

clean:
	rm -rf logs/ state/

help:
	@echo "目标："
	@echo "  sudo make all                 # 完整安装（~60-90 min）"
	@echo "  sudo make <stage>             # 单步：00-preflight / 10-mirrors / ..."
	@echo "  sudo make force-<stage>       # 强制重做（忽略幂等守卫）"
	@echo "  make clean                    # 清空 logs/ state/"
	@echo ""
	@echo "Stage 列表："
	@$(foreach s,$(STAGES),echo "  $(s)";)
