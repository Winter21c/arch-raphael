# Fedora 44 (aarch64) 发行版层

Xiaomi Redmi K20 Pro (raphael) 的 Fedora 44 镜像层。由 `build.sh fedora` 在镜像
已挂载（rootfs = $MNT，ESP = $MNT/boot）后 source 并调用 5 个函数。

## 文件

| 文件 | 作用 |
|---|---|
| `distro.sh` | `distro_bootstrap / distro_packages / distro_desktop / distro_configure / distro_initramfs` |
| `packages.txt` | 基础/硬件/服务包（83 个） |
| `packages-desktop.txt` | 桌面包（30 个：niri / quickshell / Qt6 / fcitx5 / greetd） |
| `dracut/99raphael/module-setup.sh` | dracut 模块：装 losetup/blkid/parted/partprobe + pre-udev hook |
| `dracut/99raphael/raphael-subpart.sh` | pre-udev hook，转调公共层映射脚本 |
| `build-quickshell.sh` | 仓库版 quickshell 版本不足时源码构建 v0.3.2 |
| `build-squeekboard.sh` | squeekboard 源码构建，失败退回 wvkbd（含 squeekboard 兼容包装） |

没有 `repos/*.repo`：整套包（含 quickshell、niri、greetd、fcitx5）都在 Fedora 官方
`fedora` / `updates` 仓库里，源码构建只需要 devel 包，无需第三方仓库。

## 分工（不要重复公共层）

`lib/configure.sh:configure_common` 已负责：fstab（btrfs @/@home + ESP）、hostname/hosts、
locale.conf/vconsole.conf/localtime、用户与密码、sudoers、sshd、zram-generator、sysctl、
logind、journald、首启扩容 `raphael-growfs.service`、启用
NetworkManager/sshd/bluetooth/fstrim.timer/timesyncd、mask getty@tty1 与 sleep/suspend。

本层 `distro_configure` **只做 Fedora 特有项**：localedef 编译 locale、SELinux 策略、
默认 graphical.target、machine-id 重置、dnf 缓存清理。

`lib/desktop.sh:desktop_install` 负责 dms / dms-greeter / greetd 配置 / niri 用户配置 /
输入法环境变量；本层 `distro_desktop` 只负责 **包 + quickshell 运行时 + 虚拟键盘**。

## 关键实现决策

### 1. dnf5 --installroot

```
dnf5 -y --installroot="$MNT" --releasever=44 --forcearch=aarch64
     --setopt=install_weak_deps=False --setopt=tsflags=nodocs
     --setopt=excludepkgs="kernel kernel-core ... dracut-config-*"
     [--nogpgcheck] install <包...>
```

* `--excludepkgs` 排除 `kernel*`：内核/固件来自预编译 deb（`lib/kernel.sh`），
  dnf 再装一套会覆盖 `/lib/modules/$KVER`。
* 签名：installroot 内还没有公钥，首次安装必须 `--nogpgcheck`；随后把
  `/etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-*` 导入 installroot rpmdb，之后自动关闭
  `--nogpgcheck`（导入失败则退回并告警，镜像完整性由 finalize 的 sha256 兜底）。
* `/etc/dnf/vars/releasever` 固化 44，`/etc/dnf/dnf.conf` 固化同上策略，保证镜像内
  `dnf install` 行为与构建时一致。

### 2. SELinux

镜像在**没有 SELinux 的主机**上构建，文件系统上没有 `security.selinux` 标签。因此：

* `selinux-policy` 已安装 → `/etc/selinux/config` 改 `SELINUX=permissive`
  （标签缺失只记审计，不阻断首启）；
* 未安装策略（`install_weak_deps=False` 的常见结果）→ `SELINUX=disabled`。

### 3. initramfs（dracut 模块 99raphael）

* pre-udev 阶段（udevd 启动前）创建 loop 设备：映射逻辑来自公共层
  `overlay/initramfs/raphael-subpartition`（distro_initramfs 装到镜像 `/usr/lib/raphael-subpartition`），
  dracut 模块只负责 `inst_multiple losetup blkid parted partprobe` + `inst_hook pre-udev 30`。
  选 pre-udev 的原因：loop 设备先建好，udevd 冷插拔会自动扫出 `loop0p1/p2` 并生成
  `/dev/disk/by-uuid`，dracut 的 rootfs-block（pre-mount）才能按 `root=UUID=` 找到根。
* 生成后**解包校验**：必须含 `/usr/lib/raphael-subpartition`、pre-udev hook，且 losetup 二进制
  含 `sector-size` 字符串（busybox applet 不支持 `--sector-size`，会静默失败）。
* btrfs 扩容不放在 initramfs：`configure_common` 已生成首启 `raphael-growfs.service`
  （`btrfs filesystem resize max /`）；initramfs 只做 loop 映射 + 分区扩容。

### 4. quickshell 版本策略

Fedora 44 仓库版是 `0.2.1^git20260209.dacfa9d-5.fc44`，DMS 2.1.2 要求 apiVersion >= 38
（对应上游 v0.3.2）。`build-quickshell.sh`：

1. 版本探测顺序：`/usr/lib/raphael-quickshell.version`（源码构建标记）→ `qs --version` → rpm 版本；
2. 不足 `QS_MIN_VERSION`（默认 0.3.2）才构建，`QS_FORCE=1` 可强制；
3. 从 `quickshell-mirror/quickshell` 取 `v0.3.2` tarball（带缓存，无 submodule），
   **在 chroot 内 cmake+ninja 编译**（保证与镜像 Qt 6.11.2 的 ABI 一致）；
4. `-DCRASH_HANDLER=OFF`：上游默认依赖 cpptrace，Fedora 44 **没有** cpptrace/cpptrace-devel；
   v0.3.2 已移除 X11 后端，所以不需要 libxcb/X11；
5. 编译前 `rpm -e --nodeps quickshell` 让出 `/usr/bin/qs` 所有权，安装/校验失败会
   `dnf install quickshell` 回滚，保证镜像一定留有可用的 `/usr/bin/qs`。

### 5. 虚拟键盘策略

F44 repodata 实测：**既没有 squeekboard，也没有 wvkbd 包**，而 `lib/desktop.sh` 与 niri 配置都以
`squeekboard` 启动键盘。`build-squeekboard.sh` 三级降级：

1. **squeekboard v1.43.1 源码构建**（meson + cargo，Rust 侧 gtk 0.18 = GTK3，需要 crates.io）；
2. 依赖不可得 / crates.io 不可达 / 编译失败 → **wvkbd 源码构建**（纯 C，`make LAYOUT=mobintl`，
   只需 wayland-client + xkbcommon + pangocairo，Fedora 全都有），并安装
   `/usr/bin/squeekboard` 兼容包装 → `/usr/bin/wvkbd-mobintl`；
   包装里**不传** `--landscape` —— wvkbd 的 main.c 用 `available_width > available_height`
   自动切换横竖屏布局（把设备整体旋转 90° 后 surface 本身就是横屏尺寸）；
3. 两者都失败 → 装 `qt6-qtvirtualkeyboard`（只有 Qt 应用能用）并告警。

`SQUEEKBOARD_MODE=auto|squeekboard|wvkbd|none` 可强制指定路径。

## 校验

* `bash -n`：distro.sh、build-quickshell.sh、build-squeekboard.sh、module-setup.sh、
  raphael-subpart.sh 全部通过；distro.sh 在 `set -euo pipefail`（build.sh 的环境）下 source 无报错。
* 包名：**150 个**声明的包名（两个 packages*.txt + distro.sh 引导集 + 三个 *_DEPS + 降级包）
  逐个对照 Fedora 44 `Everything/aarch64` 的 `releases/44` 与 `updates/44` repodata
  （primary.xml.zst 解压出的 69663 个包名）校验，**缺失 0 个**。

## 风险

1. **quickshell 源码构建**是最长的一步（emulated aarch64 下可能需要 20-60 分钟），且依赖
   `Qt6CorePrivate/Qt6QuickPrivate` 的 devel 包布局。失败不会破坏镜像（回滚到仓库版 0.2.1），
   但 DMS 会报 apiVersion 不足 —— 此时应检查 Qt6 devel 是否齐全，或把 `QS_MIN_VERSION` 调到
   仓库版实际值。**若 DMS 后续升级解除 apiVersion 约束，把 `QS_MIN_VERSION` 设为 0.2.1 即可跳过整个编译。**
2. **squeekboard 是 Rust + crates.io 依赖**（gtk-rs 0.18/zbus/xkbcommon 0.9），Fedora 上没有对应的
   `librust-*-devel` 包，必须联网拉 crates.io；构建期无网络或 Rust 版本过低即自动退回 wvkbd。
   wvkbd 功能弱于 squeekboard（无 emoji 面板之外的高级布局、无输入法集成），但满足触摸打字。
3. **`qt6-qtquickcontrols2` 在 Fedora 44 不存在**：Qt 6.11 已把 QuickControls 并入
   `qt6-qtdeclarative`（该包提供 `/usr/lib64/qt6/qml/QtQuick/Controls/qmldir`）。包列表里装了
   `qt6-qtdeclarative`，DMS 的 `import QtQuick.Controls` 可满足；**不要**再往列表里加
   `qt6-qtquickcontrols2`（dnf 会直接报没有这个包）。
4. **没有 greetd-tuigreet / gtkgreet 官方包**（F44 有 gtkgreet、tuigreet 之外的 `greetd` 本体），
   登录界面依赖 `lib/desktop.sh` 安装的 dux-greeter（预编译 arm64）；若那一步没做，
   `/etc/greetd/config.toml` 的 `command` 会找不到可执行文件，需要人工改成自动登录。
5. **无 XWayland**：包列表没装 `xorg-x11-server-Xwayland`（手机体积优先）。需要跑 X11 应用时
   追加该包或将 compose 换成 xwayland-satellite（额外仓库）。
6. **高通守护进程缺失**：F44 没有 `pd-mapper` / `hexagonrpcd` / `qcom-phone-utils`，
   只有 `rmtfs`、`qrtr`、`fastrpc`（均已在列表或可选）。基带/传感器
   相关服务由 `lib/hardware.sh` 按 `command -v rmtfs` 条件启用，缺失只降级不失败。
7. **systemd-timesyncd 的包归属**：Fedora 没有 `systemd-timesyncd` 这个包，二进制与单元在
   `systemd-udev` 里。`configure_common` 的 `svc_enable systemd-timesyncd` 因此可生效，
   本层额外做了单元存在性检查。
8. **镜像大小**：`IMAGE_SIZE=10G`（config/distro.conf）。若保留 quickshell 编译依赖
   （`QS_KEEP_DEPS=1` 默认，含 gcc/Qt6 devel），根文件系统会多占约 600-800MB；空间紧张时用
   `QS_KEEP_DEPS=0` 让脚本构建完卸载 devel 包。
