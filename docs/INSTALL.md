# 刷机与首次启动排障

> 目标设备：小米 **Redmi K20 Pro（xiaomi-raphael / sm8150）**。
> 总览见 [../README.md](../README.md)，构建原理见 [BUILD.md](BUILD.md)。

---

## 0. 你需要准备什么

- 一台 **已解锁 BootLoader** 的 Redmi K20 Pro（数据会被清空）；
- **支持 Linux 引导的 U-Boot**（本仓库**不提供**，见第 2 节）；
- 电脑上的 Android **platform-tools**（`fastboot`、`adb`）与可用数据线；
- 本仓库/Release 提供的 `rootfs.img`（或 `rootfs-<distro>-<kver>.7z`）；
- 充足的耐心：8–10G 镜像的写入与首次启动都比较慢。

---

## 1. 解锁 BootLoader

1. 小米账号绑定设备并在「设置 → 更多设置 → 开发者选项 → 设备解锁状态」中申请解锁；
2. 使用官方 **Mi Unlock** 工具在 fastboot 下解锁，通常需要等待解锁期（168 小时左右）；
3. 解锁会清除全部数据。

> 解锁后用 `fastboot oem device-info` 可查看部分机型的解锁状态（不同 U-Boot/固件版本输出不同）。
> 解锁后**不要**再刷回官方 MIUI 的锁回状态，否则会失去 fastboot 刷写能力。

---

## 2. 准备 U-Boot（本项目不提供）

本仓库只产出根文件系统镜像。设备需要先由 U-Boot 负责初始化硬件并引导 ESP 上的
`/EFI/BOOT/BOOTAA64.EFI`（systemd-boot）。

U-Boot 的镜像来源与刷写方式请参考：

- [GengWei1997/linux-xiaomi-raphael-uboot](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot)（README / Wiki / 一键安装包）
- [Nura Wiki](https://wiki.nura.eco)

要点：

- U-Boot 必须能按**4096 字节扇区**读取 `userdata` 里的嵌套 GPT（本镜像即按此制作）；
- **刷 U-Boot 涉及的分区名（boot / aboot / 其它）以对应项目的文档为准**，
  本仓库不猜测、也不提供这些命令，避免刷错分区变砖。

---

## 3. 校验下载的镜像

```bash
# 7z 包：先测完整性再解压
7z t  rootfs-arch-7.3.7z
7z x  rootfs-arch-7.3.7z           # 得到 rootfs.img

# 校验和（两种都给，按你手上的文件选）
sha256sum -c rootfs-arch-7.3.7z.sha256
sha256sum -c rootfs-arch-7.3.7.img.sha256
```

`rootfs.img` 的大小通常 8–10 GiB（`IMAGE_SIZE` 决定），用 `ls -lh` 确认。

---

## 4. 刷写

```bash
# 1) 关机后按住 音量下 + 电源 进入 fastboot，或 adb reboot bootloader
fastboot devices                     # 能看到设备序列号

# 2) 整块写入 userdata —— 这一步会覆盖 Android 的 userdata 分区
fastboot flash userdata rootfs.img

# 3) 重启进系统
fastboot reboot
```

说明：

- 写入 8–10 GiB 通常需要 **几分钟**，`fastboot` 会持续打印进度，不要中途拔线；
- 若提示 `Partition table doesn't exist` / `Failed to load sparse` 之类，多半是
  U-Boot / fastboot 版本不匹配或镜像没解压完整；
- 想彻底回到“干净”状态：`fastboot erase userdata`（同样会丢数据）。

---

## 5. 首次启动的预期时间线

| 阶段 | 现象 | 首次耗时（参考） |
|---|---|---|
| U-Boot | 厂商/U-Boot logo | 数秒 |
| systemd-boot | 1 秒超时（`timeout 1`），可能一闪而过 | 1s |
| 内核 | 黑屏 / logo（`quiet splash`） | 5–20s |
| initramfs | 映射 userdata、扩分区，无输出 | 数秒 |
| btrfs / 服务 | 首次 `raphael-growfs.service`、NetworkManager 等初始化 | 数十秒 |
| greetd | 进入 **dux-greeter 登录界面**（横屏） | — |

首次启动整体可能 **1–3 分钟**；之后明显变快。**不要**在 initramfs 阶段就断电。

---

## 6. 登录与基本设置

| 用户 | 密码 | 权限 |
|:---:|:---:|:---|
| `user` | `1234` | wheel 组（`sudo`） |
| `root` | `1234` | root |

```bash
passwd                 # 立刻改密码（user）
sudo passwd root       # 改 root 密码
sudo btrfs filesystem usage /
```

**SSH（USB 直连）**：插 USB 到电脑后设备通过 CDC-NCM 暴露 `usb0` = `172.16.42.1`：

```bash
ssh user@172.16.42.1
# 电脑侧网卡应拿到 172.16.42.x 的 DHCP 地址（设备内置 dnsmasq）
```

**屏幕方向 / 输入法**：默认横屏（`transform 90`）。会话内临时改方向：

```bash
niri msg output DSI-1 transform 270
```

---

## 7. 排障

| 症状 | 可能原因 | 处理 |
|---|---|---|
| 停在 U-Boot，进不去系统 | U-Boot 未刷/版本不支持、镜像没写进去 | 重刷 U-Boot（按其文档）与 `userdata` |
| U-Boot 之后直接黑屏，长时间无反应 | ESP 里缺 `vmlinuz` / `initrd.img` / `BOOTAA64.EFI` | 在电脑上挂载镜像检查 `/boot`（见第 9 节） |
| 掉进 initramfs rescue shell | 嵌套分区映射失败：`losetup` 缺 `--sector-size`、`blkid/parted` 没进 initramfs、userdata 标签被改 | 在 rescue shell 里手工执行 `losetup --find --show -P --sector-size 4096 --direct-io=on /dev/disk/by-partlabel/userdata`，再 `blkid` 找 UUID |
| `root=UUID=... not found` | 同上，或镜像扇区大小不是 4096 | 确认用本仓库构建产物、未被重新分区 |
| 挂载根时报 `wrong fs type / bad option` | 少了 `rootflags=subvol=@` 或 btrfs 损坏 | 检查 ESP 上 `loader/entries/raphael.conf` 的 `options` 行 |
| 登录界面没有虚拟键盘、点不动输入框 | squeekboard 未安装（构建日志有警告），或合成器版本不支持输入法协议 | 插 **OTG 键盘/USB 键盘**；在镜像里装 squeekboard；或重建时切 `COMPOSITOR=sway` |
| 屏幕方向反了 | `SCREEN_ROTATION` / `FBCON_ROTATE` 与你机器方向不符 | 重建时改这两个变量；或运行时 `niri msg output DSI-1 transform 270` |
| 没有 Wi-Fi | 接口名不是 `wlan0`、ath10k 固件缺失、rfkill 关闭 | `ip l`、`dmesg` 里查 ath10k、`rfkill list` |
| SSH 连不上 `172.16.42.1` | `usb-ncm.service` 未起、`dnsmasq` 未装、电脑无 NCM 驱动 | `systemctl status usb-ncm`、`ip a show usb0`；改用蓝牙/Wi-Fi/OTG |
| 磁盘空间仍然只有 8/10G | 首启 `raphael-growfs.service` 没跑到 | `sudo btrfs filesystem resize max /`（分区已在 initramfs 扩过） |
| 卡在某服务超时、风扇/发热 | 首次初始化 + 缺少某些可选守护进程 | 耐心等待；`journalctl -b -p err` 看错误 |
| 彻底刷坏 / 想回 Android | — | 重刷原厂 ROM，或 `fastboot flash userdata` 官方镜像 |

**抓日志**：能进系统的话，`journalctl -b`、`dmesg`；不能进系统时，可在另一台电脑上挂载镜像查看
`/var/log`（首次启动前的日志不在镜像里）。

---

## 8. 从电脑侧检查镜像内容（不用开机）

```bash
# 分区表（必须用 4096 字节扇区查看）
fdisk -l -b 4096 rootfs.img

# 挂 p2 的 @ 子卷
sudo losetup --find --show --sector-size 4096 -P rootfs.img     # 记下 /dev/loopX
sudo mkdir -p /mnt/raphael && sudo mount -o subvol=@ /dev/loopXp2 /mnt/raphael
ls  /mnt/raphael/boot                     # vmlinuz / initrd.img / EFI/BOOT/BOOTAA64.EFI
cat /mnt/raphael/boot/loader/entries/raphael.conf
cat /mnt/raphael/etc/fstab
systemctl --root=/mnt/raphael is-enabled greetd.service    # 可选
sudo umount /mnt/raphael && sudo losetup -D
```

---

## 9. 恢复 / 回退

- **重新刷本镜像**：`fastboot flash userdata rootfs.img` 即可（会清空数据）；
- **回到 Android**：进入 fastboot 后刷回官方/第三方 ROM 的 `userdata` 与系统镜像（按其刷机说明），
  必要时 `fastboot -w` 清数据；
- **只换内核**：在系统内 `dpkg -i` 之类的内核包流程由发行版层决定，本仓库的固定名引导
  由 `raphael-kernel-update` 刷新（`/usr/local/bin/raphael-kernel-update`）。

---

## 10. 参考

- [GengWei1997/linux-xiaomi-raphael-uboot](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot)
- [Nura Wiki](https://wiki.nura.eco)
- [duxlabs-dev/dux-shell](https://github.com/duxlabs-dev/dux-shell) · [dux-greeter](https://github.com/duxlabs-dev/dux-greeter)
- [niri](https://github.com/YaLTeR/niri) · [squeekboard](https://gitlab.gnome.org/World/Phosh/squeekboard)
