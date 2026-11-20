#!/usr/bin/env bash
# 收尾：清理缓存、卸载、归档

finalize_image() {
    step "收尾与镜像归档"
    rm -rf "$MNT/tmp"/* 2>/dev/null || true
    rm -rf "$MNT/var/cache/pacman/pkg"/* 2>/dev/null || true
    rm -rf "$MNT/var/cache/dnf"/* "$MNT/var/cache/libdnf5"/* 2>/dev/null || true

    img_umount

    local base="rootfs-$DISTRO_ID-$KERNEL_VERSION"
    sha256sum "$IMAGE_PATH" | awk -v n="$base.img" '{print $1"  "n}' | tee "$base.img.sha256"
    log "镜像: $IMAGE_PATH ($(du -h "$IMAGE_PATH" | cut -f1))"

    if [ "$COMPRESS_IMAGE" = "1" ] && have 7z; then
        step "压缩镜像（7z）"
        7z a -bso0 -bsp0 "$base.7z" "$IMAGE_PATH"
        sha256sum "$base.7z" | awk -v n="$base.7z" '{print $1"  "n}' | tee "$base.7z.sha256"
        ls -lh "$base.7z"
    fi
}
