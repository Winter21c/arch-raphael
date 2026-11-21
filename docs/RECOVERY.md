# 设备恢复手册（raphael）

设备起不来时的固定流程。所有命令在宿主机执行，设备通过 USB 连接。

## 0. 判断当前状态

| 现象 | 含义 | 处理 |
|---|---|---|
| `fastboot devices` 有输出 | 已进 fastboot | 直接跳到第 2 步 |
| `ip link` 出现 `enp0s20f0u*` 且能 SSH 172.16.42.1 | 系统已起来 | 无需恢复 |
| 两者都没有、`lsusb` 也看不到 | 死机/关机 | 第 1 步 |

## 1. 进入 fastboot

1. **长按电源键 ~10 秒**强制关机
2. 按住 **音量下 + 电源**，直到屏幕出现 `FASTBOOT`
3. `fastboot devices` 应看到序列号

## 2. 刷入能启动的 cache 分区镜像

cache 分区放的是引导链：systemd-boot + 内核 + initramfs + dtb。

```bash
# 已知可用的安全镜像（本机已生成）
sudo fastboot flash cache /tmp/cache-safe.img
sudo fastboot reboot
```

若该文件不存在，用工具重新生成（参数必须成对匹配）：

```bash
sudo tools/mk-cache.sh \
  --kernel   <与 initramfs 同版本的内核 Image> \
  --initramfs <对应 initramfs> \
  --dtb      <能启动的那份 dtb> \
  --root-uuid ee8d3593-59b1-480e-a3b6-4fefb17ee7d8 \
  --out      /tmp/cache-safe.img
```

## 3. 三条铁律（都是踩坑换来的）

1. **内核与 initramfs 必须同版本**。不同版本 → initramfs 阶段加载模块失败 → 无 USB、无 SSH，只能物理恢复。
2. **DTB 不能随便替换**。本地 `overlay/dtb/` 与 `/tmp` 下的副本都缺 `/memory` 节点，用它引导会黑屏。
   能启动的是参考 cache 镜像里那份 **113,245 字节**的 `raphael-redmi-k20pro.dtb`；
   要改就用 `fdtput` **局部修改**，不要整份替换。
3. **rootflags 不要重复拼接**（出现过 `subvol=@,subvol=@,`），统一由 `tools/mk-cache.sh` 生成。

## 4. 完整刷机（全新部署）

```bash
sudo fastboot erase dtbo
sudo fastboot flash boot  u-boot.img
sudo fastboot flash cache cache-<distro>-<kver>.img
sudo fastboot flash userdata rootfs.img
sudo fastboot reboot
```
或使用 `tools/flash.sh --uboot u-boot.img --cache cache.img rootfs.img`。

## 5. 启动后自检

```bash
tools/wait-boot.sh                 # 等 SSH 就绪（172.16.42.1，user/1234）
tools/device-test.sh               # 逐项 PASS/WARN/FAIL
```
登录：`user` / `1234`（root 同密码）。

## 6. 音频现状判据

```bash
i2cget -y -f 0 0x34 0x00 w     # TFA9874 状态字：静默 vs 播放中对比
```
- 7.2 上实测恒为 `0x1800`（不变）→ 功放未运行 → 无声
- 若播放时数值变化 → 功放真正在工作

另：`aplay -D hw:0,0` 报 `pcm_write EIO` **不代表**硬件坏，必须用 `pw-play`（PipeWire）判断。
