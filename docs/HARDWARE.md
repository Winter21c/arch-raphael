# 硬件支持核对表（以实际镜像 / DTB / 内核 config 为依据）

> 全部条目来自对**已发布镜像**的挂载检查、镜像内 DTB 反编译、以及内核 `config-7.3.0-rc5-sm8150-gc033da1fc4fe`。
> 这是「镜像里有没有」的证据，不等于「真机上跑通了」——后者需要刷机验证（见 STATUS.md）。

| 子系统 | 设备树节点 | 驱动（镜像内 `.ko`） | 固件 / 配置 | 结论 |
|---|---|---|---|---|
| 触控 | `touchscreen@5d compatible="goodix,gt9886"`（1080×2340） | `goodix_ts.ko`、`goodix_gtx8.ko` | 无（I2C 直连） | ✅ 齐备 |
| 面板 | `panel@0 compatible="samsung,ams639rq08"`（DSI0） | `panel-samsung-ams639rq08.ko`、`panel-novatek-nt36672a.ko`（备用） | 无 | ✅ 齐备 |
| GPU | Adreno 640 | `msm.ko`、`adreno.ko`（DRM/MSM 整套） | `a640_zap.mbn` | ✅ 齐备 |
| 音频 | `sound { compatible="qcom,sm8150-sndcard"; model="Raphael" }`；`codec@1,0 = slim217,250`（WCD9340）；`speaker-codec@34`（WSA881x） | `snd-soc-sm8150.ko`、`snd-soc-wcd934x.ko`、`snd-soc-wsa881x.ko`、`snd-soc-wcd-classh.ko`、`snd-soc-wcd-mbhc.ko` + `sound/soc/qcom/qdsp6/*` | `adsp.mbn`/`adspr.jsn`；UCM `/usr/share/alsa/ucm2/Raphael/Raphael.conf` 与 `conf.d/sm8150_raphael/` | ✅ 齐备 |
| Wi-Fi | `compatible="qcom,wcn3990-wifi"` | `ath10k_snoc.ko`、`ath10k_core.ko` | `ath10k/WCN3990/hw1.0/{firmware-5.bin,board-2.bin}`（含 .zst） | ✅ 齐备 |
| 蓝牙 | `bluetooth0 = serial@c8c000/bluetooth` | `btqca.ko`、`hci_uart`、`bluetooth.ko` | `qca/crbtfw21.tlv`、`crbtfw32.tlv`、`nvm_*.bin` | ✅ 齐备 |
| 调制解调器（远程处理器） | `remoteproc` 系列 | `qcom_q6v5*.ko`、`qcom_q6v5_pas.ko` | `modem.mbn`、`modem_pr`、`ipa_fws.mbn` | ⚠️ 驱动/固件齐备，但用户态 `rmtfs`/`pd-mapper` 在 Arch/Fedora 无官方包（代码已按 `command -v` 降级） |
| 视频编解码 | `video-codec@aa00000`（Venus） | `venus*.ko` | — | ✅ 镜像内配置 `LIBVA_DRIVER_NAME=venus` |
| 电池 / 充电 | `pm8150b` 系列 | `qcom_smb2`、`qcom_battmgr` 等 | — | ✅ 齐备 |
| USB（NCM/OTG） | `dwc3` | `dwc3.ko`、`libcomposite`、`usb_f_ncm` | `/usr/local/sbin/setup-usb-ncm.sh` + `usb-ncm.service` | ✅ 齐备 |
| 背光 | — | — | udev 规则 `99-raphael-backlight.rules`（video 组可写 brightness） | ✅ |

## 内核关键配置（片段）

```
CONFIG_BTRFS_FS=y            # 根文件系统（内建，无需 initramfs 模块）
CONFIG_BLK_DEV_LOOP=y        # 嵌套 GPT 映射
CONFIG_SND_SOC_SM8150=m
CONFIG_SND_SOC_WCD934X=m
CONFIG_SND_SOC_WSA881X=m
CONFIG_SND_SOC_QDSP6_{COMMON,CORE,AFE,ADM,ASM,ROUTING}=m
CONFIG_TOUCHSCREEN_GOODIX=m
CONFIG_DRM_PANEL_SAMSUNG_AMS639RQ08=m
CONFIG_ATH10K_SNOC=m
CONFIG_BT_QCA=m
```

## 已知缺口

1. **基带/传感器用户态**：`rmtfs`、`pd-mapper`、`tqftpserv`、`hexagonrpcd` 在 Arch ARM / Fedora 44 都没有现成包。镜像里 `99-qcom-rmtfs.rules` 与启用逻辑都写成「有二进制才启用」，所以不会报错，但蜂窝网络与部分传感器预计不可用。
2. **WCD938x**：本机 DTB 用的是 WCD9340（SLIMbus）+ WSA881x，因此内核未开 `CONFIG_SND_SOC_WCD938X_SDW` 不影响（那是给用 SoundWire 的机型用的）。

## 音频（2026-11 真机实测结论）

### 必须的四件事
1. **功放驱动**：内核 deb 只带 `snd-soc-tfa9872`（驱动名 `tfa987x`），它同样匹配 `nxp,tfa9874`
   并抢先绑定 i2c `0-0034`，导致功放不被正确初始化 → 扬声器无声。
   解决：构建期安装自建 `snd-soc-tfa9874.ko`（源码 `overlay/modules/tfa9874.c`），
   并用 `modprobe.d` 屏蔽 `snd-soc-tfa9872`、`modules-load.d` 让新驱动在声卡创建前加载。
   验证：`dmesg | grep tfa9874` → `TFA9874 detected, revision 0x0c74`。
2. **UCM 按驱动名匹配**：alsa-lib 的 ucm2 用 **ASoC 驱动名**（`sm8150`）查表，不是卡名
   （`Raphael`/`sm8150raphael` 都会 ENOENT -2）。落位 `ucm2/conf.d/sm8150/sm8150.conf`（Syntax 4）。
   验证：`alsaucm -c sm8150 set _verb HiFi` → rc=0。
3. **DTB 用带音频补丁的那份**：stock DTB 缺 `slimcap`/`speaker-dai-link` 等节点，
   Q6 写入会 EIO。使用 `overlay/dtb/raphael-redmi-k20pro.dtb`（speaker-dai-link:
   cpu=<&q6afe 0x16> QUAT_MI2S_RX、codec=<&tfa9874>）。
4. **必须走 PipeWire，不要用 aplay 直连**：
   `aplay -D hw:0,0` 会 `pcm_write: Input/output error`（周期/格式参数与 DSP 不匹配），
   而 `pw-play` 正常。播放时功放 DAPM 应为：
   ```
   SPKR AIF IN / SPKR HiFi Playback / SPKR SPK / SPKR SPK DRV = On, bias_level = On
   ```

### 其它
- `raphael-audio-routing.service/timer`（每 5 秒、仅在值不同时才写 mixer）负责
  耳机/扬声器二选一、并保活采集路由；不要改成无条件写入（会打断正在播放的流）。
- WirePlumber 固定 Speaker 为默认 sink（`priority.session=2000`）。
- greeter 会话已 mask pipewire/wireplumber，避免与用户会话抢同一张声卡。

### 7.3 内核对照实验（已就绪，未切换）

设备 cache 分区已备好（默认启动项仍是可用的 7.2）：

| 文件 | 说明 |
|---|---|
| `/boot/linux73.efi` | 7.3.0-raphael-g8611da3 Image（27,703,808 B，来自参考内核树） |
| `/boot/loader/entries/arch73.conf` | 独立启动项，指向 linux73.efi + 现有 initramfs + 音频补丁 DTB |
| `/lib/modules/7.3.0-raphael` | 与之匹配的模块集（含 snd-soc-tfa9874.ko） |

切换方式（二选一）：
- 开机时在 systemd-boot 菜单（`timeout 2`）里直接选 `Arch Linux (7.3.0-raphael 测试)`；
- 或 `sed -i 's/^default.*/default arch73.conf/' /boot/loader/loader.conf` 后重启。

回滚：把 `default` 改回 `newarch.conf`（当前的 7.2 配置）。

判据（客观）：播放时读取功放状态寄存器，应当**变化**：
```
i2cget -y -f 0 0x34 0x00 w     # 静默 vs 播放中
```
7.2 上实测恒为 `0x1800`（不变）→ 功放未运行 → 无声。
