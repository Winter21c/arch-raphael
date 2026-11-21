#!/usr/bin/env bash
# 设备硬件适配：Wi-Fi / 蓝牙 / 音频 / USB 网络 / 电源 / 基带（可选）

hardware_overlay() {
    step "硬件适配配置"

    # ---- Wi-Fi（ath10k WCN3990）-----------------------------------------
    install -d "$MNT/etc/modprobe.d"
    printf 'options ath10k_core skip_otp=y\n' > "$MNT/etc/modprobe.d/ath10k.conf"

    install -d "$MNT/etc/NetworkManager/conf.d"
    printf '[connection]\nwifi.powersave = 2\n' > "$MNT/etc/NetworkManager/conf.d/wifi-powersave.conf"

    # 固定 Wi-Fi 接口名为 wlan0（否则会被 udev 重命名为 wld0）
    install -d "$MNT/etc/systemd/network"
    cat > "$MNT/etc/systemd/network/10-wlan0.link" <<'EOF'
[Match]
OriginalName=wlan*
[Link]
Name=wlan0
EOF

    # ---- 音频（WirePlumber，手机小缓冲）---------------------------------
    install -d "$MNT/etc/wireplumber/wireplumber.conf.d"
    cat > "$MNT/etc/wireplumber/wireplumber.conf.d/51-raphael.conf" <<'EOF'
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "~alsa_input.*" },
      { node.name = "~alsa_output.*" }
    ]
    actions = {
      update-props = {
        audio.format         = "S16LE"
        audio.rate           = 48000
        api.alsa.period-size = 4096
        api.alsa.period-num  = 6
        api.alsa.headroom    = 512
      }
    }
  }
]
EOF

    # ---- 音频路由（Q6 后端 DAI 使能）-----------------------------------
    # 实测：Q6 routing 开关（*_RX Audio Mixer MultiMediaN）打开后，PCM 才能拿到
    # backend DAI；否则 dmesg 报 "no backend DAIs enabled ... missing UCM profile"，
    # aplay 直接 EINVAL。UCM 侧无论怎么放都对不上（见 docs/HARDWARE.md），
    # 因此这里用 oneshot 服务在开机后把开关打开并读回校验。
    cat > "$MNT/usr/local/sbin/raphael-audio-route.sh" <<'EOF'
#!/bin/sh
# 打开 Q6 路由开关并读回校验；幂等，可重复执行
set -u
CARD=${RAPHAEL_CARD:-0}
ok=0; bad=0; missing=0
for sw in "QUAT_MI2S_RX Audio Mixer MultiMedia1" \
          "QUAT_MI2S_RX Audio Mixer MultiMedia2" \
          "SLIMBUS_0_RX Audio Mixer MultiMedia1"; do
    if ! amixer -c "$CARD" sget "$sw" >/dev/null 2>&1; then
        missing=$((missing+1)); echo "SKIP $sw (不存在)"; continue
    fi
    amixer -c "$CARD" sset "$sw" on >/dev/null 2>&1 || true
    st=$(amixer -c "$CARD" sget "$sw" 2>/dev/null | grep -m1 -E '\[(on|off)\]' || true)
    case "$st" in
        *"[on]"*) ok=$((ok+1)); echo "OK   $sw" ;;
        *)        bad=$((bad+1)); echo "FAIL $sw :: $st" ;;
    esac
done
echo "raphael-audio-route: ok=$ok bad=$bad missing=$missing"
[ "$bad" -eq 0 ]
EOF
    chmod 755 "$MNT/usr/local/sbin/raphael-audio-route.sh"

    cat > "$MNT/etc/systemd/system/raphael-audio-route.service" <<'EOF'
[Unit]
Description=Enable Q6 audio routing mixers (backend DAI)
After=sound.target local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/raphael-audio-route.sh

[Install]
WantedBy=multi-user.target
EOF

    # ---- ALSA UCM 兜底落位 ----------------------------------------------
    # 内核把声卡命名为 "Raphael"（来自 DTB model），而 alsa-ucm-conf 的官方包是按
    # "sm8150_raphael"/长名匹配的。这里把随内核 deb 附带的 UCM 复制到 alsa-lib
    # 可能查找的三条路径，尽量让路由能被加载（实测仍有 -2，见 docs/HARDWARE.md）。
    if [ -d "$MNT/usr/share/alsa/ucm2/Raphael" ]; then
        install -d "$MNT/usr/share/alsa/ucm/Raphael" "$MNT/usr/share/alsa/ucm2/conf.d/Raphael"
        cp -f "$MNT/usr/share/alsa/ucm2/Raphael/"*.conf "$MNT/usr/share/alsa/ucm/Raphael/" 2>/dev/null || true
        cp -f "$MNT/usr/share/alsa/ucm2/Raphael/"*.conf "$MNT/usr/share/alsa/ucm2/conf.d/Raphael/" 2>/dev/null || true
        # HiFi.conf 是 UCM2 语法，外层要用 Syntax 4 才能被 ucm2 加载器导入
        cat > "$MNT/usr/share/alsa/ucm2/conf.d/Raphael/Raphael.conf" <<'EOF'
Syntax 4

SectionUseCase."HiFi" {
	File "HiFi.conf"
	Comment "HiFi quality Music"
}
EOF
        log "ALSA UCM 已落位到 ucm/、ucm2/、ucm2/conf.d/ 三处（卡名 Raphael）"
    fi

    # ---- Venus VA-API 硬解（H.264/HEVC）----------------------------------
    install -d "$MNT/etc/environment.d"
    printf 'LIBVA_DRIVER_NAME=venus\n' > "$MNT/etc/environment.d/40-venus.conf"

    # ---- USB NCM 网络共享（设备 172.16.42.1）-----------------------------
    install -d "$MNT/etc/dnsmasq.d"
    # dnsmasq 默认配置不含 conf-dir，drop-in 不会被读取 → 会去抢 53 端口并与
    # systemd-resolved 冲突（实测报 “failed to create listening socket for port 53”）
    if [ -f "$MNT/etc/dnsmasq.conf" ]; then
        grep -q '^conf-dir=/etc/dnsmasq.d' "$MNT/etc/dnsmasq.conf" 2>/dev/null \
            || echo 'conf-dir=/etc/dnsmasq.d,*.conf' >> "$MNT/etc/dnsmasq.conf"
    else
        printf 'conf-dir=/etc/dnsmasq.d,*.conf\n' > "$MNT/etc/dnsmasq.conf"
    fi

    # dnsmasq 必须在 usb0 就绪之后启动，否则 DHCP 绑定不到接口
    install -d "$MNT/etc/systemd/system/dnsmasq.service.d"
    cat > "$MNT/etc/systemd/system/dnsmasq.service.d/10-usb-ncm.conf" <<'EOF'
[Unit]
After=usb-ncm.service
Wants=usb-ncm.service
EOF

    cat > "$MNT/etc/dnsmasq.d/usb-ncm.conf" <<'EOF'
interface=usb0
bind-dynamic
port=0
dhcp-authoritative
dhcp-range=172.16.42.2,172.16.42.254,255.255.255.0,1h
dhcp-option=3,172.16.42.1
EOF

    cat > "$MNT/usr/local/sbin/setup-usb-ncm.sh" <<'EOF'
#!/bin/sh
# 通过 configfs 建立 CDC-NCM USB 网卡，设备侧 172.16.42.1
set -e
modprobe libcomposite 2>/dev/null || true
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
G=/sys/kernel/config/usb_gadget/g1
[ -d "$G" ] || mkdir -p "$G"
echo 0x1d6b > "$G/idVendor"
echo 0x0104 > "$G/idProduct"
echo 0x0200 > "$G/bcdUSB"
mkdir -p "$G/strings/0x409"
echo "xiaomi-raphael" > "$G/strings/0x409/manufacturer"
echo "NCM" > "$G/strings/0x409/product"
cat /etc/machine-id > "$G/strings/0x409/serialnumber" 2>/dev/null || true
mkdir -p "$G/configs/c.1/strings/0x409"
echo NCM > "$G/configs/c.1/strings/0x409/configuration"
mkdir -p "$G/functions/ncm.usb0"
[ -L "$G/configs/c.1/ncm.usb0" ] || ln -sf "$G/functions/ncm.usb0" "$G/configs/c.1/"
UDC=$(ls /sys/class/udc 2>/dev/null | head -n 1)
[ -n "$UDC" ] && echo "$UDC" > "$G/UDC"
ip link set usb0 up 2>/dev/null || true
ip addr add 172.16.42.1/24 dev usb0 2>/dev/null || true
systemctl restart dnsmasq 2>/dev/null || true
EOF
    chmod 755 "$MNT/usr/local/sbin/setup-usb-ncm.sh"

    cat > "$MNT/etc/systemd/system/usb-ncm.service" <<'EOF'
[Unit]
Description=USB CDC-NCM gadget (172.16.42.1)
After=network.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/setup-usb-ncm.sh

[Install]
WantedBy=multi-user.target
EOF

    # ---- 触摸控制器冷启动自愈 -------------------------------------------
    # gt9886 在冷启动时驱动 probe 过早，控制器会进入「有中断但不上报」的状态；
    # 等供电稳定后重新 bind 一次 i2c 设备即可恢复（实测 IRQ 10 → 1384，事件正常）。
    cat > "$MNT/etc/systemd/system/raphael-touch-reset.service" <<'UNIT'
[Unit]
Description=Re-bind Goodix GTX8 touch controller (cold-boot workaround)
After=local-fs.target systemd-udevd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'D=/sys/bus/i2c/drivers/goodix-gtx8; i=0; while [ $i -lt 150 ]; do [ "$(cat /sys/class/drm/card0-DSI-1/enabled 2>/dev/null)" = "enabled" ] && break; i=$((i+1)); sleep 1; done; i=0; while [ $i -lt 60 ]; do dev=$(ls /sys/bus/i2c/devices 2>/dev/null | grep -- "-005d$" | head -1); [ -n "$dev" ] && break; i=$((i+1)); sleep 1; done; if [ -z "$dev" ]; then echo "no goodix i2c device"; exit 1; fi; for n in 1 2 3; do echo "rebinding $dev (try $n)"; echo "$dev" > "$D/unbind" 2>/dev/null; sleep 1; echo "$dev" > "$D/bind" 2>/dev/null; sleep 12; done; echo "touch rebind done"'

[Install]
WantedBy=multi-user.target
UNIT

    if chroot_sh "command -v dnsmasq >/dev/null 2>&1"; then
        svc_enable dnsmasq.service usb-ncm.service raphael-touch-reset.service raphael-audio-route.service
    else
        warn "未安装 dnsmasq，USB 网络共享不可用"
    fi

    # ---- 基带 / 传感器（postmarketOS 守护进程，若发行版提供）------------
    install -d "$MNT/etc/udev/rules.d"
    cat > "$MNT/etc/udev/rules.d/99-qcom-rmtfs.rules" <<'EOF'
# qcom_rmtfs_mem 出现时触发 rmtfs.service（仅当系统装有 rmtfs）
ACTION=="add", KERNEL=="qcom_rmtfs_mem*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="rmtfs.service"
EOF
    if chroot_sh "command -v rmtfs >/dev/null 2>&1"; then
        install -d "$MNT/etc/systemd/system/rmtfs.service.d"
        cat > "$MNT/etc/systemd/system/rmtfs.service.d/raphael.conf" <<'EOF'
[Unit]
ConditionPathExists=/dev/qcom_rmtfs_mem1
EOF
        svc_enable rmtfs.service pd-mapper.service 2>/dev/null || true
    else
        log "未安装 rmtfs/pd-mapper：跳过基带守护进程（可选组件）"
    fi

    # ---- 亮度 / DRM 设备权限 --------------------------------------------
    install -d "$MNT/etc/udev/rules.d"
    cat > "$MNT/etc/udev/rules.d/99-raphael-backlight.rules" <<'EOF'
# 允许 video 组调整屏幕亮度
SUBSYSTEM=="backlight", ACTION=="add", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
EOF

    log "硬件适配完成"
}
