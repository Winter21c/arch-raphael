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

    # ---- Venus VA-API 硬解（H.264/HEVC）----------------------------------
    install -d "$MNT/etc/environment.d"
    printf 'LIBVA_DRIVER_NAME=venus\n' > "$MNT/etc/environment.d/40-venus.conf"

    # ---- USB NCM 网络共享（设备 172.16.42.1）-----------------------------
    install -d "$MNT/etc/dnsmasq.d"
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

    if chroot_sh "command -v dnsmasq >/dev/null 2>&1"; then
        svc_enable dnsmasq.service usb-ncm.service
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
