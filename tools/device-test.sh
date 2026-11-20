#!/usr/bin/env bash
# 通过 USB NCM 登录设备，检查触控/显示/音频/无线/电池/桌面服务是否正常
#   用法: tools/device-test.sh [--user user] [--pass 1234] [--host 172.16.42.1]
# 依赖: sshpass
set -uo pipefail

HOST=${HOST:-172.16.42.1}
RUSER=${RUSER:-user}
RPASS=${RPASS:-1234}

while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST=${2:-}; shift 2 ;;
        --user) RUSER=${2:-}; shift 2 ;;
        --pass) RPASS=${2:-}; shift 2 ;;
        -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

command -v sshpass >/dev/null 2>&1 || { echo "需要 sshpass（pacman -S sshpass）" >&2; exit 1; }

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8)

remote() {
    sshpass -p "$RPASS" ssh "${SSH_OPTS[@]}" "$RUSER@$HOST" "$1" 2>&1
}

echo "==> 连接 $RUSER@$HOST"
if ! remote 'echo connected' | grep -q connected; then
    echo "无法通过 SSH 连接。检查：设备是否已开机 / USB 线 / 是否已启动 usb-ncm.service" >&2
    exit 1
fi

PASS=0; WARN=0; FAILN=0
ok() { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { FAILN=$((FAILN+1)); printf '  \033[31m✗\033[0m %s\n' "$*"; }
warn() { WARN=$((WARN+1)); printf '  \033[33m!\033[0m %s\n' "$*"; }

check() {
    local desc="$1" cmd="$2"
    if remote "$cmd" 2>/dev/null | grep -q .; then ok "$desc"; else bad "$desc"; fi
}

echo
echo "===== 系统 ====="
remote '. /etc/os-release; echo "$PRETTY_NAME"'
remote 'uname -r; cat /proc/cmdline'
echo
echo "===== 根文件系统（btrfs 子卷 + 扩容）====="
remote 'findmnt -no FSTYPE,OPTIONS /; df -h / | tail -1'
if remote 'btrfs filesystem usage / 2>/dev/null | grep -i "device size"' >/dev/null 2>&1; then
    remote 'btrfs filesystem usage / 2>/dev/null | head -4'
fi
if remote 'ls /var/lib/raphael-growfs.done' >/dev/null 2>&1; then ok "首启扩容已完成"; else warn "首启扩容标记未生成（可能未跑或未完成）"; fi

echo
echo "===== 显示 ====="
remote 'for d in /sys/class/drm/card*-DSI-*; do printf "%s %s\n" "$d" "$(cat $d/status 2>/dev/null)"; done'
remote 'ls /dev/dri 2>/dev/null'
if remote 'ls /sys/class/drm/card*-DSI-*/modes 2>/dev/null | head -1' | grep -q modes; then
    remote 'head -3 /sys/class/drm/card*-DSI-*/modes 2>/dev/null'
else
    warn "未读到 DSI 模式（面板可能未点亮）"
fi
remote 'journalctl -b -k --no-pager 2>/dev/null | grep -iE "adreno|msm|dpu|dsi" | tail -5'

echo
echo "===== 触控 ====="
remote 'grep -iE "Name=|Handlers=" /proc/bus/input/devices | head -20'
if remote 'journalctl -b -k --no-pager 2>/dev/null | grep -iE "goodix|gt9886|touchscreen" | tail -5' | grep -qi goodix; then
    ok "touchscreen 驱动已加载（goodix）"
else
    warn "内核日志未见到 goodix 触控（可能用别的驱动）"
fi
remote 'ls -l /dev/input/event* 2>/dev/null | head -8'

echo
echo "===== 音频 ====="
remote 'aplay -l 2>&1 | head -10'
remote 'journalctl -b -k --no-pager 2>/dev/null | grep -iE "snd|wcd|adsp|q6|apr" | tail -6'
if remote 'command -v wpctl >/dev/null && wpctl status 2>/dev/null | head -5' | grep -q .; then
    remote 'wpctl status 2>/dev/null | head -12'
else
    warn "WirePlumber/PipeWire 未运行（桌面会话未起？）"
fi

echo
echo "===== 无线 / 蓝牙 ====="
remote 'ip -br link 2>/dev/null | head -6'
remote 'journalctl -b -k --no-pager 2>/dev/null | grep -iE "ath10k|wcn3990|hci" | tail -5'
remote 'rfkill list 2>/dev/null | head -6'

echo
echo "===== 电池 / 充电 ====="
remote 'for p in /sys/class/power_supply/*; do echo "$p"; cat $p/uevent 2>/dev/null | grep -E "POWER_SUPPLY_(NAME|STATUS|CAPACITY|ONLINE)="; done'

echo
echo "===== 桌面 / 登录界面 ====="
remote 'systemctl --failed --no-legend --no-pager 2>/dev/null | head -10'
remote 'systemctl is-active greetd 2>/dev/null; pgrep -a dms-greeter | head -2; pgrep -a quickshell | head -2; pgrep -a squeekboard | head -2'
remote 'systemctl --user is-active dms 2>/dev/null || true'

echo
echo "===== 最近的错误日志 ====="
remote 'journalctl -b -p err --no-pager 2>/dev/null | tail -12'

echo
echo "汇总：PASS $PASS / WARN $WARN / FAIL $FAILN"
[ "$FAILN" -eq 0 ]
