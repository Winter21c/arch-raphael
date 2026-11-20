#!/usr/bin/env bash
# 嵌套 GPT 镜像：p1=ESP(FAT32) + p2=btrfs(@/@home)
# 整块镜像刷入 userdata，initramfs 用 4096 扇区把 userdata 映射为 loop 设备

# 确保 loop 设备的分区节点存在（无 udev 的容器环境必需）
img_ensure_part_nodes() {
    local base name dev i
    base=$(basename "$1")
    local n
    for n in 1 2 3; do
        name="/dev/${base}p${n}"
        [ -e "$name" ] && continue
        i=0
        while [ ! -e "/sys/class/block/${base}p${n}/dev" ] && [ "$i" -lt 30 ]; do
            i=$((i+1)); sleep 0.1
        done
        [ -e "/sys/class/block/${base}p${n}/dev" ] || continue
        dev=$(cat "/sys/class/block/${base}p${n}/dev")
        mknod "$name" b "${dev%%:*}" "${dev##*:}" 2>/dev/null || true
        [ -e "$name" ] && log "已创建分区节点 $name"
    done
}

img_create() {
    step "创建 GPT 镜像 (大小 $IMAGE_SIZE, boot $BOOT_SIZE, 扇区 $SECTOR_SIZE)"
    # 只清理与本镜像相关的旧 loop 设备（不要 losetup -D，会误卸宿主机其它 loop 挂载）
    local old old_list
    old_list=$(losetup -j "$IMAGE_PATH" -O NAME -n 2>/dev/null || true)
    for old in $old_list; do losetup -d "$old" 2>/dev/null || true; done
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

    # 容器里没有 udev：分区节点不会自动出现，需要 partprobe + mknod 兜底
    partprobe "$LOOP" 2>/dev/null || blockdev --rereadpt "$LOOP" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 1
    img_ensure_part_nodes "$LOOP"

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
    local target
    for target in "$MNT/boot" "$MNT/home" "$MNT"; do
        [ -e "$target" ] || continue
        mountpoint -q "$target" || continue
        if ! umount -R "$target" 2>/dev/null; then
            warn "卸载 $target 失败，诊断如下："
            mount | grep -F "$target" | sed 's/^/    /' | head -8
            have fuser && fuser -vm "$target" 2>&1 | head -8
            warn "尝试 lazy 卸载 $target"
            umount -Rl "$target" 2>/dev/null || true
        fi
    done
    sync; sleep 1
    if mountpoint -q "$MNT"; then
        warn "镜像根仍被挂载，跳过 btrfs 校验与 loop 清理（镜像可能不完整）"
        return 0
    fi
    if btrfs check --readonly "$LOOP"p2 >/dev/null 2>&1; then
        log "btrfs 只读校验通过"
    else
        warn "btrfs check 有输出（常见为 extent 告警，可忽略）"
    fi
    losetup -d "$LOOP" 2>/dev/null || true
    LOOP=""
}

img_cmdline() {
    local extra=""
    if [ "${BOOT_VERBOSE:-0}" = "1" ]; then
        extra="loglevel=7"
    else
        extra="quiet loglevel=3 splash"
    fi
    echo "root=UUID=$ROOT_UUID rw rootflags=subvol=@ $extra console=tty0 fbcon=rotate:$FBCON_ROTATE"
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
    img_ensure_part_nodes "$LOOP"
    mountpoint -q "$MNT" || { mkdir -p "$MNT"; mount -o "$BTRFS_OPTS" "$LOOP"p2 "$MNT"; }
    mkdir -p "$MNT/home" "$MNT/boot"
    mountpoint -q "$MNT/home" || mount -o "$BTRFS_HOME_OPTS" "$LOOP"p2 "$MNT/home"
    mountpoint -q "$MNT/boot" || mount -t vfat "$LOOP"p1 "$MNT/boot"
    mount_virtual
}

img_is_mounted() { mountpoint -q "$MNT"; }
