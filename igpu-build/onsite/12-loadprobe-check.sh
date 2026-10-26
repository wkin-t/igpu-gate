#!/bin/sh
# 12-loadprobe-check.sh —— Phase 2b-A0 的只读判定（必须在目标机上跑）
#
# 唯一目的：回答「OpenCore 注入到 Boot/Aux KC 的 kext，能否满足对
#   System KC 里 com.apple.iokit.IOGraphicsFamily 的依赖」。
#
# 用法： sudo sh onsite/12-loadprobe-check.sh [--config PATH]
#   只读：挂载 EFI 后读文件、读日志；不写配置、不动 kext、不加载任何东西。
# 退出码：0=LOADED；1=DEPENDENCY_MISSING；2=NOT_INJECTED；3=UNKNOWN
set -u

CFG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) [ $# -ge 2 ] || { printf '%s\n' '--config 需要路径' >&2; exit 2; }; CFG=$2; shift 2 ;;
    --config=*) CFG=${1#--config=}; shift ;;
    -h|--help) printf '用法：sudo sh onsite/12-loadprobe-check.sh [--config PATH]\n'; exit 0 ;;
    *) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$1"; }
KEXTNAME="IGPULoadProbe"
BUNDLEID="dev.igpu.loadprobe"

say "== loadprobe：A0 加载路径判定 =="

# ---- 定位并挂载 EFI ----
CAND=$(diskutil list 2>/dev/null | awk '/OCEFI/ {print $NF}' | sort -u)
N=$(printf '%s\n' "$CAND" | grep -c . 2>/dev/null || true)
if [ "${N}" -ne 1 ]; then
  say "FAIL 找不到唯一的 OCEFI 分区（候选数=${N}）；无法确认 kext 是否已注入"
  say "RESULT: NOT_INJECTED（EFI 不可判定）"
  exit 2
fi
ESP=${CAND}
diskutil mount "${ESP}" >/dev/null 2>&1 || true
MP=$(diskutil info "${ESP}" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2}')
if [ -z "${MP}" ] || [ ! -d "${MP}" ]; then
  say "FAIL EFI 挂载失败（非 root 时常见）"
  say "RESULT: NOT_INJECTED（EFI 不可判定）"
  exit 2
fi
say "   EFI: ${MP}"

[ -n "${CFG}" ] || CFG="${MP}/EFI/OC/config.plist"
KEXT="${MP}/EFI/OC/Kexts/${KEXTNAME}.kext"
BIN="${KEXT}/Contents/MacOS/${KEXTNAME}"
PLIST="${KEXT}/Contents/Info.plist"

# ---- 1. 注入面 ----
say ""
say "-- 1. 注入面 --"
INJECTED=0
if [ -f "${PLIST}" ] && [ -f "${BIN}" ]; then
  INJECTED=1
  say "   kext 在位：$(/usr/bin/stat -f '%z' "${BIN}" 2>/dev/null || echo '?') 字节"
  if /usr/bin/plutil -lint "${PLIST}" >/dev/null 2>&1; then say "   Info.plist 合法 ✓"; else say "   ⚠ Info.plist 不合法"; fi
  BID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "${PLIST}" 2>/dev/null || true)
  say "   bundle id: ${BID:-读不到}"
  if [ "${BID}" != "${BUNDLEID}" ]; then say "   ⚠ bundle id 与预期 ${BUNDLEID} 不一致"; fi
else
  say "   ✗ ESP 上没有 ${KEXTNAME}.kext（或缺少可执行文件）"
fi
if [ -f "${CFG}" ]; then
  CNT=$(grep -c "${KEXTNAME}.kext" "${CFG}" 2>/dev/null || true)
  say "   config 中引用次数：${CNT:-0}"
else
  say "   ✗ 找不到 config：${CFG}"
  CNT=0
fi

if [ "${INJECTED}" -ne 1 ] || [ "${CNT:-0}" -eq 0 ]; then
  say ""
  say "RESULT: NOT_INJECTED"
  exit 2
fi

# ---- 2. 加载面 ----
say ""
say "-- 2. 加载面（kmutil showloaded）--"
LOADED=0
SL=$(kmutil showloaded 2>/dev/null | grep -i "${BUNDLEID}" || true)
if [ -n "${SL}" ]; then
  LOADED=1
  printf '%s\n' "${SL}" | sed -n '1,3p' | while IFS= read -r line; do say "   ${line}"; done
else
  say "   ✗ 未在已加载列表中（可能是依赖未满足、或未注入成功）"
fi

# ---- 3. 日志证据 ----
say ""
say "-- 3. 日志证据（本次启动）--"
LOGSTART=$(log show --last boot --style compact --predicate 'eventMessage CONTAINS "IGPULoadProbe"' 2>/dev/null | grep -c 'kern_start' || true)
if [ "${LOGSTART:-0}" -ge 1 ]; then
  say "   kern_start 出现：${LOGSTART} 次 ✓"
  log show --last boot --style compact --predicate 'eventMessage CONTAINS "IGPULoadProbe"' 2>/dev/null | grep 'kern_start' | sed -n '1,2p' | while IFS= read -r line; do say "     ${line}"; done
else
  say "   ✗ 没有 kern_start 日志（依赖不满足或加载失败时正是这样）"
fi

DEPFAIL=0
DF=$(log show --last boot --style compact 2>/dev/null | grep -i "${BUNDLEID}" | grep -iE 'fail|unresolved|denied|could not|not found' || true)
if [ -n "${DF}" ]; then
  DEPFAIL=1
  say "   发现失败痕迹："
  printf '%s\n' "${DF}" | sed -n '1,5p' | while IFS= read -r line; do say "     ${line}"; done
fi

# ---- 4. 判定 ----
say ""
if [ "${LOADED}" -eq 1 ] && [ "${LOGSTART:-0}" -ge 1 ]; then
  say "RESULT: LOADED（A0 通过：AuxKC 注入的 kext 能满足 IOGraphicsFamily 依赖）"
  exit 0
fi
if [ "${LOADED}" -eq 1 ] && [ "${LOGSTART:-0}" -eq 0 ]; then
  say "RESULT: UNKNOWN（已在 showloaded 里，但没看到 kern_start —— 核对日志窗口/谓词）"
  exit 3
fi
if [ "${DEPFAIL}" -eq 1 ]; then
  say "RESULT: DEPENDENCY_MISSING（A0 失败：看起来是依赖/加载问题，把上面的失败行带回来）"
  exit 1
fi
say "RESULT: DEPENDENCY_MISSING（未加载且无失败细节：先确认 OC 日志里是否真的注入了该 kext）"
exit 1