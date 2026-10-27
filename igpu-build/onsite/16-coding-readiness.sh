#!/bin/sh
# 16-coding-readiness.sh —— "能不能进正式编码"的唯一判定入口
#
# 判定逻辑**只有一份**：tools/pre2b-decode.py。这里只负责：
#   1) 调解码器生成 model.json；
#   2) 把四门结果打到终端；
#   3) 用退出码告诉调用方能不能开工。
# 这样现场看到的结果和事后离线跑出来的完全一致，不会出现"脚本说 PASS、模型说 FAIL"。
#
# 用法： sh onsite/16-coding-readiness.sh [--quiet]
# 退出码：0 = 四门全过；1 = 有门未过；2 = 解码器跑不起来
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BUNDLE=$(cd "${HERE}/.." && pwd)
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

PY=python3
command -v python3 >/dev/null 2>&1 || PY=python
DECODE="${BUNDLE}/tools/pre2b-decode.py"
MODEL="${BUNDLE}/model.json"

if [ ! -f "${DECODE}" ]; then
  printf '%s\n' "FAIL 缺少 ${DECODE}（包不完整）"
  printf '%s\n' "RESULT: NOT-READY（解码器缺失）"
  exit 2
fi

if [ "${QUIET}" -eq 0 ]; then
  printf '%s\n' "== 解码现场证据 =="
fi
"${PY}" -I "${DECODE}" --bundle "${BUNDLE}" > /dev/null 2>"${BUNDLE}/.decode.err" || {
  printf '%s\n' "FAIL 解码器失败："
  sed -n '1,8p' "${BUNDLE}/.decode.err" 2>/dev/null
  printf '%s\n' "RESULT: NOT-READY（解码失败）"
  exit 2
}

"${PY}" -I - "${MODEL}" <<'PYEOF'
import json, sys

try:
    m = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as exc:  # noqa: BLE001
    print("FAIL 读不了 model.json：%s" % exc)
    print("RESULT: NOT-READY（模型不可读）")
    raise SystemExit(2)

g = m.get("gates", {})
c = m.get("container", {})
s = m.get("scanout", {})
rows = [
    ("G1 2a 三轮判物", g.get("G1_2a"), "轮次与加载序列是否符合 normal/off/normal"),
    ("G2 驱动容器", g.get("G2_container"), c.get("reason", "")),
    ("G3 A1 基线", g.get("G3_a1_baseline"),
     "实测 %s / 计划 %s" % (s.get("measured_decoded", {}).get("pipesrc_wh"),
                            (s.get("plan") or {}).get("pipesrc") and "已算出")),
    ("G4 回滚链路", g.get("G4_rollback"), "恢复 EFI 是否已人工验证"),
]
print("  门                  结果     说明")
for name, st, why in rows:
    print("  %-18s %-8s %s" % (name, st, why))

unknowns = m.get("unknowns") or []
if unknowns:
    print("")
    print("  未知项 %d：" % len(unknowns))
    for u in unknowns:
        print("    - %s" % u)

fails = [n for n, st, _ in rows if st != "PASS"]
print("")
if fails:
    print("RESULT: NOT-READY（未过：%s）" % "、".join(fails))
    print("  可以并行做的：证据解码器、时序/寄存器模型、测试替身（已就绪）。")
    print("  不能做的：任何'如何被加载/如何接管显示'的代码。")
    raise SystemExit(1)
print("RESULT: CODING-READY（四门全过，可以进入正式编码）")
raise SystemExit(0)
PYEOF
RC=$?
rm -f "${BUNDLE}/.decode.err" 2>/dev/null || true
exit "${RC}"