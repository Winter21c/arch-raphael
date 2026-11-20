#!/usr/bin/env python3
"""生成 Android boot image（header v2），把 Linux 内核 + initramfs + DTB 打包，
让设备的原厂 ABL 直接引导，不依赖 U-Boot。

用法:
  mkbootimg.py --kernel vmlinuz --ramdisk initrd.img --dtb raphael.dtb \
               --cmdline "..." --output boot.img [--page-size 4096] [--name raphael]
"""
import argparse, gzip, hashlib, os, struct, sys

PAGE = 4096

def pad(data, page=PAGE):
    n = len(data) % page
    return data if n == 0 else data + b"\x00" * (page - n)

def unwrap_kernel(data):
    """把 arm64 EFI zboot / gzip 内核还原成 ABL 能引导的原始 Image。

    Debian/Ubuntu 的 /boot/vmlinuz-* 在 arm64 上是 PE/COFF EFI zboot 容器
    （开头 "MZ" + "zimg"，内嵌 gzip 压缩的 Image）；Android boot image 里的
    kernel 必须是原始 Image（偏移 56 处为 0x644d5241 "ARMd"）。
    """
    if data[:2] == b"MZ" and data[4:8] == b"zimg":
        off = struct.unpack_from("<I", data, 8)[0]
        size = struct.unpack_from("<I", data, 12)[0]
        comp = data[0x18:0x1c].decode("ascii", "replace").strip("\x00")
        payload = data[off:off + size]
        if comp.startswith("gzip"):
            payload = gzip.decompress(payload)
        elif comp.startswith("zstd"):
            import subprocess
            payload = subprocess.run(["zstd", "-dc"], input=payload, capture_output=True, check=True).stdout
        data = payload
    elif data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    return data


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
    raw = unwrap_kernel(kernel)
    if len(raw) != len(kernel) or raw[:2] != b"MZ":
        kernel = raw
        magic = kernel[56:60]
        if magic != b"ARMd":
            sys.exit("kernel 不是 arm64 Image（偏移 56 期望 ARMd，实际 %r）" % magic)
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
