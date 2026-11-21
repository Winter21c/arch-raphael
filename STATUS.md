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
