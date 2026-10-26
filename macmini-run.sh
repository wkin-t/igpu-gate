#!/bin/sh
# Mac mini 自检（两种模式）
#
#   sh macmini-run.sh            verify-only（默认）：只验证已封存的交付物，不构建、不改 dist/
#   sh macmini-run.sh --build    在 .build-tmp/ 里构建并校验；全部通过后才原子替换 dist/、
#                                更新 EXPECTED_BIN_SHA 与 BUILD-REPORT，并重封两份清单
#
# 为什么分两种：普通自检如果直接重建 dist/，会删掉/改写被清单封存的 BUILD-REPORT 副本，
# 随后又用旧清单校验新文件，必然自相矛盾（codex N9）。发布候选产物才走 --build。
set -u

MODE=verify
case "${1:-}" in
  ""|--verify) MODE=verify ;;
  --build) MODE=build ;;
  -h|--help)
    printf '%s\n' '用法：sh macmini-run.sh [--verify | --build]'
    printf '%s\n' '  --verify（默认）只验证已封存产物；--build 构建候选产物并重封清单'
    exit 0 ;;
  *) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
esac

ROOT=$(cd "$(dirname "$0")" && pwd)
BUILD="$ROOT/igpu-build"
KIT="$ROOT/testkit"
LOG="$ROOT/report-macmini.txt"
DIST="$BUILD/dist"
EXPBIN="$BUILD/EXPECTED_BIN_SHA"
DIST_BIN="$DIST/IGPUProbe.kext/Contents/MacOS/IGPUProbe"
DIST_PLIST="$DIST/IGPUProbe.kext/Contents/Info.plist"
TMP="$ROOT/.build-tmp"

: > "$LOG"
PATH="$KIT/bin:$PATH"
export PATH
PYTHONDONTWRITEBYTECODE=1
export PYTHONDONTWRITEBYTECODE
find "$ROOT" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

PASS=0; FAIL=0; HARD=0

log() { printf '%s\n' "$*" | tee -a "$LOG"; }

record() {
  name=$1; rc=$2
  if [ "$rc" -eq 0 ]; then PASS=$((PASS+1)); log "PASS  $name"
  else FAIL=$((FAIL+1)); HARD=1; log "FAIL  $name"; fi
}

step() {
  name=$1; dir=$2; shift 2
  out=$( cd "$dir" && "$@" 2>&1 ); rc=$?
  { printf '\n===== %s (rc=%d) =====\n' "$name" "$rc"; printf '%s\n' "$out"; } >> "$LOG"
  printf '%s\n' "$out" | tail -6
  record "$name" "$rc"
  return "$rc"
}

info() {
  name=$1; shift
  out=$("$@" 2>&1); rc=$?
  { printf '\n===== %s (info, rc=%d) =====\n' "$name" "$rc"; printf '%s\n' "$out"; } >> "$LOG"
  printf '%s\n' "$out" | head -4
}

sha_of() {
  h=$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}')
  [ -n "$h" ] || h=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
  printf '%s' "$h" | tr 'A-F' 'a-f'
}

expected_sha() {
  [ -f "$EXPBIN" ] || return 1
  _e=$(awk 'END {
    if (NR != 1) exit 2
    gsub(/[[:space:]]/, "")
    if ($0 !~ /^[0-9a-fA-F]{64}$/) exit 3
    print tolower($0)
  }' "$EXPBIN" 2>/dev/null) || return 1
  [ -n "$_e" ] || return 1
  printf '%s' "$_e"
}

# 校验一个 dist 目录（kext + SHA256SUMS + BUILD-REPORT）
make_dist() {  # make_dist <kext 源目录> <目标 dist 目录> <igpu-build 根>
  _k=$1; _d=$2; _b=$3
  rm -rf "$_d"; mkdir -p "$_d" || return 1
  cp -R "$_k" "$_d/IGPUProbe.kext" || return 1
  ( cd "$_d" && shasum -a 256 IGPUProbe.kext/Contents/MacOS/IGPUProbe IGPUProbe.kext/Contents/Info.plist > SHA256SUMS ) || return 1
  {
    printf "build_utc=%s\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf "host=%s %s\n" "$(uname -m)" "$(sw_vers -productVersion 2>/dev/null)"
    printf "clang=%s\n" "$(xcrun clang --version 2>/dev/null | head -1)"
    printf "sdk=%s\n" "$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)"
    printf "source_cpp_sha256=%s\n" "$(sha_of "$_b/kext/IGPUProbe/IGPUProbe.cpp")"
    printf "source_hpp_sha256=%s\n" "$(sha_of "$_b/kext/IGPUProbe/IGPUProbeState.hpp")"
    printf "binary_sha256=%s\n" "$(sha_of "$_d/IGPUProbe.kext/Contents/MacOS/IGPUProbe")"
    printf "binary_bytes=%s\n" "$(wc -c < "$_d/IGPUProbe.kext/Contents/MacOS/IGPUProbe" | tr -d ' ')"
    printf "plist_sha256=%s\n" "$(sha_of "$_d/IGPUProbe.kext/Contents/Info.plist")"
  } > "$_d/BUILD-REPORT.txt"
  ( cd "$_d" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1 )
}

check_dist_identity() {  # 返回 0 + 打印；失败 record
  if [ ! -s "$DIST_BIN" ]; then
    log "  缺少 ${DIST_BIN}（先跑 --build 或用已封存的 dist）"
    record "dist 二进制存在" 1
    return 1
  fi
  record "dist 二进制存在" 0

  file_out=$(file "$DIST_BIN" 2>&1) || true
  { printf '\n===== file (dist) =====\n'; printf '%s\n' "$file_out"; } >> "$LOG"
  printf '%s' "$file_out" | grep -q 'x86_64'
  record "dist 架构 x86_64" $?

  nm_out=$(nm -arch x86_64 -gU "$DIST_BIN" 2>&1) || true
  { printf '\n===== nm (dist) =====\n'; printf '%s\n' "$nm_out"; } >> "$LOG"
  printf '%s\n' "$nm_out" | awk 'NF>=3 && $3=="_kmod_info" && $2 ~ /^[A-Za-z]$/ {ok=1} END{exit ok?0:1}'
  record "dist nm: _kmod_info 已定义" $?

  ( cd "$DIST" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1 )
  record "dist/SHA256SUMS 自校验" $?

  DSHA=$(sha_of "$DIST_BIN")
  log "  binary_sha256=$DSHA"
  if [ -f "$DIST/BUILD-REPORT.txt" ]; then
    RSH=$(sed -n 's/^binary_sha256=//p' "$DIST/BUILD-REPORT.txt" | head -1)
    [ "$RSH" = "$DSHA" ]
    record "BUILD-REPORT 与 dist 二进制一致" $?
  else
    record "BUILD-REPORT 存在" 1
  fi

  EXP=$(expected_sha) || EXP=""
  if [ -n "$EXP" ]; then
    log "  EXPECTED_BIN_SHA=$EXP"
    [ "$EXP" = "$DSHA" ]
    record "dist 二进制 = EXPECTED_BIN_SHA" $?
  else
    log "  EXPECTED_BIN_SHA 缺失或格式非法"
    record "EXPECTED_BIN_SHA 可读" 1
  fi
  return 0
}

log "=================================================="
log " igpu Mac mini 自检  mode=$MODE  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log " 包根：$ROOT"
log "=================================================="

log ""
log "== 0. 环境 =="
info "uname" uname -a
info "sw_vers" sw_vers
info "xcode-select" xcode-select -p
info "clang" xcrun clang --version
info "python shim" sh -c 'command -v python; python -c "import sys; print(sys.executable); print(sys.version)"'
info "外部工具" sh -c 'command -v shasum; command -v plutil; command -v otool'

log ""
log "== 1. 先验已封存清单（此时不动任何交付物） =="
step "igpu-build SHA256SUMS 校验" "$BUILD" shasum -a 256 -c SHA256SUMS
step "kit 顶层 SHA256SUMS 校验" "$ROOT" shasum -a 256 -c SHA256SUMS

log ""
log "== 2. 交付产物身份（dist） =="
check_dist_identity || true

if [ "$MODE" = "build" ]; then
  log ""
  log "== 3. 候选构建（.build-tmp，不碰交付树） =="
  rm -rf "$TMP"
  mkdir -p "$TMP" || { log "FAIL 无法创建 $TMP"; record "创建 .build-tmp" 1; }
  cp -R "$BUILD" "$TMP/src" || { log "FAIL 复制 igpu-build 失败"; record "复制源码树" 1; }
  rm -rf "$TMP/src/dist" "$TMP/src/kext/IGPUProbe/IGPUProbe.kext"

  step "构建候选 IGPUProbe.kext (x86_64)" "$TMP/src" bash kext/IGPUProbe/build.sh
  NK="$TMP/src/kext/IGPUProbe/IGPUProbe.kext"
  NBIN="$NK/Contents/MacOS/IGPUProbe"

  if [ -s "$NBIN" ]; then
    record "候选产物存在" 0
    file_out=$(file "$NBIN" 2>&1) || true
    { printf '\n===== file (candidate) =====\n'; printf '%s\n' "$file_out"; } >> "$LOG"
    printf '%s' "$file_out" | grep -q 'x86_64'; record "候选架构 x86_64" $?
    nm_out=$(nm -arch x86_64 -gU "$NBIN" 2>&1) || true
    { printf '\n===== nm (candidate) =====\n'; printf '%s\n' "$nm_out"; } >> "$LOG"
    printf '%s\n' "$nm_out" | awk 'NF>=3 && $3=="_kmod_info" && $2 ~ /^[A-Za-z]$/ {ok=1} END{exit ok?0:1}'
    record "候选 nm: _kmod_info 已定义" $?
  else
    record "候选产物存在" 1
  fi

  step "候选源码红线 R1–R8" "$TMP/src" python tools/check-kext-source.py --kext-dir kext/IGPUProbe

  if [ -s "$NBIN" ]; then
    make_dist "$NK" "$TMP/dist" "$TMP/src"; record "生成候选 dist" $?
    NSHA=$(sha_of "$TMP/dist/IGPUProbe.kext/Contents/MacOS/IGPUProbe")
    log "  候选 binary_sha256=$NSHA"
  else
    record "生成候选 dist" 1
    NSHA=""
  fi

  if [ "$HARD" -eq 0 ] && [ -n "$NSHA" ]; then
    MOVED=0
    if [ -e "$DIST" ]; then
      if mv "$DIST" "$TMP/dist-old"; then
        MOVED=1
      else
        record "替换前移走旧 dist" 1
      fi
    else
      MOVED=1
    fi
    if [ "$MOVED" -eq 1 ]; then
      if mv "$TMP/dist" "$DIST"; then
        record "原子替换 dist/" 0
        printf '%s\n' "$NSHA" > "$EXPBIN" || record "更新 EXPECTED_BIN_SHA" 1
        # 发布后硬校验：dist 里必须就是候选二进制，且白名单等于它
        PUB_SHA=$(sha_of "$DIST/IGPUProbe.kext/Contents/MacOS/IGPUProbe" 2>/dev/null)
        PUB_EXP=$(expected_sha 2>/dev/null || true)
        if [ "$PUB_SHA" = "$NSHA" ] && [ "$PUB_EXP" = "$NSHA" ]; then
          record "发布后身份复核" 0
        else
          log "  发布后身份不符：dist=$PUB_SHA expected=$PUB_EXP candidate=$NSHA"
          record "发布后身份复核" 1
        fi
      else
        record "原子替换 dist/" 1
        [ "$MOVED" -eq 1 ] && [ -d "$TMP/dist-old" ] && mv "$TMP/dist-old" "$DIST" 2>/dev/null || true
      fi
    fi
  else
    log "  构建/候选校验未全过：不替换 dist/"
  fi
else
  log ""
  log "== 3. 跳过构建（verify-only；要重建用 --build） =="
fi

log ""
log "== 4. 源码红线 R1–R8（交付树） =="
step "check-kext-source R1–R8" "$BUILD" python tools/check-kext-source.py --kext-dir kext/IGPUProbe

log ""
log "== 5. kextutil（软门禁，失败只 WARN） =="
if [ -d "$DIST/IGPUProbe.kext" ]; then
  k_out=$(kextutil -n -print-diagnostics "$DIST/IGPUProbe.kext" 2>&1); k_rc=$?
  { printf '\n===== kextutil -n (rc=%d) =====\n' "$k_rc"; printf '%s\n' "$k_out"; } >> "$LOG"
  printf '%s\n' "$k_out" | tail -8
  [ "$k_rc" -ne 0 ] && log "WARN  kextutil rc=${k_rc}（新系统可能不支持 -n；软门禁）"
else
  log "WARN  未找到 dist kext，跳过 kextutil"
fi

log ""
log "== 6. 桩件仿真（五套） =="
step "harness: run-state.sh" "$KIT/harness" bash run-state.sh
step "harness: run.sh" "$KIT/harness" bash run.sh
step "harness: run-collect.sh" "$KIT/harness" bash run-collect.sh
step "harness: run-probe.sh" "$KIT/harness" bash run-probe.sh
step "harness: run-kcgate.sh" "$KIT/harness" bash run-kcgate.sh

log ""
log "== 7. cases（可移植版） =="
step "cases.py" "$KIT" python cases.py
step "cases2.py" "$KIT" python cases2.py
step "cases3.py" "$KIT" python cases3.py

log ""
log "== 8. plist 与（build 模式下的）重封 =="
step "plutil -lint dist/Info.plist" "$DIST" plutil -lint IGPUProbe.kext/Contents/Info.plist
if [ "$MODE" = "build" ]; then
  step "重封清单" "$ROOT" python "$BUILD/tools/reseal-manifests.py" "$ROOT"
  step "重封后 igpu-build 清单" "$BUILD" shasum -a 256 -c SHA256SUMS
  step "重封后 kit 顶层清单" "$ROOT" shasum -a 256 -c SHA256SUMS
  log "  注意：--build 已更新 dist/ 与 EXPECTED_BIN_SHA，需把新 dist 回传后再分发 Dell 包。"
fi

log ""
log "=================================================="
DSHA=$(sha_of "$DIST_BIN")
EXP=$(expected_sha) || EXP=""
log "binary_sha256=$DSHA"
log "expected_bin_sha=$EXP"
if [ -n "$EXP" ] && [ "$EXP" = "$DSHA" ]; then
  log "identity_match=yes"
else
  # 身份不一致是硬失败：verify-only 也不能在产物与白名单不符时报 PASS
  log "identity_match=no  (binary=$DSHA expected=${EXP:-missing})"
  HARD=1
  FAIL=$((FAIL+1))
fi
if [ "$HARD" -eq 0 ]; then log "RESULT: PASS"; else log "RESULT: FAIL"; fi
log "PASS=$PASS FAIL=$FAIL"
log "报告：$LOG"
log "=================================================="
[ "$HARD" -eq 0 ]