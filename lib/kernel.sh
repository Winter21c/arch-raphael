#!/usr/bin/env bash
# 内核 / 模块 / 设备树 / 固件 / ALSA UCM 安装（发行版无关）

kernel_install() {
    step "安装内核与固件"
    local k="$CACHE_DIR/kernel/$KERNEL_VERSION"
    local x="$WORK_DIR/kernel-extract"
    rm -rf "$x"; mkdir -p "$x"
    extract_deb "$k/linux-image.deb" "$x"

    KVER=$(ls "$x/lib/modules" | grep -vE '^(build|source)$' | head -1)
    [ -n "$KVER" ] || die "无法确定内核版本"

    install -Dm644 "$x/boot/vmlinuz-$KVER" "$WORK_DIR/vmlinuz"
    install -Dm644 "$x/boot/config-$KVER"  "$WORK_DIR/config-$KVER" 2>/dev/null || true

    # 模块
    rm -rf "$MNT/lib/modules/$KVER"
    install -d "$MNT/lib/modules"
    cp -a "$x/lib/modules/$KVER" "$MNT/lib/modules/$KVER"

    # 设备树
    if [ -d "$x/usr/lib/linux-image-$KVER/qcom" ]; then
        install -d "$MNT/boot/dtbs/qcom"
        cp -a "$x/usr/lib/linux-image-$KVER/qcom/." "$MNT/boot/dtbs/qcom/"
    fi

    # 固件
    local f="$WORK_DIR/firmware-extract"
    rm -rf "$f"; extract_deb "$k/firmware.deb" "$f"
    install -d "$MNT/usr/lib/firmware"
    cp -a "$f/usr/lib/firmware/." "$MNT/usr/lib/firmware/"

    # ALSA UCM（音频路由，设备相关）
    if [ -s "$k/alsa.deb" ]; then
        local a="$WORK_DIR/alsa-extract"
        rm -rf "$a"; extract_deb "$k/alsa.deb" "$a"
        if [ -d "$a/usr/share/alsa" ]; then copy_tree "$a/usr/share/alsa" "$MNT/usr/share/alsa"; fi
    fi

    chroot_sh "depmod -a $KVER" || warn "depmod 失败（可忽略）"
    log "内核 $KVER 安装完成（模块 $(find "$MNT/lib/modules/$KVER" -name '*.ko*' | wc -l) 个）"
}
