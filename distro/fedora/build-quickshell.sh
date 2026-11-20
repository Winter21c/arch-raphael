#!/usr/bin/env bash
# ============================================================================
# quickshell 源码构建（仅当仓库版本低于 DMS 要求时执行）
#
# 背景：Fedora 44 仓库里的 quickshell 是 0.2.1^git20260209.dacfa9d（apiVersion 较低），
#       DMS 2.1.2 要求 apiVersion >= 38（对应上游 v0.3.2 的 API 版本）。
#       仓库包由 distro.sh 先装好（提供 /usr/bin/qs）；本脚本检测版本，不足时从源码构建
#       并接管 /usr/bin/qs。
#
# 调用方式：由 distro/fedora/distro.sh 以 bash 执行，继承导出的
#           MNT / CACHE_DIR / WORK_DIR / JOBS 等变量；也可单独运行（自行读取 config/device.conf）。
#
# 环境变量：
#   QS_MIN_VERSION  视为满足的最低版本（默认 0.3.2）
#   QS_GIT_REF      构建的上游 tag（默认 v<QS_MIN_VERSION>）
#   QS_SRC_URL      源码仓库（默认 https://github.com/quickshell-mirror/quickshell）
#   QS_FORCE=1      即使仓库版本已足够也强制源码构建
#   QS_JOBS         编译并行度（默认 $JOBS 或 4）
#   QS_KEEP_DEPS=0  构建成功后卸载编译依赖（默认保留）
#
# 退出码：0 = 已可用（仓库版够新，或源码构建成功）；非 0 = 只能继续用仓库版。
# ============================================================================
set -uo pipefail

FEDORA_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$FEDORA_DIR/../.." && pwd)
# shellcheck source=../../lib/common.sh
. "$REPO_DIR/lib/common.sh"
if [ -z "${MNT:-}" ] || [ -z "${CACHE_DIR:-}" ]; then
    # shellcheck disable=SC1091
    . "$REPO_DIR/config/device.conf"
fi
# 复用 distro.sh 的 _fedora_dnf（同一套 installroot / excludepkgs / 签名策略）
# shellcheck disable=SC1091
. "$FEDORA_DIR/distro.sh"

QS_MIN_VERSION=${QS_MIN_VERSION:-0.3.2}
QS_GIT_REF=${QS_GIT_REF:-v${QS_MIN_VERSION}}
QS_SRC_URL=${QS_SRC_URL:-https://github.com/quickshell-mirror/quickshell}
QS_JOBS=${QS_JOBS:-${JOBS:-4}}
QS_FORCE=${QS_FORCE:-0}
QS_KEEP_DEPS=${QS_KEEP_DEPS:-1}

QS_MARKER=$MNT/usr/lib/raphael-quickshell.version
QS_BUILD_ROOT=$MNT/tmp/quickshell-build

# Fedora quickshell.spec 的 BuildRequires 对应包（F44 全部存在；--skip-unavailable 兜底改名）
QS_BUILD_DEPS="cmake ninja-build gcc gcc-c++ pkgconf-pkg-config
    qt6-qtbase-devel qt6-qtbase-private-devel qt6-qtdeclarative-devel
    qt6-qtwayland-devel qt6-qtsvg-devel qt6-qtshadertools-devel
    cli11-devel jemalloc-devel libdrm-devel mesa-libgbm-devel pipewire-devel
    pam-devel polkit-devel wayland-devel wayland-protocols-devel glib2-devel
    spirv-tools desktop-file-utils"

# 0.2.1^git20260209.dacfa9d-5.fc44 -> 0.2.1 ; v0.3.2 -> 0.3.2
_vnorm() {
    printf '%s' "$1" | sed -e 's/^[vV]//' -e 's/[^0-9.].*$//' -e 's/\.*$//'
}

# _vge A B —— A >= B ?
_vge() {
    [ -n "$1" ] || return 1
    [ "$1" = "$2" ] && return 0
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# 当前可用版本：源码构建标记 > qs --version > rpm 版本
_detect_version() {
    local v=""
    if [ -s "$QS_MARKER" ]; then
        v=$(_vnorm "$(grep -m1 '^version=' "$QS_MARKER" | cut -d= -f2-)")
        if [ -n "$v" ]; then
            printf '%s' "$v"
            return 0
        fi
    fi
    v=$(chroot_sh "qs --version 2>/dev/null" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
    if [ -z "$v" ] && rpm --root "$MNT" -q quickshell >/dev/null 2>&1; then
        v=$(rpm --root "$MNT" -q --qf '%{VERSION}' quickshell 2>/dev/null | head -1 || true)
        v=$(_vnorm "$v")
    fi
    printf '%s' "$v"
}

# dnf5 的 --skip-unavailable 在个别版本上不存在：失败后退回普通 install
_dnf_install_soft() {
    _fedora_dnf install --skip-unavailable "$@" && return 0
    warn "dnf5 --skip-unavailable 失败，改用普通 install 重试"
    _fedora_dnf install "$@"
}

# 卸掉仓库版（rpm 拥有 /usr/bin/qs，否则源码安装的文件会被视为冲突）
_drop_rpm() {
    if rpm --root "$MNT" -q quickshell >/dev/null 2>&1; then
        log "卸载仓库版 quickshell（/usr/bin/qs 改由源码构建提供）"
        chroot_sh "rpm -e --nodeps quickshell" || warn "rpm -e quickshell 失败（可能残留文件冲突）"
        return 0
    fi
    return 1
}

_restore_rpm() {
    warn "源码构建失败，回滚到仓库版 quickshell"
    _fedora_dnf install quickshell >/dev/null 2>&1 \
        || warn "回滚失败：请在镜像内手动 dnf install quickshell"
    rm -f "$QS_MARKER"
}

_verify() {
    if ! chroot_sh "test -x /usr/bin/qs"; then
        warn "源码安装后 /usr/bin/qs 不存在"
        return 1
    fi
    local out qml
    out=$(chroot_sh "qs --version 2>&1 | head -1" 2>/dev/null || true)
    qml=$(ls -d "$MNT"/usr/lib64/qt6/qml/Quickshell "$MNT"/usr/lib/qt6/qml/Quickshell 2>/dev/null | head -1 || true)
    if [ -z "$qml" ]; then
        warn "找不到 Quickshell QML 模块目录（dms 会加载失败）"
        return 1
    fi
    log "源码构建校验通过: /usr/bin/qs ${out:-（无 --version 输出）} / $qml"
    return 0
}

main() {
    [ -d "$MNT/usr" ] || { warn "MNT 未就绪: ${MNT:-}"; return 1; }
    mount_virtual

    local cur
    cur=$(_detect_version)
    log "quickshell 当前版本: ${cur:-未知}（要求 >= $QS_MIN_VERSION，构建 tag $QS_GIT_REF）"
    if [ "$QS_FORCE" != "1" ] && _vge "$cur" "$QS_MIN_VERSION"; then
        log "已满足要求，跳过源码构建"
        return 0
    fi

    step "从源码构建 quickshell $QS_GIT_REF"

    # ---- 1) 编译依赖 -----------------------------------------------------
    log "安装编译依赖"
    if ! _dnf_install_soft $QS_BUILD_DEPS; then
        warn "编译依赖安装失败"
        return 1
    fi
    if ! chroot_sh "command -v cmake >/dev/null && command -v ninja >/dev/null && command -v g++ >/dev/null"; then
        warn "cmake / ninja / g++ 不完整"
        return 1
    fi

    # ---- 2) 源码（缓存到 CACHE_DIR）--------------------------------------
    local tb="$CACHE_DIR/qs/quickshell-$QS_GIT_REF.tar.gz"
    if [ ! -s "$tb" ]; then
        dl "$QS_SRC_URL/archive/refs/tags/$QS_GIT_REF.tar.gz" "$tb" || return 1
    fi
    [ -s "$tb" ] || { warn "源码包为空: $tb"; return 1; }

    # ---- 3) 解包到镜像内（chroot 内编译，Qt ABI 与镜像一致）--------------
    rm -rf "$QS_BUILD_ROOT"
    install -d "$QS_BUILD_ROOT"
    if ! tar -xzf "$tb" -C "$QS_BUILD_ROOT"; then
        warn "解包失败: $tb"
        rm -rf "$QS_BUILD_ROOT"
        return 1
    fi
    local srcdir
    srcdir=$(ls -d "$QS_BUILD_ROOT"/*/ 2>/dev/null | head -1 || true)
    if [ -z "$srcdir" ]; then
        warn "源码包结构异常"
        rm -rf "$QS_BUILD_ROOT"
        return 1
    fi
    srcdir=/tmp/quickshell-build/$(basename "$srcdir")
    log "源码目录（镜像内）: $srcdir"

    # ---- 4) 让出 /usr/bin/qs 的所有权（失败可回滚）-----------------------
    local dropped=0
    if _drop_rpm; then
        dropped=1
    fi

    # ---- 5) 配置 / 编译 / 安装 -------------------------------------------
    # CRASH_HANDLER=OFF：上游默认依赖 cpptrace（F44 无此包）
    # v0.3.2 已移除 X11 后端，因此不需要 libxcb / X11 选项
    local cmake_args="-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_SKIP_INSTALL_RPATH=ON -DCRASH_HANDLER=OFF -DDISTRIBUTOR=Fedora"
    if ! chroot_sh "cd $srcdir && cmake -S . -B build -GNinja $cmake_args"; then
        warn "cmake 配置失败（Qt6 私有头 / devel 包缺失？见上方 cmake 输出）"
        [ "$dropped" = "1" ] && _restore_rpm
        rm -rf "$QS_BUILD_ROOT"
        return 1
    fi
    if ! chroot_sh "cd $srcdir && cmake --build build -j$QS_JOBS"; then
        warn "cmake 编译失败"
        [ "$dropped" = "1" ] && _restore_rpm
        rm -rf "$QS_BUILD_ROOT"
        return 1
    fi
    if ! chroot_sh "cd $srcdir && cmake --install build"; then
        warn "cmake 安装失败"
        [ "$dropped" = "1" ] && _restore_rpm
        rm -rf "$QS_BUILD_ROOT"
        return 1
    fi
    chroot_sh "ldconfig" >/dev/null 2>&1 || true

    # ---- 6) 校验 + 记录版本标记 ------------------------------------------
    if ! _verify; then
        [ "$dropped" = "1" ] && _restore_rpm
        rm -rf "$QS_BUILD_ROOT"
        return 1
    fi
    install -d "$(dirname "$QS_MARKER")"
    {
        printf 'version=%s\n' "$(_vnorm "$QS_GIT_REF")"
        printf 'ref=%s\n' "$QS_GIT_REF"
        printf 'source=%s\n' "$QS_SRC_URL"
        printf 'built=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$QS_MARKER"

    # ---- 7) 清理 ---------------------------------------------------------
    rm -rf "$QS_BUILD_ROOT"
    if [ "$QS_KEEP_DEPS" = "0" ]; then
        log "卸载编译依赖（QS_KEEP_DEPS=0）"
        _fedora_dnf remove $QS_BUILD_DEPS >/dev/null 2>&1 || warn "卸载编译依赖失败（可忽略）"
    fi
    log "quickshell $QS_GIT_REF 已安装到 /usr（QML 模块 + /usr/bin/qs）"
    return 0
}

main "$@"
