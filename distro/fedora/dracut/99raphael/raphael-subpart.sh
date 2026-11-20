#!/bin/sh
# dracut pre-udev hook（99raphael）：把 userdata 映射成 loop 设备。
#
# 逻辑在 /usr/lib/raphael-subpartition（公共层 overlay/initramfs/raphael-subpartition），
# 这里只做转调，避免两处维护同一份映射代码。
# 失败不影响启动：dracut 会退回常规根设备探测。

[ -f /usr/lib/raphael-subpartition ] || exit 0
sh /usr/lib/raphael-subpartition
exit 0
