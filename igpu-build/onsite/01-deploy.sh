#!/bin/sh
# 01-deploy.sh —— 部署 IGPUProbe.kext 到 OCEFI ESP（macOS 侧，需 sudo）
#
# 用法： sudo sh onsite/01-deploy.sh [--reinject] [kext路径]
#
#   顺序：先跑 onsite/05-kcgate.sh（对同一份 dist 产物），再跑本脚本改 ESP。
#   --reinject  基线态（无探针条目）或已注入但 boot-args 非 normal 时，
#               先做一次**事务化**的重新注入/归一，再继续 kext 替换。
#
# 事务模型（第五轮 codex 评审后，F2/F3/F4/F11/F14）：
#   · 先分类（baseline / injected / dirty），不再用"哈希碰巧等于部署版"放行；
#   · 改配置之前：建唯一备份目录、把改前 config 复制到 ESP 上的备份并记录 sha，
#     同时在 ESP 外再存一份（默认 /var/tmp，可用 IGPU_BACKUP_DIR 覆盖）；
#   · 所有配置修改都在同目录暂存副本 config.plist.staged-$$ 上完成，
#     校验（XML / 探针恰 1 条 / boot-args 规范且 state=normal / 其它 key 未变）通过后才 mv 原子替换；
#   · 替换后从磁盘回读再校验；此后任何失败，EXIT 陷阱从 config_before 恢复 config 与 kext；
#   · 恢复意图位（CFG_MODIFIED/MOVED/INSTALLED）在 mv **之前**置位，信号窗口不会漏恢复；
#   · 部署前只读检查：ESP 只读/剩余空间、恢复基线文件、python/nm/plutil 功能性、旧备份目录（只报告）；
#   · 产物身份：带签名或提供白名单（EXPECTED_BIN_SHA）时必须匹配，签名视作新产物。
set -u

EXPECT_VOL="OCEFI"
EXPECT_OFF="1048576"
# 基线 config 的哈希**随 config 内容变化**（换 SMBIOS 序列号/MLB/UUID 就会变）。
# 默认值 = 当前 Dell 现场的基线；换过身份后必须用 IGPU_BASELINE_SHA 覆盖，
# 否则 01/03/10 都会把合法基线判成 dirty。
CFG_BASELINE="${IGPU_BASELINE_SHA:-991c9de090924d1bd68b2a1db4e104c91337286aae158c63fae98e301fae16e3}"
BACKUP_ROOT="${IGPU_BACKUP_DIR:-/var/tmp}"

BUNDLE=$(cd "$(dirname "$0")/.." && pwd -P)

say() { printf '%s\n' "$1"; }
die() { printf '\n[中止] %s\n' "$1" >&2; exit "${2:-1}"; }
take_sha() { _o=$(shasum -a 256 "$1" 2>/dev/null) || return 1; printf '%s' "$_o" | awk '{print $1}'; }

REINJECT=0
SRC=""
for _a in "$@"; do
  case "${_a}" in
    --reinject) REINJECT=1 ;;
    --help|-h) printf '用法：sudo sh onsite/01-deploy.sh [--reinject] [kext路径]\n'; exit 0 ;;
    --*) die "未知参数：${_a}（只支持 --reinject 与 kext 路径）" 2 ;;
    *)
      [ -z "$SRC" ] || die "只能给一个 kext 路径（已收到 ${SRC}，又收到 ${_a}）" 2
      SRC="${_a}"
      ;;
  esac
done
unset _a
if [ -z "$SRC" ]; then
  if [ -d "$BUNDLE/dist/IGPUProbe.kext" ]; then
    SRC="$BUNDLE/dist/IGPUProbe.kext"
    say "   [产物] 默认使用 dist/IGPUProbe.kext（存在）"
  else
    SRC="$BUNDLE/kext/IGPUProbe/IGPUProbe.kext"
    say "   [产物] 未找到 dist/IGPUProbe.kext，回退 kext/IGPUProbe/IGPUProbe.kext"
  fi
else
  say "   [产物] 显式指定：$SRC"
fi

[ "$(id -u)" -eq 0 ] || die "需要写 ESP：sudo sh onsite/01-deploy.sh"

say "== 1/8 检查待部署产物 =="
[ -d "$SRC" ] || die "找不到 kext 目录：$SRC"
SRC_BIN="$SRC/Contents/MacOS/IGPUProbe"
SRC_PLIST="$SRC/Contents/Info.plist"
[ -f "$SRC_BIN" ] || die "缺可执行文件：$SRC_BIN"
[ -f "$SRC_PLIST" ] || die "缺 Info.plist：$SRC_PLIST"
command -v nm >/dev/null 2>&1 || die "找不到 nm（需要 Xcode Command Line Tools）"
command -v plutil >/dev/null 2>&1 || die "找不到 plutil（macOS 自带，异常）"
nm -arch x86_64 -gU "$SRC_BIN" 2>/dev/null \
  | awk 'NF>=3 && $3=="_kmod_info" && $2 ~ /^[A-Za-z]$/ { ok=1 } END { exit ok ? 0 : 1 }' \
  || die "产物没有已定义的 _kmod_info —— OC 会以 Invalid Parameter 拒绝注入"
plutil -lint "$SRC_PLIST" >/dev/null 2>&1 || die "Info.plist 语法不合法"
ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC_PLIST" 2>/dev/null)
[ "$ID" = "dev.igpu.probe" ] || die "CFBundleIdentifier 不是 dev.igpu.probe（实际：${ID}）"
SRC_B=$(take_sha "$SRC_BIN") || die "读不到源二进制哈希"
SRC_P=$(take_sha "$SRC_PLIST") || die "读不到源 plist 哈希"
say "   二进制 $SRC_B"
say "   plist  $SRC_P"
say "   _kmod_info 已定义 ✓"

# ---- N3 产物身份：白名单必须是文件；环境变量只能复述同一个值 ----
SIGNED=no
if command -v otool >/dev/null 2>&1; then
  if otool -l "$SRC_BIN" 2>/dev/null | grep -q LC_CODE_SIGNATURE; then SIGNED=yes; fi
fi
EXP_FILE="$BUNDLE/EXPECTED_BIN_SHA"
[ -f "$EXP_FILE" ] || die "缺少白名单 ${EXP_FILE}（生产路径不再允许无白名单放行）。
请用 shasum -a 256 记录待部署二进制哈希，写入该文件（恰好一行 64 位 hex）。"
# 整个文件必须**恰好一条记录**且是 64hex：合法行 + 垃圾行、合法行 + 空行都拒绝。
# awk 的 NR 按记录数计，能同时覆盖"末尾有无换行"两种情况。
FILE_HEX=$(awk 'END {
  if (NR != 1) exit 2
  gsub(/[[:space:]]/, "")
  if ($0 !~ /^[0-9a-fA-F]{64}$/) exit 3
  print tolower($0)
}' "$EXP_FILE") || die "白名单格式非法：${EXP_FILE} 必须恰好一行 64 位 hex（不允许空行或附加行）"
FILE_HEX=$(printf '%s' "$FILE_HEX" | tr 'A-F' 'a-f')
EXPECTED=$FILE_HEX
EXP_SOURCE=file
if [ -n "${IGPU_EXPECTED_BIN_SHA:-}" ]; then
  ENV_HEX=$(printf '%s' "$IGPU_EXPECTED_BIN_SHA" | tr 'A-F' 'a-f')
  [ "$ENV_HEX" = "$FILE_HEX" ] || die "IGPU_EXPECTED_BIN_SHA 与文件白名单不同：
  env  $ENV_HEX
  file $FILE_HEX
环境变量只能复述文件值；要换产物请更新 ${EXP_FILE}。"
  EXP_SOURCE=env
fi
ACT=$(printf '%s' "$SRC_B" | tr 'A-F' 'a-f')
[ "$ACT" = "$EXPECTED" ] || die "产物二进制哈希与白名单不符（签名/重签视为新产物）：
  实际 $SRC_B
  期望 $EXPECTED
请先更新 ${EXP_FILE} 并重封清单。"
say "   产物身份 ✓ ${ACT}（来源 ${EXP_SOURCE}，签名=${SIGNED}）"

# 相对路径必须解析成规范路径后再判断：Runbook 允许 `dist/IGPUProbe.kext`，
# 只按字符串前缀匹配会漏掉 plist 身份核验（codex N3 复现过）。
SRC_ABS=$(cd "$SRC" 2>/dev/null && pwd -P) || die "无法解析 kext 目录：$SRC"
case "$SRC_ABS" in
  "$BUNDLE"/dist/*)
    DS="$BUNDLE/dist/SHA256SUMS"
    [ -f "$DS" ] || die "部署 dist 产物但缺少 ${DS}"
    DS_B=$(awk '$2=="IGPUProbe.kext/Contents/MacOS/IGPUProbe" {print $1}' "$DS" | head -1)
    DS_P=$(awk '$2=="IGPUProbe.kext/Contents/Info.plist" {print $1}' "$DS" | head -1)
    [ -n "$DS_B" ] && [ -n "$DS_P" ] || die "dist/SHA256SUMS 缺二进制或 plist 条目"
    SP=$(printf '%s' "$SRC_P" | tr 'A-F' 'a-f')
    [ "$(printf '%s' "$DS_B" | tr 'A-F' 'a-f')" = "$ACT" ] || die "dist 二进制与 dist/SHA256SUMS 不符"
    [ "$(printf '%s' "$DS_P" | tr 'A-F' 'a-f')" = "$SP" ] || die "dist plist 与 dist/SHA256SUMS 不符"
    say "   dist/SHA256SUMS ✓ 二进制+plist 一致"
    ;;
esac

say ""
say "== 2/8 定位并校验 ESP =="
CAND=$(diskutil list 2>/dev/null | awk '/OCEFI/ {print $NF}' | sort -u)
N=$(printf '%s\n' "$CAND" | grep -c . 2>/dev/null || true)
[ "$N" -eq 1 ] || { diskutil list; die "OCEFI 候选数=${N}（必须恰好 1 个）"; }
ESP=$CAND
VOL=$(diskutil info "$ESP" 2>/dev/null | awk -F': *' '/Volume Name/ {print $2}')
OFF_RAW=$(diskutil info "$ESP" 2>/dev/null | awk -F': *' '/Partition Offset/ {print $2}')
set -- $OFF_RAW; OFF=${1:-}
[ "$VOL" = "$EXPECT_VOL" ] || die "卷名不符：$VOL"
[ "$OFF" = "$EXPECT_OFF" ] || die "分区偏移不符：$OFF"
PARENT=$(printf '%s' "$ESP" | sed 's/s[0-9][0-9]*$//')
PNAME=$(diskutil info "$PARENT" 2>/dev/null | awk -F': *' '/Device \/ Media Name/ {print $2}')
say "   $ESP  $VOL / 偏移 $OFF ✓  父磁盘 ${PARENT}（${PNAME}）"
case "$PNAME" in *SanDisk*) : ;; *) say "   ⚠ 父磁盘不是 SanDisk，请确认目标（卷名+偏移已校验）" ;; esac

say ""
say "== 3/8 挂载、只读/空间与工具前置检查 =="
diskutil mount "$ESP" >/dev/null 2>&1 || true
MP=$(diskutil info "$ESP" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2}')
[ -n "$MP" ] && [ -d "$MP" ] || die "挂载失败：拿不到挂载点"
CFG="$MP/EFI/OC/config.plist"
[ -f "$CFG" ] || die "ESP 上没有 EFI/OC/config.plist"
RO=$(diskutil info "$ESP" 2>/dev/null | awk -F': *' '/Read-Only Volume/ {print $2}')
[ "$RO" = "No" ] || die "ESP 卷不可写（Read-Only Volume=${RO:-未知}）"
AVAIL=$(df -k "$MP" 2>/dev/null | awk 'NR>1 && NF>=4 {v=$4} END {print v}')
case "${AVAIL:-}" in ''|*[!0-9]*) die "读不到 ESP 剩余空间（df -k $MP 失败）" ;; esac
[ "$AVAIL" -ge 20480 ] || die "ESP 剩余空间不足：${AVAIL} KB（要求 ≥ 20 MB）"

# python：必须真的能导入本套工具用到的标准库，不能只看 command -v
PY=""
for _c in python3 python; do
  if command -v "$_c" >/dev/null 2>&1 \
     && "$_c" -c 'import plistlib, argparse, pathlib, xml.etree.ElementTree, base64, sys; sys.exit(0)' >/dev/null 2>&1; then
    PY="$_c"; break
  fi
done
[ -n "$PY" ] || die "找不到可用的 python3/python（plistlib 等标准库导入失败）。请安装 Xcode Command Line Tools 后重试。"
say "   python=$PY 功能可用 ✓  ESP 剩余 ${AVAIL} KB ✓  可写 ✓"

# 恢复基线文件：存在则哈希必须是基线；缺失只告警（本次会另建 config_before）
BASE_FILE=""
for _f in "$MP"/EFI/OC/config-before-probe-*.plist; do
  [ -f "$_f" ] && BASE_FILE="$_f"
done
if [ -n "$BASE_FILE" ]; then
  BASE_SHA=$(take_sha "$BASE_FILE") || die "读不到恢复基线文件哈希：${BASE_FILE}"
  [ "$BASE_SHA" = "$CFG_BASELINE" ] || die "恢复基线文件不是基线（${BASE_FILE} = ${BASE_SHA}），拒绝继续"
  say "   恢复基线文件 $BASE_SHA ✓"
else
  say "   ⚠ 未找到 config-before-probe-*.plist：rollback --config 将不可用（本次会另建 config_before）"
fi
OLD_BK=$(ls -d "$MP"/igpu-backup-* 2>/dev/null | wc -l | tr -d ' ')
OLD_ST=$(ls -d "$MP"/igpu-state-* 2>/dev/null | wc -l | tr -d ' ')
say "   旧备份目录：igpu-backup-* ${OLD_BK} 个、igpu-state-* ${OLD_ST} 个（只报告，不删除）"

say ""
say "== 4/8 分类当前配置（baseline / injected / dirty）=="
CFG_SHA=$(take_sha "$CFG") || die "读不到 config 哈希"
CHK=$("$PY" "$BUNDLE/tools/set-bootargs.py" --config "$CFG" --check 2>&1) || true
PROBE_COUNT=$(printf '%s\n' "$CHK" | sed -n 's/^probe_count=//p' | head -1)
[ -n "$PROBE_COUNT" ] || PROBE_COUNT=0
CUR_STATE=$(printf '%s\n' "$CHK" | sed -n 's/^state=//p' | head -1)
CUR_CANON=$(printf '%s\n' "$CHK" | sed -n 's/^canonical=//p' | head -1)
CUR_DEL=$(printf '%s\n' "$CHK" | sed -n 's/^nvram_delete_bootargs=//p' | head -1)
say "   config $CFG_SHA  探针 ${PROBE_COUNT} 条  state=${CUR_STATE:-unknown} canonical=${CUR_CANON:-unknown} delete=${CUR_DEL:-unknown}"

CLASS=""
DIRTY_WHY=""
if [ "$PROBE_COUNT" -eq 0 ]; then
  if [ "$CFG_SHA" = "$CFG_BASELINE" ]; then
    CLASS="baseline"
  else
    CLASS="dirty"
    DIRTY_WHY="没有探针条目，但哈希不是基线（配置被改过，无法判断意图）"
  fi
elif [ "$PROBE_COUNT" -eq 1 ]; then
  STR=$("$PY" "$BUNDLE/tools/set-bootargs.py" --config "$CFG" --require-probe 2>&1) || true
  if printf '%s\n' "$STR" | grep -q '^probe_ok=yes'; then
    case "${CUR_STATE}:${CUR_CANON}" in
      normal:yes|off:yes|verbose:yes|prep:yes) CLASS="injected" ;;
      *) CLASS="dirty"; DIRTY_WHY="boot-args 状态不干净（state=${CUR_STATE:-unknown} canonical=${CUR_CANON:-unknown}）" ;;
    esac
  else
    CLASS="dirty"; DIRTY_WHY="探针条目字段/Enabled/Comment 不符：$(printf '%s' "$STR" | tail -1)"
  fi
else
  CLASS="dirty"; DIRTY_WHY="探针条目有 ${PROBE_COUNT} 条（要求恰好 1 条）"
fi

case "$CLASS" in
  baseline)
    if [ "$REINJECT" -eq 0 ]; then
      die "当前是基线配置（哈希 ${CFG_SHA}，无探针条目），不能直接部署。
先把改前配置复制到 ESP 外并记下哈希，再用受控重新注入：
  cp \"${CFG}\" \"${BACKUP_ROOT}/igpu-config-baseline-\$(date +%Y%m%d-%H%M%S).plist\"
  shasum -a 256 \"${BACKUP_ROOT}\"/igpu-config-baseline-*.plist
  sudo sh onsite/01-deploy.sh --reinject"
    fi
    say "   → baseline，且给了 --reinject"
    ;;
  injected)
    say "   → 已注入态（结构校验通过）"
    ;;
  dirty)
    die "配置状态不干净，拒绝部署（不做哈希碰运气的放行）：
  ${DIRTY_WHY}
请先人工核对 config.plist；修正后再重跑。"
    ;;
esac

if [ "$CLASS" = "injected" ]; then
  if [ "$CUR_STATE" != "normal" ] || [ "$CUR_CANON" != "yes" ] || [ "$CUR_DEL" != "yes" ]; then
    if [ "$REINJECT" -eq 0 ]; then
      die "已注入但未达可部署状态（state=${CUR_STATE:-unknown} canonical=${CUR_CANON:-unknown} nvram_delete_bootargs=${CUR_DEL:-unknown}）：
直接部署会让第一轮 normal 拿不到数据，或第二轮切 off 失败。
请先归一：sudo sh onsite/01-deploy.sh --reinject"
    fi
    say "   → 当前未达可部署状态，--reinject 将在暂存副本上归一"
  else
    say "   → 已注入且可部署（normal / canonical / delete 全过）"
  fi
fi

say ""
say "== 5/8 改前备份（config 双份 + 唯一目录）=="
TS=$(date +%Y%m%d-%H%M%S)
BK="$MP/igpu-backup-$TS-$$"
mkdir "$BK" 2>/dev/null || die "备份目录无法创建（重名或权限问题）：$BK"
printf 'STATE=partial\n' > "$BK/STATE" || die "写备份状态失败"
cp "$CFG" "$BK/config.plist" || die "备份 config 到 ESP 失败"
CFG_BEFORE_SHA=$(take_sha "$BK/config.plist") || die "读不到备份 config 哈希"
[ "$CFG_BEFORE_SHA" = "$CFG_SHA" ] || die "备份 config 哈希与现网不一致（拒绝继续）"

mkdir -p "$BACKUP_ROOT" || die "无法创建外部备份根目录：$BACKUP_ROOT"
LOCAL_DIR="$BACKUP_ROOT/igpu-config-$TS-$$"
mkdir "$LOCAL_DIR" || die "外部备份目录创建失败：$LOCAL_DIR"
chmod 700 "$LOCAL_DIR" 2>/dev/null || say "   ⚠ chmod 700 失败（外部备份目录权限）"
cp "$CFG" "$LOCAL_DIR/config.plist" || die "备份 config 到外部目录失败"
[ "$(take_sha "$LOCAL_DIR/config.plist")" = "$CFG_BEFORE_SHA" ] || die "外部备份哈希不符"

{
  echo "TYPE=deploy"
  echo "class=$CLASS"
  echo "reinject=$REINJECT"
  echo "config_before=$BK/config.plist"
  echo "config_before_sha=$CFG_BEFORE_SHA"
  echo "config_before_local=$LOCAL_DIR/config.plist"
  echo "signed=$SIGNED"
  echo "expected_bin_sha=${EXPECTED:-none}"
  echo "binary_sha=$SRC_B"
  echo "plist_sha=$SRC_P"
  echo "esp_free_kb=$AVAIL"
  echo "baseline_file=${BASE_FILE:-missing}"
} > "$BK/META" || die "写 META 失败"
say "   ESP 备份 ${BK}（config_before=${CFG_BEFORE_SHA}）"
say "   外部备份 $LOCAL_DIR/config.plist"

DST="$MP/EFI/OC/Kexts/IGPUProbe.kext"
NEW="$MP/EFI/OC/Kexts/.IGPUProbe.kext.new-$TS-$$"
HELD="$MP/EFI/OC/Kexts/.IGPUProbe.kext.old-$TS-$$"
STAGED="$MP/EFI/OC/config.plist.staged-$$"
# 进入事务前就记录现场是否存在 kext —— restore() 不能等到第 7 步才知道，
# 否则早期失败会把"原本存在但还没备份"的 kext 当成"原本没有"删掉。
if [ -d "$DST" ]; then EXISTED="yes"; else EXISTED="no"; fi
MOVED=0
INSTALLED=0
CFG_MODIFIED=0
COMMITTED=0

restore() {
  [ "${COMMITTED:-0}" -eq 1 ] && return 0
  if [ "${CFG_MODIFIED:-0}" -eq 1 ]; then
    if [ -f "$BK/config.plist" ] \
       && [ "$(take_sha "$BK/config.plist")" = "$CFG_BEFORE_SHA" ] \
       && cp "$BK/config.plist" "$CFG" 2>/dev/null \
       && [ "$(take_sha "$CFG")" = "$CFG_BEFORE_SHA" ]; then
      printf '[恢复] config.plist 已还原为改前内容（%s）\n' "$CFG_BEFORE_SHA" >&2
    else
      printf '[恢复失败] 请手工用 %s 覆盖 %s，并核对 sha256=%s\n' "$BK/config.plist" "$CFG" "$CFG_BEFORE_SHA" >&2
    fi
  fi
  if [ "${MOVED:-0}" -eq 1 ] && [ -d "$HELD" ]; then
    rm -rf "$DST" 2>/dev/null
    if mv "$HELD" "$DST" 2>/dev/null; then
      printf '[恢复] 旧 kext 已放回 %s\n' "$DST" >&2
    else
      printf '[恢复失败] 旧 kext 在 %s，请手工 mv 回去\n' "$HELD" >&2
    fi
  elif [ "${INSTALLED:-0}" -eq 1 ] && [ -d "$DST" ]; then
    rm -rf "$DST" 2>/dev/null && printf '[恢复] 已移除本次安装的 kext\n' >&2
  elif [ "$EXISTED" = "no" ] && [ -d "$DST" ]; then
    rm -rf "$DST" 2>/dev/null && printf '[恢复] 已移除新装 kext（原本没有）\n' >&2
  fi
  rm -f "$STAGED" 2>/dev/null
  rm -rf "$NEW" 2>/dev/null
}
trap 'restore' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

say ""
say "== 6/8 配置归一（仅基线或需要归一时；全部在暂存副本上做）=="
NEED_CFG_WRITE=0
if [ "$REINJECT" -eq 1 ]; then
  if [ "$CLASS" = "baseline" ]; then
    NEED_CFG_WRITE=1
  elif [ "${CUR_STATE:-}" != "normal" ] || [ "${CUR_CANON:-}" != "yes" ] || [ "${CUR_DEL:-}" != "yes" ]; then
    NEED_CFG_WRITE=1
  fi
fi

if [ "$NEED_CFG_WRITE" -eq 1 ]; then
  cp "$CFG" "$STAGED" || die "创建暂存副本失败（现网未动）"
  [ "$(take_sha "$STAGED")" = "$CFG_BEFORE_SHA" ] || die "暂存副本哈希不符（现网未动）"
  if [ "$CLASS" = "baseline" ]; then
    INJ=$("$PY" "$BUNDLE/tools/inject-probe.py" --config "$STAGED" 2>&1) \
      || die "暂存副本注入失败（现网未动）：$INJ"
    printf '%s\n' "$INJ" | sed 's/^/   /'
  fi
  NORM=$("$PY" "$BUNDLE/tools/set-bootargs.py" --config "$STAGED" --mode normal --require-deployable 2>&1) \
    || die "暂存副本归一到 normal 失败（现网未动）：$NORM"
  printf '%s\n' "$NORM" | sed 's/^/   /'
  VER=$("$PY" "$BUNDLE/tools/inject-probe.py" --verify-staged "$STAGED" --orig "$BK/config.plist" --expect-state normal 2>&1) \
    || die "暂存副本严格校验失败（现网未动）：$VER"
  printf '%s\n' "$VER" | sed 's/^/   /'
  STAGED_SHA=$(take_sha "$STAGED") || die "读不到暂存副本哈希（现网未动）"
  CFG_MODIFIED=1
  mv "$STAGED" "$CFG" || { CFG_MODIFIED=0; die "替换 config 失败（现网未动）"; }
  [ "$(take_sha "$CFG")" = "$STAGED_SHA" ] || die "替换后 config 哈希不符（将自动恢复）"
  AFTER=$("$PY" "$BUNDLE/tools/set-bootargs.py" --config "$CFG" --check --require-deployable 2>&1) \
    || die "替换后 config 严格校验失败（将自动恢复）：$AFTER"
  printf '%s\n' "$AFTER" | sed 's/^/   /'
  F_STATE=$(printf '%s\n' "$AFTER" | sed -n 's/^state=//p' | head -1)
  F_CANON=$(printf '%s\n' "$AFTER" | sed -n 's/^canonical=//p' | head -1)
  F_PROBE=$(printf '%s\n' "$AFTER" | sed -n 's/^probe_count=//p' | head -1)
  [ "$F_STATE" = "normal" ] || die "替换后 state=${F_STATE}，不是 normal（将自动恢复）"
  [ "$F_CANON" = "yes" ] || die "替换后 boot-args 不是规范串（将自动恢复）"
  [ "$F_PROBE" = "1" ] || die "替换后探针条目=${F_PROBE}，不是 1（将自动恢复）"
  F_DEL=$(printf '%s\n' "$AFTER" | sed -n 's/^nvram_delete_bootargs=//p' | head -1)
  [ "$F_DEL" = "yes" ] || die "替换后 NVRAM/Delete 缺 boot-args（nvram_delete_bootargs=${F_DEL:-unknown}，将自动恢复）"
  CFG_SHA=$(take_sha "$CFG") || die "读不到新 config 哈希"
  say "   配置已事务化替换：$CFG_BEFORE_SHA → $CFG_SHA"
else
  say "   无需改配置（已注入且 boot-args 已是规范 normal）"
fi

say ""
say "== 7/8 暂存 kext → 校验 → rename 就位 =="
if [ -d "$DST" ]; then
  EXISTED="yes"
  /usr/bin/ditto --norsrc --noextattr --noqtn "$DST" "$BK/IGPUProbe.kext" 2>"$BK/ditto.err" \
    || die "备份旧 kext 失败（见 $BK/ditto.err）"
  OB=$(take_sha "$BK/IGPUProbe.kext/Contents/MacOS/IGPUProbe") || die "备份里读不到二进制"
  OP=$(take_sha "$BK/IGPUProbe.kext/Contents/Info.plist") || die "备份里读不到 plist"
  { echo "old_binary=$OB"; echo "old_plist=$OP"; } > "$BK/SHA256.old" || die "写 SHA256.old 失败"
  [ "$OB" = "$(take_sha "$DST/Contents/MacOS/IGPUProbe")" ] || die "备份二进制与现网不一致"
  [ "$OP" = "$(take_sha "$DST/Contents/Info.plist")" ] || die "备份 plist 与现网不一致"
  printf 'EXISTED_KEXT=yes\n' >> "$BK/META"
  say "   旧 kext 备份并核对: $OB"
else
  EXISTED="no"
  printf 'EXISTED_KEXT=no\n' >> "$BK/META"
  say "   ESP 上原本没有 IGPUProbe.kext"
fi

rm -rf "$NEW"
if ! /usr/bin/ditto --norsrc --noextattr --noqtn "$SRC" "$NEW" 2>"$BK/ditto2.err"; then
  rm -rf "$NEW"
  /bin/cp -R "$SRC" "$NEW" 2>>"$BK/ditto2.err" || die "复制到 ESP 失败（见 $BK/ditto2.err）"
fi
[ -f "$NEW/Contents/MacOS/IGPUProbe" ] || die "暂存目录结构不对"
[ "$(take_sha "$NEW/Contents/MacOS/IGPUProbe")" = "$SRC_B" ] || die "暂存二进制哈希不符"
[ "$(take_sha "$NEW/Contents/Info.plist")" = "$SRC_P" ] || die "暂存 plist 哈希不符"
plutil -lint "$NEW/Contents/Info.plist" >/dev/null 2>&1 || die "暂存 plist 语法不合法"

# dot_clean 失败不再静默吞掉：记录 WARN 与原始错误，继续（不影响哈希已核对的事实）
DC=ok
if ! dot_clean -m "$NEW" >/dev/null 2>"$BK/dot_clean.err"; then
  if ! /usr/sbin/dot_clean -m "$NEW" >/dev/null 2>>"$BK/dot_clean.err"; then
    DC=warn
    say "   ⚠ dot_clean 失败（已记入 $BK/dot_clean.err，WARN）"
  fi
fi
printf 'dot_clean=%s\n' "$DC" >> "$BK/META"
say "   暂存并核对完成"

if [ -d "$DST" ]; then
  MOVED=1
  mv "$DST" "$HELD" || { MOVED=0; die "移动旧 kext 失败（原样未动）"; }
fi
INSTALLED=1
mv "$NEW" "$DST" || die "安装新 kext 失败（旧 kext 在 ${HELD}，退出时会自动放回）"
say "   新 kext 已就位"

say ""
say "== 8/8 全部复核通过后才提交 =="
[ "$(take_sha "$DST/Contents/MacOS/IGPUProbe")" = "$SRC_B" ] || die "部署后二进制哈希不符"
[ "$(take_sha "$DST/Contents/Info.plist")" = "$SRC_P" ] || die "部署后 plist 哈希不符"
plutil -lint "$DST/Contents/Info.plist" >/dev/null 2>&1 || die "部署后 plist 不合法"
[ "$(take_sha "$CFG")" = "$CFG_SHA" ] || die "config.plist 被意外改动"
printf 'config_after_sha=%s\n' "$CFG_SHA" >> "$BK/META"
printf 'STATE=complete\n' > "$BK/STATE" || die "写完成标记失败"
COMMITTED=1
rm -rf "$HELD" 2>/dev/null || true
say "   二进制 ✓  plist ✓  config ✓  → 已提交"
say "   备份目录 ${BK}（config_before=${CFG_BEFORE_SHA}  config_after=${CFG_SHA}）"

sync || die "sync 失败（kext 已就位，请手动 sync 后再重启）"
if ! diskutil unmount "$ESP" >/dev/null 2>&1 && ! diskutil unmount "$MP" >/dev/null 2>&1; then
  die "卸载失败（kext 已就位）—— 请手动：diskutil unmount $ESP"
fi
say "   已卸载 ✓"
say ""
say "完成。备份：$BK"
say "回滚：sudo sh onsite/03-rollback.sh --from-backup ${BK}   （完整撤销本次部署）"
say "下一步：sudo reboot → 重启后 sh onsite/02-collect.sh"