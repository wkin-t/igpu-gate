#!/bin/sh
# 13-fb-describe.sh —— Phase 2b-A1 的**只读**基线采集（无 kext、无写入）
#
# 目的：把"当前到底由谁在出画面、模式/扫描面长什么样"落成证据，
# 供 2b-A1（继承现有扫描面）使用。不做任何判断、不改任何东西。
#
# 用法： sudo sh onsite/13-fb-describe.sh [--outdir DIR]
# 产出： results-fbdescribe-<UTC>/ 下
#          ioreg-IOFramebuffer.plist   原始 ioreg -a（权威，plist 而非文本）
#          summary.txt                 人可读摘要
#          displays.txt                system_profiler 显示信息
# 退出码：0=采集完成（不代表任何结论）；2=前置缺失
set -u

OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --outdir) [ $# -ge 2 ] || { printf '%s\n' '--outdir 需要路径' >&2; exit 2; }; OUT=$2; shift 2 ;;
    --outdir=*) OUT=${1#--outdir=}; shift ;;
    -h|--help) printf '用法：sudo sh onsite/13-fb-describe.sh [--outdir DIR]\n只读；不改配置、不加载 kext。\n'; exit 0 ;;
    *) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$1"; }
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
[ -n "${OUT}" ] || OUT="results-fbdescribe-${STAMP}"
mkdir -p "${OUT}" || { say "FAIL 无法创建输出目录 ${OUT}"; exit 2; }

say "== fb-describe：只读采集 =="
say "   输出目录：${OUT}"

# ---- 1. ioreg（用 -a 拿 plist；-w0 文本打印机会改写 OSData）----
say ""
say "-- 1. ioreg -a -c IOFramebuffer --"
IOREG_OUT="${OUT}/ioreg-IOFramebuffer.plist"
if ioreg -a -l -w0 -r -c IOFramebuffer > "${IOREG_OUT}" 2>/dev/null; then
  SZ=$(/usr/bin/stat -f '%z' "${IOREG_OUT}" 2>/dev/null || echo 0)
  say "   已保存 ${IOREG_OUT}（${SZ} 字节）"
  if [ "${SZ}" -lt 100 ]; then
    say "   ⚠ 文件过小：本机可能没有 IOFramebuffer 实例，或 ioreg 权限不足"
  fi
else
  say "   ⚠ ioreg 采集失败"
fi

# ---- 2. system_profiler（显示/分辨率/像素深度）----
say ""
say "-- 2. system_profiler SPDisplaysDataType --"
DISPL="${OUT}/displays.txt"
if system_profiler SPDisplaysDataType > "${DISPL}" 2>/dev/null; then
  say "   已保存 ${DISPL}"
  sed -n '1,40p' "${DISPL}" | while IFS= read -r line; do say "     ${line}"; done
else
  say "   ⚠ system_profiler 采集失败"
fi

# ---- 3. 摘要（解析 ioreg plist）----
say ""
say "-- 3. 摘要 --"
SUM="${OUT}/summary.txt"
{
  echo "== fb-describe summary =="
  echo "stamp: ${STAMP}"
  echo
  echo "-- uptime --"
  uptime
  echo
  echo "-- 谁在提供显示（IOFramebuffer 实例）--"
} > "${SUM}"

if [ -s "${IOREG_OUT}" ]; then
  python3 - "${IOREG_OUT}" "${SUM}" <<'PYEOF'
import plistlib, sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    doc = plistlib.loads(f.read())

# ioreg -a 的结构是 { "IORegistry": { ... } }（不同版本可能平铺），两种都兼容
root = doc.get("IORegistry", doc)

INTEREST = ("IOFB", "AAPL", "EDID", "IOClass", "IOProviderClass", "CFBundleIdentifier",
            "IOPowerManagement", "IOFBMemorySize", "IOFBCurrentPixelCount",
            "IOFBCurrentPixelClock", "IOFramebufferInfo", "IODisplayConnectFlags")

def walk(node, depth, out):
    if not isinstance(node, dict):
        return
    cls = node.get("IOClass") or node.get("CFBundleIdentifier") or "?"
    if any(k.startswith("IOFB") for k in node) or "Framebuffer" in str(cls):
        out.append("")
        out.append("%s%s  (provider=%s)" % ("  " * depth, cls, node.get("IOProviderClass", "?")))
        for k in sorted(node):
            if not any(k.startswith(p) for p in INTEREST):
                continue
            v = node[k]
            s = repr(v)
            if len(s) > 200:
                s = s[:200] + "…"
            out.append("%s  %s = %s" % ("  " * depth, k, s))
    for v in node.values():
        if isinstance(v, dict):
            walk(v, depth + 1, out)
        elif isinstance(v, list):
            for e in v:
                if isinstance(e, dict):
                    walk(e, depth + 1, out)

lines = []
walk(root, 0, lines)
with open(dst, "a") as f:
    if lines:
        f.write("\n".join(lines) + "\n")
    else:
        f.write("(没有找到带 IOFB* 属性的节点)\n")
    f.write("\n-- 所有 IOFramebuffer 类的节点名 --\n")
PYEOF
  # 节点名单独列出（便于确认 index/归属）
  python3 - "${IOREG_OUT}" "${SUM}" <<'PYEOF'
import plistlib, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    doc = plistlib.loads(f.read())
root = doc.get("IORegistry", doc)
names = []
def walk(node):
    if not isinstance(node, dict):
        return
    if str(node.get("IOClass", "")).find("Framebuffer") >= 0:
        names.append((node.get("IOClass"), node.get("IOProviderClass"),
                      node.get("IOPCIAddressSpace") or node.get("IOPCIMatch") or ""))
    for v in node.values():
        if isinstance(v, dict):
            walk(v)
        elif isinstance(v, list):
            for e in v:
                if isinstance(e, dict):
                    walk(e)
walk(root)
with open(dst, "a") as f:
    if names:
        for n in names:
            f.write("  %s  provider=%s  %s\n" % n)
    else:
        f.write("  (无)\n")
PYEOF
  sed -n '1,60p' "${SUM}" | while IFS= read -r line; do say "     ${line}"; done
else
  say "   跳过摘要（没有 ioreg 数据）"
fi

say ""
say "采集完成。把整个 ${OUT} 目录带回来即可（只读，无副作用）。"
say "RESULT: DESCRIBED（这不代表任何兼容性结论）"
exit 0