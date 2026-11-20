#!/usr/bin/env bash
# 嵌套 GPT 镜像：p1=ESP(FAT32) + p2=btrfs(@/@home)
# 整块镜像刷入 userdata，initramfs 用 4096 扇区把 userdata 映射为 loop 设备

img_create() {
    step "创建 GPT 镜像 (大小 $IMAGE_SIZE, boot $BOOT_SIZE, 扇区 $SECTOR_SIZE)"
    losetup -D 2>/dev/null || true
    rm -f "$IMAGE_PATH"
    truncate -s "$IMAGE_SIZE" "$IMAGE_PATH"

    LOOP=$(losetup --find --show --sector-size "$SECTOR_SIZE" -P "$IMAGE_PATH")
    log "loop 设备: $LOOP"
    udevadm settle 2>/dev/null || sleep 1

    parted -s "$LOOP" mklabel gpt
    parted -s "$LOOP" mkpart primary fat32 "$BOOT_PART_START"s "$BOOT_SIZE"
    parted -s "$LOOP" mkpart primary "$BOOT_SIZE" 100%
    parted -s "$LOOP" type 1 "$ESP_PART_TYPE"
    parted -s "$LOOP" type 2 "$ROOT_PART_TYPE"
    parted -s "$LOOP" set 1 esp on
    udevadm settle 2>/dev/null || sleep 1

    mkfs.vfat -F 32 -n "$BOOT_LABEL" -i "$BOOT_VOLID" "$LOOP"p1 >/dev/null
    mkfs.btrfs -f -q -L "$ROOT_LABEL" -U "$ROOT_UUID" "$LOOP"p2

    mkdir -p "$MNT"
    mount "$LOOP"p2 "$MNT"
    btrfs subvolume create "$MNT/@" >/dev/null
    btrfs subvolume create "$MNT/@home" >/dev/null
    umount "$MNT"

    mount -o "$BTRFS_OPTS" "$LOOP"p2 "$MNT"
    mkdir -p "$MNT/home" "$MNT/boot" "$MNT/var" "$MNT/etc"
    mount -o "$BTRFS_HOME_OPTS" "$LOOP"p2 "$MNT/home"
    mount -t vfat "$LOOP"p1 "$MNT/boot"
    log "btrfs 子卷 @ / @home 已创建并挂载"
}

img_umount() {
    step "卸载镜像"
    umount_virtual
    local d
    for d in boot home ""; do
        mountpoint -q "$MNT/$d" && umount -R "$MNT/$d" 2>/dev/null
    done
    sync; sleep 1
    if btrfs check --readonly "$LOOP"p2 >/dev/null 2>&1; then
        log "btrfs 只读校验通过"
    else
        warn "btrfs check 有输出（常见为 extent 告警，可忽略）"
    fi
    losetup -d "$LOOP" 2>/dev/null || true
    LOOP=""
}

img_cmdline() {
    echo "root=UUID=$ROOT_UUID rw rootflags=subvol=@ quiet loglevel=3 splash console=tty0 fbcon=rotate:$FBCON_ROTATE"
}
#!/usr/bin/env bash
# 把已存在的镜像重新挂载（支持分阶段构建）

img_attach() {
    [ -f "$IMAGE_PATH" ] || die "镜像不存在: $IMAGE_PATH（先执行 image 阶段）"
    if losetup -j "$IMAGE_PATH" | grep -q .; then
        LOOP=$(losetup -j "$IMAGE_PATH" -O NAME -n | head -1)
        log "复用 loop 设备: $LOOP"
    else
        LOOP=$(losetup --find --show --sector-size "$SECTOR_SIZE" -P "$IMAGE_PATH")
        log "附加 loop 设备: $LOOP"
        udevadm settle 2>/dev/null || sleep 1
    fi
    mountpoint -q "$MNT" || { mkdir -p "$MNT"; mount -o "$BTRFS_OPTS" "$LOOP"p2 "$MNT"; }
    mkdir -p "$MNT/home" "$MNT/boot"
    mountpoint -q "$MNT/home" || mount -o "$BTRFS_HOME_OPTS" "$LOOP"p2 "$MNT/home"
    mountpoint -q "$MNT/boot" || mount -t vfat "$LOOP"p1 "$MNT/boot"
    mount_virtual
}

img_is_mounted() { mountpoint -q "$MNT"; }
