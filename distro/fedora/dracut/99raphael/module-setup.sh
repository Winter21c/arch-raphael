#!/usr/bin/env bash
# ============================================================================
# dracut 模块 99raphael
#
# 目的：把 Android 的 userdata 分区（整块 rootfs.img 刷进去的那个）用
# util-linux losetup 以 4096 字节逻辑扇区映射成 loop 设备，从而暴露镜像内嵌 GPT 的
#   p1 = Boot(FAT32 ESP) / p2 = Root(btrfs @/@home)
# 让 cmdline 里的 root=UUID=<ROOT_UUID> 能被 dracut 的 rootfs-block 解析到。
#
# 映射逻辑只有一份：overlay/initramfs/raphael-subpartition
# ============================================================================

check() {
    return 0
}

depends() {
    echo base
}

install() {
    # 用绝对路径逐个安装，避开 PATH 里可能存在的 busybox applet 符号链接
    # （busybox 的 losetup 不支持 --sector-size，会导致嵌套 GPT 映射失败）
    local b p c
    for b in losetup blkid partprobe parted; do
        p=""
        for c in /usr/bin/$b /usr/sbin/$b /bin/$b /sbin/$b; do
            [ -x "$c" ] && { p="$c"; break; }
        done
        if [ -n "$p" ]; then
            inst_simple "$p"
        else
            echo "raphael: 未找到 $b" >&2
        fi
    done

    inst_multiple -o udevadm modprobe partx sleep head basename cat strings

    inst_simple /usr/lib/raphael-subpartition /usr/lib/raphael-subpartition
    inst_hook pre-udev 30 "$moddir/raphael-subpart.sh"
}
