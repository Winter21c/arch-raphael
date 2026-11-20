#!/usr/bin/env bash
# 系统通用配置：fstab / 用户 / locale / 服务 / zram / 首启扩容

configure_common() {
    step "系统通用配置"

    # ---- fstab（btrfs 子卷 + ESP）----------------------------------------
    local boot_uuid
    boot_uuid="${BOOT_VOLID:0:4}-${BOOT_VOLID:4:4}"
    install -d "$MNT/etc"
    cat > "$MNT/etc/fstab" <<EOF
# <file system>                              <mount> <type>  <options>                 <dump> <pass>
UUID=$ROOT_UUID  /       btrfs   $BTRFS_OPTS       0 0
UUID=$ROOT_UUID  /home   btrfs   $BTRFS_HOME_OPTS  0 0
UUID=$boot_uuid  /boot   vfat    umask=0077,noatime        0 2
EOF

    # ---- hostname / hosts -------------------------------------------------
    echo "$HOSTNAME_DEFAULT" > "$MNT/etc/hostname"
    cat > "$MNT/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME_DEFAULT
::1         localhost ip6-localhost
EOF

    # ---- 时区 / locale ----------------------------------------------------
    install -d "$MNT/etc"
    if [ -f "$MNT/usr/share/zoneinfo/$DESKTOP_TZ" ]; then
        ln -sf "/usr/share/zoneinfo/$DESKTOP_TZ" "$MNT/etc/localtime"
    fi
    echo "$DESKTOP_TZ" > "$MNT/etc/timezone" 2>/dev/null || true
    echo "LANG=$DESKTOP_LANG" > "$MNT/etc/locale.conf"
    echo "KEYMAP=us" > "$MNT/etc/vconsole.conf"
    echo "FONT=Lat2-Terminus16" >> "$MNT/etc/vconsole.conf"

    # ---- 用户 -------------------------------------------------------------
    if ! chroot_sh "id $USER_NAME >/dev/null 2>&1"; then
        chroot_sh "useradd -m -s /bin/bash -G wheel,video,input,render,audio $USER_NAME" \
            || warn "创建用户 $USER_NAME 失败（发行版层可能已创建）"
    fi
    if chroot_sh "id $USER_NAME >/dev/null 2>&1"; then
        echo "$USER_NAME:$USER_PASS" | chroot "$MNT" chpasswd || true
        chroot_sh "usermod -aG wheel,video,input,render,audio $USER_NAME" || true
    fi
    echo "root:$ROOT_PASS" | chroot "$MNT" chpasswd || true

    # sudo：wheel 组可用密码提权
    install -d "$MNT/etc/sudoers.d"
    if [ ! -f "$MNT/etc/sudoers.d/10-wheel" ]; then
        echo '%wheel ALL=(ALL:ALL) ALL' > "$MNT/etc/sudoers.d/10-wheel"
        chmod 440 "$MNT/etc/sudoers.d/10-wheel"
    fi

    # ---- SSH（USB NCM 直连调试用）----------------------------------------
    install -d "$MNT/etc/ssh/sshd_config.d"
    cat > "$MNT/etc/ssh/sshd_config.d/10-raphael.conf" <<EOF
PermitRootLogin yes
PasswordAuthentication yes
EOF

    # ---- 重置 machine-id（否则所有镜像共用同一个 id，影响 DHCP/序列号）----
    : > "$MNT/etc/machine-id"
    rm -f "$MNT/var/lib/dbus/machine-id" 2>/dev/null || true

    # ---- zram（zram-generator）-------------------------------------------
    install -d "$MNT/etc/systemd"
    cat > "$MNT/etc/systemd/zram-generator.conf" <<EOF
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
swap-priority = 100
EOF

    # ---- 内核参数（手机/内存）--------------------------------------------
    install -d "$MNT/etc/sysctl.d"
    cat > "$MNT/etc/sysctl.d/90-raphael.conf" <<EOF
vm.swappiness = 150
vm.vfs_cache_pressure = 150
vm.dirty_writeback_centisecs = 1500
kernel.sched_autogroup_enabled = 0
fs.inotify.max_user_watches = 524288
EOF

    # ---- 电源键 / 合盖 / 空闲 --------------------------------------------
    install -d "$MNT/etc/systemd/logind.conf.d"
    cat > "$MNT/etc/systemd/logind.conf.d/raphael.conf" <<EOF
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=poweroff
HandleLidSwitch=ignore
IdleAction=ignore
EOF

    # 手机上禁用休眠（无休眠分区）
    svc_mask sleep.target suspend.target hibernate.target hybrid-sleep.target

    # ---- journald 限制 ----------------------------------------------------
    install -d "$MNT/etc/systemd/journald.conf.d"
    printf '[Journal]\nSystemMaxUse=100M\nRuntimeMaxUse=32M\n' \
        > "$MNT/etc/systemd/journald.conf.d/raphael.conf"

    # ---- 首启自动扩展 btrfs 到整块 userdata ------------------------------
    install -d "$MNT/etc/systemd/system"
    cat > "$MNT/etc/systemd/system/raphael-growfs.service" <<'EOF'
[Unit]
Description=Raphael: grow btrfs filesystem to fill userdata
After=local-fs.target
ConditionPathExists=!/var/lib/raphael-growfs.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/raphael-growfs
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    cat > "$MNT/usr/local/sbin/raphael-growfs" <<'EOF'
#!/bin/sh
# / 与 /home 同属一个 btrfs，扩展一次即可
set -e
btrfs filesystem resize max / || true
touch /var/lib/raphael-growfs.done
EOF
    chmod 755 "$MNT/usr/local/sbin/raphael-growfs"
    svc_enable raphael-growfs.service

    # ---- 基础服务 ---------------------------------------------------------
    svc_enable systemd-timesyncd.service
    svc_enable NetworkManager.service
    svc_enable bluetooth.service
    svc_enable fstrim.timer
    svc_mask getty@tty1.service
    svc_mask systemd-firstboot.service
    svc_enable sshd.service

    log "fstab / 用户 / locale / 服务配置完成"
}
