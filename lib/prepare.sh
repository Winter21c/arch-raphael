#!/usr/bin/env bash
# 下载内核 / 固件 / dux 组件到缓存

prepare_all() {
    step "准备构建素材"
    local k="$CACHE_DIR/kernel/$KERNEL_VERSION"
    local base="https://github.com/$KERNEL_DEB_REPO/releases/download/kernel-v$KERNEL_VERSION"
    mkdir -p "$k"
    dl "$base/linux-image-xiaomi-raphael.deb"   "$k/linux-image.deb"
    dl "$base/linux-headers-xiaomi-raphael.deb" "$k/linux-headers.deb"
    dl "$base/firmware-xiaomi-raphael.deb"      "$k/firmware.deb"
    # ALSA UCM（设备音频路由，可选）
    dl "$base/alsa-xiaomi-raphael.deb" "$k/alsa.deb" || true

    local d="$CACHE_DIR/dux"
    mkdir -p "$d"
    local sbase="https://github.com/duxlabs-dev/dux-shell/releases/download/v$DUX_SHELL_VERSION"
    local gbase="https://github.com/duxlabs-dev/dux-greeter/releases/download/v$DUX_GREETER_VERSION"
    dl "$sbase/dms-qml.tar.gz"          "$d/dms-qml.tar.gz"
    dl "$sbase/dms-distropkg-arm64.gz"  "$d/dms-cli-arm64.gz"
    dl "$gbase/dms-greeter-linux-arm64.gz" "$d/dms-greeter.gz"
    dl "$gbase/dank-greeter-$DUX_GREETER_VERSION.tar.gz" "$d/dux-greeter-src.tar.gz"
    log "素材准备完成"
}
