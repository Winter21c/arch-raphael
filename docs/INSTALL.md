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
  由 `raphael-kernel-update` 刷新（`/usr/local/bin/raphael-kernel-update`）；
- **从任何状态回到 fastboot、以及刷回 Android 的具体命令**：见第 12 节。

---

## 10. 刷写与验证流程

前置：本机有 `fastboot` / `adb`（android-tools）与 `sshpass`；设备停在 fastboot。

```bash
# 0) 解压 + 校验（详见第 3 节）
7z x rootfs-arch-7.3.7z
sha256sum -c rootfs-arch-7.3.7.img.sha256

# 1) 刷写（覆盖 userdata，8-10G 需几分钟）
sudo tools/flash.sh rootfs.img

# 2) 等设备起来：轮询 USB-NCM 的 172.16.42.1:22
tools/wait-boot.sh

# 3) 逐项验证
tools/device-test.sh
```

串成一条（前一步失败就不往下走）：

```bash
sudo tools/flash.sh rootfs.img && tools/wait-boot.sh && tools/device-test.sh
```

常用变体：

| 场景 | 命令 |
|---|---|
| 刷完不自动重启（自己控制时机） | `sudo tools/flash.sh --no-reboot rootfs.img` |
| 首启慢，多等一会儿 | `tools/wait-boot.sh --timeout 600` |
| 现场测触控（提示在屏幕上滑动 3 秒） | `tools/device-test.sh --touch` |
| 现场测音频（播 440Hz） | `tools/device-test.sh --sound` |
| 存机器可读结果，逐轮对比 | `tools/device-test.sh --json > run-$(date +%s).json` |
| 用户名/密码/地址不是默认的 | `wait-boot.sh` 与 `device-test.sh` 都支持 `--user` / `--pass` / `--host` |

退出码与输出约定：

- `flash.sh`：非 0 = 刷写失败（镜像/设备/分区问题）；
- `wait-boot.sh`：非 0 = 超时，会打印「只读自查 + 4 步排查」建议；
- `device-test.sh`：非 0 = 存在 FAIL；WARN（多为「未实测」）不影响退出码；
- `--json` 输出
  `{schema, generated, host, user, connected, counts{pass,warn,fail}, checks[{id,status,detail,evidence[]}]}`，
  按 `id` 做两轮 diff，就能看出「这一轮新坏了什么」。

---

## 11. 逐项验证清单

`tools/device-test.sh` 逐项给 PASS / WARN / FAIL；下表是**看哪条命令的输出**。
手工命令都在设备上跑（`ssh user@172.16.42.1` 之后），用来复核不达标的那一项。

| 项目 | device-test id | 手工命令 | 正常的样子 |
|---|---|---|---|
| 触控 | `touch.input` / `touch.node` / `touch.events` | `grep -iE 'Name=\|Handlers=\|PROP=' /proc/bus/input/devices`<br>`sudo timeout 5 cat /dev/input/eventN \| wc -c`（滑动时跑） | 有触控块（`goodix-ts` 之类）、`B: PROP=2`（INPUT_PROP_DIRECT）、`H: Handlers=` 里有 `eventN`；滑动时字节数 > 0 |
| 显示 | `display.dri` / `display.connector` / `display.modes` | `ls /dev/dri`<br>`cat /sys/class/drm/card0-DSI-*/status`<br>`head -3 /sys/class/drm/card0-DSI-*/modes`<br>`niri msg outputs` | `/dev/dri` 有 `card0`；DSI 是 `connected`；有 `1080x2340 ...` 模式 |
| 音频 | `audio.cards` / `audio.mixer` / `audio.pipewire` / `audio.kernel` / `audio.tone` | `aplay -l`<br>`amixer scontrols`<br>`wpctl status`<br>`dmesg \| grep -iE 'wcd938x\|wsa881x\|adsp\|q6'` | `aplay -l` 有 `card 0:`；`wpctl` 有 Sink；dmesg 有 `wcd938x` / `adsp` 行 |
| Wi-Fi | `wifi.iface` / `wifi.driver` / `radio.rfkill` | `ip -br link`<br>`rfkill list`<br>`dmesg \| grep -i ath10k` | 有 `wlan0`；`rfkill` 无 `blocked: yes`；dmesg 有 `ath10k` |
| 蓝牙 | `bt.hci` | `ls /sys/class/bluetooth`<br>`bluetoothctl show` | 有 `hci0`；`Powered: yes` |
| 电池 | `power.battery` / `power.charging` | `cat /sys/class/power_supply/battery/uevent` | 有 `POWER_SUPPLY_CAPACITY=`；插 USB 时 `STATUS=Charging` |
| 桌面登录 | `desktop.greetd` / `desktop.greeter` / `desktop.compositor` / `desktop.shell` / `desktop.keyboard` / `desktop.session` | `systemctl status greetd`<br>`pgrep -a dms-greeter`<br>`pgrep -a niri`<br>`journalctl -u greetd -b \| tail` | greetd 是 `active (running)`；屏幕上是 dux-greeter 登录界面；登录后有 `niri` + `dms` |
| （附加）首启扩容 | `rootfs.grown` / `rootfs.size` | `ls /var/lib/raphael-growfs.done`<br>`btrfs filesystem usage /` | 标记文件存在；文件系统已占满分区 |

几个容易误判的点：

- **`touch.events` 报 WARN「未实测」**：普通模式不读 event 设备，加 `--touch` 才会提示滑动并统计 5 秒内字节数。
- **读 `/dev/input/eventN` 报 Permission denied**：普通用户不在 `input` 组时读不了；用 `sudo`，或直接加 `--touch`（脚本会自己提权）。
- **`audio.pipewire` 在纯 SSH 会话里拿不到用户总线**：先登录桌面，或 `XDG_RUNTIME_DIR=/run/user/$(id -u) wpctl status`。
- **`desktop.greeter` 为空不一定是坏**：已登录后 greeter 退出，换成用户会话的 `niri` + `dms`，此时看 `desktop.compositor` / `desktop.shell`。
- **`display.connector` 只在面板点亮后才是 `connected`**：有 `card0` 但 `niri msg outputs` 无输出时，先看 `journalctl -u greetd -b`。

---

## 12. 恢复：回到 fastboot / 刷回 Android

### 12.1 任何状态 → fastboot

| 当前状态 | 做法 |
|---|---|
| 系统能起来（SSH 或桌面可用） | `sudo poweroff`，关机后按住「音量下 + 电源」约 3 秒 |
| 黑屏 / 卡 logo / 卡 initramfs | 长按 **电源键 10 秒**强制断电 → 松开 → 按住「音量下 + 电源」 |
| 掉在 initramfs rescue shell | 同上；shell 里也可以 `reboot -f` 后再按键 |
| 跑 Android/Recovery 且 PC 认得 adb | `adb reboot bootloader` |
| 长按也毫无反应 | 拔线断电等 30 秒再插；仍无反应再考虑拆后盖断电（有风险） |

确认真的在 fastboot（只读）：

```bash
fastboot devices          # <序列号>  fastboot
fastboot getvar product   # raphael
```

### 12.2 从 fastboot 重刷本镜像

```bash
sudo tools/flash.sh rootfs.img      # 覆盖 userdata
tools/wait-boot.sh && tools/device-test.sh
```

只想清数据、不重刷：`fastboot erase userdata`（之后设备里没有可引导的 Linux rootfs）。

### 12.3 刷回 Android

1. 官方/第三方 ROM 的 `boot`（以及 `xbl` / `aboot` 等）会覆盖 U-Boot，
   **分区名以 ROM 包里的 `flash-all.sh` / `flash-all.bat` 为准**——本仓库不猜分区名，避免刷错变砖；
2. fastboot 包（`*.tgz`）解压后通常是：

```bash
fastboot -w                                   # 清数据（userdata 现在是 Linux rootfs）
fastboot flash boot     images/boot.img       # 文件名/分区随 ROM 而变
fastboot flash dtbo     images/dtbo.img
fastboot flash system   images/system.img
fastboot flash vendor   images/vendor.img
fastboot reboot
```

3. 刷完首次开机较慢（10 分钟级），别急着断电；
4. 想彻底回到出厂状态：用官方 **MiFlash / 线刷包**，按其说明操作。

> 变砖风险集中在 `aboot` / `xbl` / `modem` 这类分区；`userdata` / `boot` 刷错都能重来。
> 动手前先确认镜像文件名与实际分区名一致。

---

## 13. 参考


- [GengWei1997/linux-xiaomi-raphael-uboot](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot)
- [Nura Wiki](https://wiki.nura.eco)
- [duxlabs-dev/dux-shell](https://github.com/duxlabs-dev/dux-shell) · [dux-greeter](https://github.com/duxlabs-dev/dux-greeter)
- [niri](https://github.com/YaLTeR/niri) · [squeekboard](https://gitlab.gnome.org/World/Phosh/squeekboard)
