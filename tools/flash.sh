#!/usr/bin/env bash
# 把镜像刷入 Redmi K20 Pro 的 userdata 分区
#   用法: sudo tools/flash.sh rootfs.img
# 前提: 设备已进入 fastboot（关机后 音量下+电源），且已刷入支持该引导链的 U-Boot
set -euo pipefail

IMG=${1:-}
[ -n "$IMG" ] || { echo "用法: $0 <rootfs.img>" >&2; exit 1; }
[ -f "$IMG" ] || { echo "镜像不存在: $IMG" >&2; exit 1; }

if ! fastboot devices | grep -qw fastboot; then
    echo "未检测到 fastboot 设备。请让设备进入 fastboot 模式：" >&2
    echo "  关机 → 按住 音量下 + 电源 → 出现 fastboot 界面" >&2
    fastboot devices >&2
    exit 1
fi

echo "==> 刷写 $IMG 到 userdata（$(du -h "$IMG" | cut -f1)）"
fastboot flash userdata "$IMG"
echo "==> 重启"
fastboot reboot
echo "完成。首次启动会：扩展内嵌 GPT 的第 2 分区 → btrfs 扩容 → 启动 greetd/dux-greeter"
echo "约 1-2 分钟后可用 USB 网卡登录：ssh <用户名>@172.16.42.1"
