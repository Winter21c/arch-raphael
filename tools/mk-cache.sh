#!/usr/bin/env bash
# ============================================================================
# tools/mk-cache.sh —— 构建 cache 分区镜像（systemd-boot + 内核 + initramfs + DTB）
#
# 用法:
#   sudo tools/mk-cache.sh --kernel <Image|vmlinuz> --initramfs <initrd> \
#        --dtb <dtb> --root-uuid <UUID> [--size 256M] [--out cache.img] \
#        [--label cache] [--subvol @] [--default raphael.conf]
#
# 设计要点（都是踩坑换来的）:
#   1. 内核与 initramfs 必须是同一版本构建的产物，否则 initramfs 阶段加载模块会失败
#      → 设备无 USB/无 SSH（只能物理恢复）。脚本会比对两侧的版本字符串并告警。
#   2. DTB 必须是**与 U-Boot/内核兼容的那一份**。整份替换成别的 DTB 可能因
#      memory/chosen 等节点不一致而无法启动。脚本会检查 DTB 是否含 memory 与
#      chosen 节点，缺失则直接拒绝。
#   3. rootflags 不要重复拼接 subvol=@（重复会导致挂载参数异常），本脚本统一生成。
# ============================================================================
set -euo pipefail

KERNEL=''; INITRD=''; DTB=''; ROOT_UUID=''
SIZE=256M; OUT=cache.img; LABEL=cache; SUBVOL='@'; ENTRY=raphael.conf; TITLE='Arch Linux ARM (raphael)'

while [ $# -gt 0 ]; do
    case "$1" in
        --kernel)    KERNEL=${2:-}; shift 2 ;;
        --initramfs) INITRD=${2:-}; shift 2 ;;
        --dtb)       DTB=${2:-}; shift 2 ;;
        --root-uuid) ROOT_UUID=${2:-}; shift 2 ;;
        --size)      SIZE=${2:-}; shift 2 ;;
        --out)       OUT=${2:-}; shift 2 ;;
        --label)     LABEL=${2:-}; shift 2 ;;
        --subvol)    SUBVOL=${2:-}; shift 2 ;;
        --title)     TITLE=${2:-}; shift 2 ;;
        -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

[ -f "$KERNEL" ]     || { echo "缺少 --kernel" >&2; exit 1; }
[ -f "$INITRD" ]     || { echo "缺少 --initramfs" >&2; exit 1; }
[ -n "$ROOT_UUID" ]  || { echo "缺少 --root-uuid" >&2; exit 1; }
command -v mkfs.vfat >/dev/null || { echo "需要 dosfstools" >&2; exit 1; }

# ---- 1) 内核/initramfs 版本一致性 -----------------------------------------
kver=$(strings "$KERNEL" | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9._-]*' || true)
iver=$(strings "$INITRD" 2>/dev/null | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9._-]*' || true)
echo "内核版本串: ${kver:-未知}"
echo "initramfs 版本串: ${iver:-未知（压缩镜像内可能看不到）}"
if [ -n "$kver" ] && [ -n "$iver" ] && [ "${kver%%.*}" != "${iver%%.*}" ]; then
    echo "[警告] 内核与 initramfs 版本串不一致，可能导致无法启动" >&2
fi

# ---- 2) DTB 兼容性检查 -----------------------------------------------------
if [ -n "$DTB" ]; then
    [ -f "$DTB" ] || { echo "DTB 不存在: $DTB" >&2; exit 1; }
    if command -v dtc >/dev/null; then
        dts=$(dtc -I dtb -O dts "$DTB" 2>/dev/null || true)
        for node in memory chosen; do
            echo "$dts" | grep -qE "^\s*${node} \{" || \
                echo "[警告] DTB 缺少 /$node 节点（实测 U-Boot 可能自行补齐，但风险较高）" >&2
        done
        # 最危险的是 chosen/bootargs 与 U-Boot 冲突，这里提示人工确认
        echo "$dts" | grep -qE "bootargs" && \
            echo "[警告] DTB 内自带 bootargs，可能覆盖 loader 的 options" >&2
        echo "$dts" | grep -q 'qcom,sm8150-sndcard' || echo "[提示] DTB 没有 sndcard 节点（音频会无声）" >&2
    else
        echo "[提示] 未安装 dtc，跳过 DTB 结构检查" >&2
    fi
fi

# ---- 3) 生成 FAT32 镜像 ----------------------------------------------------
rm -f "$OUT"
truncate -s "$SIZE" "$OUT"
mkfs.vfat -F 32 -n "$LABEL" "$OUT" >/dev/null

LOOP=$(losetup --find --show "$OUT")
MNT=$(mktemp -d)
trap 'sync; umount "$MNT" 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT
mount "$LOOP" "$MNT"

install -d "$MNT/EFI/BOOT" "$MNT/loader/entries" "$MNT/dtbs/qcom"
SD=$(ls /usr/lib/systemd/boot/efi/systemd-bootaa64.efi /lib/systemd/boot/efi/systemd-bootaa64.efi 2>/dev/null | head -1 || true)
[ -n "$SD" ] && install -Dm644 "$SD" "$MNT/EFI/BOOT/BOOTAA64.EFI" || echo "[提示] 未找到 systemd-bootaa64.efi" >&2

install -Dm644 "$KERNEL" "$MNT/linux.efi"
install -Dm644 "$INITRD" "$MNT/initramfs"
if [ -n "$DTB" ]; then
    install -Dm644 "$DTB" "$MNT/dtbs/qcom/$(basename "$DTB")"
fi

OPTS="root=UUID=$ROOT_UUID rootfstype=btrfs rootflags=subvol=$SUBVOL,compress=zstd:3,noatime,ssd,discard=async,space_cache=v2 rw rootwait console=tty0 loglevel=6"
{
    echo "title   $TITLE"
    echo "linux   /linux.efi"
    echo "initrd  /initramfs"
    [ -n "$DTB" ] && echo "devicetree /dtbs/qcom/$(basename "$DTB")"
    echo "options $OPTS"
} > "$MNT/loader/entries/$ENTRY"

printf 'default  %s\ntimeout  5\neditor   yes\nconsole-mode keep\n' "$ENTRY" > "$MNT/loader/loader.conf"

sync
echo "==> 已生成 $OUT（$SIZE）"
echo "    内核: $KERNEL"
echo "    initramfs: $INITRD"
echo "    DTB: ${DTB:-无}"
echo "    root: UUID=$ROOT_UUID subvol=$SUBVOL"
echo
echo "刷写: fastboot flash cache $OUT && fastboot reboot"
