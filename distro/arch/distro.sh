#!/usr/bin/env bash
# ============================================================================
# Arch Linux ARM (aarch64) 发行版层
#
# build.sh 在挂载好镜像后 source 本文件，并按顺序调用：
#   distro_bootstrap -> distro_packages -> distro_configure -> distro_desktop
#   -> distro_initramfs        （image/hardware/kernel/boot/verify 由公共层负责）
#
# 约定：
#   * $MNT = btrfs @ 子卷（根），$MNT/home = @home 子卷，$MNT/boot = ESP(FAT32)
#   * fstab / locale.conf / hostname / 用户 / zram / 基础服务启用由 lib/configure.sh
#     负责；本文件只做 Arch 特有部分（locale 生成、pacman 源、mkinitcpio、
#     systemd-boot 校验）
#   * 镜像使用预编译的 raphael 内核（/lib/modules/$KVER），不装 ALARM 官方内核
# ============================================================================

ARCH_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ARCH_REPO_DIR=$(cd -- "$ARCH_DIR/../.." && pwd)

# ---------------------------------------------------------------------------
# 内部工具
# ---------------------------------------------------------------------------

# 在镜像内执行命令（干净环境，避免宿主 locale/PATH 泄漏）
_arch_run() {
    chroot "$MNT" /usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/bin \
        HOME=/root TERM=linux LANG=C.UTF-8 \
        "$@"
}

_arch_sh() { _arch_run /bin/bash -c "$1"; }

# 读取包列表（去掉注释与空行）
_arch_pkgs() {
    local f="$1"
    [ -f "$f" ] || die "包列表不存在: $f"
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$f" | grep -v '^$'
}

# 安装包（--needed，失败即退出）
_arch_install() {
    [ "$#" -gt 0 ] || return 0
    log "pacman -S --needed（$# 个包）"
    _arch_run pacman -S --noconfirm --needed "$@" || die "pacman 安装失败（见上方输出）"
}

# 重写 mkinitcpio.conf 里的数组赋值（MODULES=(...) / HOOKS=(...)）
_arch_conf_array() {
    local conf="$1" var="$2" value="$3" tmp
    tmp=$(mktemp)
    awk -v var="$var" -v line="$var=($value)" '
        !done && index($0, var "=(") == 1 { print line; done = 1; next }
        { print }
    ' "$conf" > "$tmp"
    grep -qE "^$var=" "$tmp" || printf '%s\n' "$var=($value)" >> "$tmp"
    cat "$tmp" > "$conf"
    rm -f "$tmp"
}

# ALARM 镜像源（$arch/$repo 由 pacman 展开）
_arch_mirrorlist() {
    install -d "$MNT/etc/pacman.d"
    {
        echo "# Arch Linux ARM (aarch64) 镜像 —— 由 distro/arch/distro.sh 生成"
        echo "# SigLevel=Required：包与数据库都验签，所以 http 镜像同样是安全的"
        if [ -n "${ALARM_MIRROR:-}" ]; then
            # shellcheck disable=SC2016  # $arch/$repo 必须保持字面量，由 pacman 展开
            printf 'Server = %s/$arch/$repo\n' "${ALARM_MIRROR%/}"
        fi
        cat <<'EOF'
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo
Server = https://mirrors.ustc.edu.cn/archlinuxarm/$arch/$repo
Server = https://ca.us.mirror.archlinuxarm.org/$arch/$repo
Server = http://mirror.archlinuxarm.org/$arch/$repo
EOF
    } > "$MNT/etc/pacman.d/mirrorlist"
}

# 报告镜像剩余空间（8G 镜像容易被 Qt6 + linux-firmware 写满）
_arch_disk_report() {
    local avail
    avail=$(df -Pm "$MNT" 2>/dev/null | awk 'NR==2{print $4}')
    [ -n "$avail" ] || return 0
    log "$1 完成，$MNT 剩余 ${avail}MiB"
    if [ "$avail" -lt 800 ]; then
        warn "镜像可用空间不足 800MiB，后续阶段可能写满（可增大 IMAGE_SIZE）"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 1. bootstrap：解包 ALARM rootfs + pacman 初始化 + 首次全量升级
# ---------------------------------------------------------------------------
distro_bootstrap() {
    step "Arch Linux ARM: bootstrap"
    require_root
    mountpoint -q "$MNT"      || die "$MNT 未挂载（先执行 image 阶段）"
    mountpoint -q "$MNT/home" || warn "/home 不是挂载点，@home 子卷可能被 tarball 覆盖"
    mountpoint -q "$MNT/boot" || warn "/boot 不是挂载点，ESP 可能被 tarball 覆盖"

    local tgz="$CACHE_DIR/ArchLinuxARM-aarch64-latest.tar.gz"
    dl "${ROOTFS_URL:-http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}" "$tgz"

    step "解包 rootfs（保留已挂载的 /home 与 /boot）"
    tar --numeric-owner -xpf "$tgz" -C "$MNT" \
        --exclude='./home' --exclude='./home/*' \
        --exclude='./boot' --exclude='./boot/*' \
        --exclude='home' --exclude='boot' \
        || die "rootfs 解包失败: $tgz"

    # 保险：tarball 若不用 './' 前缀，上面的 --exclude 可能没命中
    find "$MNT/home" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

    # ALARM 的 /etc/resolv.conf 是指向 systemd-resolved stub 的符号链接；
    # chroot 里没有 resolved，换成真实文件，否则 pacman 无法解析域名。
    rm -f "$MNT/etc/resolv.conf"
    cp -L /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null \
        || warn "无法复制 resolv.conf（chroot 内可能无法联网）"

    _arch_mirrorlist
    install -Dm644 "$ARCH_DIR/pacman.conf" "$MNT/etc/pacman.conf"

    mount_virtual

    step "初始化 pacman keyring（archlinuxarm）"
    _arch_sh "pacman-key --init && pacman-key --populate archlinuxarm" \
        || die "pacman-key 初始化失败"

    # ALARM rootfs 自带 linux-aarch64。镜像用的是预编译 raphael 内核，移除它可以：
    #   1) 避免后续升级时 mkinitcpio 的 pacman hook 为不存在的 /boot/Image 生成 initramfs
    #   2) 省掉数百 MB 无用模块
    if _arch_sh "pacman -Q linux-aarch64 >/dev/null 2>&1"; then
        log "移除 ALARM 官方内核 linux-aarch64（使用设备内核）"
        _arch_run pacman -Rdd --noconfirm linux-aarch64 \
            || warn "移除 linux-aarch64 失败（可忽略，kernel 阶段会覆盖模块目录）"
    fi

    step "首次全量升级（pacman -Syu）"
    _arch_run pacman -Syu --noconfirm || die "首次 pacman -Syu 失败"
    _arch_sh "pacman-key --populate archlinuxarm" || warn "keyring 刷新失败（可忽略）"

    [ -x "$MNT/usr/bin/pacman" ]      || die "bootstrap 后缺少 /usr/bin/pacman"
    [ -x "$MNT/usr/bin/mkinitcpio" ]  || die "bootstrap 后缺少 /usr/bin/mkinitcpio"
    [ -f "$MNT/etc/mkinitcpio.conf" ] || die "bootstrap 后缺少 /etc/mkinitcpio.conf"
    log "bootstrap 完成：$(_arch_sh 'pacman -Q | wc -l') 个包"
}

# ---------------------------------------------------------------------------
# 2. packages：基础系统 + 手机硬件
# ---------------------------------------------------------------------------
distro_packages() {
    step "Arch Linux ARM: 基础/硬件包"
    local -a pkgs=()
    mapfile -t pkgs < <(_arch_pkgs "$ARCH_DIR/packages.txt")
    [ "${#pkgs[@]}" -gt 0 ] || die "packages.txt 为空"
    _arch_install "${pkgs[@]}"

    local c missing=0
    for c in mkinitcpio NetworkManager nmcli bluetoothctl pipewire wireplumber \
             losetup blkid parted partprobe btrfs mkfs.vfat pacman-key; do
        if ! _arch_sh "command -v $c >/dev/null 2>&1"; then
            warn "缺少命令: $c"
            missing=$((missing + 1))
        fi
    done
    [ "$missing" -eq 0 ] || warn "有 $missing 个关键命令缺失（请检查包列表）"

    _arch_disk_report "基础/硬件包"
}

# ---------------------------------------------------------------------------
# 3. desktop：niri / quickshell / squeekboard / Qt6 QML 运行时
#    （dms + dux-greeter + niri 配置由 lib/desktop.sh 在本函数之后安装）
# ---------------------------------------------------------------------------
distro_desktop() {
    step "Arch Linux ARM: 桌面组件"
    local -a pkgs=()
    mapfile -t pkgs < <(_arch_pkgs "$ARCH_DIR/packages-desktop.txt")
    [ "${#pkgs[@]}" -gt 0 ] || die "packages-desktop.txt 为空"
    _arch_install "${pkgs[@]}"

    if [ "${INSTALL_IME:-0}" = "1" ]; then
        step "安装中文输入法（fcitx5）"
        _arch_install fcitx5 fcitx5-chinese-addons fcitx5-configtool fcitx5-qt fcitx5-gtk
    fi

    # 桌面层会用到这些可执行文件；缺任何一个都会在 verify 阶段暴露
    local c
    for c in "${COMPOSITOR:-niri}" niri-session qs squeekboard fuzzel kitty; do
        _arch_sh "command -v $c >/dev/null 2>&1" || warn "缺少命令: $c"
    done

    _arch_disk_report "桌面包"
}

# ---------------------------------------------------------------------------
# 4. configure：Arch 特有配置（通用配置在 lib/configure.sh:configure_common）
# ---------------------------------------------------------------------------
distro_configure() {
    step "Arch Linux ARM: 发行版特有配置"
    [ -d "$MNT/etc" ] || die "rootfs 未就绪（先执行 bootstrap/packages）"

    _arch_locale_gen
    _arch_check_bootloader
    _arch_pacman_tidy

    log "Arch 特有配置完成"
}

_arch_locale_gen() {
    local f="$MNT/etc/locale.gen" l
    [ -f "$f" ] || die "缺少 /etc/locale.gen（glibc 未安装？）"
    cp -a "$f" "$f.raphael.bak"

    # en_US.UTF-8 / zh_CN.UTF-8 在 locale.gen 里都是预置的注释行：取消注释即可。
    # 若表的格式被改过，下面的 grep 兜底会直接追加一行，保证 locale-gen 前存在未注释行。
    sed -i -E \
        -e 's/^#*[[:space:]]*en_US\.UTF-8([[:space:]].*)?$/en_US.UTF-8 UTF-8/' \
        -e 's/^#*[[:space:]]*zh_CN\.UTF-8([[:space:]].*)?$/zh_CN.UTF-8 UTF-8/' \
        "$f"
    for l in en_US.UTF-8 zh_CN.UTF-8; do
        grep -qxF "$l UTF-8" "$f" || printf '%s UTF-8\n' "$l" >> "$f"
    done

    # locale.conf / vconsole.conf 由 lib/configure.sh 写，这里只生成实际数据
    _arch_run locale-gen || die "locale-gen 失败"
    _arch_sh "locale -a | grep -qi '^zh_cn.utf8$'" || die "zh_CN.UTF-8 未生成"
    _arch_sh "locale -a | grep -qi '^en_us.utf8$'" || die "en_US.UTF-8 未生成"
    log "locale 已生成: en_US.UTF-8 zh_CN.UTF-8（LANG=${DESKTOP_LANG:-}）"
}

_arch_check_bootloader() {
    local efi="/usr/lib/systemd/boot/efi/systemd-bootaa64.efi"
    [ -f "$MNT$efi" ] || die "缺少 $efi（应由 systemd 包提供），ESP 无法引导"
    log "systemd-boot: $efi（loader 条目由 lib/boot.sh 写入）"
}

_arch_pacman_tidy() {
    # 包缓存由 lib/finalize.sh 统一清理；这里只清掉 pacman 的临时残留
    rm -rf "$MNT/var/cache/pacman/pkg/tmp" 2>/dev/null || true
    install -d "$MNT/etc"
    printf 'DISTRO=%s\nDISTRO_ID=%s\nPKG_MANAGER=%s\nINITRAMFS=%s\nKERNEL=%s\n' \
        "${DISTRO_NAME:-Arch Linux ARM}" "${DISTRO_ID:-arch}" \
        "${PKG_MANAGER:-pacman}" "${INITRAMFS:-mkinitcpio}" "${KERNEL_VERSION:-}" \
        > "$MNT/etc/raphael-release"
}

# ---------------------------------------------------------------------------
# 5. initramfs：mkinitcpio + 自定义 hook（嵌套 GPT 映射，在根挂载前运行）
# ---------------------------------------------------------------------------
distro_initramfs() {
    step "Arch Linux ARM: 生成 initramfs（mkinitcpio）"
    mountpoint -q "$MNT" || die "$MNT 未挂载"

    if [ -z "${KVER:-}" ]; then
        local d b
        for d in "$MNT"/lib/modules/*; do
            [ -d "$d" ] || continue
            b="${d##*/}"
            case "$b" in build|source) continue ;; esac
            KVER="$b"
        done
    fi
    [ -n "${KVER:-}" ] || die "无法确定内核版本（/lib/modules 为空，先执行 kernel 阶段）"
    [ -d "$MNT/lib/modules/$KVER" ] || die "缺少 /lib/modules/$KVER（先执行 kernel 阶段）"
    log "内核版本: $KVER"

    # ---- 1. 映射脚本 + mkinitcpio hook -----------------------------------
    local src="${RAPHAEL_INITRAMFS_SCRIPT:-$ARCH_REPO_DIR/overlay/initramfs/raphael-subpartition}"
    [ -f "$src" ] || die "缺少嵌套 GPT 映射脚本: $src"
    install -Dm755 "$src" "$MNT/usr/lib/raphael-subpartition"
    install -Dm755 "$ARCH_DIR/mkinitcpio/raphael-hook"   "$MNT/etc/initcpio/install/raphael"
    install -Dm755 "$ARCH_DIR/mkinitcpio/raphael-script" "$MNT/etc/initcpio/hooks/raphael"
    log "已安装 mkinitcpio hook: install/raphael + hooks/raphael"

    # ---- 2. /etc/mkinitcpio.conf ----------------------------------------
    _arch_mkinitcpio_conf "$KVER"

    # ---- 3. 生成 --------------------------------------------------------
    local img="/boot/initrd.img-$KVER"
    rm -f "$MNT$img"
    _arch_run mkinitcpio -g "$img" -k "$KVER" || die "mkinitcpio 生成失败"
    [ -s "$MNT$img" ] || die "mkinitcpio 未产出 $img"

    # ---- 4. 内容校验（失败即 die）--------------------------------------
    _arch_verify_initramfs "$KVER"

    # ---- 5. 交给 boot 阶段（固定名 /boot/initrd.img）---------------------
    install -Dm644 "$MNT$img" "$WORK_DIR/initrd.img"
    log "initramfs 就绪: $WORK_DIR/initrd.img ($(du -h "$WORK_DIR/initrd.img" | cut -f1))"
}

# shellcheck disable=SC2086  # MODULES/HOOKS 是空格分隔列表，必须按词拆分
_arch_mkinitcpio_conf() {
    local kver="$1"
    local conf="$MNT/etc/mkinitcpio.conf"
    [ -f "$conf" ] || die "缺少 /etc/mkinitcpio.conf（mkinitcpio 未安装）"
    cp -a "$conf" "$conf.raphael.bak"

    # ---- MODULES：追加 loop（嵌套 GPT 需要 loop；btrfs 为 CONFIG_BTRFS_FS=y 内建）----
    local mods
    mods=$(sed -nE 's/^MODULES=\(([^)]*)\)/\1/p' "$conf" | head -1)
    case " $mods " in
        *" loop "*) : ;;
        *) mods="loop $mods" ;;
    esac
    mods=$(printf '%s\n' $mods)        # 折叠多余空格
    _arch_conf_array "$conf" MODULES "$mods"

    # ---- HOOKS ----
    local hooks h
    hooks=$(sed -nE 's/^HOOKS=\(([^)]*)\)/\1/p' "$conf" | head -1)
    [ -n "$hooks" ] || die "无法解析 /etc/mkinitcpio.conf 的 HOOKS 行"
    if ! printf '%s\n' $hooks | grep -qx filesystems; then
        die "HOOKS 中没有 filesystems，无法确定自定义 hook 的插入位置"
    fi

    local -a out=()
    for h in $hooks; do
        case "$h" in
            # mkinitcpio 的 systemd init 不执行 add_runscript 装的 runscript hook
            # （install/systemd 的 help 明确说明其它 hook 的运行时部分需要移植），
            # 因此退回 base + udev 的 busybox init，runscript hook 才会被执行。
            systemd|sd-vconsole) continue ;;
            # 交叉构建（docker/qemu）时 autodetect 读的是宿主 /sys，只会带进无关模块
            autodetect) continue ;;
            # btrfs 不需要 fsck
            fsck) continue ;;
            # 重跑本阶段时 HOOKS 里已经有 raphael：先去掉，下面按位置重新插入
            raphael) continue ;;
            filesystems)
                # 嵌套 GPT 映射必须在根文件系统解析/挂载之前
                out+=(raphael filesystems)
                continue
                ;;
        esac
        out+=("$h")
    done

    # 确保 udev 在 base 之后（提供 udevd 与 /dev/disk/by-partlabel）
    if ! printf '%s\n' "${out[@]}" | grep -qx udev; then
        local -a tmp2=()
        for h in "${out[@]}"; do
            tmp2+=("$h")
            [ "$h" = "base" ] && tmp2+=(udev)
        done
        out=("${tmp2[@]}")
        printf '%s\n' "${out[@]}" | grep -qx udev || out=(udev "${out[@]}")
    fi

    _arch_conf_array "$conf" HOOKS "${out[*]}"

    # ---- COMPRESSION：initramfs 解压算法必须编译进内核（CONFIG_RD_*）----
    # mkinitcpio 默认 zstd，但 arm64 defconfig 不一定开 CONFIG_RD_ZSTD，而 raphael
    # 内核的配置无法在构建期假定，所以按实际 config 选择（拿不到 config 就用 gzip）。
    local comp
    comp=$(_arch_initramfs_compression "$kver")
    sed -i -e '/^COMPRESSION=/d' -e '/^# raphael: initramfs compression/d' "$conf"
    {
        printf '# raphael: initramfs compression（依据内核 CONFIG_RD_* 自动选择）\n'
        printf 'COMPRESSION="%s"\n' "$comp"
    } >> "$conf"

    log "mkinitcpio.conf: MODULES=($mods)"
    log "mkinitcpio.conf: HOOKS=(${out[*]}) COMPRESSION=$comp"
}

# 依据内核 config 的 CONFIG_RD_* 选择 initramfs 压缩方式
_arch_initramfs_compression() {
    local kver="$1" cfg="" c
    for c in "${WORK_DIR:-}/config-$kver" "$MNT/boot/config-$kver"; do
        if [ -f "$c" ]; then cfg="$c"; break; fi
    done
    if [ -z "$cfg" ]; then
        echo gzip          # 拿不到内核 config：选所有内核都支持的方式
        return 0
    fi
    if grep -q '^CONFIG_RD_ZSTD=y' "$cfg"; then
        echo zstd
    elif grep -q '^CONFIG_RD_GZIP=y' "$cfg"; then
        echo gzip
    else
        echo cat           # 内核没有启用任何 initramfs 解压算法：用未压缩镜像
    fi
}

_arch_verify_initramfs() {
    local img="/boot/initrd.img-$1"
    local list="$WORK_DIR/initramfs.list"

    _arch_run lsinitcpio -l "$img" > "$list" 2>"$list.err" \
        || { cat "$list.err" >&2 2>/dev/null || true; die "lsinitcpio 无法读取 $img"; }

    local bad=0
    grep -qE '(^|/)hooks/raphael$' "$list" \
        || { warn "initramfs 缺少 /hooks/raphael"; bad=1; }
    grep -qE '(^|/)usr/lib/raphael-subpartition$' "$list" \
        || { warn "initramfs 缺少 /usr/lib/raphael-subpartition"; bad=1; }
    grep -qE '(^|/)(usr/)?(s?bin/)?losetup$' "$list" \
        || { warn "initramfs 缺少 losetup"; bad=1; }
    [ "$bad" -eq 0 ] || die "initramfs 内容校验失败（列表: $list）"

    # 解包确认 losetup 是 util-linux 版（支持 --sector-size；busybox 版不支持）
    local x="/tmp/raphael-initrd-check.$$"
    _arch_sh "rm -rf $x && mkdir -p $x && cd $x && lsinitcpio -x $img >/dev/null 2>&1" \
        || { _arch_sh "rm -rf $x"; die "无法解包 $img 做内容校验"; }

    local lo="" p
    for p in /usr/bin/losetup /usr/sbin/losetup /bin/losetup /sbin/losetup; do
        if _arch_sh "test -f $x$p"; then lo="$x$p"; break; fi
    done
    if [ -z "$lo" ]; then
        _arch_sh "rm -rf $x"
        die "initramfs 内没有 losetup 二进制"
    fi
    if ! _arch_sh "strings $lo | grep -q -- --sector-size"; then
        _arch_sh "rm -rf $x"
        die "initramfs 内 losetup 不支持 --sector-size（必须是 util-linux 版）"
    fi
    if ! _arch_sh "test -f $x/usr/lib/raphael-subpartition"; then
        _arch_sh "rm -rf $x"
        die "initramfs 内缺少 /usr/lib/raphael-subpartition"
    fi
    _arch_sh "rm -rf $x"

    log "initramfs 校验通过：hooks/raphael + raphael-subpartition + util-linux losetup"
}
