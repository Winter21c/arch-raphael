#!/usr/bin/env bash
# ============================================================================
# dracut 模块 99raphael
#
# 目的：把 Android 的 userdata 分区（整块 rootfs.img 刷进去的那个）用
# util-linux losetup 以 4096 字节逻辑扇区映射成 loop 设备，从而暴露镜像内嵌 GPT 的
#   p1 = Boot(FAT32 ESP) / p2 = Root(btrfs @/@home)
# 让 cmdline 里的 root=UUID=<ROOT_UUID> 能被 dracut 的 rootfs-block 解析到。
#
# 挂在 pre-udev 阶段（udevd 启动之前）：loop 设备建好后，udevd 的冷插拔会自己扫出
# loop0p1/p2 并生成 /dev/disk/by-uuid 符号链接，dracut 后续的 pre-mount 才能按 UUID 找到根。
#
# 实际映射/扩容逻辑不在这里：由公共层的 overlay/initramfs/raphael-subpartition 提供
# （distro_initramfs 会把它装到镜像 /usr/lib/raphael-subpartition），本模块只负责把它
# 和它需要的工具一起塞进 initramfs。
# ============================================================================

check() {
    # 无内核版本/硬件条件：所有 raphael 镜像都必须做嵌套 GPT 映射
    return 0
}

depends() {
    echo base
}

install() {
    # util-linux losetup 必须支持 --sector-size（busybox applet 不支持，会静默失败）；
    # blkid 按 UUID 定位根，parted/partprobe 把内嵌 GPT 的 p2 扩到分区末尾。
    inst_multiple losetup blkid parted partprobe

    # 映射脚本里用到的其他工具（-o = 缺失不报错）
    inst_multiple -o udevadm modprobe partx sleep head basename cat strings

    # 公共层映射脚本（已含 shebang，hook 里用 sh 调用，权限位不敏感）
    inst_simple /usr/lib/raphael-subpartition /usr/lib/raphael-subpartition

    inst_hook pre-udev 30 "$moddir/raphael-subpart.sh"
}
