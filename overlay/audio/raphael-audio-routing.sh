#!/bin/bash
# Raphael 音频路由 / 耳机自动切换 (由 raphael-audio-routing.timer 每 5 秒调用)
#
# 2026-10-15 真机结论(三条都是实测踩出来的):
#  1) 只在**值确实不同**时才写 mixer —— 无条件 cset 会打断正在播放的流。
#     实测: routing 每 20 秒无条件写一次, 导致 paplay 卡了 6 分 36 秒(文件才 2 秒),
#     sink-input 一直挂着不释放。
#  2) **不能**把 SLIMBUS_0_RX(WCD9340 耳机)和 QUAT_MI2S_RX(TFA9874 扬声器)
#     同时挂在 MultiMedia1 上: 音频会同时走两个后端, 播放**稳定卡死**
#     (连测 3/3 返回 124)。
#  3) 所以按**耳机插入状态**二选一:
#       插耳机 -> SLIMBUS_0_RX 开(需先给 HPH 通路 DAPM 上电) + 扬声器 mixer 关
#       没插   -> 只开 QUAT_MI2S_RX(底部扬声器) + 耳机路由关
#     插入状态读 ALSA 的 CARD 级 jack 控件: iface=CARD,name="Headset Jack"
#     (驱动是 snd_soc_wcd_mbhc, 另有输入设备 "Raphael Headset Jack" /dev/input/event4)
#  4) ★ 麦克风(2026-10-15): PipeWire 的 ACP **不会**执行 UCM 里 Mic 设备的
#     EnableSequence。实测 pw-record 时 pcm1c=RUNNING, 但 AMIC1 DAPM=Off、
#     MultiMedia2 Mixer SLIMBUS_0_TX=off, 录出来 44 字节全零。
#     所以采集路由(MM2 TX + codec 麦克风链)必须由这里保活。
#     反过来, 这里的 MM2 也**不能**再被扬声器占用(同槽), 于是扬声器统一走 MM1。
set +u
aplay -l 2>/dev/null | grep -q "^card 0" || exit 0

set_if_diff() {  # set_if_diff <control> <value>
  cur=$(amixer -c 0 cget "name=$1" 2>/dev/null | tail -1 | grep -oE "[0-9]+$")
  [ "$cur" = "$2" ] && return 0
  timeout 5 amixer -c 0 cset "name=$1" "$2" >/dev/null 2>&1
}

jack_state() {
  amixer -c 0 -D hw:0 cget iface=CARD,name="Headset Jack" 2>/dev/null | tail -1 | grep -oE "on|off"
}

if [ "$(jack_state)" = "on" ]; then
  # --- 耳机已插入: 先给 HPH 通路上电, 再开 SLIMBUS_0_RX 路由, 最后静音扬声器 ---
  for c in "SLIM RX0 MUX AIF1_PB" "SLIM RX1 MUX AIF1_PB" \
           "RX INT1_1 MIX1 INP0 RX0" "RX INT2_1 MIX1 INP0 RX1" \
           "COMP1 Switch 1" "COMP2 Switch 1" \
           "RX INT1 DEM MUX CLSH_DSM_OUT" "RX INT2 DEM MUX CLSH_DSM_OUT"; do
    name="${c% *}"; val="${c##* }"
    cur=$(amixer -c 0 cget "name=$name" 2>/dev/null | tail -1)
    case "$cur" in *"$val"*) continue;; esac
    amixer -c 0 cset "name=$name" "$val" >/dev/null 2>&1
  done
  set_if_diff "SLIMBUS_0_RX Audio Mixer MultiMedia1" 1
  set_if_diff "QUAT_MI2S_RX Audio Mixer MultiMedia1" 0
else
  # --- 没插耳机: 只走底部扬声器(这条路径最稳) ---
  set_if_diff "SLIMBUS_0_RX Audio Mixer MultiMedia1" 0
  set_if_diff "QUAT_MI2S_RX Audio Mixer MultiMedia1" 1
fi

# --- 麦克风采集路由 (MM2 + WCD9340 麦克风链) ---------------------------------
# 只在真的有采集流时写, 否则 idle 状态下没必要反复 cset 去打断别的流。
# 判据用 pcm1c 的 status (hw:0,1 = MultiMedia2, 就是 UCM 里 Mic 的 CapturePCM)。
cap_active() {
  grep -qE "state: (RUNNING|PREPARED|XRUN)" \
    /proc/asound/card0/pcm1c/sub0/status 2>/dev/null
}

# 无条件兜住采集路由: PipeWire/ACP 每次重启都会重新加载 UCM, 那时它探测
# CapturePCM "hw:0,1" 会真的打开 PCM, 而 Q6 的 sessions[1].port_id 还没写成 3
# -> 打开失败 -> ACP 判定整个 UCM 不可用 -> **放弃整个 UCM**,
# profiles 里连扬声器都没了 (只剩 off / pro-audio)。实测重启 3 次必现。
if true; then
  set_if_diff "MultiMedia2 Mixer SLIMBUS_0_TX" 1
  set_if_str() {  # 只在值不同时写字符串枚举
    local cur
    cur=$(amixer -c 0 cget "name=$1" 2>/dev/null | tail -1)
    case "$cur" in *"$2"*) return 0;; esac
    timeout 5 amixer -c 0 cset "name=$1" "$2" >/dev/null 2>&1
  }
  set_if_str "CDC_IF TX0 MUX" DEC0
  set_if_str "ADC MUX0" AMIC
  set_if_str "AMIC MUX0" ADC1
  # AIF1_CAP Mixer SLIM TX0 是纯开关, set_if_diff 的数字比较对它不适用
  capmix=$(amixer -c 0 cget "name=AIF1_CAP Mixer SLIM TX0" 2>/dev/null | tail -1)
  case "$capmix" in *on*) ;; *) timeout 5 amixer -c 0 cset "name=AIF1_CAP Mixer SLIM TX0" 1 >/dev/null 2>&1;; esac
fi
cap_active() { :; }   # 兼容旧调用, 采集路由现在无条件保活

# 声卡 profile 兜底: pro-audio 会让 Q6 AFE 使能失败(-110/-22) -> 完全没声音;
# off 则连 sink 都没有(auto_null 假播放)。
# ★ 所有 pactl 调用都必须带 timeout: set-card-profile 会在探测 CapturePCM 时
#   阻塞(ACP 正等 Q6 应答), 不设上限的话整个 oneshot 单元会挂住 ->
#   systemd 报 failed, 后续路由全断。实测踩过: 服务卡在
#   "pactl set-card-profile alsa_card.platform-sound HiFi" 直到超时。
if command -v pactl >/dev/null 2>&1; then
  # ⚠️ 不要写成 timeout 8 as_user pactl ...: as_user 是 shell 函数, timeout 只能
  #   执行真实可执行文件, 会直接 127 (command not found), 整个 oneshot 判 failed。
  #   所以走 AU 环境变量, 直接对 sudo 套 timeout。
  # 用户/UID 由构建期注入（原脚本硬编码 winter/1000）
  RUSER="${RAPHAEL_USER:-user}"
  RUID=$(id -u "$RUSER" 2>/dev/null || echo 1001)
  AU="sudo -u $RUSER env XDG_RUNTIME_DIR=/run/user/$RUID DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$RUID/bus"
  # ⚠️ 不能用 awk '{print $NF}': profile 名是 "HiFi (Mic, Speaker)", 带空格,
  #    $NF 只会拿到 "Speaker)", 于是判定"当前不是 off 就不管", profile 卡死。
  #    要取冒号后面整段再去掉换行。
  CUR="$(timeout 8 $AU pactl list cards 2>/dev/null \
         | sed -n 's/^[[:space:]]*Active Profile:[[:space:]]*//p' | head -1 | tr -d '\r')"
  case "$CUR" in
    HiFi*) : ;;   # 已经是带麦克风的 profile, 不用动
    *)
      timeout 20 $AU pactl set-card-profile alsa_card.platform-sound HiFi >/dev/null 2>&1
      ;;
  esac
fi
