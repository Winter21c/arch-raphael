#!/usr/bin/env bash
# 公共函数：日志、下载、解包、chroot、挂载清理

C_RESET=$'\033[0m'; C_BLUE=$'\033[0;34m'; C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'

log()  { printf '%s[%s]%s %s\n' "$C_BLUE" "$(date +'%H:%M:%S')" "$C_RESET" "$*"; }
step() { printf '\n%s==> %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s[警告] %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
die()  { printf '%s[错误] %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
need_cmd() { local c; for c in "$@"; do have "$c" || die "缺少命令: $c"; done; }
require_root() { [ "$(id -u)" -eq 0 ] || die "需要 root 权限（镜像创建/挂载/chroot），请用 sudo 运行"; }
ensure_dirs() { mkdir -p "$CACHE_DIR" "$WORK_DIR" "$MNT"; }

# 下载（带重试），已存在则跳过
dl() {
    local url="$1" out="$2"
    if [ -s "$out" ]; then log "缓存命中: $(basename "$out")"; return 0; fi
    mkdir -p "$(dirname "$out")"
    log "下载: $url"
    curl -fL --retry 5 --retry-delay 2 --connect-timeout 20 -o "$out.part" "$url" || { rm -f "$out.part"; die "下载失败: $url"; }
    mv "$out.part" "$out"
}

# 解包 .deb（不依赖 dpkg，Arch/Fedora 主机通用）
extract_deb() {
    local deb="$1" dest="$2" tmp data
    tmp=$(mktemp -d)
    ( cd "$tmp" && ar x "$deb" ) || { rm -rf "$tmp"; die "无法解开 deb: $deb"; }
    data=$(ls "$tmp"/data.tar* 2>/dev/null | head -1)
    [ -n "$data" ] || { rm -rf "$tmp"; die "deb 内找不到 data.tar: $deb"; }
    mkdir -p "$dest"
    tar --use-compress-program=unzstd -xf "$data" -C "$dest" 2>/dev/null || tar -xf "$data" -C "$dest"
    rm -rf "$tmp"
}

in_chroot()   { chroot "$MNT" "$@"; }
chroot_sh()   { chroot "$MNT" /bin/sh -c "$1"; }

mount_virtual() {
    # 新建的 btrfs 子卷是空的：先建挂载点，否则 mount 会因路径不存在而失败
    mkdir -p "$MNT/proc" "$MNT/sys" "$MNT/dev/pts" "$MNT/etc" "$MNT/tmp" "$MNT/var/tmp"
    mountpoint -q "$MNT/proc"    || mount -t proc proc "$MNT/proc"
    mountpoint -q "$MNT/sys"     || mount --rbind /sys "$MNT/sys"
    mountpoint -q "$MNT/dev"     || mount --rbind /dev "$MNT/dev"
    mountpoint -q "$MNT/dev/pts" || mount --rbind /dev/pts "$MNT/dev/pts"
    [ -f "$MNT/etc/resolv.conf" ] || cp -L /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true
}

umount_virtual() {
    local d
    for d in dev/pts dev sys proc; do
        mountpoint -q "$MNT/$d" && umount -l "$MNT/$d" 2>/dev/null
    done
    return 0
}

cleanup_all() {
    set +e
    umount_virtual
    local d
    for d in boot home; do
        mountpoint -q "$MNT/$d" && umount -Rl "$MNT/$d" 2>/dev/null
    done
    mountpoint -q "$MNT" && umount -Rl "$MNT" 2>/dev/null
    # 兜底：按镜像路径找到 loop 并 detach（LOOP 变量可能已丢失）
    if [ -n "${IMAGE_PATH:-}" ]; then
        for d in $(losetup -j "$IMAGE_PATH" -O NAME -n 2>/dev/null); do
            losetup -d "$d" 2>/dev/null
        done
    fi
    LOOP=""
    return 0
}

# systemctl 在 chroot 里不可靠（没有运行中的 systemd）；优先用宿主机 --root 离线操作
_svc_op() {
    local op="$1"; shift
    [ -d "$MNT/etc/systemd" ] || { warn "缺少 $MNT/etc/systemd，跳过 $op $*"; return 0; }
    if have systemctl && systemctl --root="$MNT" "$op" "$@" >/dev/null 2>&1; then
        return 0
    fi
    if chroot_sh "systemctl $op $*" >/dev/null 2>&1; then
        return 0
    fi
    warn "systemctl $op $* 失败（镜像内可能未生效）"
    return 0
}

svc_enable()  { _svc_op enable "$@"; }
svc_mask()    { _svc_op mask "$@"; }
svc_disable() { _svc_op disable "$@"; }

copy_tree() { local src="$1" dst="$2"; mkdir -p "$dst"; tar -C "$src" -cf - . | tar -C "$dst" -xf -; }
