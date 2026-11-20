#!/usr/bin/env bash
# 构建产物自检（在镜像已挂载、各阶段完成后执行）

VERIFY_FAIL=0
v_ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
v_bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; VERIFY_FAIL=$((VERIFY_FAIL+1)); }
v_warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
v_file() { [ -e "$MNT$1" ] && v_ok "$1" || v_bad "缺少 $1"; }

verify_image() {
    step "镜像自检"

    echo "[引导]"
    v_file /boot/vmlinuz
    v_file /boot/initrd.img
    v_file /boot/EFI/BOOT/BOOTAA64.EFI
    local entry
    entry=$(ls "$MNT"/boot/loader/entries/*.conf 2>/dev/null | head -1)
    if [ -n "$entry" ]; then
        v_ok "loader 条目: $(basename "$entry")"
        grep -q "rootflags=subvol=@" "$entry" && v_ok "cmdline 含 rootflags=subvol=@" || v_bad "cmdline 缺少 rootflags=subvol=@"
        grep -q "root=UUID=$ROOT_UUID" "$entry" && v_ok "cmdline root UUID 正确" || v_bad "cmdline root UUID 不匹配"
    else
        v_bad "缺少 loader 条目"
    fi

    echo "[内核与模块]"
    if [ -n "${KVER:-}" ] && [ -d "$MNT/lib/modules/$KVER" ]; then
        v_ok "模块目录 /lib/modules/$KVER ($(find "$MNT/lib/modules/$KVER" -name '*.ko*' | wc -l) 个)"
    else
        v_bad "缺少 /lib/modules（KVER=${KVER:-未设置}）"
    fi
    [ -e "$MNT/boot/dtbs/qcom/sm8150-xiaomi-raphael.dtb" ] && v_ok "设备树 sm8150-xiaomi-raphael.dtb" \
        || v_bad "缺少 raphael 设备树"

    echo "[文件系统]"
    grep -q "subvol=@" "$MNT/etc/fstab" && v_ok "fstab 使用 btrfs subvol=@" || v_bad "fstab 未使用 btrfs 子卷"
    grep -q "subvol=@home" "$MNT/etc/fstab" && v_ok "fstab 使用 subvol=@home" || v_bad "fstab 缺少 @home"
    if [ -n "${LOOP:-}" ]; then
        local fsid
        fsid=$(blkid -s UUID -o value "${LOOP}p2" 2>/dev/null || true)
        [ "$fsid" = "$ROOT_UUID" ] && v_ok "root 分区 UUID = $ROOT_UUID" || v_bad "root 分区 UUID 不匹配: $fsid"
    fi

    echo "[桌面]"
    for f in /usr/share/quickshell/dms/shell.qml /usr/bin/dms /usr/bin/dms-greeter \
             /etc/greetd/config.toml /etc/greetd/niri_overrides.kdl \
             /etc/skel/.config/niri/config.kdl /etc/pam.d/dankshell; do
        v_file "$f"
    done
    # /usr/bin/qs 是指向 /usr/bin/quickshell 的绝对符号链接，宿主机上 -x 会解析到宿主路径
    if chroot_sh "test -x /usr/bin/qs" >/dev/null 2>&1; then
        v_ok "/usr/bin/qs（quickshell 运行时）"
    else
        v_bad "缺少可用的 /usr/bin/qs，dms run 无法启动"
    fi
    if [ -x "$MNT/usr/bin/squeekboard" ]; then v_ok "虚拟键盘 squeekboard"; else v_warn "未找到 squeekboard（虚拟键盘不可用）"; fi
    grep -q "transform" "$MNT/etc/skel/.config/niri/config.kdl" && v_ok "默认横屏配置存在" || v_bad "缺少横屏配置"
    if ls "$MNT"/etc/systemd/system/*.wants/greetd.service >/dev/null 2>&1 \
       || [ -L "$MNT/etc/systemd/system/display-manager.service" ]; then
        v_ok "greetd 已启用（display-manager）"
    else
        v_warn "greetd 未启用（登录界面不会出现）"
    fi

    echo "[initramfs]"
    local initrd="$MNT/boot/initrd.img"
    if [ -f "$initrd" ]; then
        local tmp="$WORK_DIR/initrd-check"
        rm -rf "$tmp"; mkdir -p "$tmp"
        # 之前 cpio 在父 shell 的 cwd 里解包（cd 只在管道左侧子 shell 生效），现已修好
        local list="$WORK_DIR/initrd.list"
        if ( cd "$tmp" && { zstd -dc "$initrd" 2>/dev/null || xz -dc "$initrd" 2>/dev/null || gzip -dc "$initrd" 2>/dev/null; } | cpio -t --quiet 2>/dev/null ) > "$list" && [ -s "$list" ]; then
            if grep -qE "raphael-subpartition$" "$list"; then
                v_ok "initramfs 含嵌套 GPT 映射脚本（$(grep -E "raphael-subpartition$" "$list" | head -1)）"
            else
                v_bad "initramfs 缺少 raphael-subpartition"
            fi
            ( cd "$tmp" && { zstd -dc "$initrd" 2>/dev/null || xz -dc "$initrd" 2>/dev/null || gzip -dc "$initrd" 2>/dev/null; } | cpio -idm --quiet 2>/dev/null ) || true
            local lo
            lo=$(find "$tmp" -name losetup -type f 2>/dev/null | head -1)
            # 以镜像内 losetup 的实际能力为准：容器的 strings 可能缺失，字符串判断会误报
            if [ -n "$lo" ] && chroot_sh "losetup --help 2>&1 | grep -q -- '--sector-size'" >/dev/null 2>&1; then
                v_ok "initramfs 内含支持 --sector-size 的 util-linux losetup（$lo）"
            elif chroot_sh "losetup --help 2>&1 | grep -q -- '--sector-size'" >/dev/null 2>&1; then
                v_warn "initramfs 未找到 losetup 文件，但镜像内 losetup 支持 --sector-size"
            else
                v_bad "initramfs 内 losetup 缺失或不支持 --sector-size"
            fi
        else
            v_bad "无法列出 initramfs 内容（解压失败）"
        fi
        local isz bsz
        isz=$(stat -c%s "$initrd")
        bsz=$(df -B1 "$MNT/boot" | awk 'NR==2{print $4}')
        [ "$isz" -lt "$bsz" ] && v_ok "initramfs 大小 $(numfmt --to=iec "$isz") < ESP 剩余 $(numfmt --to=iec "$bsz")" \
            || v_bad "ESP 空间不足（initramfs $isz > 剩余 $bsz）"
        rm -rf "$tmp"
    else
        v_bad "缺少 /boot/initrd.img"
    fi

    echo "[服务]"
    ls "$MNT"/etc/systemd/system/multi-user.target.wants/NetworkManager.service >/dev/null 2>&1 \
        && v_ok "NetworkManager 已启用" || v_warn "NetworkManager 未启用"
    ls "$MNT"/etc/systemd/system/multi-user.target.wants/sshd.service >/dev/null 2>&1 \
        || ls "$MNT"/etc/systemd/system/multi-user.target.wants/ssh.service >/dev/null 2>&1 \
        && v_ok "SSH 已启用" || v_warn "SSH 未启用"

    echo
    if [ "$VERIFY_FAIL" -gt 0 ]; then
        die "自检失败：$VERIFY_FAIL 项"
    fi
    log "镜像自检通过"
}
