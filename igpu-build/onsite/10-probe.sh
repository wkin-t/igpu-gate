#!/bin/sh
# 现场前置探针（F1/N8）：不靠 `command -v` 放行，用**真实执行结果**判断；
# 并且先定位真实 ESP/config、再做配置检查——不允许"执行成功但没验证到部署目标"。
#
# 为什么顺序如此：旧版先跑 python --help、后找 ESP，找不到 ESP 只 WARN，
# 于是 `sh 10-probe.sh` 会在没有部署目标的机器上打印 RESULT: PASS（N8）。
#
# 用法：
#   sh onsite/10-probe.sh [--config <config.plist>] [--esp <挂载点>]
# 退出码：0 = 全部硬项可用；非 0 = 有硬项失败（逐项已打印原因）。
# 测试钩子：IGPU_ESP_ROOT 可指定一个含 EFI/OC 的目录，替代 /Volumes/* 扫描。

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BUNDLE=$(cd "${HERE}/.." && pwd)
PYTHONDONTWRITEBYTECODE=1
export PYTHONDONTWRITEBYTECODE

PASS=0
FAIL=0
WARN=0
CONFIG=""
ESP_ARG=""
# 基线哈希随 config 内容变化；换过 SMBIOS 身份后用 IGPU_BASELINE_SHA 覆盖
BASELINE_SHA="${IGPU_BASELINE_SHA:-991c9de090924d1bd68b2a1db4e104c91337286aae158c63fae98e301fae16e3}"

say() { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); say "PASS  $*"; }
bad()  { FAIL=$((FAIL + 1)); say "FAIL  $*"; }
warn() { WARN=$((WARN + 1)); say "WARN  $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG=${2:-}; shift 2 ;;
    --esp) ESP_ARG=${2:-}; shift 2 ;;
    --help|-h) say "用法：sh onsite/10-probe.sh [--config <config.plist>] [--esp <挂载点>]"; exit 0 ;;
    *) say "未知参数：$1"; exit 2 ;;
  esac
done

say "== 现场前置探针（$(date '+%Y-%m-%d %H:%M:%S')）=="
say "kit:    ${BUNDLE}"
say "宿主:   $(uname -m) / $(sw_vers -productVersion 2>/dev/null || echo unknown)"

# ---------- 1. 先定位真实 ESP 与 config ----------
say ""
say "== 1. 部署目标（ESP/config）=="
FOUND=""
if [ -n "${ESP_ARG}" ]; then
  if [ -d "${ESP_ARG}/EFI/OC" ]; then FOUND=${ESP_ARG}; else bad "指定的 --esp 下没有 EFI/OC：${ESP_ARG}"; fi
elif [ -n "${IGPU_ESP_ROOT:-}" ]; then
  if [ -d "${IGPU_ESP_ROOT}/EFI/OC" ]; then FOUND=${IGPU_ESP_ROOT}; else bad "IGPU_ESP_ROOT 下没有 EFI/OC：${IGPU_ESP_ROOT}"; fi
else
  for m in /Volumes/OCEFI /Volumes/EFI /Volumes/ESP; do
    if [ -d "${m}/EFI/OC" ]; then FOUND=$m; break; fi
  done
  if [ -z "${FOUND}" ] && command -v diskutil >/dev/null 2>&1; then
    _d=$(diskutil list 2>/dev/null | awk '/OCEFI/ {print $NF}' | sort -u | head -1)
    if [ -n "${_d}" ]; then
      diskutil mount "${_d}" >/dev/null 2>&1 || true
      _mp=$(diskutil info "${_d}" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2}')
      if [ -n "${_mp}" ] && [ -d "${_mp}/EFI/OC" ]; then FOUND=${_mp}; fi
    fi
  fi
fi

if [ -n "${FOUND}" ]; then
  ok "找到 OC ESP：${FOUND}/EFI/OC"
  if [ -f "${FOUND}/EFI/OC/config.plist" ]; then
    ok "config.plist 存在：$(wc -c < "${FOUND}/EFI/OC/config.plist" | tr -d ' ') 字节"
    [ -n "${CONFIG}" ] || CONFIG="${FOUND}/EFI/OC/config.plist"
  else
    bad "找到 EFI/OC 但没有 config.plist"
  fi
  if [ -f "${FOUND}/EFI/OC/OpenCore.efi" ]; then
    warn "OpenCore.efi 存在；版本号需另用 ocvalidate/串口确认（本探针不猜）"
  fi
else
  bad "没有找到任何 OC ESP（/Volumes/OCEFI|EFI|ESP 或 diskutil 的 OCEFI）——先挂载 ESP 再跑"
fi

if [ -n "${CONFIG}" ]; then
  if [ ! -f "${CONFIG}" ]; then
    bad "指定的 config 不存在：${CONFIG}"
    CONFIG=""
  elif [ ! -r "${CONFIG}" ]; then
    bad "指定的 config 不可读：${CONFIG}"
    CONFIG=""
  else
    ok "待检查 config：${CONFIG}"
  fi
else
  bad "没有可检查的 config.plist（部署目标不可判定）"
fi

# 空间：取不到就是"不可判定"，必须硬失败，不能默认 PASS
DF_KB=""
if [ -n "${FOUND}" ] && command -v df >/dev/null 2>&1; then
  DF_KB=$(df -k "${FOUND}" 2>/dev/null | awk 'NR==2 {print $4}')
fi
case "${DF_KB}" in
  ''|*[!0-9]*) bad "ESP 可用空间不可判定（df 无有效输出）" ;;
  *)
    if [ "${DF_KB}" -lt 2048 ]; then
      bad "ESP 可用空间不足：$((DF_KB / 1024)) MiB（< 2 MiB）"
    else
      ok "ESP 可用空间：$((DF_KB / 1024)) MiB"
    fi
    ;;
esac

# ---------- 2. Python：实际执行 + 标准库导入 + 真实配置解析 ----------
say ""
say "== 2. Python 与配置解析 =="
PY=""
for cand in python3 /usr/bin/python3 /usr/local/bin/python3 python; do
  if command -v "$cand" >/dev/null 2>&1; then
    if "$cand" -c 'import sys; sys.stdout.write("PYOK\n")' >/tmp/igpu-probe-py.$$ 2>&1 \
       && grep -q PYOK /tmp/igpu-probe-py.$$; then
      PY=$cand
      ok "python 可执行：${cand}（$("$cand" -V 2>&1 | head -1)）"
      break
    fi
    warn "候选 ${cand} 存在但执行失败：$(head -2 /tmp/igpu-probe-py.$$ | tr '\n' ' ')"
  fi
done
rm -f /tmp/igpu-probe-py.$$

CLASS="unknown"; CFG_SHA="unknown"; PROBE_COUNT="unknown"
if [ -z "${PY}" ]; then
  bad "没有可用 Python（需要 xcode-select --install；装完必须重跑本探针，不能以'已发起安装'放行）"
else
  if "$PY" - <<'PYEOF' >>/tmp/igpu-probe-import.$$ 2>&1
import argparse, base64, pathlib, plistlib, xml.etree.ElementTree
print("IMPORTS-OK")
PYEOF
  then
    grep -q IMPORTS-OK /tmp/igpu-probe-import.$$ \
      && ok "标准库导入：argparse/base64/pathlib/plistlib/xml.etree.ElementTree" \
      || bad "标准库导入未产生预期标记：$(head -3 /tmp/igpu-probe-import.$$ | tr '\n' ' ')"
  else
    bad "标准库导入失败：$(head -3 /tmp/igpu-probe-import.$$ | tr '\n' ' ')"
  fi
  rm -f /tmp/igpu-probe-import.$$

  SB="${BUNDLE}/tools/set-bootargs.py"
  SB_RC=255
  SB_OUT=""
  if [ ! -f "${SB}" ]; then
    bad "缺少 tools/set-bootargs.py（kit 不完整）"
  elif [ -n "${CONFIG}" ]; then
    # 先只记录结果，不立刻判死：baseline 现场"没有探针条目"是合法的，
    # 工具拒绝改 boot-args（rc=3）正是预期行为，不能把合法现场判成失败（N8）。
    # 必须是严格检查：`--check` 只输出状态，不验证"可部署"（codex N8 复现过 off/dirty 全过）
    SB_OUT=$("$PY" "${SB}" --config "${CONFIG}" --check --require-deployable 2>&1)
    SB_RC=$?
  else
    bad "没有 config，无法验证 set-bootargs.py 的真实解析路径"
  fi

  # ---------- 3. 现场分类（baseline / injected / dirty）----------
  if [ -n "${CONFIG}" ]; then
    say ""
    say "== 3. 现场分类 =="
    CLS=$("$PY" - "${CONFIG}" "${BASELINE_SHA}" 2>/tmp/igpu-probe-cls.$$ <<'PYEOF'
import hashlib, plistlib, sys

path, baseline = sys.argv[1], sys.argv[2]
raw = open(path, 'rb').read()
sha = hashlib.sha256(raw).hexdigest()
print('sha256=%s' % sha)
try:
    obj = plistlib.loads(raw)
except Exception as exc:
    print('parse=failed:%s' % type(exc).__name__)
    print('classification=dirty')
    print('probe_count=unknown')
    sys.exit(0)
print('parse=ok')
adds = (obj.get('Kernel') or {}).get('Add') or []
probes = []
for a in adds:
    if not isinstance(a, dict):
        continue
    bp = str(a.get('BundlePath', ''))
    ident = str(a.get('BundleIdentifier', ''))
    if 'IGPUProbe.kext' in bp or ident == 'dev.igpu.probe':
        probes.append(a)
print('probe_count=%d' % len(probes))
if len(probes) == 1:
    print('classification=injected')
    print('probe_enabled=%s' % (probes[0].get('Enabled')))
    print('probe_comment=%s' % (probes[0].get('Comment', '')))
elif len(probes) > 1:
    print('classification=dirty')
else:
    print('classification=%s' % ('baseline' if sha == baseline else 'dirty'))
PYEOF
)
    { printf '%s\n' "${CLS}"; } >> /tmp/igpu-probe-cls.$$
    cls() { printf '%s\n' "${CLS}" | sed -n "s/^$1=//p" | head -1; }
    CFG_SHA=$(cls sha256); [ -n "${CFG_SHA}" ] || CFG_SHA="unknown"
    PROBE_COUNT=$(cls probe_count); [ -n "${PROBE_COUNT}" ] || PROBE_COUNT="unknown"
    CLASS=$(cls classification); [ -n "${CLASS}" ] || CLASS="unknown"
    say "   sha256=${CFG_SHA}"
    say "   probe_count=${PROBE_COUNT}"
    case "${CLASS}" in
      baseline)
        ok "分类 baseline（无探针条目，哈希=$(printf '%s' "${CFG_SHA}" | cut -c1-12)…）"
        say "   → 首次部署必须 --reinject；先把 config 复制到 ESP 外并记 sha256"
        ;;
      injected)
        # 仅"恰 1 条探针"不足以叫 injected：还要 Enabled、state=normal、canonical、Delete 全过。
        if printf '%s' "${SB_OUT}" | grep -q '^deployable=yes' \
           && printf '%s' "${SB_OUT}" | grep -q '^state=normal' \
           && printf '%s' "${SB_OUT}" | grep -q '^canonical=yes' \
           && printf '%s' "${SB_OUT}" | grep -q '^nvram_delete_bootargs=yes' \
           && printf '%s' "${SB_OUT}" | grep -q '^probe_enabled=True'; then
          ok "分类 injected（探针恰 1 条，且 state=normal/canonical/Delete 全过）"
          say "   → 可直接部署；建议仍带 --reinject 归一到 normal"
        else
          bad "探针条目恰 1 条但不可直接部署（state/canonical/Delete/Enabled 有未过项）——按 dirty 处理，先 --reinject"
        fi
        ;;
      *)
        bad "分类 dirty（探针条目=${PROBE_COUNT}，哈希=$(printf '%s' "${CFG_SHA}" | cut -c1-12)…）——先人工检查，不要直接部署"
        ;;
    esac
    if printf '%s' "${CLS}" | grep -q '^parse=failed'; then
      bad "config.plist 解析失败（$(cls parse)）"
    fi

    if [ -f "${SB}" ] && [ -n "${CONFIG}" ]; then
      case "${SB_OUT}" in
        *xcrun*|*"command line developer tools"*)
          bad "set-bootargs.py 触发开发工具提示（CLT 未装好）：$(printf '%s' "${SB_OUT}" | head -2 | tr '\n' ' ')" ;;
        *)
          case "${CLASS}" in
            baseline)
              if [ "${SB_RC}" -eq 3 ]; then
                ok "set-bootargs.py 拒绝基线是预期（无探针条目，rc=3）"
              else
                bad "baseline 的 set-bootargs.py 返回 rc=${SB_RC}（预期 3，其余异常不得放行）：$(printf '%s' "${SB_OUT}" | head -1)"
              fi ;;
            *)
              if [ "${SB_RC}" -eq 0 ] && printf '%s' "${SB_OUT}" | grep -q '^state='; then
                ok "set-bootargs.py --check：$(printf '%s' "${SB_OUT}" | head -1)"
              else
                bad "set-bootargs.py --check 失败（rc=${SB_RC}，分类=${CLASS}）：$(printf '%s' "${SB_OUT}" | head -3 | tr '\n' ' ')"
              fi ;;
          esac ;;
      esac
    fi
  fi
fi

# ---------- 4. 其它硬工具：真实调用 ----------
say ""
say "== 4. 其它工具 =="
if command -v nm >/dev/null 2>&1 && nm -arch x86_64 /bin/ls >/dev/null 2>&1; then
  ok "nm 可用（真实执行 -arch x86_64）"
else
  bad "nm 不可用（01-deploy 的 _kmod_info 门禁依赖它；需要 CLT）"
fi

if command -v plutil >/dev/null 2>&1 && plutil -lint "${BUNDLE}/kext/IGPUProbe/Info.plist" 2>/dev/null | grep -q 'OK'; then
  ok "plutil -lint Info.plist"
else
  bad "plutil 校验 Info.plist 失败：$(plutil -lint "${BUNDLE}/kext/IGPUProbe/Info.plist" 2>&1 | head -2 | tr '\n' ' ')"
fi

if command -v file >/dev/null 2>&1 && file /bin/ls >/dev/null 2>&1; then
  ok "file 可用"
else
  bad "file 不可用"
fi

for t in diskutil kmutil csrutil sysctl ioreg; do
  if command -v "$t" >/dev/null 2>&1; then
    ok "${t} 在 PATH"
  else
    warn "${t} 不在 PATH（对应步骤会降级，需在报告里注明）"
  fi
done

# ---------- 5. 恢复基线文件 ----------
if [ -n "${FOUND}" ]; then
  if ls "${FOUND}/EFI/OC/config-before-probe-"*.plist >/dev/null 2>&1; then
    ok "恢复基线 config-before-probe-*.plist 存在"
  else
    warn "未见 config-before-probe-*.plist：首次基线部署前必须手工备份并记哈希"
  fi
fi

say ""
say "== 汇总 =="
say "PASS=${PASS} FAIL=${FAIL} WARN=${WARN}"
say "classification=${CLASS} config_sha256=${CFG_SHA} probe_count=${PROBE_COUNT}"
if [ "${FAIL}" -gt 0 ]; then
  say "RESULT: FAIL"
  exit 1
fi
say "RESULT: PASS"
exit 0