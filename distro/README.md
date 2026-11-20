# 发行版层接口契约（distro/<name>/distro.sh）

`build.sh` 在挂载好镜像（rootfs 位于 `$MNT`，ESP 位于 `$MNT/boot`）后，
source `distro/<name>/distro.sh` 并调用下列函数。所有函数运行在 root 下、
且镜像根已挂载；可使用 `lib/common.sh` 提供的 log/step/warn/die/chroot_sh/
svc_enable/svc_mask/copy_tree 等工具。

必须实现的函数：

| 函数 | 时机 | 职责 |
|---|---|---|
| `distro_bootstrap` | 镜像创建后 | 从零填充根文件系统（Arch: 解包 ALARM rootfs；Fedora: dnf --installroot 安装 fedora-release 最小集） |
| `distro_packages` | bootstrap 后 | 安装基础/硬件/桌面依赖包（包列表放 distro/<name>/packages*.txt） |
| `distro_desktop` | packages 后 | 安装合成器(niri)、quickshell、虚拟键盘；必要时源码构建 |
| `distro_configure` | desktop 后 | locale/时区/hostname/users/ssh/zram/fstab/服务启用、systemd-boot 包 |
| `distro_initramfs` | 内核安装后 | 生成 initramfs → 必须产出 `$MNT/boot/initrd.img-$KVER` 和 `$WORK_DIR/initrd.img` |

约定：
- `$KVER` 由 `lib/kernel.sh` 设置（内核版本），initramfs 函数可直接使用。
- 嵌套 GPT 映射脚本必须由发行版 initramfs 生成器装入镜像（Arch: mkinitcpio hook；
  Fedora: dracut 模块），内容见 `lib/raphael-initramfs.sh`（已提供，直接安装即可）。
- 内核模块目录已就位（`/lib/modules/$KVER`），firmware 已在 `/usr/lib/firmware`。
- btrfs 子卷布局：`/` = `subvol=@`，`/home` = `subvol=@home`，`/boot` = FAT32 ESP。
  fstab 由 `lib/configure.sh` 统一写入，发行版层不要覆盖（除非需要额外挂载）。
- 不要修改 `config/device.conf` 的镜像几何，也不要改动 `lib/` 下他人负责的文件。

可参考已完成的实现：`distro/arch/`、`distro/fedora/`。
