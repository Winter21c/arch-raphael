#!/usr/bin/env bash
# ============================================================================
# Redmi K20 Pro (raphael) Arch Linux / Fedora 镜像构建入口
#
#   sudo ./build.sh arch              # 在 arm64 主机上直接构建（非 arm64 自动用 docker）
#   sudo ./build.sh fedora --inner    # 在容器/arm64 内部执行（CI 用）
#   sudo ./build.sh arch packages     # 只跑某个阶段（需镜像已存在）
#   ./build.sh --help
# ============================================================================
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$REPO_DIR"

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

参数：
  <arch|fedora>        目标发行版
  [stage]              可选阶段：prepare image bootstrap packages config desktop
                       hardware kernel initramfs boot finalize（默认 all）
  --stage <name>       同上（等价写法）
  --inner              已在 arm64 环境内部，不再尝试容器化
  -h, --help           显示帮助

常用环境变量（会覆盖 config 默认值）：
  KERNEL_VERSION=7.3  IMAGE_SIZE=10G  COMPRESS_IMAGE=1  BOOT_SIZE=512M
  USER_NAME=user USER_PASS=1234 ROOT_PASS=1234  COMPOSITOR=niri
  SCREEN_ROTATION=90  INSTALL_IME=1  DUX_SHELL_VERSION=2.1.2
EOF
}

DISTRO=""; STAGE="all"; INNER=0
ARG_STAGE=""
while [ $# -gt 0 ]; do
    case "$1" in
        arch|fedora) DISTRO="$1"; shift ;;
        prepare|image|bootstrap|packages|config|desktop|hardware|kernel|initramfs|boot|verify|finalize|all)
            STAGE="$1"; shift ;;
        --stage) ARG_STAGE="${2:-}"; shift 2 ;;
        --stage=*) ARG_STAGE="${1#*=}"; shift ;;
        --inner) INNER=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage; exit 1 ;;
    esac
done
[ -n "$ARG_STAGE" ] && STAGE="$ARG_STAGE"
[ -n "$DISTRO" ] || { echo "请指定发行版: arch | fedora" >&2; usage; exit 1; }

# ---- 读取配置（环境变量优先）---------------------------------------------
source config/device.conf
source lib/common.sh
source config/distro.conf
distro_config "$DISTRO" || die "发行版配置错误"

# ---- 需要容器时自动进入容器 ----------------------------------------------
# 触发条件（--inner 可跳过本段，表示“已经在合适的构建环境里”）：
#   1) 主机不是 aarch64（需要 qemu binfmt 执行 arm64 用户态）
#   2) 目标是 Fedora 但主机没有 dnf5（如在 Ubuntu arm64 runner 上构建 Fedora）
NEED_CONTAINER=0
ARCH_MISMATCH=0
if [ "$(uname -m)" != "aarch64" ]; then
    ARCH_MISMATCH=1
    # x86_64 主机只要注册了 qemu-aarch64 binfmt，就可以直接 chroot 进 arm64 根文件系统，
    # 宿主机上的 parted/mkfs/dracut 等工具与架构无关，因此无需容器。
    if [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        step "x86_64 主机 + qemu-aarch64 binfmt → 原生 chroot 构建（不进入容器）"
    else
        NEED_CONTAINER=1
    fi
fi
if [ "$DISTRO" = "fedora" ] && ! have dnf5; then
    NEED_CONTAINER=1
fi

if [ "$INNER" != "1" ] && [ "$NEED_CONTAINER" = "1" ]; then
    have docker || die "需要 docker 才能构建（主机 $(uname -m)，目标 $DISTRO；也可改用 arm64 原生主机）"
    if [ "$ARCH_MISMATCH" = "1" ]; then
        die "缺少 qemu-aarch64 binfmt 注册，且需要容器化构建。请安装 qemu-user-static 并注册 binfmt"
    fi
    step "在容器内构建: $CONTAINER_IMAGE ($DISTRO, 阶段 $STAGE)"
    docker_env=()
    for v in KERNEL_VERSION IMAGE_SIZE BOOT_SIZE SECTOR_SIZE COMPRESS_IMAGE \
             USER_NAME USER_PASS ROOT_PASS HOSTNAME_DEFAULT COMPOSITOR SCREEN_ROTATION \
             INSTALL_IME BOOT_SERIAL_CONSOLE DUX_SHELL_VERSION DUX_GREETER_VERSION KERNEL_DEB_REPO; do
        eval "val=\${$v:-}"
        [ -n "$val" ] && docker_env+=(-e "$v=$val")
    done
    docker_tty=()
    [ -t 0 ] && docker_tty=(-it)
    exec docker run --rm "${docker_tty[@]}" --privileged --platform linux/arm64 \
        -v "$REPO_DIR:/work" -w /work \
        "${docker_env[@]}" \
        "$CONTAINER_IMAGE" bash -lc "bash tools/host-prep.sh && bash build.sh $DISTRO $STAGE --inner"
fi

# ---- 内部执行 ------------------------------------------------------------
LOOP=""
require_root
ensure_dirs
need_cmd parted losetup mkfs.vfat mkfs.btrfs ar curl tar sha256sum

source lib/image.sh
source lib/prepare.sh
source lib/kernel.sh
source lib/configure.sh
source lib/desktop.sh
source lib/hardware.sh
source lib/raphael-initramfs.sh
source lib/boot.sh
source lib/verify.sh
source lib/finalize.sh

DISTRO_SH="$REPO_DIR/distro/$DISTRO/distro.sh"
[ -f "$DISTRO_SH" ] || die "缺少发行版层: $DISTRO_SH"
# shellcheck disable=SC1090
source "$DISTRO_SH"
for fn in distro_bootstrap distro_packages distro_desktop distro_configure distro_initramfs; do
    declare -f "$fn" >/dev/null || die "发行版层未实现函数: $fn"
done
export KVER=""

log "发行版: $DISTRO_NAME | 镜像: $IMAGE_PATH ($IMAGE_SIZE) | 内核: $KERNEL_VERSION"

stage_prepare()   { prepare_all; }
stage_image()     { img_create; mount_virtual; }
stage_bootstrap() { img_is_mounted || img_attach; distro_bootstrap; }
stage_packages()  { img_is_mounted || img_attach; distro_packages; }
stage_config()    { configure_common; distro_configure; }
stage_desktop()   { distro_desktop; desktop_install; }
stage_hardware()  { hardware_overlay; }
stage_kernel()    { kernel_install; }
stage_initramfs() { distro_initramfs; }
stage_boot()      { boot_install; boot_build_android; }
stage_verify()    { verify_image; }
stage_finalize()  { finalize_image; }

ORDER="prepare image bootstrap packages config desktop hardware kernel initramfs boot verify finalize"

run_stage() {
    case "$1" in
        prepare)   stage_prepare ;;
        image)     stage_image ;;
        bootstrap) stage_bootstrap ;;
        packages)  stage_packages ;;
        config)    stage_config ;;
        desktop)   stage_desktop ;;
        hardware)  stage_hardware ;;
        kernel)    stage_kernel ;;
        initramfs) stage_initramfs ;;
        boot)      stage_boot ;;
        verify)    stage_verify ;;
        finalize)  stage_finalize ;;
        *) die "未知阶段: $1" ;;
    esac
}

if [ "$STAGE" = "all" ]; then
    for s in $ORDER; do
        step "[$s] ($DISTRO)"
        run_stage "$s"
    done
    step "构建完成"
    ls -lh "$IMAGE_PATH" 2>/dev/null || true
    ls -lh "rootfs-$DISTRO_ID-$KERNEL_VERSION"*.7z 2>/dev/null || true
else
    run_stage "$STAGE"
fi