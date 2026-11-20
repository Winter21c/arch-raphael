#!/usr/bin/env bash
# ============================================================================
# tools/host-prep.sh —— 检查 / 安装构建镜像所需的主机依赖（幂等，可重复执行）
#
# 用法：
#   sudo tools/host-prep.sh              # 安装缺失依赖（自动识别 apt / dnf / pacman）
#   tools/host-prep.sh --check           # 只检查，不安装（不需要 root）
#   tools/host-prep.sh --skip-cross      # 不安装 qemu binfmt（在 arm64 原生主机上构建）
#   tools/host-prep.sh --with-cross      # 强制安装 qemu binfmt（在 x86_64 主机上构建 arm64）
#
# 谁在调用它：
#   - GitHub Actions（ubuntu-24.04-arm）:  sudo bash tools/host-prep.sh --yes
#   - build.sh 的容器路径（非 arm64 主机）：容器内 bash tools/host-prep.sh
#   - 本地手工构建：见 README“本地构建”
#
# 构建镜像需要两件事：
#   1. root 权限 —— losetup / mount / chroot / btrfs
#   2. aarch64 执行环境 —— arm64 主机原生；x86_64 主机需要 qemu-user-static + binfmt
# ============================================================================
set -uo pipefail

ASSUME_YES=0
CHECK_ONLY=0
CROSS_MODE=auto   # auto | 1 | 0

usage() {
    sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        --check)      CHECK_ONLY=1 ;;
        --yes|-y)     ASSUME_YES=1 ;;
        --skip-cross) CROSS_MODE=0 ;;
        --with-cross) CROSS_MODE=1 ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "未知参数: $arg（--help 查看用法）" >&2; exit 2 ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }
have_any() { local c; for c in "$@"; do have "$c" && return 0; done; return 1; }
warn() { printf '[警告] %s\n' "$*" >&2; }

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# ---- 检测包管理器 ----------------------------------------------------------
if have apt-get; then FAMILY=debian
elif have dnf; then FAMILY=fedora
elif have pacman; then FAMILY=arch
else FAMILY=unknown
fi

case "$FAMILY" in
    debian)
        BASE_PKGS=(parted dosfstools btrfs-progs util-linux mount curl xz-utils zstd
                   binutils ca-certificates systemd kmod gdisk e2fsprogs file
                   python3-yaml)
        ZIP_PKGS=(7zip p7zip-full)
        CROSS_PKGS=(qemu-user-static binfmt-support)
        UPDATE_CMD="apt-get update"
        INSTALL_CMD="apt-get install -y --no-install-recommends"
        ;;
    fedora)
        BASE_PKGS=(parted dosfstools btrfs-progs util-linux mount curl xz zstd
                   binutils ca-certificates systemd kmod gdisk e2fsprogs file
                   python3-pyyaml)
        ZIP_PKGS=(7zip p7zip p7zip-plugins)
        CROSS_PKGS=(qemu-user-static)
        UPDATE_CMD=""
        INSTALL_CMD="dnf install -y"
        ;;
    arch)
        BASE_PKGS=(parted dosfstools btrfs-progs util-linux mount curl xz zstd
                   binutils ca-certificates systemd kmod gptfdisk e2fsprogs file
                   python-yaml)
        ZIP_PKGS=(7zip)
        CROSS_PKGS=(qemu-user-static qemu-user-static-binfmt)
        UPDATE_CMD=""
        INSTALL_CMD="pacman -S --needed --noconfirm"
        ;;
    *)
        echo "[错误] 无法识别包管理器（支持 apt / dnf / pacman）。" >&2
        echo "       请手动安装：parted dosfstools btrfs-progs util-linux curl xz zstd" >&2
        echo "       binutils ca-certificates 7zip(p7zip) systemd kmod gdisk e2fsprogs file" >&2
        exit 1
        ;;
esac

# ---- 构建必需的命令（"|" 分隔候选名）--------------------------------------
REQUIRED_CMDS=(
    parted                 # GPT 分区表
    losetup                # loop 设备（--sector-size 4096 / -P）
    partx                  # 分区扫描
    mkfs.vfat              # ESP 格式化
    mkfs.btrfs             # btrfs 格式化
    btrfs                  # 子卷 / 只读校验
    mount
    umount
    curl                   # 下载内核与素材
    xz                     # 解包 .xz
    zstd                   # 解包 .deb 内的 zst
    ar                     # 拆 .deb
    tar
    udevadm
    blkid
    sha256sum
    chroot
    depmod
    modprobe
    "7z|7zz|7za"           # 压缩产物（包名随发行版而异）
)

HOST_ARCH=$(uname -m)
if [ "$CROSS_MODE" = auto ]; then
    if [ "$HOST_ARCH" = aarch64 ]; then CROSS_MODE=0; else CROSS_MODE=1; fi
fi

# ---- 检查 ------------------------------------------------------------------
MISSING=()
CROSS_MISSING=()
ZIP_MISSING=0

check_all() {
    MISSING=()
    local spec alts
    for spec in "${REQUIRED_CMDS[@]}"; do
        IFS='|' read -ra alts <<<"$spec"
        have_any "${alts[@]}" || MISSING+=("${spec//|/ 或 }")
    done

    ZIP_MISSING=0
    have_any 7z 7zz 7za || ZIP_MISSING=1

    CROSS_MISSING=()
    if [ "$CROSS_MODE" = 1 ]; then
        have_any qemu-aarch64-static qemu-aarch64 || CROSS_MISSING+=("qemu-aarch64-static")
        [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || CROSS_MISSING+=("binfmt(qemu-aarch64)")
    fi
}

print_missing() {
    local m
    if [ "${#MISSING[@]}" -gt 0 ]; then
        echo "[缺失] 构建命令: ${MISSING[*]}"
    fi
    if [ "${#CROSS_MISSING[@]}" -gt 0 ]; then
        for m in "${CROSS_MISSING[@]}"; do
            echo "[缺失] 交叉执行环境: $m"
        done
    fi
}

report_hint() {
    echo
    echo "  手工安装（$FAMILY）："
    [ -n "$UPDATE_CMD" ] && echo "    $SUDO $UPDATE_CMD"
    echo "    $SUDO $INSTALL_CMD ${BASE_PKGS[*]} ${ZIP_PKGS[*]}"
    if [ "$CROSS_MODE" = 1 ]; then
        echo "    $SUDO $INSTALL_CMD ${CROSS_PKGS[*]}"
        echo "  然后确认 binfmt 已注册："
        echo "    systemctl restart systemd-binfmt 2>/dev/null || true"
        echo "    ls /proc/sys/fs/binfmt_misc/qemu-aarch64"
    fi
    echo
}

# ---- 安装（先整组装，失败后逐个装并跳过不可用包）--------------------------
APT_UPDATED=0

install_group() {
    case "$FAMILY" in
        debian)
            if [ "$APT_UPDATED" = 0 ]; then
                $SUDO env DEBIAN_FRONTEND=noninteractive $UPDATE_CMD || warn "apt-get update 失败"
                APT_UPDATED=1
            fi
            $SUDO env DEBIAN_FRONTEND=noninteractive $INSTALL_CMD "$@"
            ;;
        *)
            $SUDO $INSTALL_CMD "$@"
            ;;
    esac
}

install_pkgs() {
    local pkgs=("$@") p
    if [ "${#pkgs[@]}" -eq 0 ]; then return 0; fi
    echo "==> 安装: ${pkgs[*]}"
    if install_group "${pkgs[@]}"; then return 0; fi
    warn "整组安装失败，改为逐个安装（跳过不可用包）"
    for p in "${pkgs[@]}"; do
        install_group "$p" || warn "不可用，跳过: $p"
    done
    return 0
}

# ---- 主流程 ----------------------------------------------------------------
echo "==> 主机: $(uname -srm) | 包管理器: $FAMILY | 交叉模式: $CROSS_MODE"

check_all
if [ "${#MISSING[@]}" -eq 0 ] && [ "$ZIP_MISSING" = 0 ] && [ "${#CROSS_MISSING[@]}" -eq 0 ]; then
    echo "[PASS] 主机依赖齐全"
    exit 0
fi

print_missing
if [ "$ZIP_MISSING" = 1 ]; then echo "[缺失] 7-Zip（7z / 7zz / 7za）"; fi

if [ "$CHECK_ONLY" = 1 ]; then
    report_hint
    echo "[FAIL] 主机依赖不完整（--check 模式不安装）"
    exit 1
fi

echo "==> 安装缺失依赖（需要 root / sudo）"
if [ "${#MISSING[@]}" -gt 0 ] || [ "$ZIP_MISSING" = 1 ]; then
    install_pkgs "${BASE_PKGS[@]}"
fi
if [ "$ZIP_MISSING" = 1 ]; then
    install_pkgs "${ZIP_PKGS[@]}"
fi
if [ "${#CROSS_MISSING[@]}" -gt 0 ]; then
    install_pkgs "${CROSS_PKGS[@]}"
    $SUDO systemctl restart systemd-binfmt 2>/dev/null || true
fi

# ---- 安装后复核 ------------------------------------------------------------
check_all
if [ "${#MISSING[@]}" -gt 0 ] || [ "$ZIP_MISSING" = 1 ] || [ "${#CROSS_MISSING[@]}" -gt 0 ]; then
    print_missing
    if [ "$ZIP_MISSING" = 1 ]; then echo "[缺失] 7-Zip（7z / 7zz / 7za）"; fi
    report_hint
    echo "[FAIL] 安装后仍缺少依赖"
    exit 1
fi

echo "[PASS] 主机依赖已就绪（$FAMILY）"
