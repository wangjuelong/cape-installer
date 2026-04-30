# cape-installer — 在干净 Ubuntu 24.04 noble 上一键复刻 CAPEv2 host + KVM + 反 VM 栈
# 入口：sudo make all
# 单步：sudo make 40-kvm-libvirt
# 强制：sudo make force-50-anti-vm-qemu （绕过幂等守卫）

SHELL := /bin/bash
.SHELLFLAGS := -eEuo pipefail -c

# 这些 target 不需要 root（看帮助 / 清日志 / 预演）
NONROOT_TARGETS := help clean uninstall-dry

# 仅当 MAKECMDGOALS 全部都不在豁免列表里时才强制 root
ifneq ($(filter-out $(NONROOT_TARGETS),$(MAKECMDGOALS)),)
ifneq ($(shell id -u),0)
$(error 必须 sudo 运行：sudo make $(MAKECMDGOALS))
endif
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

UNINSTALL_STAGES := \
  u00-preflight \
  u10-stop-services \
  u20-backup-data \
  u30-purge-apt \
  u40-remove-files \
  u50-remove-systemd-units \
  u60-revert-system-config \
  u70-remove-users \
  u80-clean-cron \
  u99-verify

C_STAGES := \
  c10-import-guest \
  c20-define-domain \
  c30-register-kvm-conf \
  c40-smoke-guest \
  c50-snapshot-and-cape

.PHONY: all clean help force-% uninstall uninstall-dry uninstall-yes import-guest $(STAGES) $(UNINSTALL_STAGES) $(C_STAGES)

all: $(STAGES)

# ----- 各 stage 串行依赖 -----
00-preflight:        ; bash scripts/install/00-preflight.sh
10-mirrors:          00-preflight       ; bash scripts/install/10-mirrors.sh
20-host-stack:       10-mirrors         ; bash scripts/install/20-host-stack.sh
30-poetry-fix:       20-host-stack      ; bash scripts/install/30-poetry-fix.sh
31-cape-config:      30-poetry-fix      ; bash scripts/install/31-cape-config.sh
40-kvm-libvirt:      31-cape-config     ; bash scripts/install/40-kvm-libvirt.sh
50-anti-vm-qemu:     40-kvm-libvirt     ; bash scripts/install/50-anti-vm-qemu.sh
51-anti-vm-seabios:  50-anti-vm-qemu    ; bash scripts/install/51-anti-vm-seabios.sh
99-smoke-test:       51-anti-vm-seabios ; bash scripts/install/99-smoke-test.sh

# ----- 卸载 stage -----
# uninstall 串行 u00→u99，每步独立（不强加 .PHONY 依赖，u30 失败 u40 仍跑）
uninstall: $(UNINSTALL_STAGES)

# 预演（不动）。target-specific export 保证子 stage 都看到 DRY_RUN=1
uninstall-dry: export DRY_RUN := 1
uninstall-dry: $(UNINSTALL_STAGES)

# 跳过确认 prompt
uninstall-yes: export YES := 1
uninstall-yes: $(UNINSTALL_STAGES)

u00-preflight:               ; bash scripts/uninstall/u00-preflight.sh
u10-stop-services:           ; bash scripts/uninstall/u10-stop-services.sh
u20-backup-data:             ; bash scripts/uninstall/u20-backup-data.sh
u30-purge-apt:               ; bash scripts/uninstall/u30-purge-apt.sh
u40-remove-files:            ; bash scripts/uninstall/u40-remove-files.sh
u50-remove-systemd-units:    ; bash scripts/uninstall/u50-remove-systemd-units.sh
u60-revert-system-config:    ; bash scripts/uninstall/u60-revert-system-config.sh
u70-remove-users:            ; bash scripts/uninstall/u70-remove-users.sh
u80-clean-cron:              ; bash scripts/uninstall/u80-clean-cron.sh
u99-verify:                  ; bash scripts/uninstall/u99-verify.sh

# ----- Phase C：客户机导入 -----
# import-guest 必须传 GUEST_QCOW2=/path/to.qcow2
ifneq ($(filter import-guest $(C_STAGES),$(MAKECMDGOALS)),)
ifeq ($(GUEST_QCOW2),)
$(error 必须传 GUEST_QCOW2: sudo make import-guest GUEST_QCOW2=/tmp/cuckoo1.qcow2)
endif
ifeq ($(wildcard $(GUEST_QCOW2)),)
$(error GUEST_QCOW2 文件不存在: $(GUEST_QCOW2))
endif
endif

import-guest: $(C_STAGES)

c10-import-guest:                                  ; bash scripts/guest/c10-import-guest.sh
c20-define-domain:    c10-import-guest             ; bash scripts/guest/c20-define-domain.sh
c30-register-kvm-conf: c20-define-domain           ; bash scripts/guest/c30-register-kvm-conf.sh
c40-smoke-guest:      c30-register-kvm-conf        ; bash scripts/guest/c40-smoke-guest.sh
c50-snapshot-and-cape: c40-smoke-guest             ; bash scripts/guest/c50-snapshot-and-cape.sh

# 强制重做某 stage（绕过幂等守卫）
force-%:
	@if [ -f scripts/install/$*.sh ]; then \
	  FORCE=1 bash scripts/install/$*.sh; \
	elif [ -f scripts/uninstall/$*.sh ]; then \
	  FORCE=1 bash scripts/uninstall/$*.sh; \
	elif [ -f scripts/guest/$*.sh ]; then \
	  FORCE=1 bash scripts/guest/$*.sh; \
	else \
	  echo "未找到 stage: $*"; exit 1; \
	fi

clean:
	rm -rf logs/ state/

help:
	@echo "安装目标："
	@echo "  sudo make all                 # 完整安装（~60-90 min）"
	@echo "  sudo make <stage>             # 单步：00-preflight / 10-mirrors / ..."
	@echo "  sudo make force-<stage>       # 强制重做（忽略幂等守卫）"
	@echo ""
	@echo "卸载目标："
	@echo "  sudo make uninstall           # 全清卸载（含确认 prompt）"
	@echo "  sudo make uninstall-dry       # 预演（DRY_RUN=1，不动任何东西）"
	@echo "  sudo make uninstall-yes       # 跳过 prompt（CI/批量用）"
	@echo "  sudo make u<NN>-<stage>       # 单步卸载：u30-purge-apt 等"
	@echo ""
	@echo "Phase C 客户机："
	@echo "  sudo make import-guest GUEST_QCOW2=/path/to.qcow2"
	@echo "                                # 校验 + 注册 + 启 VM + 拍快照 + unmask cape"
	@echo "  sudo make c<NN>-<stage>       # 单步：c10-import-guest / c20-define-domain / ..."
	@echo ""
	@echo "其他："
	@echo "  make clean                    # 清空 logs/ state/"
	@echo ""
	@echo "Stage 列表："
	@$(foreach s,$(STAGES),echo "  install:   $(s)";)
	@$(foreach s,$(UNINSTALL_STAGES),echo "  uninstall: $(s)";)
	@$(foreach s,$(C_STAGES),echo "  phase-c:  $(s)";)
