#!/usr/bin/env bash
# systemd-boot + 固定名引导条目（与 Nura / postmarketOS 一致）

boot_install() {
    step "配置 systemd-boot 引导"

    local sd=""
    local p
    for p in "$MNT/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" "$MNT/lib/systemd/boot/efi/systemd-bootaa64.efi"; do
        [ -f "$p" ] && { sd="$p"; break; }
    done
    [ -n "$sd" ] || warn "未找到 systemd-bootaa64.efi，ESP 将无法启动（请确认已安装 systemd-boot）"

    install -d "$MNT/boot/EFI/BOOT" "$MNT/boot/loader/entries"
    [ -n "$sd" ] && install -Dm644 "$sd" "$MNT/boot/EFI/BOOT/BOOTAA64.EFI"

    install -Dm644 "$WORK_DIR/vmlinuz" "$MNT/boot/vmlinuz"
    if [ -f "$WORK_DIR/initrd.img" ]; then
        install -Dm644 "$WORK_DIR/initrd.img" "$MNT/boot/initrd.img"
    else
        warn "initrd.img 缺失：请先执行 initramfs 阶段"
    fi

    cat > "$MNT/boot/loader/entries/raphael.conf" <<EOF
title   $DEVICE_MODEL ($DISTRO_NAME)
linux   /vmlinuz
initrd  /initrd.img
options $(img_cmdline)
EOF

    cat > "$MNT/boot/loader/loader.conf" <<EOF
default  raphael.conf
timeout  1
console-mode keep
EOF

    cat > "$MNT/usr/local/bin/raphael-kernel-update" <<'EOS'
#!/bin/sh
# 将最新内核与 initramfs 同步到固定名引导位置
set -e
KVER=$(ls /lib/modules | grep -vE '^(build|source)$' | sort -V | tail -1)
[ -n "$KVER" ] || { echo "找不到内核模块目录"; exit 1; }
[ -f "/boot/vmlinuz-$KVER" ] && cp -f "/boot/vmlinuz-$KVER" /boot/vmlinuz
[ -f "/boot/initrd.img-$KVER" ] && cp -f "/boot/initrd.img-$KVER" /boot/initrd.img
if [ -d "/usr/lib/linux-image-$KVER/qcom" ]; then
    mkdir -p /boot/dtbs/qcom
    cp -rf "/usr/lib/linux-image-$KVER/qcom/." /boot/dtbs/qcom/ 2>/dev/null || true
fi
echo "已更新固定名引导 -> $KVER"
EOS
    chmod 755 "$MNT/usr/local/bin/raphael-kernel-update"
    log "引导参数: $(img_cmdline)"
}
# 生成 Android boot image（ABL 直接引导 Linux，不依赖 U-Boot）
boot_build_android() {
    step "打包 Android boot image（内核 + initramfs + DTB）"
    local dtb="$MNT/boot/dtbs/qcom/sm8150-xiaomi-raphael.dtb"
    [ -f "$dtb" ] || die "缺少设备树: $dtb"
    [ -f "$WORK_DIR/vmlinuz" ] || die "缺少内核: $WORK_DIR/vmlinuz"
    [ -f "$WORK_DIR/initrd.img" ] || die "缺少 initramfs: $WORK_DIR/initrd.img"

    python3 "$REPO_DIR/tools/mkbootimg.py" \
        --kernel "$WORK_DIR/vmlinuz" \
        --ramdisk "$WORK_DIR/initrd.img" \
        --dtb "$dtb" \
        --cmdline "$(img_cmdline)" \
        --name raphael \
        --output "$WORK_DIR/boot.img" || die "mkbootimg 失败"

    install -Dm644 "$WORK_DIR/boot.img" "$REPO_DIR/boot-$DISTRO_ID-$KERNEL_VERSION.img"
    log "boot image: $REPO_DIR/boot-$DISTRO_ID-$KERNEL_VERSION.img ($(du -h "$WORK_DIR/boot.img" | cut -f1))"
}
