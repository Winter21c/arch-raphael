# 供发行版 initramfs 生成器引用的常量与安装助手
# 参考：raphael-subpartition（嵌入 initramfs 的脚本）
RAPHAEL_INITRAMFS_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/overlay/initramfs/raphael-subpartition"

# raphael_copy_initramfs_deps <destdir>
# 把 losetup/blkid/parted/partprobe 及其动态库复制进 destdir（initramfs 根）
raphael_copy_initramfs_deps() {
    local dest="$1" bin dep
    for bin in /usr/sbin/losetup /usr/bin/losetup /usr/sbin/blkid /usr/bin/blkid \
               /usr/sbin/parted /usr/bin/parted /usr/sbin/partprobe /usr/bin/partprobe; do
        [ -x "$bin" ] || continue
        install -Dm755 "$bin" "$dest$bin" 2>/dev/null || continue
        while read -r dep; do
            [ -f "$dep" ] || continue
            install -Dm644 "$dep" "$dest$dep" 2>/dev/null || true
        done <<EOF
$(ldd "$bin" 2>/dev/null | awk '/=> \//{print $3} /^\//{print $1}' | sort -u)
EOF
    done
}
