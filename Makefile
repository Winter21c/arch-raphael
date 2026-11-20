# ============================================================================
# arch-raphael —— 本地构建入口（CI 见 .github/workflows/build.yml）
#
#   make arch       构建 Arch Linux ARM 镜像
#   make fedora     构建 Fedora 镜像
#   make all        依次构建两个发行版
#   make verify     静态自检（不需要 root）
#   make clean      卸载 loop / 挂载点，删除镜像产物
#   make distclean  clean + 删除 work/ 与 cache/
#   make help       显示本帮助
#
# 常用变量（覆盖 config/*.conf 的默认值，直接透传给 build.sh）：
#   make arch STAGE=packages KERNEL_VERSION=7.3 IMAGE_SIZE=10G COMPRESS_IMAGE=0
# ============================================================================
SHELL := /bin/bash

DISTROS  := arch fedora
STAGE    ?= all
BUILD    ?= ./build.sh
VERIFY   ?= ./tools/verify.sh

# 以 KEY=VALUE 透传给 build.sh（config/*.conf 使用 := 默认值，环境变量优先）
PASSTHROUGH := KERNEL_VERSION IMAGE_SIZE COMPRESS_IMAGE BOOT_SIZE \
               COMPOSITOR SCREEN_ROTATION INSTALL_IME DUX_SHELL_VERSION

ifeq ($(shell id -u),0)
SUDO :=
else
SUDO := sudo
endif

ENV_ASSIGN := $(strip $(foreach v,$(PASSTHROUGH),$(if $($(v)),$(v)=$($(v)))))

.PHONY: all arch fedora verify clean distclean help

all: arch fedora

arch:
	$(SUDO) env $(ENV_ASSIGN) $(BUILD) arch $(STAGE)

fedora:
	$(SUDO) env $(ENV_ASSIGN) $(BUILD) fedora $(STAGE)

verify:
	@bash $(VERIFY)

clean:
	-@$(SUDO) umount -R work/rootdir 2>/dev/null || true
	-@$(SUDO) losetup -D 2>/dev/null || true
	@rm -rf out
	@rm -f rootfs.img rootfs-*.7z rootfs-*.img rootfs-*.sha256
	@echo "已清理镜像产物（work/ 与 cache/ 保留，用 make distclean 删除）"

distclean: clean
	@rm -rf work cache
	@echo "已删除 work/ 与 cache/"

help:
	@sed -n '2,15p' $(firstword $(MAKEFILE_LIST)) | sed 's/^# \{0,1\}//'
