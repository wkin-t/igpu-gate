#!/bin/sh
# 16-coding-readiness.sh —— 用证据回答"能不能进入正式编码"（只读、离线可跑）
#
# 消费：results-collect-*（3 轮）、results-a0-gate.txt、results-pre2b-*、results-fbdescribe-*
# 产出：终端四门判定表 + 退出码（0 = 四门全过且无 UNKNOWN；1 = 有门未过；2 = 环境不可判）
#
# 关键纪律：UNKNOWN 不算过。宁可判"不能"，也不要用"看起来正常"放行。
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BUNDLE=$(cd "${HERE}/.." && pwd)
say() { printf '%s\n' "$1"; }

G1=UNKNOWN; G2=UNKNOWN; G3=UNKNOWN; G4=UNKNOWN
E1=""; E2=""; E3=""; E4=""

# ---------- G1：2a 三轮判物 ----------
ROUNDS=$(ls -dt "${BUNDLE}"/results-collect-* 2>/dev/null | head -3 | tac 2>/dev/null || ls -dt "${BUNDLE}"/results-collect-* 2>/dev/null)
N=$(printf '%s\n' "${ROUNDS}" | grep -c . 2>/dev/null || true)
if [ "${N}" -lt 3 ]; then
  G1=FAIL; E1="只有 ${N} 轮采集（需要 3 轮）"
else
  MODES=""; LOADED=""; MATERIAL=""
  for d in ${ROUNDS}; do
    MODES="${MODES} $(sed -n 's/^mode=//p' "$d/summary.txt" 2>/dev/null | head -1)"
    LOADED="${LOADED} $(sed -n 's/^probe_loaded=//p' "$d/summary.txt" 2>/dev/null | head -1)"
    MATERIAL="${MATERIAL} $(sed -n 's/^material_complete=//p' "$d/summary.txt" 2>/dev/null | head -1)"
  done
  case "${MODES}" in
    " normal off normal") G1=PARTIAL ;;
    *) G1=FAIL; E1="三轮 mode 不是 normal/off/normal：${MODES}" ;;
  esac
  case "${LOADED}" in
    " yes no yes") [ "${G1}" = PARTIAL ] && G1=PASS ;;
    *) [ "${G1}" = PARTIAL ] && { G1=FAIL; E1="probe_loaded 不是 yes/no/yes：${LOADED}"; } ;;
  esac
  case "${MATERIAL}" in
    *no*) [ "${G1}" = PASS ] && { G1=FAIL; E1="有轮 material_complete=no：${MATERIAL}"; } ;;
  esac
  [ "${G1}" = PASS ] && E1="三轮 模式/加载/材料 均符合"
fi

# ---------- G2：驱动容器 ----------
A0F="${BUNDLE}/../results-a0-gate.txt"
[ -f "${A0F}" ] || A0F="${HOME}/results-a0-gate.txt"
PRE2B=$(ls -dt "${BUNDLE}"/results-pre2b-* 2>/dev/null | head -1)
A0R=""
[ -f "${A0F}" ] && A0R=$(sed -n 's/^RESULT: //p' "${A0F}" | tail -1)
if [ -z "${A0R}" ]; then
  G2=FAIL; E2="没有 A0 判定（${A0F}）"
elif [ "${A0R}" = "GATE-INVALID" ]; then
  G2=FAIL; E2="A0 判定无效（GATE-INVALID）"
elif [ -z "${PRE2B}" ]; then
  G2=FAIL; E2="缺 results-pre2b-*（容器可行性证据没采）"
else
  # aux 可行性：SIP 状态 + /L/E 是否可写 + aux KC 是否存在
  SIP=$(sed -n 's/^sip: //p' "${PRE2B}/INDEX.txt" 2>/dev/null | head -1)
  AUXKC=$(grep -c 'AuxiliaryKernelExtensions.kc' "${PRE2B}/03-auxkc.txt" 2>/dev/null || true)
  LE=$(grep -c '^d.* /Library/Extensions' "${PRE2B}/03-auxkc.txt" 2>/dev/null || true)
  case "${A0R}" in
    A0-SYMBOLS-PRESENT)
      G2=PASS; E2="Boot KC 能解析 IOFramebuffer ⇒ 容器可沿用 OC 注入" ;;
    A0-CROSS-KC-IMPOSSIBLE)
      if [ "${AUXKC:-0}" -ge 1 ] && [ "${LE:-0}" -ge 1 ]; then
        G2=PASS; E2="跨 KC 不可行，但 AuxKC 路径存在（SIP=${SIP:-未知}）⇒ 容器=AuxKC"
      else
        G2=FAIL; E2="跨 KC 不可行，且未看到 aux KC / /L/E 证据 ⇒ 容器未定，不能写接管代码"
      fi ;;
    *) G2=FAIL; E2="A0 判定未识别：${A0R}" ;;
  esac
fi

# ---------- G3：A1 基线 ----------
FBD=$(ls -dt "${BUNDLE}"/results-fbdescribe-* 2>/dev/null | head -1)
if [ -z "${FBD}" ]; then
  G3=FAIL; E3="缺 results-fbdescribe-*（扫描面基线没采）"
else
  NODES=$(sed -n 's/^fb_like_nodes=//p' "${FBD}/summary.txt" 2>/dev/null | head -1)
  EDID=""
  [ -n "${PRE2B}" ] && EDID=$(grep -c '首选时序' "${PRE2B}/16-edid.txt" 2>/dev/null || true)
  if [ "${NODES:-0}" -ge 1 ] && [ "${EDID:-0}" -ge 1 ]; then
    G3=PASS; E3="fb 节点 ${NODES} 个，EDID 首选时序已解出"
  else
    G3=FAIL; E3="fb_like_nodes=${NODES:-0}，EDID 首选时序=${EDID:-0}"
  fi
fi

# ---------- G4：回滚链路（人工门） ----------
if [ -f "${BUNDLE}/../RECOVERY-EFI-VERIFIED.txt" ] || [ -f "${HOME}/RECOVERY-EFI-VERIFIED.txt" ]; then
  G4=PASS; E4="恢复 EFI 已有验证标记"
else
  G4=FAIL; E4="未看到恢复 EFI 验证标记（人工确认后创建 RECOVERY-EFI-VERIFIED.txt）"
fi

# ---------- 输出 ----------
say "== 编码启动门（G1–G4）=="

show() { printf '  %-4s %-8s %s\n' "$1" "$2" "$3"; }
show G1 "${G1}" "${E1}"
show G2 "${G2}" "${E2}"
show G3 "${G3}" "${E3}"
show G4 "${G4}" "${E4}"
say ""
FAILN=$(printf '%s %s %s %s\n' "${G1}" "${G2}" "${G3}" "${G4}" | tr ' ' '\n' | grep -c -v '^PASS$' || true)
UNKN=$(printf '%s %s %s %s\n' "${G1}" "${G2}" "${G3}" "${G4}" | tr ' ' '\n' | grep -c '^UNKNOWN$' || true)
if [ "${FAILN}" -eq 0 ]; then
  say "RESULT: CODING-READY（四门全过，可以进入正式编码）"
  exit 0
fi
say "RESULT: NOT-READY（${FAILN} 个门未过，其中 UNKNOWN ${UNKN} 个）"
say "  可以并行做的（与容器无关）：证据解码器、寄存器/时序模型、测试替身、编译骨架。"
say "  不能做的：任何'如何被加载/如何接管显示'的代码。"
exit 1