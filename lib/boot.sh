#!/usr/bin/env bash
# systemd-boot + 固定名引导条目（与 Nura / postmarketOS 一致）

# ============================================================================
# 生成 cache 分区镜像（U-Boot 链路的引导分区）
#
#   cache(FAT32) = EFI/BOOT/BOOTAA64.EFI(systemd-boot)
#                  linux.efi(内核 Image / vmlinuz)
#                  initramfs
#                  dtbs/qcom/*.dtb
#                  loader/loader.conf + loader/entries/raphael.conf
#
# 实测：raphael 原厂 ABL 会拒绝未签名的 boot.img（Load Error），
# 因此正式链路是 ABL -> U-Boot(boot 分区) -> 本 cache 分区 -> 内核。
# ============================================================================

# ============================================================================
# 把 DTB 里声卡的 model 改成 UCM 期望的名字
#
# 内核用 DT 的 /sound model 作为 ALSA 卡名。alsa-ucm-conf 官方包按
# "sm8150_raphael" 提供 UCM（ucm2/conf.d/sm8150_raphael/），而内核 deb 里的
# DTB 写的是 "Raphael" → 卡名对不上，UCM 导入失败（-2），表现为
#   MultiMedia1: ASoC: no backend DAIs enabled ... missing UCM profile
# 构建期把 model 改成 sm8150_raphael 后，官方 UCM 就能直接命中。
# ============================================================================
patch_sound_model() {
    local dtb="$1" model="${2:-sm8150_raphael}"
    [ -f "$dtb" ] || return 0
    if ! command -v fdtput >/dev/null 2>&1 || ! command -v fdtget >/dev/null 2>&1; then
        warn "缺少 fdtput/fdtget（dtc 包），跳过声卡名补丁: $dtb"
        return 0
    fi
    local cur
    cur=$(fdtget "$dtb" /sound model 2>/dev/null || true)
    if [ -z "$cur" ]; then
        warn "DTB 中没有 /sound model，跳过: $dtb"
        return 0
    fi
    [ "$cur" = "$model" ] && return 0
    if fdtput -t s "$dtb" /sound model "$model" 2>/dev/null; then
        log "DTB 声卡名: $cur → $model ($(basename "$dtb"))"
    else
        warn "改写 DTB 声卡名失败: $dtb"
    fi
}

boot_build_cache() {
    step "生成 cache 分区镜像（systemd-boot + linux.efi + initramfs + dtb）"

    local cache_img="$WORK_DIR/cache.img"
    local sd=""
    local p
    for p in "$MNT/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" \
             "$MNT/lib/systemd/boot/efi/systemd-bootaa64.efi"; do
        [ -f "$p" ] && { sd="$p"; break; }
    done
    [ -n "$sd" ] || die "未找到 systemd-bootaa64.efi（请确认 systemd 已安装）"
    [ -f "$WORK_DIR/vmlinuz" ] || die "缺少内核: $WORK_DIR/vmlinuz"
    [ -f "$WORK_DIR/initrd.img" ] || die "缺少 initramfs（请先执行 initramfs 阶段）"

    # 找 dtb：优先内核包里的 qcom/*，其次 boot 下已安装的
    local dtb_src=""
    for p in "$MNT"/usr/lib/modules/*/dtbs/qcom "$MNT/boot/dtbs/qcom" "$MNT/usr/lib/linux-image-"*/qcom; do
        [ -d "$p" ] && { dtb_src="$p"; break; }
    done
    [ -n "$dtb_src" ] || die "找不到 qcom 设备树目录"

    rm -f "$cache_img"
    truncate -s "$CACHE_SIZE" "$cache_img"
    mkfs.vfat -F 32 -n "$CACHE_LABEL" "$cache_img" >/dev/null

    local CLOOP CROOT
    CLOOP=$(losetup --find --show "$cache_img")
    CROOT="$WORK_DIR/cache-root"
    rm -rf "$CROOT"; mkdir -p "$CROOT"
    mount "$CLOOP" "$CROOT"

    install -d "$CROOT/EFI/BOOT" "$CROOT/loader/entries" "$CROOT/dtbs/qcom"
    install -Dm644 "$sd"                 "$CROOT/EFI/BOOT/BOOTAA64.EFI"
    install -Dm644 "$WORK_DIR/vmlinuz"   "$CROOT/linux.efi"
    install -Dm644 "$WORK_DIR/initrd.img" "$CROOT/initramfs"
    cp -f "$dtb_src"/*.dtb "$CROOT/dtbs/qcom/" 2>/dev/null || true
    local _d
    for _d in "$CROOT"/dtbs/qcom/*.dtb; do
        [ -f "$_d" ] && patch_sound_model "$_d"
    done

    cat > "$CROOT/loader/entries/raphael.conf" <<EOF
title   $DEVICE_MODEL ($DISTRO_NAME)
linux   /linux.efi
initrd  /initramfs
devicetree /dtbs/qcom/sm8150-xiaomi-raphael.dtb
options $(img_cmdline)
EOF

    cat > "$CROOT/loader/loader.conf" <<EOF
default  raphael.conf
timeout  2
editor   yes
console-mode keep
EOF

    sync
    umount "$CROOT"
    losetup -d "$CLOOP"
    rmdir "$CROOT" 2>/dev/null || true

    install -Dm644 "$cache_img" "$REPO_DIR/cache-$DISTRO_ID-$KERNEL_VERSION.img"
    log "cache 镜像: $REPO_DIR/cache-$DISTRO_ID-$KERNEL_VERSION.img ($(du -h "$cache_img" | cut -f1))"
}

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
    patch_sound_model "$dtb"
    [ -f "$WORK_DIR/vmlinuz" ] || die "缺少内核: $WORK_DIR/vmlinuz"
    [ -f "$WORK_DIR/initrd.img" ] || die "缺少 initramfs: $WORK_DIR/initrd.img"

    python3 "$REPO_DIR/tools/mkbootimg.py" \
        --kernel "$WORK_DIR/vmlinuz" \
        --ramdisk "$WORK_DIR/initrd.img" \
        --dtb "$dtb" \
        --cmdline "$(img_cmdline)" \
        --name raphael \
        --output "$WORK_DIR/boot.img" || die "mkbootimg 失败"

    local size_mb
    size_mb=$(( $(stat -c%s "$WORK_DIR/boot.img") / 1048576 ))
    if [ "$size_mb" -gt 63 ]; then
        warn "boot.img 为 ${size_mb}MB，可能超出 boot 分区（raphael 约 64MB）"
    fi

    install -Dm644 "$WORK_DIR/boot.img" "$REPO_DIR/boot-$DISTRO_ID-$KERNEL_VERSION.img"
    log "boot image: $REPO_DIR/boot-$DISTRO_ID-$KERNEL_VERSION.img（${size_mb}MB，内核已解包为原始 Image）"
}
