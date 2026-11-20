# 构建原理

> 面向想改构建脚本的人。刷机步骤见 [INSTALL.md](INSTALL.md)，用户向总览见 [../README.md](../README.md)。

## 1. 一次构建做了什么

入口是 `build.sh <arch|fedora> [stage] [--inner]`。`all` 会按下面的顺序跑完全部阶段：

| # | 阶段 | 实际调用 | 作用 | 前提 |
|:--:|---|---|---|---|
| 1 | `prepare` | `lib/prepare.sh: prepare_all` | 下载内核/固件/ALSA deb 与 dux-shell、dux-greeter 产物到 `cache/` | 网络 |
| 2 | `image` | `lib/image.sh: img_create` | 建 4096 扇区 GPT 镜像（p1 ESP / p2 btrfs），挂到 `work/rootdir` | root、losetup |
| 3 | `bootstrap` | `distro/<name>: distro_bootstrap` | 填充根文件系统（Arch 解包 ALARM tarball；Fedora `dnf --installroot`） | 发行版层 |
| 4 | `packages` | `distro_packages` | 安装基础/硬件/桌面包（`distro/<name>/packages*.txt`） | 发行版层 |
| 5 | `config` | `lib/configure.sh: configure_common` + `distro_configure` | fstab / 用户 / locale / SSH / zram / sysctl / logind / 首启扩容 / 服务 | 根文件系统可 chroot |
| 6 | `desktop` | `distro_desktop` + `lib/desktop.sh: desktop_install` | DMS、dux-greeter、greetd、niri 配置、虚拟键盘接线 | 上一步完成 |
| 7 | `hardware` | `lib/hardware.sh: hardware_overlay` | Wi-Fi / 音频 / VA-API / USB NCM / 背光 / 可选 rmtfs | 同上 |
| 8 | `kernel` | `lib/kernel.sh: kernel_install` | 解 deb，装 `/lib/modules`、DTB、firmware、ALSA UCM | 镜像已挂载 |
| 9 | `initramfs` | `distro_initramfs`（用 `lib/raphael-initramfs.sh` 助手） | 产出 `/boot/initrd.img-$KVER` 与 `work/initrd.img` | 内核已安装 |
| 10 | `boot` | `lib/boot.sh: boot_install` | 写 systemd-boot、固定名内核/initrd、loader 条目 | ESP 已挂载 |
| 11 | `verify` | `lib/verify.sh: verify_image` | 引导/内核/fstab/桌面/initramfs/服务自检（失败即中止） | 各阶段完成 |
| 12 | `finalize` | `lib/finalize.sh: finalize_image` | 卸载、`btrfs check`、sha256、打 .7z | 需要 `7z` |

分阶段构建：

```bash
sudo ./build.sh arch image        # 只建镜像骨架
sudo ./build.sh arch packages     # 再装包（自动 img_attach 重新挂载已有镜像）
sudo ./build.sh arch all          # 全流程
```

`img_attach`（`lib/image.sh`）会复用已有 loop 设备与挂载点，所以阶段可以反复执行；这是调试单个阶段的主要方式。

---

## 2. 为什么要 4096 字节扇区 + 嵌套 GPT

设备 UFS 的**逻辑扇区是 4096 字节**，U-Boot 也按 4096 去读 `userdata`。镜像整块写进 `userdata`，
它自己的 GPT 是**嵌套**的 —— U-Boot 和内核默认都只看到 `userdata` 这一个分区，看不到里面的 p1 / p2。

因此启动必须经过一次“再映射”：

```
userdata (4096B 扇区, 内部 GPT) --losetup --sector-size 4096 -P--> /dev/loopX
                                                                  ├── /dev/loopXp1  ESP (FAT32)
                                                                  └── /dev/loopXp2  Root (btrfs)
```

- 扇区大小写错（例如按 512 读）→ 分区表解析错位、`losetup` 报扇区大小错误，
  cmdline 里的 `root=UUID=...` 找不到根，表现为卡在 initramfs 或掉进 rescue shell。
- `-P` 让内核扫描 loop 内的分区表；没有它就不会出现 `/dev/loopXp1/p2`。
- 相关参数集中在 `config/device.conf`：`SECTOR_SIZE=4096`、`BOOT_PART_START=2048`、`BOOT_SIZE=512M`、`ROOT_UUID`。

---

## 3. initramfs 如何映射嵌套分区

脚本：`overlay/initramfs/raphael-subpartition`（POSIX sh），在挂载根之前运行：

1. 等待 `/dev/disk/by-partlabel/userdata`（最多约 5 秒，兼容 udev 慢启动）；
2. `losetup --find --show -P --sector-size 4096 --direct-io=on /dev/disk/by-partlabel/userdata`；
3. 用 cmdline 里的 `root=UUID=<ROOT_UUID>` 校验映射结果（`blkid --uuid`）；
   不匹配则**兜底遍历** `/sys/class/block/*` 的所有分区逐个尝试 —— 与 postmarketOS 的
   `mount_subpartitions` 思路一致，避免分区标签被改动后无法启动；
4. `parted resizepart 2 100% + partprobe`：把内嵌 p2 扩到镜像末尾
   （userdata 通常 48G 以上，而镜像只有 8G / 10G）；
5. `udevadm settle`，之后内核用 cmdline 的 UUID 找到真正的根。

**依赖二进制必须进 initramfs**：`losetup`、`blkid`、`parted`、`partprobe` 及它们的动态库。
`lib/raphael-initramfs.sh` 提供两个东西：

- `RAPHAEL_INITRAMFS_SCRIPT`：上面那个脚本的绝对路径；
- `raphael_copy_initramfs_deps <destdir>`：按 `ldd` 把二进制与库复制进 initramfs 根。

注册方式由发行版层决定（Arch: mkinitcpio hook；Fedora: dracut 模块），契约见 [../distro/README.md](../distro/README.md)。

---

## 4. btrfs 子卷与容量

- p2 是 btrfs，子卷 `@` → `/`，`@home` → `/home`；
  挂载参数来自 `config/device.conf`：`compress=zstd:3,noatime,ssd,discard=async`。
- `lib/configure.sh` 写 `/etc/fstab`：根与 `/home` 都用**固定 UUID**（`ROOT_UUID`），
  ESP 用 `BOOT_VOLID` 派生的 `1BF4-A32B` 形式。
- 容量是两层：
  1. initramfs 把**分区**扩到 userdata 末尾（`parted resizepart`）；
  2. 首次启动 `raphael-growfs.service` 执行 `btrfs filesystem resize max /` 把**文件系统**铺满分区。

  顺序不能反：先分区再文件系统。服务用 `/var/lib/raphael-growfs.done` 做一次性标记。

---

## 5. 引导链与内核更新

```
U-Boot
 └── ESP: /EFI/BOOT/BOOTAA64.EFI        (systemd-boot)
      └── /loader/entries/raphael.conf
            linux   /vmlinuz
            initrd  /initrd.img
```

- **固定名**（`/boot/vmlinuz`、`/boot/initrd.img`、`/boot/dtbs/qcom`）：引导器不需要猜内核版本号；
- `/usr/local/bin/raphael-kernel-update`（`lib/boot.sh` 写入）把 `/boot/vmlinuz-$KVER`、
  `/boot/initrd.img-$KVER`、DTB 同步到固定名；
- cmdline（`lib/image.sh: img_cmdline`）：

  ```
  root=UUID=ee8d3593-... rw rootflags=subvol=@ quiet loglevel=3 splash console=tty0 fbcon=rotate:1
  ```

---

## 6. 默认横屏是怎么实现的

两处独立设置，缺一个就会“桌面横了但控制台还是竖的”：

| 层 | 实现 | 变量 |
|---|---|---|
| 内核控制台 / 早期启动 | cmdline `fbcon=rotate:1` | `FBCON_ROTATE` |
| Wayland（登录界面 + 会话） | niri `output "DSI-1" { transform 90 }` | `SCREEN_ROTATION` |

- 登录界面：`/etc/greetd/niri_overrides.kdl`（`lib/desktop.sh`）
- 用户会话：`/etc/skel/.config/niri/config.kdl` 与 `/home/$USER/.config/niri/config.kdl`
- 想反过来（`270`）：`SCREEN_ROTATION=270 FBCON_ROTATE=3 sudo ./build.sh arch all`

---

## 7. 桌面与登录

- **dux-shell（DMS）**：预编译 `dms` 二进制 → `/usr/bin/dms`，QML → `/usr/share/quickshell/dms`；
  用户 niri 配置里 `spawn-at-startup "dms" "run"`。
- **dux-greeter**：`/usr/bin/dms-greeter` + `/etc/greetd/config.toml`：
  `command = "dms-greeter --command niri"`（`COMPOSITOR` 决定）。
- **虚拟键盘**：登录界面与会话都在 niri 配置里 `spawn-at-startup "squeekboard"`。
  squeekboard 本体由**发行版层**安装；`lib/desktop.sh` 只做接线与自检（缺失时打印警告）。
- `svc_mask getty@tty1`：避免 tty1 的 getty 与 greetd 的 vt 1 抢屏。

---

## 8. 硬件适配要点（`lib/hardware.sh`）

- Wi-Fi（ath10k）：`options ath10k_core skip_otp=y`，并用 `/etc/systemd/network/10-wlan0.link` 固定接口名 `wlan0`；
- 音频：WirePlumber 规则改成手机用的缓冲（`period-size 4096`），ALSA UCM 由 `lib/kernel.sh` 从 deb 装入；
- 视频硬解：`LIBVA_DRIVER_NAME=venus`（`/etc/environment.d/40-venus.conf`）；
- USB 网络：configfs 建 CDC-NCM gadget（`usb0` = `172.16.42.1`），`dnsmasq` 下发 `172.16.42.2-254`；
  设备侧没有 `dnsmasq` 时只打印警告，服务不启用；
- 背光：udev 规则让 `video` 组可写 `/sys/class/backlight/*/brightness`；
- **可选组件**：`rmtfs` / `pd-mapper` 只在系统里已存在时才启用（基带相关，默认不集成）。

---

## 9. 环境变量与交叉构建

`config/device.conf` 与 `config/distro.conf` 全部使用 `: "${VAR:=默认值}"`，
所以**外部环境变量优先**，CI 与 `make` 都靠这个覆盖：

| 变量 | 影响 |
|---|---|
| `KERNEL_VERSION` | 下载哪个 release 的内核 deb（`kernel-v<版本>`） |
| `IMAGE_SIZE` / `BOOT_SIZE` | 镜像与 ESP 大小 |
| `COMPRESS_IMAGE` | 是否打 .7z |
| `USER_NAME` / `USER_PASS` / `ROOT_PASS` | 默认账号 |
| `COMPOSITOR` / `SCREEN_ROTATION` / `INSTALL_IME` | 桌面行为 |
| `DUX_SHELL_VERSION` / `DUX_GREETER_VERSION` | dux 组件版本 |

**架构**：

- arm64 主机：直接构建（CI 用 `ubuntu-24.04-arm`）；
- x86_64 主机两种路径：
  1. 装 `qemu-user-static` + 注册 binfmt（`tools/host-prep.sh --with-cross`），
     然后 `sudo ./build.sh arch --inner`；
  2. 不装 binfmt，直接 `sudo ./build.sh arch` —— `build.sh` 会自动
     `docker run --privileged --platform linux/arm64`（镜像由 `CONTAINER_IMAGE` 决定），
     容器内先跑 `tools/host-prep.sh` 再执行 `build.sh <distro> <stage> --inner`。

---

## 10. 产物

| 文件 | 说明 |
|---|---|
| `rootfs.img` | 刷入 userdata 的镜像 |
| `rootfs-<distro>-<kernelver>.7z` | 压缩包（`COMPRESS_IMAGE=1`） |
| `rootfs-<distro>-<kernelver>.7z.sha256` | 压缩包校验和 |
| `rootfs-<distro>-<kernelver>.img.sha256` | 裸镜像校验和（文件名指向 `.img`，实际内容对应 `rootfs.img`） |

CI 会再算一次 payload 的 sha256 并上传 artifact；失败时上传 `build-<distro>-<kver>.log`。

---

## 11. 在电脑侧检查镜像（不用开机）

```bash
# 挂载镜像内部的 p2（注意必须是 4096 扇区）
sudo losetup --find --show --sector-size 4096 -P rootfs.img
lsblk
sudo mount -o subvol=@,compress=zstd:3 /dev/loopXp2 /mnt
ls /mnt/boot            # vmlinuz / initrd.img / EFI/BOOT/BOOTAA64.EFI
cat /mnt/etc/fstab
sudo umount /mnt && sudo losetup -D

# 只看分区表
fdisk -l -b 4096 rootfs.img
```
