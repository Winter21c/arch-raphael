#!/usr/bin/env bash
# ============================================================================
# tools/flash.sh —— 把根文件系统镜像刷入 Redmi K20 Pro 的 userdata 分区
#
# 用法: sudo tools/flash.sh [--boot <boot.img>] [--no-reboot] <rootfs.img>
#   --boot IMG    先把 Android boot image（内核+initramfs+DTB）刷进 boot 分区，
#                 这样原厂 ABL 会直接引导 Linux（推荐；无需 U-Boot）
#   --no-reboot   刷完不自动 fastboot reboot（重启时机由你决定）
#   -h, --help    显示本帮助
#
# 前提: 设备已进 fastboot（关机后「音量下 + 电源」）
# 注意: 会覆盖 userdata（Android 的 userdata 一并丢），8-10G 镜像需几分钟
#
# 刷完先 tools/wait-boot.sh 等 SSH，再 tools/device-test.sh 逐项验证。
# ============================================================================
set -euo pipefail

IMG=''
BOOT=''
REBOOT=1

while [ $# -gt 0 ]; do
    case "$1" in
        --boot)      BOOT=${2:-}; shift 2 ;;
        --no-reboot) REBOOT=0; shift ;;
        -h|--help)   sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)          echo "未知参数: $1（--help 看用法）" >&2; exit 2 ;;
        *)           IMG=$1; shift ;;
    esac
done

[ -n "$IMG" ] || { echo "用法: sudo $0 [--no-reboot] <rootfs.img>" >&2; exit 1; }
[ -f "$IMG" ] || { echo "镜像不存在: $IMG" >&2; exit 1; }
command -v fastboot >/dev/null 2>&1 || { echo "找不到 fastboot（装 android-tools）" >&2; exit 1; }

if ! fastboot devices 2>/dev/null | grep -qw fastboot; then
    echo "未检测到 fastboot 设备。请让设备进入 fastboot 模式：" >&2
    echo "  关机 → 按住「音量下 + 电源」→ 出现 fastboot 界面" >&2
    echo "  已在系统里的话：docs/INSTALL.md 第 12 节「恢复」" >&2
    fastboot devices >&2 || true
    exit 1
fi

if [ -n "$BOOT" ]; then
    [ -f "$BOOT" ] || { echo "boot 镜像不存在: $BOOT" >&2; exit 1; }
    echo "==> 刷写 $BOOT（$(du -h "$BOOT" | cut -f1)）到 boot 分区（内核+initramfs+DTB，ABL 直接引导）"
    fastboot flash boot "$BOOT"
fi

SIZE=$(du -h "$IMG" | cut -f1)
echo "==> 刷写 $IMG（$SIZE）到 userdata 分区"
fastboot flash userdata "$IMG"

if [ "$REBOOT" = 1 ]; then
    echo "==> 重启（首次启动会扩展嵌套 GPT 第 2 分区 → btrfs 扩容 → greetd/dux-greeter）"
    fastboot reboot
else
    echo "==> 已跳过 fastboot reboot（--no-reboot）"
    echo "    需要时手动：fastboot reboot"
fi

cat <<'EOS'

下一步：
  tools/wait-boot.sh                  # 等 172.16.42.1 的 SSH 就绪（默认 300s 超时）
  tools/device-test.sh                # 逐项 PASS/WARN/FAIL
  tools/device-test.sh --touch --sound # 现场测触控/音频（需人在设备旁）

刷完不能拔线太早：写入是同步完成的，但首次启动仍需要 1-3 分钟做分区扩容。
EOS
