# 项目状态（截至第 15 轮）

> 结论：**构建设施已完成并全部实跑通过**；剩下唯一未完成项是**真机刷入 + 驱动逐项验证**，
> 该项被硬件阻塞：红米 K20 Pro 自第 2 轮起不再出现在 USB 上（`lsusb` 无 `18d1/05c6`）。

## 1. 已交付并验证

### 两个仓库

| 仓库 | 作用 |
|---|---|
| [Winter21c/arch-raphael](https://github.com/Winter21c/arch-raphael) | 源码：`build.sh`、`lib/`、`distro/{arch,fedora}`、`tools/`、文档；CI 只做静态自检 |
| [Winter21c/arch-raphael-build](https://github.com/Winter21c/arch-raphael-build) | 专用构建：从源码仓库 checkout，在 `ubuntu-24.04-arm` 构建并发布到自身 Release |

### Release `latest` 产物

| 文件 | 大小 | 已验证 |
|---|---|---|
| `rootfs-arch-7.3.7z` | 1990 MB | 离线挂载逐项核对 |
| `boot-arch-7.3.img` | 42 MB | kernel 28,180,480B，偏移 56 为 `ARMd`（原始 arm64 Image）；initramfs 内含 `raphael-subpartition` 诊断版 |
| `rootfs-fedora-7.3.7z` | 1159 MB | 离线挂载逐项核对 |
| `boot-fedora-7.3.img` | 47.4 MB | kernel 28,180,480B，偏移 56 为 `ARMd` |

### 离线验证证据（挂载真实镜像得出，非推断）

- **引导链**：`default.target → graphical.target（Wants=display-manager.service）→ display-manager.service → greetd → dms-greeter --command niri`
- **桌面**：`/usr/bin/dms`(83MB, DMS 2.1.2 QML)、`/usr/bin/qs → quickshell`、`/usr/lib64/qt6/qml/Quickshell`
- **虚拟键盘**：Arch 用真 `squeekboard`(5.2MB ELF)；Fedora 用兼容包装 → `wvkbd-mobintl`
- **横屏**：`/etc/skel/.config/niri/config.kdl` 与 `/etc/greetd/niri_overrides.kdl` 均含 `transform 90`
- **文件系统**：fstab `subvol=@` / `@home` + ESP `1BF4-A32B`；首启 `raphael-growfs.service`
- **initramfs 映射**：Arch 为 mkinitcpio hook + `/usr/lib/raphael-subpartition`；Fedora 为 dracut `pre-udev` hook `30-raphael-subpart.sh` + 同一脚本
- **音频**：DT `sound { model = "Raphael" }` ↔ UCM `/usr/share/alsa/ucm2/Raphael/` ↔ 驱动 `SND_SOC_SM8150/WCD934X/WSA881X + QDSP6_*` ↔ 固件 `adsp.mbn`
- **账号**：`root` / `user`(1001, wheel+video+input+render+audio) / `greeter`(962, /var/lib/greetd)

### 构建参数（CI 输入，均已实跑）

`distro`(both/arch/fedora)、`kernel_version`、`image_size`、`compress`、
`root_password`、`user_name`、`user_password`、`hostname`、`install_ime`、`source_repo`、`source_ref`。

本地等价：`sudo ./build.sh arch|fedora [stage]`，凭据用 `ROOT_PASS=… USER_NAME=… USER_PASS=…` 覆盖。

## 2. 唯一未完成：真机刷写与驱动验证

设备需人工恢复（USB 端口复位无效，设备会直接消失）：

1. **长按电源 10~15 秒**强制断电（屏幕全黑后松手）；
2. **按住音量下 + 电源** 进入 fastboot；
3. 插 USB。

然后一条命令完成刷机：

```bash
sudo tools/flash.sh --boot boot-arch-7.3.img rootfs.img   # 预检 boot 分区容量 → 刷 boot → 刷 userdata → 重启
tools/wait-boot.sh                                        # 等 172.16.42.1 SSH（自动 DHCP + 每 20s 重试）
tools/device-test.sh --touch --sound                      # 9 组 32 项：系统/根fs/显示/触控/音频/WiFi+BT/电池/桌面/日志
```

若起不来：屏幕会打印 `loglevel=7` 的内核日志，以及我们加的诊断行

```
raphael: expected root UUID: ee8d3593-...
raphael:   /dev/loop0p1  uuid=1BF4-A32B label=Boot type=vfat
raphael:   /dev/loop0p2  uuid=ee8d3593-... label=Root type=btrfs
```

拍照即可定位是「没映射上」「UUID 不匹配」还是「面板/GPU 未初始化」。

## 3. 已知风险

| 风险 | 说明 / 缓解 |
|---|---|
| `fastboot flash boot` 容量 | Arch 42MB、Fedora 47.4MB（分区约 64MB）；`flash.sh` 会先 `getvar partition-size:boot` 预检，超了直接报错不刷。 |
| ABL 对 header v2 的支持 | raphael 为 Android 10 代 ABL，支持 v2+DTB；若仍拒绝，可改走 U-Boot + systemd-boot（镜像 ESP 里已备好 `EFI/BOOT/BOOTAA64.EFI`）。 |
| 首次启动扩容 | initramfs 里 `parted resizepart 2 100%` + 首启 `btrfs filesystem resize max /`；若 GPT 备份头位置告警，parted 用 `-f` 处理，失败也不影响启动（只是不扩容）。 |
| 基带 / 传感器 | `rmtfs/pd-mapper/hexagonrpcd` 在 Arch/Fedora 无官方包，代码按 `command -v` 降级；蜂窝与部分传感器可能不可用。 |
| Fedora 桌面 | quickshell 源码构建最耗时；已补 `-DINSTALL_QMLDIR`，构建失败会自动回滚到仓库版并告警。 |
