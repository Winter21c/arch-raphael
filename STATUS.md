# 项目状态（真机实测）

目标设备：Redmi K20 Pro（raphael / SM8150），U-Boot 引导链。

## 引导链（设备上唯一验证可用的顺序）

```
ABL → U-Boot(boot 分区) → cache 分区 FAT32(systemd-boot)
     → linux.efi + initramfs + dtbs/qcom/*.dtb → 扁平 btrfs rootfs(userdata)
```

- ABL 直接引导我们打的 `boot.img` **必失败**（`Failed to load/authenticate boot image`），不要再用
- rootfs 必须是**扁平 btrfs**（无嵌套 GPT），`@` / `@home` 子卷，`rootflags=subvol=@,...`
- 内核与 initramfs **必须同版本构建**（不一致会卡在 initramfs 阶段：无 USB、无 SSH）
- DTB 必须用**能启动的那一份**：本地 `overlay/dtb/` 与 `/tmp` 下的副本都缺 `/memory` 节点，
  用它们引导会黑屏；参考 cache 镜像里的 113,245 字节那份才可用

## 构建期开关（`config/device.conf`）

| 变量 | 默认 | 说明 |
|---|---|---|
| `BOOT_CHAIN` | `uboot` | `uboot` = U-Boot + cache；`abl` = 旧 Android boot.img |
| `ROOTFS_LAYOUT` | `flat` | `flat` = 扁平 btrfs；`gpt` = 嵌套 GPT（旧） |
| `SCREEN_ROTATION` | `270` | niri `transform`；实测 90 会上下颠倒 |
| `FBCON_ROTATE` | `3` | 与屏幕方向一致 |
| `CACHE_SIZE` | `256M` | cache 引导分区镜像大小 |

工具：`tools/mk-cache.sh` 一键生成 cache 镜像（含内核/initramfs 版本一致性检查与 DTB 结构告警）；
`tools/flash.sh --uboot <u-boot.img> --cache <cache.img> <rootfs.img>` 完成整套刷写。

## 真机已验证通过

| 项 | 证据 |
|---|---|
| 扁平 btrfs 根 | `findmnt / → /dev/sda31[/@]`，`systemctl is-system-running = running` |
| 触摸（Goodix GTX8） | 冷启动自愈服务 `raphael-touch-reset` 重新绑定 i2c `1-005d`；实测 12s 内 event 1392 字节 |
| 显示 | `card0-DSI-1` connected+enabled，背光 1023/2047 |
| 桌面/登录 | `greetd` → `niri`（dux-greeter）；`dms run` 桌面 |
| 电源键 | 独立守护进程读 `pm8941_pwrkey`（仅 KEY_POWER 按下 value==1），背光状态机切换，不会卡死 |
| 音量键 | niri bind（物理 +/- 与 keysym 相反，已交换） |
| 自动登录 | greetd `[initial_session]` → 直接进桌面；账号 `user` / `1234` |
| USB 网络 | `usb0` + dnsmasq DHCP（conf-dir 修复，避免抢 53 端口） |
| Wi-Fi / 蓝牙 / 电池 | `wld0` 已连、`hci0` active、`qcom-battery 99% Full` |

## 音频（未通过）

已解决：
- 功放驱动：自建 `snd-soc-tfa9874.ko`（源码 `overlay/modules/tfa9874.c`），
  屏蔽会抢绑 `nxp,tfa9874` 的 `snd-soc-tfa9872`；`dmesg: TFA9874 detected, revision 0x0c74`
- UCM：按**驱动名 `sm8150`** 匹配（`ucm2/conf.d/sm8150/sm8150.conf`，Syntax 4），`set _verb HiFi` rc=0
- PipeWire：WirePlumber 生成 Speaker/Headphone，Speaker 设为默认；`pw-play` rc=0

未解决（客观判据）：
- `i2cget -y -f 0 0x34 0x00 w` 在静默与播放中**恒为 0x1800** → 功放未进入运行态 → 无声
- 7.2 内核：`aplay hw:0,0` → `pcm_write EIO`；`AFE enable for port 0x4000 failed -22`
- 7.3 内核：因为运行中的 DT 是 U-Boot 自带 stock DT（`sound/model = Xiaomi Redmi K20 Pro`），
  `msm-snd-sm8150` 无绑定设备 → `no soundcards`

下一步：让 7.3 用上带音频链路的 DTB（**保留能启动的那份，只做 fdtput 局部修改**），
声卡注册后再用 i2c 判据确认功放是否运行。

## 仓库

- 源码：`Winter21c/arch-raphael`（`main`）
- 构建：`Winter21c/arch-raphael-build`（`workflow_dispatch`；产物 = rootfs + cache + u-boot）
- 本地自检：`bash tools/verify.sh` → PASS 83 / WARN 0 / FAIL 0

## 内核来源与版本对不上（重要）

CI 与本地构建使用的内核 deb 是：

```
cache/kernel/7.3/linux-image.deb
Package: linux-image-7.3.0-rc5-sm8150-gc033da1fc4fe
Version: 7.3.0~rc5-gc033da1fc4fe-1
```

也就是说 **CI 产物的内核是 `7.3.0-rc5-sm8150-gc033da1fc4fe`**，而设备上验证过的
内核是 `7.3.0-raphael-g8611da3`（来自参考内核树 `linux-sm8150-7.3.0`）。

两者是**不同的构建**，因此：

- `overlay/modules/snd-soc-tfa9874.ko`（当前按 7.2 编的）在 CI 产物里会被
  `lib/hardware.sh` 的 vermagic 守卫跳过 → **CI 镜像的扬声器功放不会被识别**；
- 需要为每个目标内核各编一份 `snd-soc-tfa9874.ko`（7.3.0-rc5 与 7.3.0-raphael 都要）。

建议的构建期做法（待实现）：
1. 在 CI 里解包 `linux-image.deb` 得到 `/lib/modules/<kver>`；
2. 用同版本内核头（`linux-headers.deb`）作为 kbuild 树，把 `overlay/modules/tfa9874.c`
   以**外部模块**方式编译（`make -C <kbuild树> M=<临时目录> modules`）；
3. 产出 `snd-soc-tfa9874-<kver>.ko` 并安装，vermagic 自然匹配。

## 设备恢复

设备起不来时见 [docs/RECOVERY.md](docs/RECOVERY.md)（含 fastboot 进入、cache 镜像重建、三条铁律）。

## 真机最终结论（2026-11-22）

### 7.2 内核 = 触摸 + 声音都正常（采用）

```
kernel 7.2.0-sm8150-ga1573649db08
root   /dev/sda31[/@]                        （扁平 btrfs）
card0  Raphael (sdm845 - Raphael)
touch  /dev/input/event4 Goodix GTX8         ✅
amp    tfa9874 (i2c 0-0034)                  ✅
Speaker (TFA9874) 默认 sink，pw-play 出声    ✅（用户现场确认）
```

**关键差异：UCM 目录名要跟机器驱动名一致**

| 内核 | 驱动名（`/proc/asound/cards` 中间那列） | UCM 需要 |
|---|---|---|
| 7.2.0-sm8150-ga1573649db08 | `sdm845` | `ucm2/conf.d/sdm845/sdm845.conf` |
| 7.3.0-raphael-g8611da3 | `sm8150` | `ucm2/conf.d/sm8150/sm8150.conf` |

构建期两个都落位（见 `lib/hardware.sh`），换内核不用改。

### 7.3 内核 = 有声音但触摸不可用（不采用）

```
[GTP-ERR] goodix_ts_probe:1943 goodix device confirm failed[skip]
goodix_ts goodix_ts.0: probe with driver goodix_ts failed with error -22
```
模块 `goodix_gtx8` 能加载、regulator 能开，但读不到芯片 ID，`i2c 1-005d` 始终不绑定，
无输入节点。多次 rebind（含面板起来后）均失败。

### 因此默认配置

- `build.sh`：`KERNEL_VERSION=7.2`
- 构建仓库 workflow：`kernel_version` 默认 `7.2`
- cache 引导镜像必须包含 **与内核同版本的 initramfs** 和 **能启动的 DTB**
  （可用备份 `out/pre-7.3-backup/boot-cache.img`，只改 root UUID）

### 音量乱跳的修复

`raphael-audio-routing.timer` 每 5 秒执行一次路由脚本会反复动 mixer/卡片 profile。
处理：`systemctl stop/disable raphael-audio-routing.timer`，音量固定（如 0.7–0.85）。
