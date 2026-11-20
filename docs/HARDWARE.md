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
