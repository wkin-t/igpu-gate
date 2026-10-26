#!/bin/bash
# 一键：校验 → 记录环境 → 静态门禁 → 构建 → 产物门禁 → 本机 KC 符号预检 → 报告
#
# 退出码（互不遮蔽，越靠前的失败越先返回）：
#   2  包哈希不符（交付包被改过 / 复制不完整）
#   3  静态红线 R1-R8 不过
#   4  构建失败（编译或链接）
#   7  构建产物缺『已定义』的 _kmod_info —— OC 必然 Invalid Parameter，禁止部署
#   5  产物结构检查失败（file / otool / shasum / nm）
#   8  本机 KC 符号预检未通过 —— 禁止部署
#   6  两项符号判决都不可用（KC 读不到且 kextutil 是假绿）→ 必须回 Windows 用 kc_gate
#   0  全过：可部署
#
# 2026-10-20（codex 对抗评审后修订）：
#   · build.sh 的 exit 7 不再被外层吞成 4；
#   · `_kmod_info` 改为 nm 已定义符号判定（strings 会假绿）；
#   · KC 预检 BootKC 必需、SystemKC 可选，且只有 KC PASS 才允许 exit 0；
#   · Preboot 回退必须唯一命中，多个候选即停止（不猜）。
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 9
REPORT="$ROOT/results-20261019/report.md"
mkdir -p "$ROOT/results-20261019"
: >"$REPORT"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
die() { log "(未通过) $1"; exit "$2"; }

log "===== IGPUProbe 构建报告 ====="
log "时间: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

log ""
log "--- 1) 完整性校验 ---"
if ! shasum -a 256 -c SHA256SUMS >>"$REPORT" 2>&1; then
  die "哈希不符 —— 停止，不要继续构建（先确认包完整）" 2
fi
log "全部文件哈希一致"

log ""
log "--- 2) 构建机身份 ---"
{
  echo "sw_vers:"; sw_vers
  echo "xcode-select: $(xcode-select -p 2>&1)"
  echo "clang:"; clang --version 2>&1 | head -2
  echo "sdk: $(xcrun --show-sdk-version 2>&1)"
  echo "sdk_path: $(xcrun --sdk macosx --show-sdk-path 2>&1)"
  echo "uname: $(uname -m) / $(uname -r)"
  echo "python: $(python3 -V 2>&1 || python -V 2>&1)"
} >>"$REPORT" 2>&1
log "已记录（见 report.md）"

log ""
log "--- 3) 静态红线检查（R1-R8）---"
if ! python3 tools/check-kext-source.py --kext-dir kext/IGPUProbe >>"$REPORT" 2>&1; then
  die "静态门禁不过 —— 源码被改过或环境不对" 3
fi
log "R1-R8 全过"

log ""
log "--- 3b) shell 变量花括号检查 ---"
# bash 3.2（macOS /bin/sh）+ 中文相邻时，`$VAR（` 会把全角括号的首字节并进变量名，
# set -u 下直接 "VAR?: unbound variable" 退出。这里提前拦下这类写法。
if ! python3 - "$ROOT" >>"$REPORT" 2>&1 <<'PYEOF'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
pat = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*|[0-9])(?=[^\x00-\x7f])')
bad = 0
for p in sorted(root.rglob("*.sh")):
    parts = p.relative_to(root).parts
    if any(part.startswith("results-") for part in parts):
        continue
    try:
        text = p.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    for i, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for m in pat.finditer(line):
            print(f"{p.relative_to(root)}:{i}: ${m.group(1)} 后紧跟非 ASCII，应写成 $\u007b{m.group(1)}\u007d")
            bad += 1
sys.exit(1 if bad else 0)
PYEOF
then
  die "存在未加花括号且紧跟中文字符的变量 —— macOS 自带 bash 3.2 会把它并进变量名" 3
fi
log "变量花括号检查通过"

log ""
log "--- 4) 构建 ---"
cd "$ROOT/kext/IGPUProbe" || exit 9
REGS="$ROOT/regs.txt" /bin/bash ./build.sh >>"$REPORT" 2>&1
RC=$?
if [ "$RC" -eq 7 ]; then
  die "产物缺 _kmod_info（构建脚本 exit 7）—— 见 report 末尾的诊断行" 7
elif [ "$RC" -ne 0 ]; then
  die "构建失败（构建脚本 exit ${RC}）—— 把 report.md 最后 40 行带回来" 4
fi
log "构建完成"

log ""
log "--- 5) 产物结构检查 ---"
BIN="IGPUProbe.kext/Contents/MacOS/IGPUProbe"
FAILED=0
file "$BIN" >>"$REPORT" 2>&1 || FAILED=1
otool -hv "$BIN" >>"$REPORT" 2>&1 || FAILED=1
shasum -a 256 "$BIN" >>"$REPORT" 2>&1 || FAILED=1
{ echo "undefined_symbols_declared: $(nm -u "$BIN" 2>/dev/null | wc -l | tr -d ' ')"; } >>"$REPORT" 2>&1

# 硬门禁：已定义的外部 _kmod_info（strings 判定会放过 U _kmod_info，属假绿）
if nm -arch x86_64 -gU "$BIN" 2>/dev/null | awk 'NF>=3 && $3=="_kmod_info" && $2 ~ /^[A-Za-z]$/ { ok=1 } END { exit ok ? 0 : 1 }'; then
  printf 'kmod_info_defined: 1\n' >>"$REPORT"
  log "_kmod_info 已定义 ✓"
else
  printf 'kmod_info_defined: 0\n' >>"$REPORT"
  { echo "## nm -gU 里与 kmod 有关的行："; nm -arch x86_64 -gU "$BIN" 2>&1 | grep -i kmod || echo "(无)"; } >>"$REPORT"
  die "产物没有已定义的 _kmod_info —— OpenCore 注入会以 Invalid Parameter 失败，禁止部署" 7
fi

# kextutil 只作诊断：macOS 26/27 已移除 -n 模式且退出码仍为 0（假绿）
KU_OUT="$(kextutil -n -print-diagnostics IGPUProbe.kext 2>&1)"
KU_RC=$?
printf 'kextutil -n (rc=%s): %s\n' "$KU_RC" "$KU_OUT" >>"$REPORT"
SYM_CHECK="unavailable"
case "$KU_OUT" in
  *"not a supported kmutil mode"*) SYM_CHECK="unavailable" ;;
  *) if [ "$KU_RC" -eq 0 ]; then SYM_CHECK="pass"; else SYM_CHECK="fail"; fi ;;
esac

if [ "$FAILED" -ne 0 ]; then
  die "产物结构检查有失败项" 5
fi

log ""
log "--- 6) 本机 KC 符号预检 ---"
BOOT_KC=/System/Library/KernelCollections/BootKernelExtensions.kc
SYS_KC=/System/Library/KernelCollections/SystemKernelExtensions.kc
if [ ! -f "$BOOT_KC" ]; then
  CAND=$(ls /System/Volumes/Preboot/*/boot/*/System/Library/KernelCollections/BootKernelExtensions.kc 2>/dev/null)
  CAND_N=$(printf '%s\n' "$CAND" | grep -c . || true)
  if [ "$CAND_N" -eq 1 ]; then
    BOOT_KC="$CAND"
  elif [ "$CAND_N" -gt 1 ]; then
    log "Preboot 下有 $CAND_N 个 BootKC 候选，无法确定当前系统所用，停止"
    printf '%s\n' "$CAND" >>"$REPORT"
    die "KC 定位歧义" 8
  fi
fi

KC_CHECK="unavailable"
KCS=()
if [ -f "$BOOT_KC" ]; then
  KCS=(--kc "$BOOT_KC")
  [ -f "$SYS_KC" ] && KCS+=(--kc "$SYS_KC")
  PY=python3
  command -v python3 >/dev/null 2>&1 || PY=python
  if [ -f "$ROOT/tools/kc_gate.py" ] && [ -f "$ROOT/tools/kc_imports.py" ]; then
    log "BootKC: $BOOT_KC"
    [ -f "$SYS_KC" ] && log "SystemKC: $SYS_KC" || log "SystemKC: 不存在，仅用 BootKC 判决"
    if "$PY" "$ROOT/tools/kc_gate.py" "${KCS[@]}" --kext "$BIN" --timeout 1800 >>"$REPORT" 2>&1; then
      KC_CHECK="pass"; log "KC 符号预检：PASS"
    else
      KC_CHECK="fail"; log "KC 符号预检：FAIL（见 report.md 末尾）"
    fi
  else
    log "tools/kc_gate.py 或 kc_imports.py 缺失，跳过"
  fi
else
  log "找不到 BootKernelExtensions.kc"
fi

{
  echo "file: $(file "$BIN" 2>&1)"
  echo "binary_sha256: $(shasum -a 256 "$BIN" 2>/dev/null | awk '{print $1}')"
  echo "plist_sha256: $(shasum -a 256 IGPUProbe.kext/Contents/Info.plist 2>/dev/null | awk '{print $1}')"
  echo "symbol_check_macos: $SYM_CHECK"
  echo "kc_gate_macos: $KC_CHECK"
} >"$ROOT/results-20261019/summary.txt"

# 只有 KC 预检 PASS 才允许给出"可以部署"；kextutil 是假绿，不能单独作为通行证
if [ "$KC_CHECK" = "fail" ]; then
  die "KC 符号预检失败 —— 这个二进制不能部署" 8
fi
if [ "$KC_CHECK" = "unavailable" ]; then
  log "⚠ KC 预检不可用（kextutil 在 macOS 26/27 是假绿，不能替代）"
  die "无法给出可部署结论 —— 请在 Windows 侧跑 kc_gate，或确认本机 KernelCollections 可读" 6
fi

log ""
log "===== 结论：可以部署 ====="
log "产物      : kext/IGPUProbe/IGPUProbe.kext"
log "二进制    : $(shasum -a 256 "$BIN" | awk '{print $1}')"
log "plist     : $(shasum -a 256 IGPUProbe.kext/Contents/Info.plist | awk '{print $1}')"
log "kmod_info : 已定义（nm 门禁）"
log "KC 预检   : $KC_CHECK"
log "下一步    : sudo sh onsite/01-deploy.sh"
exit 0