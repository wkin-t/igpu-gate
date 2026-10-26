#!/bin/sh
# 14-a0-gate.sh —— Phase 2b-A0 的**离线**判定（只读，不需重启、不碰 ESP）
#
# 要回答的问题：
#   「继承 IOFramebuffer 的 kext，被 OpenCore 注入 Boot KC 后，
#     能否解析 System KC 里的 IOGraphicsFamily 符号？」
#
# 为什么不用"部署 + 重启 + 看日志"（原 A0 方案，已否决）：
#   1) kmutil(8)：system KC 是 prelinked against the boot KC；反向不存在
#      ⇒ Boot 侧 kext 结构上就拿不到 System 侧符号；
#   2) OpenCore 在 prelink 阶段逐个 InternalSolveSymbol，失败即 EFI_LOAD_ERROR，
#      内核根本没参与 ⇒ kernel log 里不会有任何痕迹；
#   3) OC 的 "OCAK: Symbol ... unresolved" 是 DEBUG() 输出，RELEASE 版被编译掉，
#      所以"被拒"与"没注入"在日志里完全同形。
# 结论：重启实验拿不到判据。这里改用 KC 符号门禁（kc_gate.py）直接算。
#
# 用法： sudo sh onsite/14-a0-gate.sh [--boot-kc PATH]
# 退出码：0 = 得到明确结论（看 RESULT 行）；3 = 门禁无法判定（GATE-INVALID）
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BUNDLE=$(cd "${HERE}/.." && pwd)
say() { printf '%s\n' "$1"; }

KC_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --boot-kc) [ $# -ge 2 ] || { say "${1} 需要路径"; exit 2; }; KC_ARG=$2; shift 2 ;;
    -h|--help) printf '用法：sudo sh onsite/14-a0-gate.sh [--boot-kc PATH]\n只读；不改 ESP、不加载 kext。\n'; exit 0 ;;
    *) say "未知参数：${1}"; exit 2 ;;
  esac
done

GATE="${BUNDLE}/tools/kc_gate.py"
BIN_A0="${BUNDLE}/kext/IGPULoadProbe/IGPULoadProbe.kext/Contents/MacOS/IGPULoadProbe"
BIN_PROBE="${BUNDLE}/dist/IGPUProbe.kext/Contents/MacOS/IGPUProbe"
PY=python3
command -v python3 >/dev/null 2>&1 || PY=python

say "== A0 离线判定（KC 符号门禁）=="
[ -f "${GATE}" ] || { say "FAIL 缺 tools/kc_gate.py（包不完整）"; say "RESULT: GATE-INVALID"; exit 3; }
[ -f "${BIN_A0}" ] || { say "FAIL 缺 A0 二进制：${BIN_A0}"; say "RESULT: GATE-INVALID"; exit 3; }
say "   A0 二进制：$(/usr/bin/stat -f '%z' "${BIN_A0}" 2>/dev/null || echo '?') 字节"

# 备份对照：IGPUProbe 只依赖 Boot KC 里的符号，它的门禁历史结论是 PASS
[ -f "${BIN_PROBE}" ] && say "   对照（已知 PASS）：IGPUProbe"

# ---- 找 Boot KC ----
KCS=""
if [ -n "${KC_ARG}" ]; then
  [ -f "${KC_ARG}" ] || { say "FAIL 指定的 KC 不存在：${KC_ARG}"; say "RESULT: GATE-INVALID"; exit 3; }
  KCS=${KC_ARG}
else
  for c in "/System/Library/KernelCollections/BootKernelExtensions.kc" \
           /System/Volumes/Preboot/*/boot/*/System/Library/KernelCollections/BootKernelExtensions.kc; do
    [ -f "${c}" ] && { KCS=${c}; break; }
  done
fi
[ -n "${KCS}" ] || {
  say "FAIL 找不到 BootKernelExtensions.kc；若能挂载运行卷，用 --boot-kc 指定"
  say "RESULT: GATE-INVALID"
  exit 3
}
say "   Boot KC：${KCS}"

# ---- 跑门禁 ----
OUT=$("${PY}" -I "${GATE}" --kc "${KCS}" --kext "${BIN_A0}" --timeout 1800 2>&1)
RC=$?
say ""
printf '%s\n' "${OUT}" | sed -n '1,12p' | sed 's/^/   /'
say ""

case "${OUT}" in
  GATE-INVALID*)
    say "RESULT: GATE-INVALID（KC 不在、导出表读不到或 helper 失败——这不是结论，需换 KC 或修工具）"
    exit 3 ;;
  GATE-FAIL*)
    say "RESULT: A0-CROSS-KC-IMPOSSIBLE"
    say "  ⇒ 预期结论成立：这些符号在 Boot KC 里不存在，OC 注入 Boot KC 后无法解析，"
    say "     booter 阶段就会 EFI_LOAD_ERROR。2b 必须换容器（AuxKC / 别名 / 不继承 IOFramebuffer），"
    say "     不要再用"部署+重启"去验证这条路。"
    exit 0 ;;
esac

if [ "${RC}" -eq 0 ]; then
  say "RESULT: A0-SYMBOLS-PRESENT"
  say "  ⇒ 与预期不符：Boot KC 里居然能解析 IOFramebuffer 符号。"
  say "     请把上面完整输出带回来，2b 的容器选择需要重新评估。"
  exit 0
fi

say "RESULT: GATE-INVALID（kc_gate 返回 rc=${RC}，输出未识别）"
exit 3