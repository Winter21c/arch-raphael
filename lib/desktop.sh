#!/usr/bin/env bash
# dux-shell（dms）+ dux-greeter 登录界面 + 虚拟键盘 + 默认横屏

desktop_install() {
    step "安装 dux-shell / dux-greeter / 虚拟键盘"
    local d="$CACHE_DIR/dux"
    local q="$MNT/usr/share/quickshell/dms"

    # ---- 1. dms 主程序（预编译 Go 二进制，arm64）--------------------------
    install -d "$MNT/usr/bin"
    gunzip -c "$d/dms-cli-arm64.gz" > "$MNT/usr/bin/dms"
    chmod 755 "$MNT/usr/bin/dms"

    # ---- 2. QML 界面 -----------------------------------------------------
    rm -rf "$q"; install -d "$q"
    tar -xzf "$d/dms-qml.tar.gz" -C "$q"
    rm -rf "$q/.git"* "$q/distro" "$q/tests" "$q/.github" "$q/.agents" 2>/dev/null || true
    echo "$DUX_SHELL_VERSION" > "$q/VERSION"

    # ---- 3. systemd 用户服务 / 桌面项 / 图标 -----------------------------
    if [ -f "$q/assets/systemd/dms.service" ]; then
        install -Dm644 "$q/assets/systemd/dms.service" "$MNT/usr/lib/systemd/user/dms.service"
    fi
    local f
    for f in dms-open.desktop dev.duxlabs.shell.desktop dev.duxlabs.shell.notepad.desktop; do
        [ -f "$q/assets/$f" ] && install -Dm644 "$q/assets/$f" "$MNT/usr/share/applications/$f"
    done
    [ -f "$q/assets/dev.duxlabs.shell.svg" ] && \
        install -Dm644 "$q/assets/dev.duxlabs.shell.svg" "$MNT/usr/share/icons/hicolor/scalable/apps/dev.duxlabs.shell.svg"

    # ---- 4. dux-greeter（登录界面，单文件内嵌 QML）----------------------
    gunzip -c "$d/dms-greeter.gz" > "$MNT/usr/bin/dms-greeter"
    chmod 755 "$MNT/usr/bin/dms-greeter"
    local g="$WORK_DIR/greeter-src"
    rm -rf "$g"; mkdir -p "$g"
    tar -xzf "$d/dux-greeter-src.tar.gz" -C "$g" --strip-components=1
    [ -f "$g/assets/systemd/sysusers-dms-greeter.conf" ] && \
        install -Dm644 "$g/assets/systemd/sysusers-dms-greeter.conf" "$MNT/usr/lib/sysusers.d/dms-greeter.conf"
    [ -f "$g/assets/systemd/tmpfiles-dms-greeter.conf" ] && \
        install -Dm644 "$g/assets/systemd/tmpfiles-dms-greeter.conf" "$MNT/usr/lib/tmpfiles.d/dms-greeter.conf"

    # greeter 用户（部分发行版 greetd 包会自带，缺少则补建）
    # greetd 的 sysusers 只建用户（无家目录）。给它一个可写 HOME，niri/dms-greeter
    # 需要写缓存；shell 与上游保持一致（/bin/bash）。
    if ! chroot_sh "id greeter >/dev/null 2>&1"; then
        chroot_sh "useradd -r -M -d /var/lib/greetd -s /bin/bash greeter" || \
            warn "创建 greeter 用户失败"
    fi
    chroot_sh "usermod -d /var/lib/greetd -s /bin/bash greeter" 2>/dev/null || true
    chroot_sh "usermod -aG video,input,render greeter" 2>/dev/null || true
    install -d "$MNT/var/lib/greetd" "$MNT/var/cache/dms-greeter"
    chroot_sh "chown -R greeter:greeter /var/lib/greetd /var/cache/dms-greeter" 2>/dev/null || true

    # ---- 5. greetd 配置（登录界面 = dux-greeter）------------------------
    install -d "$MNT/etc/greetd"
    cat > "$MNT/etc/greetd/config.toml" <<EOF
# dux-greeter（Dux Shell 配套登录界面）
[terminal]
vt = 1

[default_session]
user = "greeter"
command = "dms-greeter --command $COMPOSITOR"
EOF

    # dux-greeter 会自动 include 该文件（登录界面同样默认横屏 + 虚拟键盘可用）
    cat > "$MNT/etc/greetd/niri_overrides.kdl" <<EOF
// 由 arch-raphael 构建系统生成：登录界面默认横屏
// DSI-1 为 sm8150 dsi0 的 DRM connector；DSI-2 作为兜底（不同内核命名差异）
output "DSI-1" {
    transform "$SCREEN_ROTATION"
}

output "DSI-2" {
    transform "$SCREEN_ROTATION"
}

// 登录界面也要能用虚拟键盘输入密码
spawn-at-startup "squeekboard"

// 硬件按键：电源键熄屏/亮屏、音量键调音量（niri 直接收到 KEY_POWER / KEY_VOLUMEUP 等）
binds {
    XF86PowerOff { spawn "/usr/local/bin/raphael-screen-toggle"; }
    XF86AudioRaiseVolume { spawn "/usr/local/bin/raphael-volume" "up"; }
    XF86AudioLowerVolume { spawn "/usr/local/bin/raphael-volume" "down"; }
    XF86AudioMute { spawn "/usr/local/bin/raphael-volume" "mute"; }
}
EOF

    # ---- 电源键守护进程（不依赖 niri 是否收到按键）----------------------
    cat > "$MNT/usr/local/sbin/raphael-powerkey.sh" <<'EOS'
#!/bin/sh
# 监听 pm8941_pwrkey 的 KEY_POWER(116) 按下事件（value==1），忽略抬起/重复
set -u
EV=/run/raphael-pwrkey.ev
DEV=""
for d in /dev/input/event*; do
    n=$(cat "/sys/class/input/$(basename "$d")/device/name" 2>/dev/null || true)
    case "$n" in *pwrkey*) DEV=$d; break;; esac
done
[ -n "$DEV" ] || { echo "no pwrkey device"; exit 1; }
echo "watching $DEV"
while :; do
    dd if="$DEV" bs=24 count=1 of="$EV" 2>/dev/null || { sleep 1; continue; }
    type=$(od -An -tu2 -j16 -N2 "$EV" 2>/dev/null | tr -d " ")
    code=$(od -An -tu2 -j18 -N2 "$EV" 2>/dev/null | tr -d " ")
    val=$(od -An -tu4 -j20 -N4 "$EV" 2>/dev/null | tr -d " ")
    if [ "$type" = "1" ] && [ "$code" = "116" ] && [ "$val" = "1" ]; then
        /usr/local/bin/raphael-screen-toggle
    fi
done
EOS
    chmod 755 "$MNT/usr/local/sbin/raphael-powerkey.sh"

    cat > "$MNT/etc/systemd/system/raphael-powerkey.service" <<'EOS'
[Unit]
Description=Power key -> screen toggle (pm8941_pwrkey)
After=local-fs.target systemd-udevd.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/raphael-powerkey.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOS

    # ---- 硬件按键辅助脚本（电源键熄屏/亮屏、音量键）--------------------
    install -Dm755 /dev/stdin "$MNT/usr/local/bin/raphael-screen-toggle" <<'EOS'
#!/bin/sh
# 电源键：背光开/关（状态机，任何情况下都能恢复）+ 同时尝试 niri 熄屏
set -u
ST=/run/raphael-screen-state
B=$(ls -d /sys/class/backlight/* 2>/dev/null | head -1)
[ -n "$B" ] || { echo "no backlight"; exit 1; }
cur=$(cat "$B/brightness" 2>/dev/null || echo 0)
max=$(cat "$B/max_brightness" 2>/dev/null || echo 1)
state=$(cat "$ST" 2>/dev/null || echo on)
if [ "$state" = "on" ]; then
    echo "$cur" > /run/raphael-screen-saved 2>/dev/null || true
    echo 0 > "$B/brightness" 2>/dev/null || true
    echo off > "$ST"
else
    saved=$(cat /run/raphael-screen-saved 2>/dev/null || echo "$max")
    [ "$saved" -gt 0 ] 2>/dev/null || saved=$max
    echo "$saved" > "$B/brightness" 2>/dev/null || true
    echo on > "$ST"
fi
EOS
    install -Dm755 /dev/stdin "$MNT/usr/local/bin/raphael-volume" <<'EOS'
#!/bin/sh
# 音量键：调整默认 sink 音量；没有 sink 时退回 ALSA
set -u
step=${RAPHAEL_VOLUME_STEP:-5}
case "${1:-}" in
    up)   wpctl set-volume @DEFAULT_AUDIO_SINK@ "${step}%+" 2>/dev/null || amixer -q -c 0 sset 'RX0 Digital' 5%+ ;;
    down) wpctl set-volume @DEFAULT_AUDIO_SINK@ "${step}%-" 2>/dev/null || amixer -q -c 0 sset 'RX0 Digital' 5%- ;;
    mute) wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle 2>/dev/null || true ;;
    *)    echo "用法: $0 up|down|mute" >&2; exit 2 ;;
esac
EOS

    # ---- 6. 用户会话 niri 配置（默认横屏 + DMS + 虚拟键盘）--------------
    mkdir -p "$WORK_DIR/userconf/niri"
    cat > "$WORK_DIR/userconf/niri/config.kdl" <<EOF
// Redmi K20 Pro (raphael) 默认配置 —— 由 arch-raphael 生成
// 手机屏幕默认横屏；DMS 由 dms run 启动；squeekboard 提供虚拟键盘

input {
    keyboard {
        xkb {
            layout "us"
        }
    }

    touchpad {
        tap
        natural-scroll
    }

    mouse {
    }
}

// DSI-1 = sm8150 dsi0 的 DRM connector（主）；DSI-2 兜底
output "DSI-1" {
    transform "$SCREEN_ROTATION"
}

output "DSI-2" {
    transform "$SCREEN_ROTATION"
}

spawn-at-startup "squeekboard"
spawn-at-startup "dms" "run"

include optional=true "dms/colors.kdl"
include optional=true "dms/layout.kdl"
include optional=true "dms/alttab.kdl"
include optional=true "dms/binds-next.kdl"
include optional=true "dms/keybinds.kdl"

layout {
    background-color "#101418"
}

hotkey-overlay {
    skip-at-startup
}


// 硬件按键：电源键熄屏/亮屏、音量键调音量（niri 直接收到 KEY_POWER / KEY_VOLUMEUP 等）
binds {
    XF86PowerOff { spawn "/usr/local/bin/raphael-screen-toggle"; }
    XF86AudioRaiseVolume { spawn "/usr/local/bin/raphael-volume" "up"; }
    XF86AudioLowerVolume { spawn "/usr/local/bin/raphael-volume" "down"; }
    XF86AudioMute { spawn "/usr/local/bin/raphael-volume" "mute"; }
}
EOF

    if [ "$INSTALL_IME" = "1" ]; then
        printf '\nspawn-at-startup "fcitx5" "-d"\n' >> "$WORK_DIR/userconf/niri/config.kdl"
    fi

    install -Dm644 "$WORK_DIR/userconf/niri/config.kdl" "$MNT/etc/skel/.config/niri/config.kdl"
    if [ -d "$MNT/home/$USER_NAME" ]; then
        install -Dm644 "$WORK_DIR/userconf/niri/config.kdl" "$MNT/home/$USER_NAME/.config/niri/config.kdl"
        local uid gid
        uid=$(chroot_sh "id -u $USER_NAME" 2>/dev/null || echo 1000)
        gid=$(chroot_sh "id -g $USER_NAME" 2>/dev/null || echo 1000)
        chown -R "$uid:$gid" "$MNT/home/$USER_NAME/.config" 2>/dev/null || true
    fi

    # ---- 7. 输入法环境（可选）-------------------------------------------
    if [ "$INSTALL_IME" = "1" ]; then
        install -d "$MNT/etc/environment.d"
        cat > "$MNT/etc/environment.d/50-ime.conf" <<'EOF'
XMODIFIERS=@im=fcitx
QT_IM_MODULE=fcitx
GTK_IM_MODULE=fcitx
SDL_IM_MODULE=fcitx
EOF
    fi

    # ---- 8. 虚拟键盘自检 -------------------------------------------------
    if ! chroot_sh "command -v squeekboard >/dev/null 2>&1"; then
        warn "未找到 squeekboard（虚拟键盘）。请确认发行版层已安装或构建 squeekboard"
    fi
    if ! chroot_sh "command -v dms >/dev/null 2>&1"; then
        die "dms 安装失败"
    fi

    # ---- 9. 锁屏 / 解锁 PAM（复制 login 服务，DMS 检测到自定义文件会直接沿用）--
    if [ -f "$MNT/etc/pam.d/login" ] && [ ! -f "$MNT/etc/pam.d/dankshell" ]; then
        install -Dm644 "$MNT/etc/pam.d/login" "$MNT/etc/pam.d/dankshell"
        log "已创建 /etc/pam.d/dankshell（锁屏解锁）"
    fi

    # ---- 10. 登录管理器 --------------------------------------------------
    svc_enable greetd.service raphael-powerkey.service
    log "dux-shell + dux-greeter + squeekboard + 横屏配置完成"
}