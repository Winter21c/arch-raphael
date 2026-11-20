#!/usr/bin/env bash
# ============================================================================
# Fedora 44 (aarch64) 发行版层
#
# 由 build.sh 在镜像已挂载（rootfs=$MNT，ESP=$MNT/boot）后 source 并调用：
#   distro_bootstrap  -> dnf5 --installroot 从零填充根文件系统
#   distro_packages   -> packages.txt（基础/硬件/服务）
#   distro_desktop    -> packages-desktop.txt + quickshell/虚拟键盘（必要时源码构建）
#   distro_configure  -> 仅 Fedora 特有项（locale 编译 / SELinux / 缓存清理）
#   distro_initramfs  -> dracut + 自定义模块 99raphael
#
# 依赖公共层提供：log/step/warn/die、chroot_sh、svc_*、mount_virtual（lib/common.sh）。
# configure_common 已负责 fstab/locale.conf/hostname/用户/sshd/zram/服务启用，本层不重复。
#
# Fedora 侧三个必须记住的事实：
#   1. installroot 内公钥未就绪时 dnf 无法验签 -> 先 --nogpgcheck 引导，导入 fedora-gpg-keys
#      的公钥后再开签名校验；导入失败则退回 --nogpgcheck（镜像完整性由 finalize 的 sha256 兜底）。
#   2. 内核/固件来自预编译 deb（lib/kernel.sh），因此 dnf 必须排除 kernel*，否则会装第二套内核。
#   3. 镜像在非 SELinux 主机上构建，文件没有 security.selinux 标签 —— SELinux 必须 permissive
#      （无策略时 disabled），否则首启服务会被拒绝，甚至卡在 relabel。
# ============================================================================

FEDORA_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FEDORA_RELEASE=${FEDORA_RELEASE:-44}
FEDORA_ARCH=${FEDORA_ARCH:-aarch64}
FEDORA_PKGS_BASE=$FEDORA_DIR/packages.txt
FEDORA_PKGS_DESKTOP=$FEDORA_DIR/packages-desktop.txt

# 1 = 安装时不校验 RPM 签名；公钥导入成功后置 0
FEDORA_NOGPGCHECK=1

# 引导最小集：先让 installroot 里有 dnf/rpm/systemd，再由 packages.txt 铺开
FEDORA_BOOTSTRAP_PKGS="fedora-release fedora-repos fedora-gpg-keys systemd systemd-udev dnf5 rpm bash coreutils util-linux kmod glibc shadow-utils setup filesystem rootfiles"

# 内核由 lib/kernel.sh 从 deb 安装，绝不能让 dnf 再装一套；dracut-config-* 会改 initramfs 默认值
FEDORA_EXCLUDEPKGS="kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-uki-virt dracut-config-generic dracut-config-rescue"

# _fedora_pkglist <file> —— 去掉注释/空行，输出空格分隔的包名
_fedora_pkglist() {
    sed -e 's/#.*//' -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//' -e '/^$/d' "$1" | tr '\n' ' '
}

# _fedora_dnf <dnf5 子命令...> —— 所有 installroot 操作的统一入口
_fedora_dnf() {
    local opts=(
        -y
        --installroot="$MNT"
        --releasever="$FEDORA_RELEASE"
        --forcearch="$FEDORA_ARCH"
        # dnf5 在 --installroot 下默认不读宿主 /etc/yum.repos.d，会报
        # "No matching repositories for *, *"；显式要求使用宿主配置与仓库目录
        --use-host-config
        --setopt=reposdir=/etc/yum.repos.d
        --setopt=install_weak_deps=False
        --setopt=tsflags=nodocs
        --setopt=keepcache=False
        --setopt=excludepkgs="$FEDORA_EXCLUDEPKGS"
    )
    if [ "$FEDORA_NOGPGCHECK" = "1" ]; then
        opts+=(--nogpgcheck)
    fi
    dnf5 "${opts[@]}" "$@"
}

# 把 fedora-gpg-keys 的公钥导入 installroot 的 rpmdb（Fedora 44: /usr/lib/sysimage/rpm）
_fedora_import_keys() {
    local k n=0
    for k in "$MNT"/etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-*; do
        [ -f "$k" ] || continue
        if rpm --root "$MNT" --import "$k" 2>/dev/null; then
            n=$((n + 1))
        fi
    done
    if [ "$n" -gt 0 ]; then
        FEDORA_NOGPGCHECK=0
        log "已向 installroot 导入 $n 个 Fedora GPG 公钥，后续安装启用签名校验"
    else
        warn "installroot 无 Fedora GPG 公钥，安装继续使用 --nogpgcheck（镜像完整性由 sha256 兜底）"
    fi
}

# ---------------------------------------------------------------------------
# 1. 引导：dnf5 --installroot 填充最小根文件系统
# ---------------------------------------------------------------------------
distro_bootstrap() {
    step "Fedora $FEDORA_RELEASE ($FEDORA_ARCH) 根文件系统引导（dnf5 --installroot）"
    need_cmd dnf5

    install -d "$MNT/etc" "$MNT/var/tmp" "$MNT/usr" "$MNT/dev" "$MNT/proc" "$MNT/sys" \
               "$MNT/run" "$MNT/tmp" "$MNT/root" "$MNT/boot" "$MNT/home"
    # rpm 脚本（systemd-sysusers / ldconfig / systemctl）需要 /proc /dev
    mount_virtual

    log "引导安装: $FEDORA_BOOTSTRAP_PKGS"
    _fedora_dnf install $FEDORA_BOOTSTRAP_PKGS || die "dnf5 引导安装失败（检查容器网络 / releasever=$FEDORA_RELEASE）"
    _fedora_import_keys

    # 镜像内 dnf 与构建时保持同一策略（后续 dnf install 不带文档与弱依赖）
    install -d "$MNT/etc/dnf"
    cat > "$MNT/etc/dnf/dnf.conf" <<'EOF'
[main]
install_weak_deps=False
tsflags=nodocs
keepcache=False
clean_requirements_on_remove=True
EOF

    # 固化 releasever：镜像内即使裁掉 /etc/fedora-release，dnf 仍指向 44
    install -d "$MNT/etc/dnf/vars"
    echo "$FEDORA_RELEASE" > "$MNT/etc/dnf/vars/releasever"

    if [ -f "$MNT/etc/os-release" ]; then
        log "installroot: $(grep -m1 '^PRETTY_NAME=' "$MNT/etc/os-release" | cut -d= -f2- | tr -d '"')"
    else
        warn "installroot 缺少 /etc/os-release（fedora-release 未生效？）"
    fi

    # --installroot 下包的 %post 里 systemctl preset 不一定执行，手动补一次
    chroot_sh "systemctl preset-all" >/dev/null 2>&1 || warn "systemctl preset-all 失败（可忽略，服务由后续阶段显式 enable）"

    log "引导完成，根文件系统 $(du -sh "$MNT" 2>/dev/null | cut -f1)"
}

# ---------------------------------------------------------------------------
# 2. 基础 / 硬件 / 服务包
# ---------------------------------------------------------------------------
distro_packages() {
    step "Fedora 基础包（packages.txt）"
    mount_virtual

    local pkgs
    pkgs=$(_fedora_pkglist "$FEDORA_PKGS_BASE")
    [ -n "$pkgs" ] || die "包列表为空: $FEDORA_PKGS_BASE"
    log "安装 $(printf '%s\n' $pkgs | wc -l) 个包"

    _fedora_dnf install $pkgs || die "基础包安装失败"
    _fedora_import_keys

    # Fedora 把 timesyncd 放在 systemd-udev 里（不存在 systemd-timesyncd 包）
    if [ -f "$MNT/usr/lib/systemd/system/systemd-timesyncd.service" ]; then
        log "systemd-timesyncd 可用（由 systemd-udev 提供）"
    else
        warn "未找到 systemd-timesyncd.service（时间同步将缺失）"
    fi

    # systemd-boot 的 aa64 EFI 由 systemd-boot-unsigned 提供，lib/boot.sh 负责复制到 ESP
    if [ -f "$MNT/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" ]; then
        log "systemd-bootaa64.efi 就位"
    else
        warn "缺少 systemd-bootaa64.efi（systemd-boot-unsigned 未安装？ESP 将无法启动）"
    fi

    # installroot 内 udev 硬件库不会自动更新
    chroot_sh "systemd-hwdb update" >/dev/null 2>&1 || true
    chroot_sh "udevadm hwdb --update" >/dev/null 2>&1 || true

    log "基础包安装完成（已装 $(rpm --root "$MNT" -qa 2>/dev/null | wc -l) 个 RPM）"
}

# ---------------------------------------------------------------------------
# 3. 桌面层：niri + quickshell + 输入法 + 虚拟键盘
# ---------------------------------------------------------------------------
distro_desktop() {
    step "Fedora 桌面层（${COMPOSITOR:-niri} + quickshell + 虚拟键盘）"
    mount_virtual

    local pkgs
    pkgs=$(_fedora_pkglist "$FEDORA_PKGS_DESKTOP")
    [ -n "$pkgs" ] || die "包列表为空: $FEDORA_PKGS_DESKTOP"
    _fedora_dnf install $pkgs || die "桌面包安装失败"

    if [ "${COMPOSITOR:-niri}" = "sway" ]; then
        _fedora_dnf install sway swaybg || warn "sway 安装失败"
    fi

    # quickshell：仓库版 0.2.1^git20260209 的 apiVersion 低于 DMS 2.1.2 要求的 38；
    # build-quickshell.sh 自行检测版本，仅在不足时从源码构建 v0.3.2
    if bash "$FEDORA_DIR/build-quickshell.sh"; then
        log "quickshell 就绪：$(chroot_sh "qs --version 2>/dev/null | head -1" 2>/dev/null || echo '版本未知')"
    else
        warn "quickshell 源码构建失败：继续使用仓库版本（DMS 可能报 apiVersion 不足）"
    fi

    # 虚拟键盘：Fedora 无 squeekboard 包 -> 源码构建，不可行时退回 wvkbd 并装兼容包装
    if bash "$FEDORA_DIR/build-squeekboard.sh"; then
        log "虚拟键盘就绪"
    else
        warn "虚拟键盘未安装（触摸输入需外接键盘）"
    fi

    chroot_sh "test -x /usr/bin/qs" 2>/dev/null || warn "/usr/bin/qs 缺失，dms run 无法启动"

    log "桌面层完成"
}

# ---------------------------------------------------------------------------
# 4. Fedora 特有配置
#    注意：fstab / hostname / hosts / locale.conf / vconsole.conf / localtime /
#    用户与密码 / sudoers / sshd / zram / sysctl / logind / journald /
#    raphael-growfs / NetworkManager+sshd+bluetooth+fstrim+timesyncd 启用
#    均由 lib/configure.sh 的 configure_common 处理，这里只做 Fedora 独有项。
# ---------------------------------------------------------------------------
distro_configure() {
    step "Fedora 特定配置（locale 编译 / SELinux / 缓存清理）"
    mount_virtual

    # ---- locale：Fedora 最小安装只有 C/POSIX，zh_CN 需 localedef 编译 ------
    local loc name
    for loc in "zh_CN:UTF-8" "en_US:UTF-8"; do
        name="${loc%%:*}.${loc##*:}"
        if chroot_sh "localedef -i ${loc%%:*} -f ${loc##*:} $name" >/dev/null 2>&1; then
            log "locale 编译完成: $name"
        else
            warn "localedef 失败: $name（glibc-locale-source 是否安装？）"
        fi
    done
    if chroot_sh "locale -a 2>/dev/null | grep -qix 'zh_CN.utf8'"; then
        log "locale -a 已包含 zh_CN.utf8"
    else
        warn "locale -a 中没有 zh_CN.utf8，中文界面可能回退到 C"
    fi

    # ---- 默认图形目标（greetd 由 lib/desktop.sh 启用）----------------------
    chroot_sh "systemctl set-default graphical.target" >/dev/null 2>&1 \
        || warn "设置 graphical.target 失败"

    # 手机不需要 NetworkManager 的启动等待
    svc_disable NetworkManager-wait-online.service

    # ---- SELinux ----------------------------------------------------------
    # 镜像在无 SELinux 的主机上构建，文件没有 security.selinux 标签：
    #   策略已装 -> permissive（保留审计，但不阻断首启）
    #   策略未装 -> disabled
    install -d "$MNT/etc/selinux"
    if [ -f "$MNT/etc/selinux/config" ]; then
        sed -i 's/^SELINUX=.*/SELINUX=permissive/' "$MNT/etc/selinux/config"
        if ! grep -q '^SELINUX=' "$MNT/etc/selinux/config"; then
            printf 'SELINUX=permissive\n' >> "$MNT/etc/selinux/config"
        fi
        log "SELinux = permissive（策略已安装；标签缺失只记审计，不阻断启动）"
    else
        printf 'SELINUX=disabled\nSELINUXTYPE=targeted\n' > "$MNT/etc/selinux/config"
        log "SELinux = disabled（未安装 selinux-policy）"
    fi

    # ---- 重置 machine-id：所有设备共用构建时的 id 会导致 DHCP/序列号冲突 ---
    : > "$MNT/etc/machine-id"
    rm -f "$MNT/var/lib/dbus/machine-id" 2>/dev/null || true

    # ---- dnf/rpm 缓存与日志（finalize 只清 /var/cache/dnf 一层）-----------
    rm -rf "$MNT"/var/cache/dnf/* "$MNT"/var/cache/libdnf5/* "$MNT"/var/cache/PackageKit/* 2>/dev/null || true
    rm -rf "$MNT"/var/lib/dnf/history* "$MNT"/var/lib/dnf5/history* 2>/dev/null || true
    rm -f "$MNT"/var/log/dnf5.log* "$MNT"/var/log/dnf.log* "$MNT"/var/log/hawkey.log* 2>/dev/null || true

    log "Fedora 配置完成"
}

# ---------------------------------------------------------------------------
# 5. initramfs：dracut + 模块 99raphael（嵌套 GPT -> loop 映射）
# ---------------------------------------------------------------------------
distro_initramfs() {
    step "生成 initramfs（dracut + 99raphael）"
    mount_virtual

    local kver=${KVER:-}
    if [ -z "$kver" ]; then
        kver=$(ls "$MNT/lib/modules" 2>/dev/null | grep -vxE 'build|source' | head -1 || true)
    fi
    [ -n "$kver" ] || die "无法确定内核版本（KVER 未设置且 /lib/modules 为空）"
    [ -d "$MNT/lib/modules/$kver" ] || die "缺少内核模块目录: /lib/modules/$kver"
    log "内核版本: $kver"

    # ---- 1) dracut 模块装入镜像 ------------------------------------------
    local moddir="$MNT/usr/lib/dracut/modules.d/99raphael"
    install -d "$moddir"
    install -Dm755 "$FEDORA_DIR/dracut/99raphael/module-setup.sh"    "$moddir/module-setup.sh"
    install -Dm755 "$FEDORA_DIR/dracut/99raphael/raphael-subpart.sh" "$moddir/raphael-subpart.sh"

    # ---- 2) 公共层的映射脚本（overlay/initramfs/raphael-subpartition）----
    local src=${RAPHAEL_INITRAMFS_SCRIPT:-}
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        die "缺少嵌套 GPT 映射脚本（RAPHAEL_INITRAMFS_SCRIPT=${src:-未设置}）"
    fi
    install -Dm755 "$src" "$MNT/usr/lib/raphael-subpartition"

    # ---- 3) dracut 默认参数 ----------------------------------------------
    install -d "$MNT/etc/dracut.conf.d"
    cat > "$MNT/etc/dracut.conf.d/99-raphael.conf" <<'EOF'
# 由 distro/fedora/distro.sh 生成
add_dracutmodules+=" raphael "
add_drivers+=" loop "
force_drivers+=" loop "
filesystems+=" btrfs "
compress="zstd"
hostonly="no"
EOF

    # ---- 4) 生成 ---------------------------------------------------------
    # btrfs 为内核内建（见 config/device.conf），--add-drivers 里的 btrfs 只会得到
    # 一条 builtin 提示；loop 是模块，必须显式加入。
    # PATH 显式补全：dracut 的 inst_multiple 靠 PATH 找 losetup/parted（/usr/sbin）
    local rpath=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    log "dracut --force --no-hostonly --kver $kver --add raphael --add-drivers 'btrfs loop'"
    if ! chroot_sh "PATH=$rpath dracut --force --no-hostonly --kver $kver --add 'raphael' --add-drivers 'btrfs loop' /boot/initrd.img-$kver"; then
        die "dracut 生成 initramfs 失败"
    fi
    [ -s "$MNT/boot/initrd.img-$kver" ] || die "dracut 未产出 /boot/initrd.img-$kver"

    # ---- 5) 解包校验：映射脚本 + 支持 --sector-size 的 losetup ------------
    local tmp="$WORK_DIR/initrd-verify"
    rm -rf "$tmp"
    install -d "$tmp"
    # dracut 可能用 zstd/xz/gzip 压缩，也可能完全不压缩（镜像里缺压缩工具时）
    # 注意：解包依赖 cpio（已在 tools/host-prep.sh 与 Fedora 包列表中加入）
    local dec
    for dec in "zstd -dc" "xz -dc" "gzip -dc" "cat"; do
        rm -rf "$tmp"
        install -d "$tmp"
        if ( cd "$tmp" && $dec "$MNT/boot/initrd.img-$kver" 2>/dev/null | cpio -idm --quiet 2>/dev/null ) \
           && [ -e "$tmp/usr/lib/raphael-subpartition" ]; then
            break
        fi
    done

    [ -e "$tmp/usr/lib/raphael-subpartition" ] || die "initramfs 内缺少 /usr/lib/raphael-subpartition"
    if find "$tmp" -path '*hooks*' -name '*raphael*' 2>/dev/null | grep -q .; then
        log "initramfs 含 raphael pre-udev hook"
    else
        die "initramfs 内缺少 99raphael 的 pre-udev hook"
    fi

    # initramfs 里可能同时存在 busybox 的 losetup applet 与 util-linux 的 losetup；
    # 取体积最大的那个（真 losetup 约 200KB）
    local lo size cand s
    lo=""; size=0
    for cand in $(find "$tmp" -type f -name losetup 2>/dev/null); do
        s=$(stat -c%s "$cand" 2>/dev/null || echo 0)
        [ "$s" -gt "$size" ] && { size=$s; lo=$cand; }
    done
    [ -n "$lo" ] || die "initramfs 内缺少 losetup"
    if strings "$lo" 2>/dev/null | grep -q 'sector-size'; then
        log "initramfs 内 losetup 支持 --sector-size（$lo, $size 字节）"
    else
        warn "initramfs 内 $lo（$size 字节）未匹配 sector-size；候选："
        find "$tmp" -name 'losetup' 2>/dev/null | sed 's/^/    /' | head -10
        die "initramfs 内 losetup 不支持 --sector-size，嵌套 GPT 映射会失败"
    fi
    rm -rf "$tmp"

    # ---- 6) 固定名引导用副本（lib/boot.sh 读 WORK_DIR/initrd.img）--------
    install -Dm644 "$MNT/boot/initrd.img-$kver" "$WORK_DIR/initrd.img"
    KVER=$kver
    export KVER

    log "initramfs 就绪: /boot/initrd.img-$kver ($(du -h "$MNT/boot/initrd.img-$kver" | cut -f1)) + $WORK_DIR/initrd.img"
}
