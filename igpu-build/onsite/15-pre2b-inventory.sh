#!/bin/sh
# 15-pre2b-inventory.sh —— 一次会话把所有后续阶段的前置证据**并发采完**（只读）
#
# 设计：每个采集项一个后台子进程（cap_bg），最后 wait；总耗时 ≈ 最慢的那一项，
#       而不是各项相加。所有输出落到各自文件，互不干扰。
# 只读：不写 ESP、不加载 kext、不改配置、不动 NVRAM。
#
# 用法： sudo sh onsite/15-pre2b-inventory.sh [--outdir DIR]
# 退出码：0 = 采完；2 = 输出目录不可写
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BUNDLE=$(cd "${HERE}/.." && pwd)
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --outdir) [ $# -ge 2 ] || { printf '%s\n' '--outdir 需要路径'; exit 2; }; OUT=$2; shift 2 ;;
    --outdir=*) OUT=${1#--outdir=}; shift ;;
    -h|--help) printf '用法：sudo sh onsite/15-pre2b-inventory.sh [--outdir DIR]\n只读、并发采集。\n'; exit 0 ;;
    *) printf '未知参数：%s\n' "$1"; exit 2 ;;
  esac
done
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
[ -n "${OUT}" ] || OUT="${BUNDLE}/results-pre2b-${STAMP}"
mkdir -p "${OUT}" || { printf 'FAIL 建不了 %s\n' "${OUT}"; exit 2; }

say() { printf '%s\n' "$1"; }
# cap_bg：后台采集。$1=文件名，其余=命令。失败也写文件（带 rc），不会阻断整体。
cap_bg() {
  _f=$1; shift
  ( { printf '## %s\n' "$*"; "$@" 2>&1; } > "${OUT}/${_f}" ) &
}
# cap_sh：后台采集一段 shell 文本
cap_sh() {
  _f=$1; _script=$2
  ( { printf '## shell: %s\n' "${_f}"; sh -c "${_script}" 2>&1; } > "${OUT}/${_f}" ) &
}

say "== pre2b inventory（并发）=="
say "   输出：${OUT}"

# ---------- 并行组 1：环境 / 安全 / KC ----------
cap_sh 01-env.txt 'sw_vers; echo; uname -a; echo "-- csrutil --"; csrutil status 2>&1; echo "-- authenticated-root --"; csrutil authenticated-root status 2>&1; echo "-- nvram 安全相关 --"; nvram -p 2>/dev/null | grep -E "csr-active-config|boot-args|SecureBoot" || echo "(无匹配)"'
cap_sh 02-kc.txt '
echo "-- KC 文件 --"; ls -l /System/Library/KernelCollections/*.kc 2>/dev/null
echo "-- Preboot KC（含 Aux）--"; ls -l /System/Volumes/Preboot/*/boot/*/System/Library/KernelCollections/*.kc 2>/dev/null | head -20
echo "-- 关注模块的 collection 归属 --"
for id in com.apple.iokit.IOGraphicsFamily com.apple.iokit.IOAcceleratorFamily2 com.apple.iokit.IONDRVSupport com.apple.iokit.IOPCIFamily com.apple.driver.AppleIntelICLLPGraphicsFramebuffer com.apple.driver.AppleIntelICLGraphics dev.igpu.probe; do
  printf "%-58s " "$id"
  for c in boot system aux; do
    kmutil showloaded --show all --collection "$c" 2>/dev/null | grep -q "$id" && printf "%s " "$c"
  done
  echo
done
echo "-- 图形相关已加载 kext --"
kmutil showloaded --show all 2>/dev/null | grep -iE "graphics|framebuffer|accelerator|AppleIntelI|IONDRV" | head -40'
cap_sh 03-auxkc.txt '
echo "-- /Library/Extensions --"; ls -ld /Library/Extensions 2>&1; ls -l /Library/Extensions 2>&1 | head -20
echo "-- aux collection 是否存在 --"; ls -l /System/Volumes/Preboot/*/boot/*/System/Library/KernelCollections/AuxiliaryKernelExtensions.kc 2>&1 | head -5
echo "-- kernelmanagerd --"; pgrep -l kernelmanagerd 2>&1 || echo "(未运行)"
echo "-- csr-active-config --"; nvram -p 2>/dev/null | grep csr-active-config || echo "(未设置)"
echo "-- 是否允许第三方 kext（kern.hv_vmm_present/vmm 无意义，仅记录）--"; sysctl -n kern.hv_vmm_present 2>/dev/null || echo n/a'
cap_sh 04-build.txt 'echo "-- xcode-select --"; xcode-select -p 2>&1; echo "-- sdk --"; xcrun --show-sdk-version 2>&1; echo "-- KDK --"; ls -l /Library/Developer/KDKs 2>&1; echo "-- clang --"; xcrun clang++ --version 2>&1 | head -2'

# ---------- 并行组 2：硬件 / 总线 / 设备树 ----------
cap_sh 05-pci.txt '
echo "-- 文本视图（iGPU）--"
ioreg -l -w0 -r -c IOPCIDevice 2>/dev/null | grep -E "0x4680|device-id|IONameMatched|IOClass|IODeviceMemory|assigned-addresses" | head -60
echo "-- plist 视图（前 300 行）--"
ioreg -a -l -w0 -r -c IOPCIDevice 2>/dev/null | head -300'
cap_sh 06-devtree.txt '
echo "-- DeviceTree 里与 iGPU/显示相关的键 --"
ioreg -l -w0 -p IODeviceTree 2>/dev/null | grep -iE "ig-platform-id|device-id|model|built-in|backlight|panel|display|IGPU|GFX" | head -80'
cap_sh 07-nvram.txt 'nvram -p 2>&1'
cap_sh 08-kmutil-all.txt 'kmutil showloaded --show all 2>&1 | head -400'

# ---------- 并行组 3：显示栈 / 模式 / 日志 / 电源 / 崩溃 ----------
for cls in IOFramebuffer IONDRVFramebuffer IOGraphicsDevice IODisplay IOAccelerator IODisplayConnect AppleBacklightDisplay; do
  cap_bg "10-ioreg-${cls}.plist" ioreg -a -l -w0 -r -c "${cls}"
done
cap_sh 11-displays.txt 'system_profiler SPDisplaysDataType -json 2>/dev/null || system_profiler SPDisplaysDataType 2>&1'
cap_sh 12-windowserver.txt 'log show --last boot --style compact --predicate "process == \"WindowServer\"" 2>/dev/null | grep -iE "error|fail|timeout" | head -40 || echo "(无匹配或不可用)"'
cap_sh 13-kernlog-gfx.txt 'log show --last boot --style compact 2>/dev/null | grep -iE "AppleIntel|i915|IGPU|IOFramebuffer|IONDRVFramebuffer" | head -200 || echo "(无匹配)"'
cap_sh 14-power.txt 'pmset -g; echo; pmset -g assertions | head -30'
cap_sh 15-crash.txt 'ls -lt /Library/Logs/DiagnosticReports 2>/dev/null | head -20; echo; ls -lt /Library/Logs/DiagnosticReports/*.panic 2>/dev/null | head -5 || echo "(没有 .panic)"'

# ---------- A0 第二意见（Apple 自家 kmutil libraries）----------
A0BIN="${BUNDLE}/kext/IGPULoadProbe/IGPULoadProbe.kext"
BOOTKC=""
for c in /System/Library/KernelCollections/BootKernelExtensions.kc /System/Volumes/Preboot/*/boot/*/System/Library/KernelCollections/BootKernelExtensions.kc; do
  [ -f "$c" ] && { BOOTKC=$c; break; }
done
(
  {
    echo "## A0 cross-check（Apple kmutil libraries）"
    echo "boot_kc=${BOOTKC:-(未找到)}"
    if [ -d "${A0BIN}" ] && [ -n "${BOOTKC}" ]; then
      kmutil libraries -B "${BOOTKC}" -p "${A0BIN}" --undef-symbols --all-symbols 2>&1 | head -80
    else
      echo "(缺 A0 kext 或 Boot KC，跳过)"
    fi
  } > "${OUT}/09-a0-crosscheck.txt"
) &

wait

# ---------- 依赖项：EDID 解码（需要 10-ioreg-IODisplayConnect.plist）----------
PY=python3
command -v python3 >/dev/null 2>&1 || PY=python
"${PY}" -I - "${OUT}" <<'PYEOF' > "${OUT}/16-edid.txt" 2>&1 || echo "(EDID 解码失败)" > "${OUT}/16-edid.txt"
import plistlib, sys, pathlib

out = pathlib.Path(sys.argv[1])
src = out / "10-ioreg-IODisplayConnect.plist"
print("## EDID 解码（A5 模式设置要用真实时序）")
if not src.is_file():
    print("(没有 IODisplayConnect 快照)")
    raise SystemExit(0)
try:
    doc = plistlib.loads(src.read_bytes())
except Exception as exc:
    print("(解析失败: %s)" % exc)
    raise SystemExit(0)

roots = doc if isinstance(doc, list) else [doc.get("IORegistry", doc)]

def walk(n, acc):
    if isinstance(n, dict):
        for k, v in n.items():
            if "EDID" in str(k).upper() and isinstance(v, (bytes, bytearray)):
                acc.append((str(k), bytes(v)))
            walk(v, acc)
    elif isinstance(n, list):
        for e in n:
            walk(e, acc)

found = []
for r in roots:
    walk(r, found)

if not found:
    print("(快照里没有 EDID 数据)")
    raise SystemExit(0)

def decode(b):
    if len(b) < 128:
        return ["EDID 长度 %d < 128，无法解析" % len(b)]
    lines = []
    mfg = (b[8] << 8) | b[9]
    letters = "".join(chr(((mfg >> s) & 0x1F) + 64) for s in (10, 5, 0))
    prod = b[10] | (b[11] << 8)
    year = 1990 + b[17]
    lines.append("厂商=%s 产品=0x%04X 年份=%d 版本=%d.%d" % (letters, prod, year, b[18], b[19]))
    lines.append("输入类型=0x%02X 尺寸=%dx%d cm" % (b[20], b[21], b[22]))
    dtd = b[54:126]
    if len(dtd) >= 18:
        pclk = (dtd[0] | (dtd[1] << 8)) * 10
        hact = dtd[2] | ((dtd[4] & 0xF0) << 4)
        hbl  = dtd[3] | ((dtd[4] & 0x0F) << 8)
        vact = dtd[5] | ((dtd[7] & 0xF0) << 4)
        vbl  = dtd[6] | ((dtd[7] & 0x0F) << 8)
        if pclk:
            lines.append("首选时序: %dx%d @ %.2f Hz (pclk %.2f MHz, hblank=%d vblank=%d)"
                         % (hact, vact, pclk / (hact + hbl) / (vact + vbl) * 1000.0,
                            pclk / 1000.0, hbl, vbl))
    for i in range(4):
        off = 54 + i * 18
        if b[off] or b[off + 1]:
            lines.append("DTD%d: %s" % (i, b[off:off + 18].hex()))
    return lines

for name, data in found[:3]:
    print("-- %s（%d 字节）--" % (name, len(data)))
    for line in decode(data):
        print("   " + line)
PYEOF

# ---------- 索引 ----------
{
  echo "== pre2b inventory INDEX =="
  echo "stamp: ${STAMP}"
  echo "bundle: ${BUNDLE}"
  echo
  echo "-- 速览 --"
  echo "sip: $(csrutil status 2>/dev/null | head -1)"
  echo "a0_kext: $([ -d "${A0BIN}" ] && echo present || echo missing)"
  echo "boot_kc: ${BOOTKC:-(未找到)}"
  echo "kdk: $(ls /Library/Developer/KDKs 2>/dev/null | tr '\n' ' ' || echo none)"
  echo "panic_files: $(ls /Library/Logs/DiagnosticReports/*.panic 2>/dev/null | wc -l | tr -d ' ')"
  echo "appleintel_loaded: $(kmutil showloaded --show all 2>/dev/null | grep -c 'AppleIntel' || true)"
  echo
  echo "-- 文件清单 --"
  for f in "${OUT}"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in INDEX.txt) continue ;; esac
    printf '%-30s %9s B\n' "$(basename "$f")" "$(/usr/bin/stat -f '%z' "$f" 2>/dev/null || echo '?')"
  done
} > "${OUT}/INDEX.txt"

say ""
sed -n '1,26p' "${OUT}/INDEX.txt" | sed 's/^/   /'
say ""
say "采集完成：${OUT}（整目录带回）"
say "RESULT: PRE2B-INVENTORY（只代表采集成功，不含兼容性结论）"
exit 0