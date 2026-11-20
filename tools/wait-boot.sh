#!/usr/bin/env bash
# ============================================================================
# tools/wait-boot.sh —— 刷写后轮询，等设备的 USB-NCM(172.16.42.1) SSH 就绪
#
# 用法: tools/wait-boot.sh [选项]
#   --host HOST      设备地址（默认 172.16.42.1；环境变量 HOST 可覆盖）
#   --user USER      SSH 用户（默认 user；环境变量 RUSER 可覆盖）
#   --pass PASS      SSH 密码（默认 1234；环境变量 RPASS 可覆盖）
#   --timeout SEC    总超时秒数（默认 300；环境变量 TIMEOUT 可覆盖）
#   --interval SEC   轮询间隔秒数（默认 3）
#   -q, --quiet      不打印中间进度，只在就绪/超时时输出
#   -h, --help       显示本帮助
#
# 退出码: 0 = SSH 可用；1 = 超时/失败；2 = 用法错误
# 依赖: sshpass（pacman -S sshpass）
#
# 只做只读检查（fastboot devices / ip / lsusb），不会刷写或重启设备。
# ============================================================================
set -uo pipefail

HOST=${HOST:-172.16.42.1}
RUSER=${RUSER:-user}
RPASS=${RPASS:-1234}
TIMEOUT=${TIMEOUT:-300}
INTERVAL=${INTERVAL:-3}
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --host)     HOST=${2:-}; shift 2 ;;
        --user)     RUSER=${2:-}; shift 2 ;;
        --pass)     RPASS=${2:-}; shift 2 ;;
        --timeout)  TIMEOUT=${2:-}; shift 2 ;;
        --interval) INTERVAL=${2:-}; shift 2 ;;
        -q|--quiet) QUIET=1; shift ;;
        -h|--help)  sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1（--help 看用法）" >&2; exit 2 ;;
    esac
done

case "$TIMEOUT" in ''|*[!0-9]*|0) echo "--timeout 需为正整数，当前: $TIMEOUT" >&2; exit 2 ;; esac
case "$INTERVAL" in ''|*[!0-9]*|0) echo "--interval 需为正整数，当前: $INTERVAL" >&2; exit 2 ;; esac

command -v sshpass >/dev/null 2>&1 || {
    echo "缺少 sshpass（pacman -S sshpass），无法用密码登录设备" >&2
    exit 1
}

SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
)

info() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

# 本机上 172.16.42.x 的地址（设备侧 dnsmasq 分配的 DHCP 地址）
host_ip() {
    ip -4 -o addr show 2>/dev/null | awk '{print $4}' | grep -m1 '^172\.16\.42\.' || true
}

tcp_open() {
    timeout 2 bash -c "exec 3<>/dev/tcp/${HOST}/22" 2>/dev/null
}

ssh_ok() {
    local out
    out=$(sshpass -p "$RPASS" ssh "${SSH_OPTS[@]}" "$RUSER@$HOST" 'echo READY' 2>/dev/null)
    [ "$out" = READY ]
}

# 返回 0=就绪 1=网卡在但端口未开 2=本机无 NCM 网卡 3=端口开但认证失败
PHASE=''
probe() {
    if [ -z "$(host_ip)" ]; then
        PHASE="本机没有 172.16.42.x 地址（USB-NCM 未枚举）"
        return 2
    fi
    if ssh_ok; then
        PHASE='SSH 可用'
        return 0
    fi
    if tcp_open; then
        PHASE="$HOST:22 已监听，但 SSH 登录失败（用户名/密码不对？）"
        return 3
    fi
    PHASE="网卡已就绪，$HOST:22 未监听（内核/initramfs 仍在启动）"
    return 1
}

echo "==> 等待 $RUSER@$HOST 的 SSH（超时 ${TIMEOUT}s，间隔 ${INTERVAL}s）"
START=$(date +%s)
LAST_REPORT=-10
PHASE_SEEN=''
RC=1

while :; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START))
    RC=0
    probe || RC=$?
    [ "$RC" -eq 0 ] && break
    [ "$ELAPSED" -ge "$TIMEOUT" ] && break
    if [ "$QUIET" = 0 ] && { [ "$PHASE" != "$PHASE_SEEN" ] || [ $((ELAPSED - LAST_REPORT)) -ge 15 ]; }; then
        printf '  [%3ss] %s\n' "$ELAPSED" "$PHASE"
        LAST_REPORT=$ELAPSED
        PHASE_SEEN=$PHASE
    fi
    sleep "$INTERVAL"
done

ELAPSED=$(( $(date +%s) - START ))

if [ "$RC" -eq 0 ]; then
    echo "==> SSH 就绪：$RUSER@$HOST（用时 ${ELAPSED}s）"
    sshpass -p "$RPASS" ssh "${SSH_OPTS[@]}" "$RUSER@$HOST" '
        . /etc/os-release 2>/dev/null
        printf "    系统: %s\n" "${PRETTY_NAME:-unknown}"
        printf "    内核: %s\n" "$(uname -r)"
        printf "    greetd=%s  niri=%s\n" "$(systemctl is-active greetd 2>/dev/null)" "$(pgrep -c niri 2>/dev/null)"
    ' 2>/dev/null
    echo
    echo "下一步："
    echo "  tools/device-test.sh --user $RUSER                 # 逐项只读检查"
    echo "  tools/device-test.sh --user $RUSER --touch --sound # 加触控/音频实测（需人在设备旁）"
    exit 0
fi

# ---------------- 超时：给出可执行的下一步 ----------------
echo >&2
echo "==> 超时：${TIMEOUT}s 内没等到 $HOST 的 SSH（最后状态：$PHASE）" >&2
echo >&2
echo "只读自查（不刷写）：" >&2
if command -v fastboot >/dev/null 2>&1 && fastboot devices 2>/dev/null | grep -q fastboot; then
    echo "  · fastboot devices 仍能看到设备 → 还停在 fastboot，没进系统" >&2
else
    echo "  · fastboot devices 无输出（设备不在 fastboot）" >&2
fi
if [ -n "$(host_ip)" ]; then
    echo "  · 本机 NCM 地址：$(host_ip)" >&2
else
    echo "  · 本机没有 172.16.42.x 地址（USB 网卡没枚举）" >&2
fi
if command -v lsusb >/dev/null 2>&1; then
    echo "  · lsusb：$(lsusb 2>/dev/null | grep -iE '18d1|2717|xiaomi|google|cdc|network' | head -3 | paste -sd';' -)" >&2
fi
cat >&2 <<'EOS'

按下面顺序排查：
 1) 设备还停在 fastboot（fastboot devices 有序列号）
      fastboot reboot                     # 只是重启，先试这个
      sudo tools/flash.sh rootfs.img      # 若确实没写进去（会清空 userdata）
      tools/wait-boot.sh                  # 刷完再等

 2) 本机没有 172.16.42.x 网卡（USB NCM 未枚举）
      - 换数据线、直插主板 USB 口（不要 hub），重新插拔；
      - 本机查 dmesg | tail -20 里有没有 cdc_ncm / usb0；
      - lsusb 出现 18d1:d00d 说明还在 fastboot，设备没进系统。

 3) 有网卡但 22 端口不通（设备可能掉在 initramfs rescue shell）
      - 接 OTG 键盘 / Type-C 转 HDMI 看屏幕提示；
      - 按 docs/INSTALL.md 第 7 节 initramfs 排障处理。

 4) 完全无反应（黑屏、PC 不枚举任何设备）
      - 长按电源键 10s 强制断电，再「音量下 + 电源」进 fastboot；
      - 见 docs/INSTALL.md 第 13 节。

首次启动本来就要 1-3 分钟（扩分区 + btrfs 扩容），等不及可加大超时：
      tools/wait-boot.sh --timeout 600
EOS
exit 1
