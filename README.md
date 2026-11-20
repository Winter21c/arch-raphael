# arch-raphael — Redmi K20 Pro 的 Arch Linux ARM / Fedora 镜像

> **两个仓库**：
> - [`arch-raphael`](https://github.com/Winter21c/arch-raphael) —— 本仓库，**源码**（构建脚本、发行版层、配置、文档），自带静态自检 workflow；
> - [`arch-raphael-build`](https://github.com/Winter21c/arch-raphael-build) —— **专用构建仓库**：从源码仓库拉取代码，在 `ubuntu-24.04-arm` 上构建 Arch/Fedora 镜像并把产物发布到自己的 Releases。

面向 **小米 Redmi K20 Pro（xiaomi-raphael，骁龙 855 / sm8150）** 的 Linux 镜像构建仓库。
一次构建产出一个 `rootfs.img`，整体刷入 `userdata` 分区即可启动，无需改动 Android 的其他分区。

桌面为 [niri](https://github.com/YaLTeR/niri) + [dux-shell (DMS)](https://github.com/duxlabs-dev/dux-shell)，
登录界面为 [dux-greeter](https://github.com/duxlabs-dev/dux-greeter)（greetd），默认横屏，
虚拟键盘使用 [squeekboard](https://gitlab.gnome.org/World/Phosh/squeekboard)。

> ⚠️ **刷机会清空 `userdata`（你的 Android 数据），并且需要解锁 BootLoader。**
> 动手前请先读 [docs/INSTALL.md](docs/INSTALL.md)。

---

## 目录

- [实现状态](#实现状态)
- [支持矩阵](#支持矩阵)
- [刷机前置](#刷机前置)
- [刷写步骤](#刷写步骤)
- [本地构建](#本地构建)
- [GitHub Actions 构建](#github-actions-构建)
- [已知限制](#已知限制)
- [目录结构](#目录结构)
- [致谢](#致谢)

---

## 实现状态

仓库分两层：**镜像骨架 `lib/`**（与发行版无关）+ **发行版层 `distro/<name>/`**（包管理、桌面依赖由它落地）。
下表只写**代码里已实现**的东西；没有实现的一律标注“可选 / 未集成”。

| 模块 | 位置 | 状态 |
|---|---|---|
| 嵌套 GPT 镜像 + btrfs 子卷 `@` / `@home` | `lib/image.sh` | ✅ |
| 内核 / 模块 / DTB / 固件 / ALSA UCM 安装 | `lib/kernel.sh` | ✅ |
| systemd-boot 固定名引导（`/boot/vmlinuz`、`/boot/initrd.img`） | `lib/boot.sh` | ✅ |
| 启动时把 `userdata` 映射成嵌套分区（initramfs） | `overlay/initramfs/raphael-subpartition` | ✅ |
| 系统通用配置（fstab / 用户 / locale / SSH / zram / sysctl / logind） | `lib/configure.sh` | ✅ |
| 首次启动自动扩展 btrfs 到整块 userdata | `lib/configure.sh`（`raphael-growfs.service`） | ✅ |
| 桌面接线（DMS / dux-greeter / greetd / niri 横屏 / 键盘自检） | `lib/desktop.sh` | ✅ |
| 硬件适配（Wi-Fi / 音频 / VA-API / USB NCM / 背光） | `lib/hardware.sh` | ✅ |
| Arch Linux ARM 发行版层（bootstrap / 包 / mkinitcpio / locale） | `distro/arch/` | ✅ |
| Fedora 44 发行版层（dnf --installroot / 包 / dracut / quickshell 与虚拟键盘源码构建） | `distro/fedora/` | ✅ |
| 基带 / 传感器守护进程（`rmtfs`、`pd-mapper`、`hexagonrpcd`） | — | ⚠️ **可选组件，未默认集成**（见[已知限制](#已知限制)） |
| 本地构建入口 | `build.sh`、`Makefile`、`tools/` | ✅ |
| CI 静态自检 | `.github/workflows/verify.yml`（源码仓库） | ✅ |
| CI 镜像构建 | `arch-raphael-build` 仓库的 `build.yml` | ✅ |

> `lib/desktop.sh` 会在镜像里检查 `dms` 与 `squeekboard`：缺少 squeekboard 时只打印警告，
> 也就是说**虚拟键盘能否用取决于发行版层有没有把它装进去**。

---

## 支持矩阵

| 特性 | Arch Linux ARM | Fedora 44 | 实现位置 |
|---|---|---|---|
| 基础系统 | ALARM aarch64 tarball + pacman | `dnf --installroot` | `distro/arch` / `distro/fedora` |
| 根文件系统 | btrfs，`compress=zstd:3`，子卷 `@` / `@home` | 同左 | `lib/image.sh` |
| 默认镜像大小 | 10G | 12G | `config/distro.conf` |
| 桌面合成器 | niri（可用 `COMPOSITOR=sway` 切换） | 同左 | `config/device.conf` |
| dux-shell (DMS) | ✅ 预编译 arm64 二进制 + QML | ✅ | `lib/desktop.sh` |
| 登录界面 | dux-greeter + greetd（vt 1） | ✅ | `lib/desktop.sh` |
| 虚拟键盘 | `squeekboard`（ALARM 包） | `squeekboard` 源码构建，失败回退 `wvkbd` + `/usr/bin/squeekboard` 兼容包装 | `lib/desktop.sh` 接线 + 自检 |
| 默认横屏 | niri `transform 90` + 控制台 `fbcon=rotate:1` | 同左 | `lib/desktop.sh` / `lib/image.sh` |
| 中文环境 | `zh_CN.UTF-8` + `Asia/Shanghai` + fcitx5（`INSTALL_IME=1`） | 同左 | `config/device.conf` |
| 首启扩容 | `raphael-growfs.service`（`btrfs filesystem resize max /`） | 同左 | `lib/configure.sh` |
| USB 网络 + SSH | CDC-NCM `usb0`，设备 `172.16.42.1`（需要 `dnsmasq`） | 同左 | `lib/hardware.sh` |
| 默认账号 | `user/1234`、`root/1234` | 同左 | `lib/configure.sh` |

---

## 刷机前置

1. **解锁 BootLoader**
   小米官方解锁流程（Mi Unlock 工具 + 账号绑定，通常需要等待解锁期）。解锁会清空数据。

2. **引导方式（二选一）**

   **推荐：本仓库产出的 `boot-<distro>-<kver>.img`（原厂 ABL 直接引导 Linux）**
   - 内含原始 arm64 `Image` + initramfs + raphael DTB + cmdline；
   - 不需要 U-Boot，直接 `fastboot flash boot boot-arch-7.3.img` 即可；
   - `BOOT_VERBOSE=1`（默认）时内核日志会打到屏幕，便于排障。

   备选：第三方 U-Boot（本仓库不提供，需另刷）
   - [GengWei1997/linux-xiaomi-raphael-uboot](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot)（分区方案、一键安装、Wiki）
   - [Nura Wiki](https://wiki.nura.eco)（`fastboot flash userdata` 同一套方案来源）

   分区方案（镜像内部 GPT，`fastboot flash userdata` 整块写入）：

   | 分区 | 编号 | 文件系统 | 标签 | 大小 | 类型 GUID |
   |:---:|:---:|:---|:---:|:---:|:---|
   | Boot (ESP) | p1 | FAT32 | `Boot` | 512M | `c12a7328-f81f-11d2-ba4b-00a0c93ec93b` |
   | Root | p2 | btrfs | `Root` | 剩余空间 | `b921b045-1df0-41c3-af44-4c6f280d3fae` |

   - 逻辑扇区 **4096 字节**（匹配 UFS，必须与 U-Boot 的读取方式一致）
   - Boot 分区起始 `2048s`（8MiB 对齐）
   - Root 固定 UUID `ee8d3593-59b1-480e-a3b6-4fefb17ee7d8`（内核 cmdline 依赖它）
   - 启动链（boot.img 方式）：ABL → 内核 + initramfs（内嵌 DTB，cmdline 带 `root=UUID=… rootflags=subvol=@`）
   - 启动链（U-Boot 方式）：U-Boot → `/boot/EFI/BOOT/BOOTAA64.EFI`（systemd-boot）→ `raphael.conf` → `/boot/vmlinuz` + `/boot/initrd.img`

3. **fastboot / adb 环境**
   Android platform-tools（`fastboot`、`adb`），USB 数据线；Windows 需装 fastboot 驱动。

4. **备份**：`fastboot flash userdata` 会覆盖整个 userdata，Android 上的照片/数据会丢。

---

## 刷写步骤

完整的首次启动排障见 [docs/INSTALL.md](docs/INSTALL.md)，这里是最短路径：

```bash
# 1. 下载并校验（Release 里形如 rootfs-arch-7.3.7z 与 boot-arch-7.3.img）
7z x rootfs-arch-7.3.7z                 # 得到 rootfs.img
sha256sum -c rootfs-arch-7.3.7z.sha256  # 校验压缩包

# 2. 设备进入 fastboot（关机后 音量下 + 电源）
fastboot devices

# 3. 刷引导镜像（推荐：ABL 直接引导内核）
fastboot flash boot boot-arch-7.3.img

# 4. 整块写入 userdata —— 这就是“刷机”
fastboot flash userdata rootfs.img
fastboot reboot
```

一条命令完成 3+4：

```bash
sudo tools/flash.sh --boot boot-arch-7.3.img rootfs.img
```

**首次启动**

1. 开机由 ABL 直接加载 `boot.img` 里的内核（带 `loglevel=7`，屏幕上能看到启动日志）；若用 U-Boot 方案则是 U-Boot → systemd-boot（1 秒超时）→ 内核；
2. 首次启动会比之后慢（`raphael-growfs.service` 扩容 + 服务初始化）；
3. 自动进入 **dux-greeter 登录界面**（默认横屏），账号：

   | 用户 | 密码 | 说明 |
   |:---:|:---:|:---|
   | `user` | `1234` | 默认桌面用户（wheel 组，可 sudo） |
   | `root` | `1234` | root（SSH 允许密码登录） |

   > 登录后请立刻用 `passwd` 修改密码。

4. **btrfs 自动扩容**：镜像只占 userdata 的一部分（默认 8G / 10G），首次启动由
   `raphael-growfs.service` 执行 `btrfs filesystem resize max /` 铺满整块 userdata。
   若因为断电等原因没跑到，手动执行一次：

   ```bash
   sudo btrfs filesystem resize max /
   sudo systemctl disable --now raphael-growfs.service  # 已完成则关掉
   ```

5. **SSH（USB 直连）**：插 USB 到电脑，设备侧 `usb0` 地址为 `172.16.42.1`：

   ```bash
   ssh user@172.16.42.1
   ```

   需要 `usb-ncm.service` 与 `dnsmasq` 正常工作；若镜像里没有 dnsmasq，
   构建日志中会有“未安装 dnsmasq”的警告，此时请改用蓝牙/Wi-Fi 或 OTG 键盘调试。

---

## 本地构建

### 依赖

- **root 权限**：要做 `losetup` / `mount` / `chroot` / btrfs；
- **aarch64 执行环境**：arm64 主机原生即可；x86_64 主机需要 `qemu-user-static` + binfmt，
  或让 `build.sh` 自动进 Docker（`--privileged --platform linux/arm64`）；
- 主机工具：`parted dosfstools btrfs-progs util-linux curl xz zstd binutils ca-certificates 7zip` 等。
  一次装齐用：

  ```bash
  sudo tools/host-prep.sh          # 自动识别 apt / dnf / pacman，幂等
  tools/host-prep.sh --check       # 只检查（不需要 root）
  ```

### 构建

```bash
sudo ./build.sh arch            # 完整构建 Arch
sudo ./build.sh fedora          # 完整构建 Fedora
sudo ./build.sh arch packages   # 只跑某个阶段（镜像需已存在）

make arch
make fedora
make all
make verify                     # 静态自检（不需要 root）
make clean                      # 卸载 loop/挂载点并删除镜像产物
```

**阶段**（`build.sh <distro> [stage]`，省略即 `all`）：

`prepare → image → bootstrap → packages → config → desktop → hardware → kernel → initramfs → boot → finalize`

**产物**（仓库根目录）：

| 文件 | 说明 |
|---|---|
| `rootfs.img` | 要刷入 userdata 的镜像 |
| `rootfs-<distro>-<kernelver>.7z` | 压缩包（`COMPRESS_IMAGE=1`，默认） |
| `rootfs-<distro>-<kernelver>.7z.sha256` | 压缩包校验和 |
| `rootfs-<distro>-<kernelver>.img.sha256` | 裸镜像校验和 |

**环境变量覆盖**（`config/*.conf` 使用 `: "${VAR:=默认值}"` 语义，外部 env 优先）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `KERNEL_VERSION` | `7.3` | 对应 kernel-deb 的 release tag `kernel-v<版本>` |
| `IMAGE_SIZE` | `10G` / `12G` | 镜像大小（arch / fedora；分阶段重跑可改大） |
| `BOOT_SIZE` | `512M` | ESP 大小 |
| `COMPRESS_IMAGE` | `1` | 是否生成 .7z |
| `USER_NAME` / `USER_PASS` / `ROOT_PASS` | `user` / `1234` / `1234` | 默认账号 |
| `COMPOSITOR` | `niri` | `niri` 或 `sway` |
| `SCREEN_ROTATION` | `90` | 屏幕旋转角度 |
| `INSTALL_IME` | `1` | 是否配置 fcitx5 输入法环境 |
| `DUX_SHELL_VERSION` / `DUX_GREETER_VERSION` | `2.1.2` | dux 组件版本 |
| `QS_KEEP_DEPS` | `0` | Fedora 源码编译 quickshell 后是否保留编译依赖（保留约 +600–800MB） |
| `SQUEEKBOARD_MODE` | `auto` | Fedora 虚拟键盘：`auto` / `squeekboard` / `wvkbd` / `none` |

```bash
sudo ./build.sh arch all 2>&1 | tee build-arch.log   # 建议留日志
```

---

## GitHub Actions 构建

镜像构建在**专用构建仓库** [`arch-raphael-build`](https://github.com/Winter21c/arch-raphael-build)：
它的 workflow 会先 `checkout` 本源码仓库，再在 arm64 runner 上构建，产物发布到构建仓库的 Releases。

1. 打开 **arch-raphael-build → Actions → 构建系统镜像 → Run workflow**；
2. 输入参数：

   | 输入 | 取值 | 说明 |
   |---|---|---|
   | `distro` | `both` / `arch` / `fedora` | 矩阵并行构建 |
   | `kernel_version` | 如 `7.3` | 内核 release tag |
   | `image_size` | 可空 | 覆盖默认镜像大小 |
   | `compress` | `true` / `false` | 是否产出 .7z |

3. Runner 为 **`ubuntu-24.04-arm`**（arm64 原生，arch 无需 qemu）：
   `tools/host-prep.sh` 装依赖 → `tools/verify.sh` 静态自检 → `sudo ./build.sh <distro>`；
   build.sh 会自行判断执行环境：arch 在 runner 上原生构建（ALARM tarball + chroot pacman），
   fedora 因 runner 没有 dnf5 会自动 `docker run fedora:44`（arm64 容器原生执行，仍然不需要 qemu）；
4. 每个发行版上传一份 artifact（`rootfs-<distro>-<kver>`），随后统一发布到 **tag `latest`** 的 Release；
5. 构建失败时会执行 `losetup -D` 清理，并额外上传该次构建的日志 artifact。

> 若暂时用不了 `ubuntu-24.04-arm`，`build.yml` 末尾有 x86_64 runner + `qemu binfmt` 的备选说明。

---

## 已知限制

- **基带 / 传感器**：`rmtfs`、`pd-mapper`、`hexagonrpcd` 等守护进程是**可选组件**，
  当前镜像**未默认集成**，因此蜂窝数据/通话、以及经由 SSC 的传感器（自动旋转、接近传感器等）不保证可用。
  `lib/hardware.sh` 只在系统里已经存在这些程序时启用对应服务，否则跳过并记录日志。
- **虚拟键盘**：squeekboard 依赖合成器的 Wayland 输入法 / 虚拟键盘协议；若某版本 niri 上弹不出来，
  可切 `COMPOSITOR=sway`，或改用 `wvkbd`。布局（横屏、中文）也需要按需调整；
  中文输入依赖 fcitx5（`INSTALL_IME=1` 只写环境变量，输入法本体由发行版层安装）。
- **性能**：DMS（Qt/Quickshell）首次启动较慢；镜像默认 8G/10G，首次启动的扩容与初始化会让开机明显变慢。
- **电源**：`sleep/suspend/hibernate` 目标已 mask（没有 swap / 休眠支持），
  待机耗电需要手动熄屏（`niri msg action power-off-monitors`）。
- **未验证硬件**：摄像头、闪光灯、指纹、NFC 未在本仓库适配/验证。
- **.7z 体积**：镜像 > 2GB 时可能超出 GitHub Release 单文件限制，此时请从 Actions 的 artifact 下载。
- **仅 arm64**：目标设备与所有二进制均为 aarch64，x86_64 主机需要 binfmt / qemu。

---

## 目录结构

```
.
├── build.sh                     # 构建入口：<distro> [stage] [--inner]
├── Makefile                     # make arch / fedora / all / verify / clean
├── config/
│   ├── device.conf              # 设备与镜像几何（GPT/btrfs/账号/桌面）
│   └── distro.conf              # 发行版差异（镜像大小、包管理器、容器镜像）
├── lib/                         # 发行版无关的镜像骨架
│   ├── common.sh                # 日志 / 下载 / 解包 / chroot / 挂载清理
│   ├── prepare.sh               # 下载内核、固件、dux 组件
│   ├── image.sh                 # 嵌套 GPT + btrfs 子卷（4096 扇区）
│   ├── kernel.sh                # 内核/模块/DTB/固件安装
│   ├── configure.sh             # fstab/用户/locale/服务/zram/首启扩容
│   ├── desktop.sh               # DMS / dux-greeter / 横屏 / 键盘接线
│   ├── hardware.sh              # Wi-Fi/音频/VA-API/USB NCM/背光
│   ├── raphael-initramfs.sh     # 把 initramfs 依赖装进镜像的助手
│   ├── boot.sh                  # systemd-boot + 固定名引导
│   └── finalize.sh              # 卸载、校验、打 .7z
├── overlay/initramfs/
│   └── raphael-subpartition     # 启动时把 userdata 映射成嵌套分区
├── distro/
│   ├── README.md                # 发行版层接口契约
│   ├── arch/                    # Arch Linux ARM（distro.sh + packages*.txt）
│   └── fedora/                  # Fedora（distro.sh + packages*.txt）
├── tools/
│   ├── host-prep.sh             # 主机依赖检查/安装（apt/dnf/pacman）
│   └── verify.sh                # 静态自检（bash -n / 文件 / 包列表 / YAML / config）
├── docs/
│   ├── INSTALL.md               # 刷机与首次启动排障
│   └── BUILD.md                 # 构建原理
└── .github/workflows/verify.yml # 源码仓库：静态自检（镜像构建在 arch-raphael-build）
```

更细的构建原理（为什么要 4096 扇区、initramfs 怎么映射、btrfs 子卷与横屏怎么落地）见 [docs/BUILD.md](docs/BUILD.md)。

---

## 致谢

- [GengWei1997/linux-xiaomi-raphael-uboot](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot)
  —— 预编译内核/固件 deb、分区方案与“整块刷 userdata”的思路；
- [Nura（原 postmarketOS）](https://wiki.nura.eco) 与 [sm8150 mainline 内核](https://gitlab.postmarketos.org/soc/qualcomm-sm8150/linux)；
- [duxlabs-dev/dux-shell](https://github.com/duxlabs-dev/dux-shell) 与
  [dux-greeter](https://github.com/duxlabs-dev/dux-greeter)；
- [Quickshell](https://quickshell.org/)、[niri](https://github.com/YaLTeR/niri)、
  [squeekboard](https://gitlab.gnome.org/World/Phosh/squeekboard)；
- [Arch Linux ARM](https://archlinuxarm.org/) 与 [Fedora](https://fedoraproject.org/) 社区。

---

> 本项目仅面向**已解锁 BootLoader 的自有设备**，刷机风险自负。
