#!/bin/sh
# 05-kcgate.sh —— 部署前针对**目标机当前 KC** 的符号门禁（必须在 Dell 上跑）
#
# 用法： sudo sh onsite/05-kcgate.sh [--boot-kc PATH] [--system-kc PATH]
#   **顺序：必须在 01-deploy.sh 之前跑**——先对同一份 dist 产物做目标机 KC 门禁，再改 ESP。
#   默认 KC：/System/Library/KernelCollections/BootKernelExtensions.kc
#            /System/Library/KernelCollections/SystemKernelExtensions.kc
#   缺失时按 Preboot 唯一候选回退（与 run-build.sh 同规则）；仍缺失记 UNKNOWN。
#   待检二进制固定为 dist/IGPUProbe.kext/Contents/MacOS/IGPUProbe，
#   必须与 BUNDLE/EXPECTED_BIN_SHA 完全一致（否则不检、直接 FAIL）。
# 判据（2026-10-21 修正）：**只有承载该 kext 的集合才算数**。
#   OpenCore 注入的 kext 由 Boot KC（AuxKC）承载 ⇒ 默认只要求 BootKernelExtensions.kc 全解析；
#   SystemKernelExtensions.kc 不承载该 kext，它的导出表不可读时判 INVALID 并**仅作参考**，
#   不再折算成"N 个符号缺失"（旧实现因此在本机报过 313 个假缺失）。
#   `--both-required` 可恢复"两个 KC 都必须 PASS"的严格模式。
#   注入目标 KC：PASS 才算过；FAIL / INVALID / 缺失一律非 0 退出。
# 退出码：0 仅 PASS；1 FAIL/UNKNOWN；2 用法或前置缺失。
set -u

BUNDLE=$(cd "$(dirname "$0")/.." && pwd)
BOOT_KC=/System/Library/KernelCollections/BootKernelExtensions.kc
SYS_KC=/System/Library/KernelCollections/SystemKernelExtensions.kc
# 测试钩子：允许离线仿真指向夹具；命令行参数仍然优先
BOOT_KC=${IGPU_BOOT_KC:-$BOOT_KC}
SYS_KC=${IGPU_SYS_KC:-$SYS_KC}
BOTH_REQUIRED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --boot-kc) [ $# -ge 2 ] || { printf '%s\n' '--boot-kc 需要路径' >&2; exit 2; }; BOOT_KC=$2; shift 2 ;;
    --boot-kc=*) BOOT_KC=${1#--boot-kc=}; shift ;;
    --system-kc) [ $# -ge 2 ] || { printf '%s\n' '--system-kc 需要路径' >&2; exit 2; }; SYS_KC=$2; shift 2 ;;
    --system-kc=*) SYS_KC=${1#--system-kc=}; shift ;;
    --both-required) BOTH_REQUIRED=1; shift ;;
    -h|--help) printf '用法：sudo sh onsite/05-kcgate.sh [--boot-kc PATH] [--system-kc PATH] [--both-required]\\n必须在 01-deploy.sh 之前跑（先门禁、后改 ESP）。\\n默认只要求注入目标 Boot KC 全解析；System KC 仅参考。UNKNOWN/INVALID 不能替代 PASS。\\n'; exit 0 ;;
    *) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$1"; }
BIN="$BUNDLE/dist/IGPUProbe.kext/Contents/MacOS/IGPUProbe"
GATE="$BUNDLE/tools/kc_gate.py"
IMPORTS="$BUNDLE/tools/kc_imports.py"

say "== kcgate：目标机 KC 符号门禁 =="
if [ ! -f "$BIN" ]; then
  say "FAIL 找不到待部署二进制：${BIN}（应来自 kit 的 dist/IGPUProbe.kext）"
  say "RESULT: FAIL"
  exit 2
fi
if [ ! -f "$GATE" ] || [ ! -f "$IMPORTS" ]; then
  say "FAIL 缺 tools/kc_gate.py 或 tools/kc_imports.py"
  say "RESULT: FAIL"
  exit 2
fi
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1; then PY=$c; break; fi
done
if [ -z "$PY" ]; then
  say "FAIL 找不到 python3/python（KC 门禁需要 Python）"
  say "RESULT: FAIL"
  exit 2
fi
if ! "$PY" -c 'import plistlib, argparse, pathlib, struct' >/dev/null 2>&1; then
  say "FAIL ${PY} 不可用（缺标准库或开发工具未装）"
  say "RESULT: FAIL"
  exit 2
fi

BIN_SHA=$(shasum -a 256 "$BIN" 2>/dev/null | awk '{print $1}')
[ -n "$BIN_SHA" ] || BIN_SHA=$(sha256sum "$BIN" 2>/dev/null | awk '{print $1}')
BIN_SHA=$(printf '%s' "$BIN_SHA" | tr 'A-F' 'a-f')
EXP_FILE="$BUNDLE/EXPECTED_BIN_SHA"
if [ ! -f "$EXP_FILE" ]; then
  say "FAIL 缺少白名单 ${EXP_FILE}（不能证明所检产物就是待部署产物）"
  say "RESULT: FAIL"
  exit 2
fi
EXPECTED=$(awk 'END {
  if (NR != 1) exit 2
  gsub(/[[:space:]]/, "")
  if ($0 !~ /^[0-9a-fA-F]{64}$/) exit 3
  print tolower($0)
}' "$EXP_FILE" 2>/dev/null)
EXP_RC=$?
if [ "$EXP_RC" -ne 0 ] || [ -z "$EXPECTED" ] || [ -z "$BIN_SHA" ]; then
  say "FAIL 白名单格式非法或二进制哈希读不到（rc=${EXP_RC}；要求恰好一行 64hex，空行/附加行都拒绝）"
  say "RESULT: FAIL"
  exit 2
fi
EXPECTED=$(printf '%s' "$EXPECTED" | tr 'A-F' 'a-f')
if [ "$BIN_SHA" != "$EXPECTED" ]; then
  say "FAIL 待检二进制与 EXPECTED_BIN_SHA 不一致："
  say "   binary   $BIN_SHA"
  say "   expected $EXPECTED"
  say "RESULT: FAIL"
  exit 2
fi
say "   binary sha256: ${BIN_SHA}（= EXPECTED_BIN_SHA ✓）"

# BootKC 缺失时按 Preboot 唯一候选回退
if [ ! -f "$BOOT_KC" ]; then
  CAND=$(ls /System/Volumes/Preboot/*/boot/*/System/Library/KernelCollections/BootKernelExtensions.kc 2>/dev/null)
  N=$(printf '%s\n' "$CAND" | grep -c . 2>/dev/null || true)
  if [ "$N" -eq 1 ]; then
    BOOT_KC=$CAND
    say "   BootKC 回退到 Preboot：$BOOT_KC"
  elif [ "$N" -gt 1 ]; then
    say "   ⚠ Preboot 下有 $N 个 BootKC 候选，无法确定当前系统所用"
  fi
fi

say "   kext : $BIN"
say "   二进制：$BIN"
say "   BootKC: $BOOT_KC"
say "   SystemKC: $SYS_KC"

RESULT=0
CHECKED=0
TARGET_STATE=unknown
SYS_STATE=skipped

run_kc() {  # run_kc <kc 路径> <required|info>
  _kc=$1
  _role=$2
  _name=$(basename "$_kc")
  if [ ! -f "$_kc" ]; then
    say ""
    if [ "$_role" = "required" ]; then
      say "--- ${_name}：UNKNOWN（文件不存在）—— 这是注入目标，必须补齐后重跑"
      TARGET_STATE=unknown
      RESULT=1
    else
      say "--- ${_name}：INFO（文件不存在；非注入目标，不计入判定）"
      SYS_STATE=missing
    fi
    return 0
  fi
  say ""
  if [ "$_role" = "required" ]; then
    say "--- ${_name}（注入目标：承载 OC 注入的 kext）"
  else
    say "--- ${_name}（非注入目标，仅参考）"
  fi
  OUT_TXT=$("$PY" -I "$GATE" --kc "$_kc" --kext "$BIN" --timeout 1800 2>&1)
  RC=$?
  printf '%s\n' "$OUT_TXT" | sed -n '1,80p'
  case "$RC" in
    0)
      say "   ${_name}：PASS"
      if [ "$_role" = "required" ]; then TARGET_STATE=pass; else SYS_STATE=pass; fi ;;
    3)
      say "   ${_name}：FAIL（缺失符号见上）"
      printf '%s\n' "$OUT_TXT" | grep 'MISSING' | sed -n '1,40p'
      if [ "$_role" = "required" ]; then TARGET_STATE=fail; RESULT=1; else SYS_STATE=fail; fi ;;
    2)
      say "   ${_name}：INVALID（无法判定：导出表不可读或输入不合法）"
      if [ "$_role" = "required" ]; then TARGET_STATE=invalid; RESULT=1; else SYS_STATE=invalid; fi ;;
    *)
      say "   ${_name}：UNKNOWN（门禁异常 rc=${RC}）"
      if [ "$_role" = "required" ]; then TARGET_STATE=unknown; RESULT=1; else SYS_STATE=unknown; fi ;;
  esac
  CHECKED=$((CHECKED + 1))
}

run_kc "$BOOT_KC" required
[ -n "$SYS_KC" ] && run_kc "$SYS_KC" info

if [ "$BOTH_REQUIRED" -eq 1 ] && [ "$SYS_STATE" != "pass" ]; then
  say ""
  say "严格模式 --both-required：System KC 状态=${SYS_STATE}（非 pass）⇒ 判定为失败"
  RESULT=1
fi

say ""
say "说明：OC 注入的 kext 由 Boot KC（AuxKC）承载；System KC 不承载该 kext，"
say "      其导出表不可读时按 INVALID 处理，不再折算成\"N 个符号缺失\"。"
if [ "$RESULT" -eq 0 ] && [ "$TARGET_STATE" = "pass" ] && [ "$CHECKED" -gt 0 ]; then
  say "RESULT: PASS（注入目标 KC 符号层必要条件成立；不证明可加载/ABI/运行）"
  exit 0
fi
if [ "$CHECKED" -eq 0 ]; then
  say "RESULT: FAIL（没有任何 KC 被实际检查）"
else
  say "RESULT: FAIL（注入目标 KC 状态=${TARGET_STATE}）"
fi
exit 1