#!/usr/bin/env bash
# ============================================================================
# tools/device-test.sh —— 通过 USB-NCM 登录 raphael，逐项验证硬件与桌面
#
# 用法: tools/device-test.sh [选项]
#   --host HOST   设备地址（默认 172.16.42.1；环境变量 HOST 可覆盖）
#   --user USER   SSH 用户（默认 user；环境变量 RUSER 可覆盖）
#   --pass PASS   SSH 密码（默认 1234；环境变量 RPASS 可覆盖）
#   --json        只往 stdout 输出机器可读 JSON（人类可读信息改写到 stderr）
#   --touch       额外做触控实测：提示在屏幕上滑动，统计 5 秒内 event 字节数
#   --sound       额外做音频实测：speaker-test 播约 1 秒 440Hz（注意音量）
#   -h, --help    显示本帮助
#
# 每项检查输出 PASS / WARN / FAIL 与证据行；退出码 0 = 无 FAIL，1 = 有 FAIL
# 除 --sound（放声音）与 --touch（只读 event 设备）外不做任何写操作
# 依赖: sshpass（pacman -S sshpass）
# ============================================================================
set -uo pipefail

HOST=${HOST:-172.16.42.1}
RUSER=${RUSER:-user}
RPASS=${RPASS:-1234}
JSON=0
DO_TOUCH=0
DO_SOUND=0

while [ $# -gt 0 ]; do
    case "$1" in
        --host)    HOST=${2:-}; shift 2 ;;
        --user)    RUSER=${2:-}; shift 2 ;;
        --pass)    RPASS=${2:-}; shift 2 ;;
        --json)    JSON=1; shift ;;
        --touch)   DO_TOUCH=1; shift ;;
        --sound)   DO_SOUND=1; shift ;;
        -h|--help) sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1（--help 看用法）" >&2; exit 2 ;;
    esac
done

command -v sshpass >/dev/null 2>&1 || {
    echo "缺少 sshpass（pacman -S sshpass），无法用密码登录设备" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# SSH 复用（一次认证，后续调用走 control socket，快很多）
# ---------------------------------------------------------------------------
CTL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/raphael-devtest.XXXXXX") || {
    echo "无法创建临时目录" >&2
    exit 1
}

SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=8
    -o ControlMaster=auto
    -o ControlPath="$CTL_DIR/ssh-%r@%h-%p"
    -o ControlPersist=60
)

cleanup() {
    ssh -O exit -o ControlPath="$CTL_DIR/ssh-%r@%h-%p" "$RUSER@$HOST" 2>/dev/null || true
    case "$CTL_DIR" in
        "${TMPDIR:-/tmp}"/raphael-devtest.*) rm -rf -- "$CTL_DIR" ;;
    esac
}
trap cleanup EXIT INT TERM

remote() {   # 设备上执行，stdout+stderr 都收
    sshpass -p "$RPASS" ssh "${SSH_OPTS[@]}" "$RUSER@$HOST" "$1" 2>&1
}

remote_q() { # 设备上执行，只收 stdout（命令不存在/无权限时给空）
    sshpass -p "$RPASS" ssh "${SSH_OPTS[@]}" "$RUSER@$HOST" "$1" 2>/dev/null
}

# 内核日志：优先 journalctl -k，退回 dmesg（dmesg 可能被 kernel.dmesg_restrict 限制）
klog() {
    local pat=$1 out
    out=$(remote_q "journalctl -b -k --no-pager 2>/dev/null | grep -iE '$pat' | tail -4")
    if [ -z "$out" ]; then
        out=$(remote_q "dmesg 2>/dev/null | grep -iE '$pat' | tail -4")
    fi
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# 输出 / 记录
# ---------------------------------------------------------------------------
NC=''
if [ -t 1 ] && [ "$JSON" = 0 ]; then NC=$'\033[0m'; fi

say() {  # --json 时人类可读信息走 stderr，保持 stdout 只有 JSON
    if [ "$JSON" = 1 ]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi
}

header() {
    [ "$JSON" = 1 ] && return 0
    printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

tr_nl() { local s=${1-}; s=${s//$'\n'/ | }; printf '%s' "$s"; }

je() {  # JSON 转义
    local s=${1-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\033'/}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/}
    s=${s//$'\n'/\\n}
    printf '%s' "$s"
}

PASS_N=0
WARN_N=0
FAIL_N=0
C_ID=()
C_ST=()
C_DT=()
C_EV=()

add_check() {  # id 状态 说明 [证据行...]
    local id=$1 st=$2 dt=$3
    shift 3
    local ev='' e
    for e in "$@"; do [ -n "$e" ] && ev="$ev$e"$'\n'; done
    C_ID+=("$id")
    C_ST+=("$st")
    C_DT+=("$dt")
    C_EV+=("$ev")
    case "$st" in
        PASS) PASS_N=$((PASS_N + 1)) ;;
        WARN) WARN_N=$((WARN_N + 1)) ;;
        *)    FAIL_N=$((FAIL_N + 1)) ;;
    esac
    [ "$JSON" = 1 ] && return 0
    local color=''
    case "$st" in
        PASS) color=$'\033[32m' ;;
        WARN) color=$'\033[33m' ;;
        *)    color=$'\033[31m' ;;
    esac
    printf '  %s[%s]%s %-18s %s\n' "$color" "$st" "$NC" "$id" "$(tr_nl "$dt")"
    if [ -n "$ev" ]; then
        while IFS= read -r e; do
            [ -n "$e" ] && printf '         · %s\n' "$(tr_nl "$e")"
        done <<<"$ev"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 各检查段
# ---------------------------------------------------------------------------
sec_system() {
    header "系统"
    local pretty kernel cmdline up
    pretty=$(remote_q '. /etc/os-release 2>/dev/null; printf "%s" "${PRETTY_NAME:-unknown}"')
    if [ -n "$pretty" ] && [ "$pretty" != unknown ]; then
        add_check system.os PASS "$pretty"
    else
        add_check system.os WARN "读不到 /etc/os-release 的 PRETTY_NAME"
    fi
    kernel=$(remote_q 'uname -r')
    cmdline=$(remote_q 'cat /proc/cmdline 2>/dev/null')
    if [ -n "$kernel" ]; then
        add_check system.kernel PASS "内核 $kernel" "cmdline: $cmdline"
    else
        add_check system.kernel FAIL "uname -r 无输出"
    fi
    up=$(remote_q 'cut -d. -f1 /proc/uptime 2>/dev/null')
    if is_num "$up"; then
        add_check system.uptime PASS "已开机 ${up}s"
    else
        add_check system.uptime WARN "读不到 /proc/uptime"
    fi
}

sec_rootfs() {
    header "根文件系统（btrfs + 首启扩容）"
    local mnt dfh fssize devsize pct
    mnt=$(remote_q 'findmnt -no FSTYPE,OPTIONS / 2>/dev/null')
    dfh=$(remote_q 'df -h / 2>/dev/null | tail -1')
    case "$mnt" in
        btrfs*) add_check rootfs.mount PASS "根是 btrfs" "$mnt" "$dfh" ;;
        '')     add_check rootfs.mount FAIL "findmnt 无输出" ;;
        *)      add_check rootfs.mount WARN "根文件系统不是 btrfs：$mnt" "$dfh" ;;
    esac
    if [ "$(remote_q 'test -e /var/lib/raphael-growfs.done && echo yes')" = yes ]; then
        add_check rootfs.grown PASS "首启扩容标记 /var/lib/raphael-growfs.done 存在"
    else
        add_check rootfs.grown WARN "没有首启扩容标记（services 没跑完？）" \
            "手工补：sudo btrfs filesystem resize max /"
    fi
    fssize=$(remote_q 'df -B1 --output=size / 2>/dev/null | tail -1 | tr -d " "')
    devsize=$(remote_q 's=$(findmnt -no SOURCE /); blockdev --getsize64 "$s" 2>/dev/null || echo 0')
    if is_num "$fssize" && is_num "$devsize" && [ "$devsize" -gt 0 ]; then
        pct=$((fssize * 100 / devsize))
        if [ "$pct" -ge 90 ]; then
            add_check rootfs.size PASS "文件系统已占分区 ${pct}%（$((fssize / 1073741824))G / $((devsize / 1073741824))G）"
        else
            add_check rootfs.size WARN "文件系统只占分区 ${pct}%（$((fssize / 1073741824))G / $((devsize / 1073741824))G）" \
                "手工补：sudo btrfs filesystem resize max /"
        fi
    else
        add_check rootfs.size WARN "读不到分区/文件系统大小"
    fi
}

sec_display() {
    header "显示（DSI 面板 / DRM）"
    local dri dsi modes kl
    dri=$(remote_q 'ls /dev/dri 2>/dev/null | tr "\n" " "')
    case "$dri" in
        *card[0-9]*) add_check display.dri PASS "/dev/dri: $dri" ;;
        '')          add_check display.dri FAIL "/dev/dri 下没有 card 节点（GPU 驱动没起来）" ;;
        *)           add_check display.dri WARN "/dev/dri 里没有 card 节点：$dri" ;;
    esac
    dsi=$(remote_q 'for d in /sys/class/drm/card*-DSI-*; do [ -r "$d/status" ] || continue; printf "%s=%s " "${d##*/}" "$(cat "$d/status")"; done')
    if printf '%s\n' "$dsi" | tr ' ' '\n' | grep -q '=connected$'; then
        add_check display.connector PASS "$dsi"
    elif [ -z "$dsi" ]; then
        add_check display.connector FAIL "没有 DSI 连接器节点（面板驱动缺失？）"
    else
        add_check display.connector WARN "DSI 未 connected：$dsi"
    fi
    modes=$(remote_q 'head -3 /sys/class/drm/card*-DSI-*/modes 2>/dev/null | tr "\n" " "')
    if [ -n "$modes" ]; then
        add_check display.modes PASS "可用模式：$modes"
    else
        add_check display.modes WARN "读不到 DSI 模式列表（面板可能未初始化）"
    fi
    kl=$(klog 'adreno|msm_drm|dpu|dsi')
    if [ -n "$kl" ]; then
        add_check display.kernel PASS "内核日志有显示相关行" "$kl"
    else
        add_check display.kernel WARN "内核日志没有 adreno/msm_drm/dpu/dsi 行"
    fi
}

# 读 /dev/input/eventN 的字节数：先按当前用户读，不行再用 RPASS 提权
touch_bytes() {
    local ev=$1 pwdq
    if [ -n "$(remote_q "test -r /dev/input/$ev && echo r")" ]; then
        remote_q "timeout 5 cat /dev/input/$ev 2>/dev/null | wc -c"
        return 0
    fi
    pwdq=$(printf '%s' "$RPASS" | sed "s/'/'\\\\''/g")
    remote_q "printf '%s\n' '${pwdq}' | sudo -S -p '' timeout 5 cat /dev/input/$ev 2>/dev/null | wc -c"
}

sec_touch() {
    header "触控"
    local dump table all line ev name flags block perm kl bytes node
    dump=$(remote_q 'cat /proc/bus/input/devices 2>/dev/null')
    if [ -z "$dump" ]; then
        add_check touch.input FAIL "读不到 /proc/bus/input/devices"
        return 0
    fi
    # 设备块里取 N:Name / H:Handlers / B:PROP；PROP 的 bit1(INPUT_PROP_DIRECT)=触控屏
    table=$(printf '%s\n' "$dump" | awk '
        BEGIN { RS=""; FS="\n" }
        {
            name=""; hand=""; prop=""
            for (i=1;i<=NF;i++) {
                l=$i
                if (l ~ /^N: Name=/) { name=l; sub(/^N: Name="/,"",name); sub(/"$/,"",name) }
                else if (l ~ /^H: Handlers=/) { hand=l; sub(/^H: Handlers=/,"",hand) }
                else if (l ~ /^B: PROP=/) { prop=l; sub(/^B: PROP=/,"",prop) }
            }
            ev=""
            n=split(hand, h, " ")
            for (i=1;i<=n;i++) if (h[i] ~ /^event[0-9]+$/) { ev=h[i]; break }
            if (ev == "") next
            flag=""
            if (prop != "") {
                lasthex=tolower(substr(prop, length(prop), 1))
                if (lasthex ~ /[2367abef]/) flag="direct"
            }
            lname=tolower(name)
            if (lname ~ /goodix|gt9|focaltech|ft5|atmel|synaptics|novatek|nt36|hx83|touch/) {
                flag=(flag == "" ? "name" : flag ",name")
            }
            printf "%s\t%s\t%s\n", ev, name, flag
        }')
    all=$(printf '%s\n' "$table" | awk -F'\t' 'NF {printf "%s(%s) ", $1, $2}')
    line=$(printf '%s\n' "$table" | awk -F'\t' '$3 ~ /direct/ {print; exit}')
    if [ -z "$line" ]; then
        line=$(printf '%s\n' "$table" | awk -F'\t' '$3 != "" {print; exit}')
    fi
    ev=$(printf '%s' "$line" | cut -f1)
    name=$(printf '%s' "$line" | cut -f2)
    flags=$(printf '%s' "$line" | cut -f3)

    if [ -z "$ev" ]; then
        add_check touch.input FAIL "没在 /proc/bus/input/devices 里找到触控设备" "$all"
        add_check touch.node WARN "没有 event 节点可查"
        add_check touch.events WARN "没有触控设备，未实测"
        kl=$(klog 'goodix|gt9886|gt9916|fts|novatek|touchscreen')
        if [ -n "$kl" ]; then
            add_check touch.driver PASS "内核日志有触控相关行" "$kl"
        else
            add_check touch.driver WARN "内核日志没有 goodix/gt9886/touchscreen 行"
        fi
        return 0
    fi

    block=$(printf '%s\n' "$dump" | awk -v n="$name" 'BEGIN { RS="" } index($0, "N: Name=\"" n "\"") { print; exit }')
    add_check touch.input PASS "$name → /dev/input/$ev（${flags:-仅按名字命中}）" "$all" "$block"
    node="/dev/input/$ev"
    perm=$(remote_q "ls -l $node 2>/dev/null | awk '{print \$1, \$3, \$4}'")
    if [ -n "$perm" ]; then
        add_check touch.node PASS "$node 存在（$perm）"
    else
        add_check touch.node FAIL "$node 不存在"
    fi
    kl=$(klog 'goodix|gt9886|gt9916|fts|novatek|touchscreen')
    if [ -n "$kl" ]; then
        add_check touch.driver PASS "内核日志有触控相关行" "$kl"
    else
        add_check touch.driver WARN "内核日志没有 goodix/gt9886/touchscreen 行"
    fi

    if [ "$DO_TOUCH" = 0 ]; then
        add_check touch.events WARN "未实测（加 --touch 现场滑动测试）"
        return 0
    fi
    if [ -z "$(remote_q 'command -v timeout')" ]; then
        add_check touch.events WARN "设备上没有 timeout 命令，无法限时采集"
        return 0
    fi
    say ""
    say ">>> 触控实测：用 $node（$name）"
    say ">>> 请在设备屏幕上用手指来回滑动约 3 秒（本地采集窗口 5 秒）..."
    bytes=$(touch_bytes "$ev")
    if is_num "$bytes" && [ "$bytes" -gt 0 ]; then
        add_check touch.events PASS "5 秒内采到 ${bytes} 字节 input 事件（触控有上报）"
    elif is_num "$bytes"; then
        add_check touch.events FAIL "5 秒内 0 字节（没有触控事件）" \
            "确认手指真的在屏幕上滑动（不是滑边框/黑边）" \
            "手工复核：sudo timeout 5 cat $node | wc -c"
    else
        add_check touch.events FAIL "采集失败：$(tr_nl "$bytes")" \
            "手工复核：sudo timeout 5 cat $node | wc -c"
    fi
}

sound_test() {
    say ""
    if [ -z "$(remote_q 'command -v speaker-test')" ]; then
        add_check audio.tone WARN "镜像里没有 speaker-test（alsa-utils）" \
            "可选：sudo pacman -S alsa-utils 后重试" \
            "或用桌面会话里的播放器（mpv/pw-play）放任意音频确认"
        return 0
    fi
    say ">>> 音频实测：用 speaker-test 播约 1 秒 440Hz 正弦波（默认音量，别贴耳）..."
    local res rc out
    res=$(remote_q 'o=$(timeout 15 speaker-test -t sine -f 440 -l 1 -c 2 2>&1); echo "rc=$?"; printf "%s\n" "$o" | tail -4')
    rc=$(printf '%s\n' "$res" | sed -n 's/^rc=//p' | head -1)
    out=$(printf '%s\n' "$res" | sed '/^rc=/d')
    if [ "$rc" = 0 ]; then
        add_check audio.tone PASS "speaker-test 播放完成（rc=0）" "$out"
    elif is_num "$rc"; then
        add_check audio.tone FAIL "speaker-test 失败（rc=$rc）" "$out" \
            "手工定位：speaker-test -D plughw:0,0 -t sine -f 440 -l 1" \
            "aplay -l 看设备号；wpctl status 看默认 sink"
    else
        add_check audio.tone WARN "speaker-test 输出异常，无法判断" "$res"
    fi
}

sec_audio() {
    header "音频"
    local cards ctl wp kl
    if [ -z "$(remote_q 'command -v aplay')" ]; then
        cards=$(remote_q 'cat /proc/asound/cards 2>/dev/null')
        add_check audio.cards WARN "镜像里没有 aplay（alsa-utils），改看 /proc/asound/cards" "$cards"
    else
        cards=$(remote_q 'aplay -l 2>&1 | head -10')
        if printf '%s\n' "$cards" | grep -qE '^card [0-9]+:'; then
            add_check audio.cards PASS "ALSA 声卡已注册" "$cards"
        elif printf '%s\n' "$cards" | grep -qi 'no soundcards'; then
            add_check audio.cards FAIL "aplay -l 报 no soundcards（声卡没被识别）" "$cards"
        else
            add_check audio.cards WARN "aplay -l 输出里没有 card 行" "$cards"
        fi
    fi
    ctl=$(remote_q 'command -v amixer >/dev/null 2>&1 && amixer scontrols 2>/dev/null | head -6')
    if [ -n "$ctl" ]; then
        add_check audio.mixer PASS "amixer 有可调控件" "$ctl"
    else
        add_check audio.mixer WARN "没有 amixer 或没有 scontrols（音量控件未暴露）"
    fi
    wp=$(remote_q 'command -v wpctl >/dev/null 2>&1 && wpctl status 2>/dev/null | head -12')
    if [ -n "$wp" ]; then
        add_check audio.pipewire PASS "wpctl status 可用" "$wp"
    else
        add_check audio.pipewire WARN "wpctl 不可用（PipeWire 未起，或 SSH 会话看不到用户总线）" \
            "登录桌面后再跑；或 ssh 后试 XDG_RUNTIME_DIR=/run/user/$(id -u) wpctl status"
    fi
    kl=$(klog 'wcd938x|wsa881x|adsp|q6|apr')
    if [ -n "$kl" ]; then
        add_check audio.kernel PASS "内核日志有音频编解码/DSP 行" "$kl"
    else
        add_check audio.kernel WARN "内核日志没有 wcd938x/wsa881x/adsp/q6 行"
    fi
    [ "$DO_SOUND" = 1 ] && sound_test
    return 0
}

sec_wireless() {
    header "无线 / 蓝牙"
    local wl ipb kl hci rf
    wl=$(remote_q 'ls /sys/class/net 2>/dev/null | grep -E "^(wl|wlan)" | tr "\n" " "')
    ipb=$(remote_q 'ip -br link 2>/dev/null | head -6')
    if [ -n "$wl" ]; then
        add_check wifi.iface PASS "无线接口：$wl" "$ipb"
    else
        add_check wifi.iface FAIL "没有 wl*/wlan* 接口（ath10k/WCN3990 没起来）" "$ipb" \
            "查：dmesg | grep -i ath10k；rfkill list"
    fi
    kl=$(klog 'ath10k|wcn3990|cnss|cfg80211')
    if [ -n "$kl" ]; then
        add_check wifi.driver PASS "内核日志有无线相关行" "$kl"
    else
        add_check wifi.driver WARN "内核日志没有 ath10k/wcn3990/cnss 行"
    fi
    hci=$(remote_q 'ls /sys/class/bluetooth 2>/dev/null | tr "\n" " "')
    if [ -n "$hci" ]; then
        add_check bt.hci PASS "蓝牙控制器：$hci"
    else
        add_check bt.hci WARN "没有 /sys/class/bluetooth 下的 hci 设备"
    fi
    rf=$(remote_q 'rfkill list 2>/dev/null | head -8')
    if [ -n "$rf" ]; then
        if printf '%s\n' "$rf" | grep -q 'blocked: yes'; then
            add_check radio.rfkill WARN "有射频被 block" "$rf"
        else
            add_check radio.rfkill PASS "rfkill 无 block" "$rf"
        fi
    else
        add_check radio.rfkill WARN "rfkill 不可用（没装 util-linux 或没有射频设备）"
    fi
}

sec_power() {
    header "电池 / 充电"
    local ps
    ps=$(remote_q 'for d in /sys/class/power_supply/*; do [ -d "$d" ] || continue; printf "%s status=%s cap=%s online=%s\n" "${d##*/}" "$(cat "$d/status" 2>/dev/null)" "$(cat "$d/capacity" 2>/dev/null)" "$(cat "$d/online" 2>/dev/null)"; done')
    if printf '%s\n' "$ps" | grep -q 'cap=[0-9]'; then
        add_check power.battery PASS "电池信息可读" "$ps"
    elif [ -n "$ps" ]; then
        add_check power.battery WARN "有 power_supply 节点但没有 capacity" "$ps"
    else
        add_check power.battery FAIL "没有 /sys/class/power_supply 节点"
    fi
    if printf '%s\n' "$ps" | grep -qi 'status=charging'; then
        add_check power.charging PASS "正在充电（USB 供电正常）"
    else
        add_check power.charging WARN "没看到 Charging 状态（可能已充满或 USB 未供电）" "$ps"
    fi
}

sec_desktop() {
    header "桌面 / 登录界面"
    local failed act greeter comp shell kbd sess
    failed=$(remote_q 'systemctl --failed --no-legend --no-pager 2>/dev/null | head -6')
    if [ -z "$failed" ]; then
        add_check desktop.failed PASS "没有 failed 的 systemd 单元"
    else
        add_check desktop.failed FAIL "有失败的 systemd 单元" "$failed" \
            "查：systemctl status <unit>；journalctl -u <unit> -b"
    fi
    act=$(remote_q 'systemctl is-active greetd 2>/dev/null')
    greeter=$(remote_q 'pgrep -a dms-greeter 2>/dev/null | head -2; pgrep -a dux-greeter 2>/dev/null | head -2')
    if [ "$act" = active ]; then
        add_check desktop.greetd PASS "greetd 是 active" "$greeter"
    else
        add_check desktop.greetd FAIL "greetd 不是 active（当前：${act:-unknown}）" \
            "$(remote_q 'systemctl status greetd --no-pager 2>/dev/null | tail -6')"
    fi
    if [ -n "$greeter" ]; then
        add_check desktop.greeter PASS "greeter 进程在跑" "$greeter"
    else
        add_check desktop.greeter WARN "没看到 dms-greeter/dux-greeter（可能已登录进用户会话）"
    fi
    comp=$(remote_q 'pgrep -a niri 2>/dev/null | head -2; pgrep -a sway 2>/dev/null | head -2')
    if [ -n "$comp" ]; then
        add_check desktop.compositor PASS "合成器在跑" "$comp"
    else
        add_check desktop.compositor WARN "没看到 niri/sway 进程"
    fi
    shell=$(remote_q 'pgrep -a -x dms 2>/dev/null | head -2')
    if [ -n "$shell" ]; then
        add_check desktop.shell PASS "dux-shell(dms) 在跑" "$shell"
    else
        add_check desktop.shell WARN "没看到 dms 进程（登录后才会起）"
    fi
    kbd=$(remote_q 'pgrep -a squeekboard 2>/dev/null | head -2')
    if [ -n "$kbd" ]; then
        add_check desktop.keyboard PASS "虚拟键盘 squeekboard 在跑" "$kbd"
    else
        add_check desktop.keyboard WARN "没看到 squeekboard（触摸输入需要它）"
    fi
    sess=$(remote_q 'loginctl list-sessions --no-legend 2>/dev/null | head -4')
    if [ -n "$sess" ]; then
        add_check desktop.session PASS "有登录会话" "$sess"
    else
        add_check desktop.session WARN "loginctl 没有会话（还停在登录界面）"
    fi
}

sec_logs() {
    header "错误日志"
    local err n
    err=$(remote_q 'journalctl -b -p err --no-pager 2>/dev/null | tail -10')
    if [ -z "$err" ]; then
        add_check log.err PASS "本次启动没有 err 级日志"
    else
        n=$(printf '%s\n' "$err" | grep -c .)
        add_check log.err WARN "本次启动有 ${n} 行 err 级日志（不一定是硬件问题）" "$err"
    fi
}

# ---------------------------------------------------------------------------
# 汇总 / JSON
# ---------------------------------------------------------------------------
json_out() {
    local i ev sep first=1
    printf '{\n'
    printf '  "schema": 1,\n'
    printf '  "generated": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "host": "%s",\n' "$(je "$HOST")"
    printf '  "user": "%s",\n' "$(je "$RUSER")"
    printf '  "connected": true,\n'
    printf '  "counts": {"pass": %d, "warn": %d, "fail": %d},\n' "$PASS_N" "$WARN_N" "$FAIL_N"
    printf '  "checks": [\n'
    for i in "${!C_ID[@]}"; do
        if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
        printf '    {"id": "%s", "status": "%s", "detail": "%s", "evidence": [' \
            "$(je "${C_ID[i]}")" "$(je "${C_ST[i]}")" "$(je "${C_DT[i]}")"
        sep=''
        while IFS= read -r ev; do
            [ -n "$ev" ] || continue
            printf '%s"%s"' "$sep" "$(je "$ev")"
            sep=', '
        done <<<"${C_EV[i]}"
        printf ']}'
    done
    printf '\n  ]\n}\n'
}

summary() {
    local total=$((PASS_N + WARN_N + FAIL_N))
    if [ "$JSON" = 1 ]; then
        json_out
    else
        printf '\n汇总：PASS %d / WARN %d / FAIL %d（共 %d 项）\n' "$PASS_N" "$WARN_N" "$FAIL_N" "$total"
        if [ "$FAIL_N" -gt 0 ]; then
            printf '有 FAIL：先看对应证据行；触控/音频实测用 --touch / --sound\n'
        elif [ "$WARN_N" -gt 0 ]; then
            printf '无 FAIL；WARN 多为「未实测」或「环境不具备」，按提示补测\n'
        fi
    fi
    [ "$FAIL_N" -eq 0 ]
}

main() {
    local hint=''
    if [ "$(remote_q 'echo connected')" != connected ]; then
        if command -v fastboot >/dev/null 2>&1 && fastboot devices 2>/dev/null | grep -q fastboot; then
            hint='设备仍在 fastboot：先 fastboot reboot，或 tools/flash.sh 重刷后跑 tools/wait-boot.sh'
        else
            hint='设备可能没起来：跑 tools/wait-boot.sh 看卡在哪一步'
        fi
        if [ "$JSON" = 1 ]; then
            printf '{"schema": 1, "generated": "%s", "host": "%s", "user": "%s", "connected": false, "error": "ssh 连接失败", "hint": "%s", "counts": {"pass": 0, "warn": 0, "fail": 1}, "checks": []}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(je "$HOST")" "$(je "$RUSER")" "$(je "$hint")"
        else
            printf '无法通过 SSH 连接 %s@%s\n' "$RUSER" "$HOST" >&2
            printf '%s\n' "$hint" >&2
            printf '（设备侧检查：usb-ncm.service / dnsmasq / sshd；见 docs/INSTALL.md 第 7 节）\n' >&2
        fi
        return 1
    fi

    sec_system
    sec_rootfs
    sec_display
    sec_touch
    sec_audio
    sec_wireless
    sec_power
    sec_desktop
    sec_logs
    summary
}

main
exit $?
