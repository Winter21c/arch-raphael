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

    # build.sh 通常以 sudo 运行：产物属主是 root，CI 后续（非 root）步骤无法覆盖 .sha256
    _chown_artifacts "$base"
    log "镜像: $IMAGE_PATH ($(du -h "$IMAGE_PATH" | cut -f1))"

    if [ "$COMPRESS_IMAGE" = "1" ] && have 7z; then
        step "压缩镜像（7z）"
        7z a -bso0 -bsp0 "$base.7z" "$IMAGE_PATH"
        sha256sum "$base.7z" | awk -v n="$base.7z" '{print $1"  "n}' | tee "$base.7z.sha256"
        ls -lh "$base.7z"
        _chown_artifacts "$base"
    fi
}

# 把产物属主交还给调用 sudo 的用户（SUDO_UID），便于 CI 的非 root 步骤继续处理
_chown_artifacts() {
    local base="$1"
    [ -n "${SUDO_UID:-}" ] || return 0
    chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$IMAGE_PATH" "$base"*.sha256 2>/dev/null || true
    [ -f "$base.7z" ] && chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$base.7z" 2>/dev/null || true
    return 0
}
