#!/usr/bin/env bash
# ============================================================================
# 虚拟键盘（OSK）：squeekboard 源码构建，失败退回 wvkbd
#
# 现状（F44 repodata 实测）：
#   * squeekboard 没有 Fedora 包（Debian/postmarketOS 才打包）
#   * wvkbd 也没有 Fedora 包
#   * lib/desktop.sh 与 niri 配置都以 "squeekboard" 启动键盘，
#     因此最终必须存在可执行的 /usr/bin/squeekboard
#
# 策略（SQUEEKBOARD_MODE=auto，默认）：
#   1. squeekboard 源码构建：meson + cargo（Rust），GTK3 + wayland-client + xkbcommon，
#      依赖链长且需要拉 crates.io —— 成功即用真正的 squeekboard
#   2. 退回 wvkbd 源码构建：纯 C + Makefile，只需
#      wayland-client / xkbcommon / pangocairo（Fedora 全都有），并安装
#      /usr/bin/squeekboard 兼容包装 -> /usr/bin/wvkbd-mobintl
#   3. 两者都失败：装 qt6-qtvirtualkeyboard（只有 Qt 应用能用）并明确告警
#
# 环境变量：
#   SQUEEKBOARD_MODE   auto | squeekboard | wvkbd | none
#   SQUEEKBOARD_REF    squeekboard 的 git tag（默认 v1.43.1）
#   WVKBD_LAYOUT       wvkbd 布局集（默认 mobintl）
#   WVKBD_ARGS         兼容包装里追加的参数（默认空；wvkbd 会自动判断横竖屏）
#
# 退出码：0 = /usr/bin/squeekboard 可用；非 0 = 没有可用的虚拟键盘。
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
# shellcheck disable=SC1091
. "$FEDORA_DIR/distro.sh"

SQUEEKBOARD_MODE=${SQUEEKBOARD_MODE:-auto}
SQUEEKBOARD_REF=${SQUEEKBOARD_REF:-v1.43.1}
SQUEEKBOARD_URL=${SQUEEKBOARD_URL:-https://gitlab.gnome.org/World/Phosh/squeekboard/-/archive}
WVKBD_LAYOUT=${WVKBD_LAYOUT:-mobintl}
WVKBD_ARGS=${WVKBD_ARGS:-}
WVKBD_URL=${WVKBD_URL:-https://git.sr.ht/~proycon/wvkbd/archive/master.tar.gz}
BUILD_ROOT=$MNT/tmp/keyboard-build

# squeekboard(v1.43.x) 的构建依赖：Rust 侧 gtk 0.18 (= GTK3) / glib / xkbcommon / zbus，
# 系统侧 meson 调 cargo，另需 pkg-config 能找到 gtk+-3.0 / wayland-client / xkbcommon
SQ_BUILD_DEPS="meson ninja-build gcc gcc-c++ rust cargo pkgconf-pkg-config python3 python3-ruamel-yaml
    glib2-devel gtk3-devel libxkbcommon-devel wayland-devel wayland-protocols-devel
    systemd-devel libbsd-devel gtk-layer-shell-devel"

# wvkbd：PKGS = wayland-client xkbcommon pangocairo（见上游 Makefile）
WVKBD_BUILD_DEPS="gcc make pkgconf-pkg-config wayland-devel wayland-protocols-devel
    libxkbcommon-devel pango-devel cairo-devel"

# dnf5 的 --skip-unavailable 在个别版本上不存在：失败后退回普通 install
_dnf_install_soft() {
    _fedora_dnf install --skip-unavailable "$@" && return 0
    warn "dnf5 --skip-unavailable 失败，改用普通 install 重试"
    _fedora_dnf install "$@"
}

_have_keyboard() {
    chroot_sh "test -x /usr/bin/squeekboard" >/dev/null 2>&1
}

# crates.io 可达性（squeekboard 的 cargo 依赖必须能拉下来）
_crates_reachable() {
    curl -sfI -m 15 https://index.crates.io/config.json >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 1) squeekboard 源码构建
# ---------------------------------------------------------------------------
_build_squeekboard() {
    step "构建 squeekboard $SQUEEKBOARD_REF（meson + cargo）"

    _dnf_install_soft $SQ_BUILD_DEPS || { warn "squeekboard 构建依赖安装失败"; return 1; }

    local miss=""
    chroot_sh "command -v meson >/dev/null" || miss="$miss meson"
    chroot_sh "command -v cargo >/dev/null" || miss="$miss cargo"
    chroot_sh "command -v rustc >/dev/null" || miss="$miss rustc"
    chroot_sh "command -v pkg-config >/dev/null" || miss="$miss pkg-config"
    chroot_sh "pkg-config --exists gtk+-3.0" || miss="$miss gtk+-3.0"
    chroot_sh "pkg-config --exists glib-2.0" || miss="$miss glib-2.0"
    chroot_sh "pkg-config --exists wayland-client" || miss="$miss wayland-client"
    chroot_sh "pkg-config --exists xkbcommon" || miss="$miss xkbcommon"
    if [ -n "$miss" ]; then
        warn "squeekboard 构建依赖不可得:$miss"
        return 1
    fi
    if ! _crates_reachable; then
        warn "无法访问 crates.io，squeekboard(Rust) 无法构建"
        return 1
    fi

    local tb="$CACHE_DIR/squeekboard/squeekboard-$SQUEEKBOARD_REF.tar.gz"
    if [ ! -s "$tb" ]; then
        dl "$SQUEEKBOARD_URL/$SQUEEKBOARD_REF/squeekboard-$SQUEEKBOARD_REF.tar.gz" "$tb" || return 1
    fi

    rm -rf "$BUILD_ROOT"; install -d "$BUILD_ROOT"
    if ! tar -xzf "$tb" -C "$BUILD_ROOT"; then
        warn "squeekboard 源码解包失败"
        rm -rf "$BUILD_ROOT"
        return 1
    fi
    local d
    d=$(ls -d "$BUILD_ROOT"/squeekboard-*/ 2>/dev/null | head -1 || true)
    if [ -z "$d" ]; then
        warn "squeekboard 源码结构异常"
        rm -rf "$BUILD_ROOT"
        return 1
    fi
    d=/tmp/keyboard-build/$(basename "$d")

    if ! chroot_sh "cd $d && meson setup build --prefix=/usr --buildtype=release -Dtests=false"; then
        warn "squeekboard meson setup 失败"
        rm -rf "$BUILD_ROOT"
        return 1
    fi
    if ! chroot_sh "cd $d && meson compile -C build"; then
        warn "squeekboard 编译失败（crates.io 网络 / Rust 版本 / GTK3 头文件）"
        rm -rf "$BUILD_ROOT"
        return 1
    fi
    if ! chroot_sh "cd $d && meson install -C build"; then
        warn "squeekboard 安装失败"
        rm -rf "$BUILD_ROOT"
        return 1
    fi
    chroot_sh "ldconfig" >/dev/null 2>&1 || true
    rm -rf "$BUILD_ROOT"

    if _have_keyboard; then
        log "squeekboard $SQUEEKBOARD_REF 构建成功（/usr/bin/squeekboard）"
        return 0
    fi
    warn "squeekboard 安装后仍找不到 /usr/bin/squeekboard"
    return 1
}

# ---------------------------------------------------------------------------
# 2) wvkbd 源码构建 + squeekboard 兼容包装
# ---------------------------------------------------------------------------
_install_wrapper() {
    # wvkbd 没有 --landscape 参数：main.c 里按 surface 宽高自动切换横竖屏布局
    # （keyboard.landscape = available_width > available_height），所以默认不传任何布局参数。
    cat > "$MNT/usr/bin/squeekboard" <<EOF
#!/bin/sh
# squeekboard 兼容包装（由 distro/fedora/build-squeekboard.sh 生成）
#
# lib/desktop.sh、niri 配置、greetd 的 niri_overrides 都以 "squeekboard" 启动虚拟键盘。
# Fedora 没有 squeekboard 包，squeekboard 源码构建也不可用，实际由 wvkbd 提供。
# wvkbd 会依据 surface 宽高自动选择横屏/竖屏布局，因此这里不传 --landscape。
exec /usr/bin/wvkbd-$WVKBD_LAYOUT $WVKBD_ARGS "\$@"
EOF
    chmod 755 "$MNT/usr/bin/squeekboard"
    log "已安装 /usr/bin/squeekboard -> wvkbd-$WVKBD_LAYOUT"
}

_build_wvkbd() {
    step "构建 wvkbd($WVKBD_LAYOUT)（squeekboard 不可用时的退回方案）"

    _dnf_install_soft $WVKBD_BUILD_DEPS || { warn "wvkbd 构建依赖安装失败"; return 1; }

    local tb="$CACHE_DIR/wvkbd/wvkbd-master.tar.gz"
    if [ ! -s "$tb" ]; then
        dl "$WVKBD_URL" "$tb" || return 1
    fi

    rm -rf "$BUILD_ROOT"; install -d "$BUILD_ROOT"
    if ! tar -xzf "$tb" -C "$BUILD_ROOT"; then
        warn "wvkbd 源码解包失败"
        rm -rf "$BUILD_ROOT"
        return 1
    fi
    local d
    d=$(ls -d "$BUILD_ROOT"/wvkbd-*/ 2>/dev/null | head -1 || true)
    if [ -z "$d" ]; then
        warn "wvkbd 源码结构异常"
        rm -rf "$BUILD_ROOT"
        return 1
    fi
    d=/tmp/keyboard-build/$(basename "$d")

    # 布局集头文件不在就退回默认布局
    if ! chroot_sh "test -f $d/layout.$WVKBD_LAYOUT.h"; then
        warn "wvkbd 没有布局集 $WVKBD_LAYOUT，改用 full"
        WVKBD_LAYOUT=full
    fi

    if ! chroot_sh "cd $d && make LAYOUT=$WVKBD_LAYOUT"; then
        warn "wvkbd 编译失败"
        rm -rf "$BUILD_ROOT"
        return 1
    fi
    if ! chroot_sh "cd $d && make LAYOUT=$WVKBD_LAYOUT install PREFIX=/usr"; then
        warn "wvkbd 安装失败"
        rm -rf "$BUILD_ROOT"
        return 1
    fi
    rm -rf "$BUILD_ROOT"

    if ! chroot_sh "test -x /usr/bin/wvkbd-$WVKBD_LAYOUT"; then
        warn "wvkbd 安装后找不到 /usr/bin/wvkbd-$WVKBD_LAYOUT"
        return 1
    fi
    # 习惯用 wvkbd 这个名字的脚本也能用
    chroot_sh "ln -sf wvkbd-$WVKBD_LAYOUT /usr/bin/wvkbd" >/dev/null 2>&1 || true
    _install_wrapper
    log "wvkbd($WVKBD_LAYOUT) 构建成功（入口 /usr/bin/squeekboard）"
    return 0
}

# ---------------------------------------------------------------------------
# 3) 最后兜底：Qt 虚拟键盘（只有 Qt 应用可用，wlroots 客户端无效）
# ---------------------------------------------------------------------------
_install_qt_fallback() {
    warn "squeekboard / wvkbd 都不可用，退到 qt6-qtvirtualkeyboard（仅 Qt 应用可用）"
    _dnf_install_soft qt6-qtvirtualkeyboard \
        || warn "qt6-qtvirtualkeyboard 安装失败"
    warn "虚拟键盘缺失：/usr/bin/squeekboard 不存在，触摸输入需要外接键盘"
    return 1
}

main() {
    [ -d "$MNT/usr" ] || { warn "MNT 未就绪: ${MNT:-}"; return 1; }
    mount_virtual

    if _have_keyboard; then
        log "虚拟键盘已存在: /usr/bin/squeekboard"
        return 0
    fi

    case "$SQUEEKBOARD_MODE" in
        none)
            warn "SQUEEKBOARD_MODE=none，跳过虚拟键盘"
            return 1
            ;;
        wvkbd)
            _build_wvkbd && return 0
            _install_qt_fallback
            return 1
            ;;
        squeekboard)
            _build_squeekboard && return 0
            warn "squeekboard 构建失败（SQUEEKBOARD_MODE=squeekboard，不退回 wvkbd）"
            return 1
            ;;
        auto|*)
            if _build_squeekboard; then
                return 0
            fi
            warn "squeekboard 不可用，退回 wvkbd"
            if _build_wvkbd; then
                return 0
            fi
            _install_qt_fallback
            return 1
            ;;
    esac
}

main "$@"
