#!/usr/bin/env python3
"""生成 Android boot image（header v2），把 Linux 内核 + initramfs + DTB 打包，
让设备的原厂 ABL 直接引导，不依赖 U-Boot。

用法:
  mkbootimg.py --kernel vmlinuz --ramdisk initrd.img --dtb raphael.dtb \
               --cmdline "..." --output boot.img [--page-size 4096] [--name raphael]
"""
import argparse, hashlib, os, struct, sys

PAGE = 4096

def pad(data, page=PAGE):
    n = len(data) % page
    return data if n == 0 else data + b"\x00" * (page - n)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--ramdisk", required=True)
    ap.add_argument("--dtb")
    ap.add_argument("--cmdline", default="")
    ap.add_argument("--output", required=True)
    ap.add_argument("--page-size", type=int, default=PAGE)
    ap.add_argument("--name", default="raphael")
    ap.add_argument("--kernel-addr", type=lambda x: int(x, 0), default=0x00008000)
    ap.add_argument("--ramdisk-addr", type=lambda x: int(x, 0), default=0x01000000)
    ap.add_argument("--tags-addr", type=lambda x: int(x, 0), default=0x00000100)
    ap.add_argument("--dtb-addr", type=lambda x: int(x, 0), default=0x01F00000)
    a = ap.parse_args()

    kernel = open(a.kernel, "rb").read()
    ramdisk = open(a.ramdisk, "rb").read()
    dtb = open(a.dtb, "rb").read() if a.dtb else b""
    page = a.page_size

    cmdline = a.cmdline.encode()
    if len(cmdline) >= 512:
        sys.exit("cmdline 过长（<512 字节）")

    # header v2 = 1660 字节
    hdr = bytearray()
    hdr += b"ANDROID!"
    hdr += struct.pack("<I", len(kernel))
    hdr += struct.pack("<I", a.kernel_addr)
    hdr += struct.pack("<I", len(ramdisk))
    hdr += struct.pack("<I", a.ramdisk_addr)
    hdr += struct.pack("<I", 0)              # second_size
    hdr += struct.pack("<I", 0)              # second_addr
    hdr += struct.pack("<I", a.tags_addr)
    hdr += struct.pack("<I", page)
    hdr += struct.pack("<I", 2)              # header_version
    hdr += struct.pack("<I", 0)              # os_version
    hdr += a.name.encode()[:16].ljust(16, b"\x00")
    hdr += cmdline.ljust(512, b"\x00")
    # id：kernel+ramdisk+second 的 SHA1
    digest = hashlib.sha1(kernel + ramdisk + b"").digest()
    hdr += digest.ljust(32, b"\x00")
    hdr += b"\x00" * 1024                    # extra_cmdline
    # v1 字段
    hdr += struct.pack("<I", 0)              # recovery_dtbo_size
    hdr += struct.pack("<Q", 0)              # recovery_dtbo_offset
    hdr += struct.pack("<I", 1660)           # header_size
    # v2 字段
    hdr += struct.pack("<I", len(dtb))
    hdr += struct.pack("<Q", a.dtb_addr)

    assert len(hdr) == 1660, len(hdr)

    with open(a.output, "wb") as f:
        f.write(pad(bytes(hdr), page))
        f.write(pad(kernel, page))
        f.write(pad(ramdisk, page))
        if dtb:
            f.write(pad(dtb, page))
    size = os.path.getsize(a.output)
    print(f"boot image: {a.output}  {size} 字节  (kernel {len(kernel)}, ramdisk {len(ramdisk)}, dtb {len(dtb)})")

if __name__ == "__main__":
    main()
