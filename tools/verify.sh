#!/usr/bin/env bash
# ============================================================================
# tools/verify.sh —— 仓库静态自检（无需 root，CI 与本地通用）
#
# 检查项：
#   1. 必要文件存在（构建入口 / lib / initramfs 覆盖层 / 发行版层 / 文档）
#   2. 全部 shell 脚本 bash -n 语法
#   3. distro/*/packages*.txt 包列表非空
#   4. workflow YAML 语法（python3 + PyYAML）与关键字段
#      源码仓库用 verify.yml；若存在 build.yml（构建仓库布局）则额外校验其关键字段
#   5. config/*.conf 可 source 且变量齐全（含 arch / fedora 两个分支）
#   6. build.sh 阶段名、--inner 与可执行位
#   7. Makefile 目标齐全
#   8. 换行符（LF）
#
# 用法：
#   tools/verify.sh            # 全量检查
#   tools/verify.sh --quiet    # 只输出 WARN / FAIL
#
# 退出码：0 = 无 FAIL；1 = 存在 FAIL（WARN 不影响退出码）
# ============================================================================
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR" || { echo "无法进入仓库根目录" >&2; exit 1; }

QUIET=0
for arg in "$@"; do
    case "$arg" in
        --quiet|-q) QUIET=1 ;;
        -h|--help)  sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $arg" >&2; exit 2 ;;
    esac
done

PASS_N=0
FAIL_N=0
WARN_N=0

pass() { PASS_N=$((PASS_N + 1)); [ "$QUIET" = 1 ] || printf '  \033[0;32m[PASS]\033[0m %s\n' "$*"; }
fail() { FAIL_N=$((FAIL_N + 1)); printf '  \033[0;31m[FAIL]\033[0m %s\n' "$*"; }
warn() { WARN_N=$((WARN_N + 1)); printf '  \033[0;33m[WARN]\033[0m %s\n' "$*"; }
group() { [ "$QUIET" = 1 ] || printf '\n\033[0;34m==> %s\033[0m\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
group "1. 必要文件"
REQUIRED_FILES=(
    build.sh
    config/device.conf
    config/distro.conf
    lib/common.sh
    lib/prepare.sh
    lib/image.sh
    lib/kernel.sh
    lib/configure.sh
    lib/desktop.sh
    lib/hardware.sh
    lib/raphael-initramfs.sh
    lib/boot.sh
    lib/finalize.sh
    overlay/initramfs/raphael-subpartition
    distro/README.md
    distro/arch/distro.sh
    distro/fedora/distro.sh
    tools/host-prep.sh
    tools/verify.sh
    Makefile
    README.md
    docs/BUILD.md
    docs/INSTALL.md
    .github/workflows/verify.yml
)
for f in "${REQUIRED_FILES[@]}"; do
    if [ -e "$f" ]; then
        pass "存在 $f"
    else
        fail "缺少 $f"
    fi
done

# ---------------------------------------------------------------------------
group "2. shell 语法（bash -n）"
mapfile -t SCRIPTS < <(
    {
        [ -f build.sh ] && echo build.sh
        find . -path ./refs -prune -o -path ./work -prune -o -path ./cache -prune \
             -o -name '*.sh' -print
    } | sort -u
)
if [ "${#SCRIPTS[@]}" -eq 0 ]; then
    fail "没有找到任何 shell 脚本"
else
    for s in "${SCRIPTS[@]}"; do
        if err=$(bash -n "$s" 2>&1); then
            pass "bash -n $s"
        else
            fail "bash -n $s"
            printf '         %s\n' "$err"
        fi
    done
fi

# POSIX sh 的 initramfs 脚本单独校验
if [ -f overlay/initramfs/raphael-subpartition ]; then
    if err=$(sh -n overlay/initramfs/raphael-subpartition 2>&1); then
        pass "sh -n overlay/initramfs/raphael-subpartition"
    else
        fail "sh -n overlay/initramfs/raphael-subpartition"
        printf '         %s\n' "$err"
    fi
fi

# ---------------------------------------------------------------------------
group "3. 包列表"
mapfile -t PKGLISTS < <(find distro -maxdepth 2 -name 'packages*.txt' 2>/dev/null | sort)
if [ "${#PKGLISTS[@]}" -eq 0 ]; then
    fail "未找到 distro/*/packages*.txt"
else
    for p in "${PKGLISTS[@]}"; do
        n=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$p" | grep -cve '^[[:space:]]*$' || true)
        if [ "$n" -gt 0 ]; then
            pass "$p（$n 行）"
        else
            fail "$p 为空"
        fi
    done
fi

# ---------------------------------------------------------------------------
group "4. workflow YAML"
if ! have python3; then
    fail "缺少 python3，无法校验 YAML"
else
    yaml_check() {
        python3 - "$1" <<'PYEOF'
import io
import sys

try:
    import yaml
except Exception:
    sys.exit(3)

try:
    with io.open(sys.argv[1], encoding="utf-8") as fh:
        docs = list(yaml.safe_load_all(fh))
except Exception as exc:
    print("YAML 解析失败: %s" % exc)
    sys.exit(1)

if not any(isinstance(d, dict) for d in docs):
    print("YAML 内容为空或顶层不是映射")
    sys.exit(1)
sys.exit(0)
PYEOF
    }

    mapfile -t YAMLS < <(find .github \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)
    if [ "${#YAMLS[@]}" -eq 0 ]; then
        fail "未找到 .github/**/*.yml"
    else
        for y in "${YAMLS[@]}"; do
            rc=0
            out=$(yaml_check "$y" 2>&1) || rc=$?
            case "$rc" in
                0) pass "YAML 语法 $y" ;;
                3) fail "缺少 PyYAML，无法校验 $y（apt: python3-yaml / dnf: python3-pyyaml / pacman: python-yaml）" ;;
                *) fail "YAML 语法 $y"; printf '         %s\n' "$out" ;;
            esac
        done
    fi

    if [ -f .github/workflows/build.yml ]; then
        for pat in 'workflow_dispatch:' 'ubuntu-24.04-arm' 'upload-artifact' 'action-gh-release' 'losetup -D'; do
            if grep -q -- "$pat" .github/workflows/build.yml; then
                pass "build.yml 包含 $pat"
            else
                fail "build.yml 缺少 $pat"
            fi
        done
    fi
fi

# ---------------------------------------------------------------------------
group "5. config 变量"
REQUIRED_VARS=(
    DEVICE_NAME DEVICE_MODEL HOSTNAME_DEFAULT
    USER_NAME USER_PASS ROOT_PASS
    IMAGE_NAME IMAGE_SIZE SECTOR_SIZE BOOT_PART_START BOOT_SIZE
    BOOT_LABEL ROOT_LABEL ROOT_UUID
    BTRFS_OPTS BTRFS_HOME_OPTS
    KERNEL_VERSION KERNEL_DEB_REPO
    COMPOSITOR SCREEN_ROTATION
    CACHE_DIR WORK_DIR MNT IMAGE_PATH COMPRESS_IMAGE
)

if ( set -u; source config/device.conf && source config/distro.conf ) >/dev/null 2>&1; then
    pass "config/device.conf 与 config/distro.conf 可 source"
else
    fail "config/*.conf 无法 source"
fi

cfg_out=$(
    set -uo pipefail
    source config/device.conf 2>/dev/null || { echo "SOURCE_FAIL:device.conf"; exit 0; }
    source config/distro.conf 2>/dev/null || { echo "SOURCE_FAIL:distro.conf"; exit 0; }

    miss=()
    for v in "${REQUIRED_VARS[@]}"; do
        eval "val=\${$v:-}"
        [ -n "$val" ] || miss+=("$v")
    done
    [ "${#miss[@]}" -eq 0 ] || echo "MISSING:${miss[*]}"

    if [ "${SECTOR_SIZE:-}" != 4096 ]; then
        echo "BAD_SECTOR:${SECTOR_SIZE:-空}"
    fi

    for d in arch fedora; do
        unset DISTRO_NAME DISTRO_ID IMAGE_SIZE PKG_MANAGER INITRAMFS
        if ! distro_config "$d" >/dev/null 2>&1; then
            echo "DISTRO_FAIL:$d"
            continue
        fi
        for v in DISTRO_NAME DISTRO_ID IMAGE_SIZE PKG_MANAGER INITRAMFS; do
            eval "val=\${$v:-}"
            [ -n "$val" ] || echo "DISTRO_VAR:$d:$v"
        done
    done
)

if [ -z "$cfg_out" ]; then
    pass "config 变量齐全（含 arch / fedora 分支）"
else
    while IFS= read -r line; do
        case "$line" in
            MISSING:*)     fail "config 缺少变量: ${line#MISSING:}" ;;
            SOURCE_FAIL:*) fail "无法 source ${line#SOURCE_FAIL:}" ;;
            BAD_SECTOR:*)  fail "SECTOR_SIZE 必须为 4096（U-Boot / userdata 扇区契约），当前: ${line#BAD_SECTOR:}" ;;
            DISTRO_FAIL:*) fail "distro_config ${line#DISTRO_FAIL:} 调用失败" ;;
            DISTRO_VAR:*)  fail "distro_config 未设置 ${line#DISTRO_VAR:}" ;;
            "")            ;;
            *)             warn "$line" ;;
        esac
    done <<<"$cfg_out"
fi

# ---------------------------------------------------------------------------
group "6. build.sh 入口契约"
if [ ! -f build.sh ]; then
    fail "build.sh 不存在，跳过阶段检查"
else
    for s in prepare image bootstrap packages config desktop hardware kernel initramfs boot finalize; do
        if grep -qE "(^|[^A-Za-z0-9_])$s([^A-Za-z0-9_]|$)" build.sh; then
            pass "build.sh 含阶段 $s"
        else
            fail "build.sh 缺少阶段 $s"
        fi
    done
    if grep -q -- '--inner' build.sh; then
        pass "build.sh 支持 --inner"
    else
        fail "build.sh 未实现 --inner（CI 依赖该入口）"
    fi
    if [ -x build.sh ]; then
        pass "build.sh 可执行"
    else
        fail "build.sh 没有可执行位（chmod +x build.sh）"
    fi
fi

# ---------------------------------------------------------------------------
group "7. Makefile 目标"
if [ ! -f Makefile ]; then
    fail "Makefile 不存在"
else
    for t in arch fedora all verify clean; do
        if grep -qE "^$t[[:space:]]*:" Makefile; then
            pass "Makefile 目标 $t"
        else
            fail "Makefile 缺少目标 $t"
        fi
    done
fi

# ---------------------------------------------------------------------------
group "8. 可执行位与换行符"
mapfile -t EXEC_FILES < <( { echo build.sh; ls tools/*.sh 2>/dev/null; echo overlay/initramfs/raphael-subpartition; } | sort -u )
for f in "${EXEC_FILES[@]}"; do
    [ -e "$f" ] || continue
    if [ -x "$f" ]; then
        pass "可执行 $f"
    else
        fail "$f 没有可执行位（chmod +x $f）"
    fi
done

CRLF=$(grep -rIl $'\r' --include='*.sh' --include='Makefile' --include='*.yml' . 2>/dev/null \
       | grep -v '^./refs/' || true)
if [ -n "$CRLF" ]; then
    fail "存在 CRLF 换行文件（应使用 LF）："
    printf '%s\n' "$CRLF" | sed 's/^/         /'
else
    pass "无 CRLF 换行问题"
fi

# ---------------------------------------------------------------------------
printf '\n\033[1m汇总：PASS %d / WARN %d / FAIL %d\033[0m\n' "$PASS_N" "$WARN_N" "$FAIL_N"
if [ "$FAIL_N" -gt 0 ]; then
    echo "[FAIL] 静态自检未通过"
    exit 1
fi
echo "[PASS] 静态自检通过"
