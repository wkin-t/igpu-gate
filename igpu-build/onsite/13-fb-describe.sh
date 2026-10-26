#!/bin/sh
# 13-fb-describe.sh —— Phase 2b-A1 的**只读**基线采集
#
# 已知坑（评审 2026-10-26 指出，已核 ioreg 源码）：
#   `ioreg -a -r -c X` 用 archive_search() 返回 **CFArray**，plist 顶层就是数组，
#   不是字典。旧版直接 doc.get(...) 会 AttributeError，而脚本没有 set -e，
#   于是"零报错地丢掉全部数据"并打印 RESULT: DESCRIBED —— 假阴性。
#   这里统一归一化成 roots 列表，并在"一个节点都没解析到"时返回非 0。
#
# 用法： sudo sh onsite/13-fb-describe.sh [--outdir DIR]
# 退出码：0 = 采到东西；2 = 采集或解析失败（trip 会告警但不阻塞 2a）
set -u

OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --outdir) [ $# -ge 2 ] || { printf '%s\n' '--outdir 需要路径'; exit 2; }; OUT=$2; shift 2 ;;
    --outdir=*) OUT=${1#--outdir=}; shift ;;
    -h|--help) printf '用法：sudo sh onsite/13-fb-describe.sh [--outdir DIR]\n只读；不改配置、不加载 kext。\n'; exit 0 ;;
    *) printf '未知参数：%s\n' "$1"; exit 2 ;;
  esac
done

say() { printf '%s\n' "$1"; }
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
[ -n "${OUT}" ] || OUT="results-fbdescribe-${STAMP}"
mkdir -p "${OUT}" || { say "FAIL 建不了输出目录 ${OUT}"; exit 2; }
IOREG_OUT="${OUT}/ioreg-IOFramebuffer.plist"
DISPL="${OUT}/displays.txt"
SUM="${OUT}/summary.txt"

say "== fb-describe：只读采集 =="
say "   输出目录：${OUT}"

if ! ioreg -a -l -w0 -r -c IOFramebuffer > "${IOREG_OUT}" 2>/dev/null; then
  : > "${IOREG_OUT}"
fi
SZ=$(/usr/bin/stat -f '%z' "${IOREG_OUT}" 2>/dev/null || echo 0)
say "   ioreg：${SZ} 字节"

system_profiler SPDisplaysDataType > "${DISPL}" 2>/dev/null || : > "${DISPL}"

PY=python3
command -v python3 >/dev/null 2>&1 || PY=python
"${PY}" -I - "${IOREG_OUT}" "${SUM}" "${DISPL}" <<'PYEOF'
import plistlib, sys

src, dst, displays = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(src, "rb") as f:
        doc = plistlib.loads(f.read())
except Exception as exc:
    print("PARSE-FAIL: %s" % exc)
    sys.exit(3)

# 归一化：ioreg -a -r 的顶层可能是 list，也可能是 {"IORegistry": ...}
roots = []
if isinstance(doc, list):
    roots = doc
elif isinstance(doc, dict):
    inner = doc.get("IORegistry", doc)
    roots = inner if isinstance(inner, list) else [inner]
else:
    print("PARSE-FAIL: 未知顶层类型 %s" % type(doc).__name__)
    sys.exit(3)

INTEREST = ("IOFB", "AAPL", "EDID", "IOObjectClass", "IOClass", "IOProviderClass",
            "CFBundleIdentifier", "IOPowerManagement", "IOPCIClassMatch")

found = []          # 带 IOFB*/Framebuffer 特征的节点
all_classes = []    # 所有节点的 IOObjectClass（用于确认是否真的没有）

def walk(node, depth):
    if isinstance(node, dict):
        cls = node.get("IOObjectClass") or node.get("IOClass") or ""
        if cls:
            all_classes.append(cls)
        if any(str(k).startswith("IOFB") for k in node) or "Framebuffer" in str(cls):
            lines = ["", "%s%s  provider=%s" % ("  " * depth, cls or "?",
                                                node.get("IOProviderClass", "?"))]
            for k in sorted(node):
                if not any(str(k).startswith(p) for p in INTEREST):
                    continue
                v = repr(node[k])
                if len(v) > 220:
                    v = v[:220] + "…"
                lines.append("%s  %s = %s" % ("  " * depth, k, v))
            found.append("\n".join(lines))
        for v in node.values():
            walk(v, depth + 1)
    elif isinstance(node, list):
        for e in node:
            walk(e, depth)

for r in roots:
    walk(r, 0)

with open(dst, "w") as f:
    f.write("== fb-describe summary ==\n")
    f.write("nodes_scanned_classes=%d\n" % len(all_classes))
    f.write("fb_like_nodes=%d\n" % len(found))
    if found:
        f.write("\n".join(found) + "\n")
    else:
        f.write("(没有找到带 IOFB*/Framebuffer 特征的节点)\n")
        f.write("\n-- 扫描到的类名（前 40 个）--\n")
        for c in sorted(set(all_classes))[:40]:
            f.write("  %s\n" % c)

try:
    with open(displays, "r") as f:
        d = f.read()
    with open(dst, "a") as f:
        f.write("\n-- system_profiler SPDisplaysDataType --\n")
        f.write(d[:4000])
except Exception:
    pass

print("nodes_scanned_classes=%d fb_like_nodes=%d" % (len(all_classes), len(found)))
sys.exit(0 if (found or all_classes) else 4)
PYEOF
PRC=$?

say ""
sed -n '1,40p' "${SUM}" 2>/dev/null | sed 's/^/   /'
say ""
if [ "${PRC}" -ne 0 ]; then
  say "FAIL 解析未得到任何节点（rc=${PRC}）；原始 ioreg 已保留：${IOREG_OUT}"
  say "RESULT: DESCRIBE-FAILED"
  exit 2
fi
say "采集完成：${OUT}"
say "RESULT: DESCRIBED（只代表采集成功，不代表任何兼容性结论）"
exit 0