#!/bin/sh
# 04-state.sh —— 切换 IGPUProbe 的运行状态（normal / off / verbose），供验收矩阵使用
#
# 用法：
#   sudo sh onsite/04-state.sh show
#   sudo sh onsite/04-state.sh off | verbose | normal
#
# 安全性（第二轮 codex 评审后修订）：
#   · 写入前用 --require-deployable 严格校验探针条目（恰好一条、字段完全匹配、Enabled=true）；
#   · 写前确认 NVRAM/Delete 含 boot-args —— 否则 OC 的 Add 不会生效，直接拒绝而不是"改了算成功"；
#   · 备份用独立前缀 igpu-state-<时间>-<pid>，独占创建，不会与 03-rollback 认的 igpu-backup-* 混淆；
#   · 失败恢复改为"备份复制到暂存 → 核对旧哈希 → rename 覆盖 → 再核对"，不再直接 cp 覆盖活动配置；
#   · 成功后打印 committed=1 / target_mode；只有清理阶段失败才用 exit 12，避免误导重试。
set -u

EXPECT_VOL="OCEFI"
EXPECT_OFF="1048576"
MODE=${1:-}
case "$MODE" in
  normal|off|verbose|prep|show|safe-on|safe-off) : ;;
  *) printf '用法：sudo sh onsite/04-state.sh {show|normal|off|verbose|prep|safe-on|safe-off}\n' >&2; exit 2 ;;
esac

BUNDLE=$(cd "$(dirname "$0")/.." && pwd)
SETTER="$BUNDLE/tools/set-bootargs.py"

say() { printf '%s\n' "$1"; }
die() { printf '\n[中止] %s\n' "$1" >&2; exit "${2:-1}"; }
take_sha() { _o=$(shasum -a 256 "$1" 2>/dev/null) || return 1; printf '%s' "$_o" | awk '{print $1}'; }

[ "$(id -u)" -eq 0 ] || die "需要写 ESP：sudo sh onsite/04-state.sh $MODE"
[ -f "$SETTER" ] || die "缺 ${SETTER}（包不完整）"
PY=python3
command -v python3 >/dev/null 2>&1 || PY=python

say "== 1/5 定位并校验 ESP =="
CAND=$(diskutil list 2>/dev/null | awk '/OCEFI/ {print $NF}' | sort -u)
N=$(printf '%s\n' "$CAND" | grep -c . 2>/dev/null || true)
[ "$N" -eq 1 ] || { diskutil list; die "OCEFI 候选数=${N}（必须恰好 1 个）"; }
ESP=$CAND
VOL=$(diskutil info "$ESP" 2>/dev/null | awk -F': *' '/Volume Name/ {print $2}')
OFF_RAW=$(diskutil info "$ESP" 2>/dev/null | awk -F': *' '/Partition Offset/ {print $2}')
set -- $OFF_RAW; OFF=${1:-}
[ "$VOL" = "$EXPECT_VOL" ] || die "卷名不符：$VOL"
[ "$OFF" = "$EXPECT_OFF" ] || die "分区偏移不符：$OFF"
say "   $ESP  $VOL / 偏移 $OFF ✓"

say ""
say "== 2/5 挂载并做探针预检 =="
diskutil mount "$ESP" >/dev/null 2>&1 || true
MP=$(diskutil info "$ESP" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2}')
[ -n "$MP" ] && [ -d "$MP" ] || die "挂载失败：拿不到挂载点"
CFG="$MP/EFI/OC/config.plist"
[ -f "$CFG" ] || die "ESP 上没有 EFI/OC/config.plist"

STRICT=$("$PY" "$SETTER" --config "$CFG" --require-probe 2>&1) || die "探针条目预检未通过：$STRICT"
printf '%s\n' "$STRICT" | sed 's/^/   /'
CUR_STATE=$(printf '%s\n' "$STRICT" | sed -n 's/^state=//p' | head -1)
CUR_CANON=$(printf '%s\n' "$STRICT" | sed -n 's/^canonical=//p' | head -1)
CUR_SAFE=$(printf '%s\n' "$STRICT" | sed -n 's/^safe=//p' | head -1)
DELETE_OK=$(printf '%s\n' "$STRICT" | sed -n 's/^nvram_delete_bootargs=//p' | head -1)

if [ "$MODE" = "show" ]; then
  say ""
  say "（show 模式不改任何文件）"
  diskutil unmount "$ESP" >/dev/null 2>&1 || diskutil unmount "$MP" >/dev/null 2>&1 || true
  exit 0
fi

if [ "$DELETE_OK" != "yes" ]; then
  die "NVRAM/Delete 里没有 boot-args —— OC 的 Add 只在变量不存在时写入，改了也不会生效；请先在 config.plist 里补上再切状态"
fi

case "$MODE" in
  safe-on)  TARGET_SAFE=on ;;
  safe-off) TARGET_SAFE=off ;;
  *)        TARGET_SAFE="" ;;
esac

if [ -n "$TARGET_SAFE" ] && [ "$CUR_SAFE" = "$TARGET_SAFE" ] && [ "$CUR_CANON" = "yes" ]; then
  say ""
  say "当前 -x（安全模式）状态已是 ${TARGET_SAFE}，无需改动。"
  diskutil unmount "$ESP" >/dev/null 2>&1 || diskutil unmount "$MP" >/dev/null 2>&1 || true
  exit 0
fi

if [ -z "$TARGET_SAFE" ] && [ "$CUR_STATE" = "$MODE" ] && [ "$CUR_CANON" = "yes" ]; then
  say ""
  say "当前已是规范状态 ${MODE}（canonical=yes），无需改动。"
  diskutil unmount "$ESP" >/dev/null 2>&1 || diskutil unmount "$MP" >/dev/null 2>&1 || true
  exit 0
fi
CFG_SHA=$(take_sha "$CFG") || die "读不到 config 哈希"

say ""
say "== 3/5 独占备份 =="
TS=$(date +%Y%m%d-%H%M%S)
BK=""
for i in 1 2 3 4 5; do
  CAND_BK="$MP/igpu-state-$TS-$$-$i"
  if mkdir "$CAND_BK" 2>/dev/null; then BK=$CAND_BK; break; fi
done
[ -n "$BK" ] || die "备份目录创建失败（多次重名，可能有并发脚本在跑）"
printf 'STATE=partial\n' > "$BK/STATE"
{
  echo "TYPE=config-state"
  echo "old_sha=$CFG_SHA"
  echo "mode_from=$CUR_STATE"
  echo "mode_to=$MODE"
} > "$BK/META"
cp "$CFG" "$BK/config.plist" || die "备份 config 失败"
[ "$(take_sha "$BK/config.plist")" = "$CFG_SHA" ] || die "config 备份哈希不符"
printf 'STATE=complete\n' > "$BK/STATE" || die "写完成标记失败"
say "   备份目录 $BK"

say ""
say "== 4/5 生成新配置并校验 =="
STAGE="$MP/EFI/OC/.config.plist.state-$TS-$$"
case "$MODE" in
  safe-on)  SET_ARG="--set-x"; SET_VAL="on" ;;
  safe-off) SET_ARG="--set-x"; SET_VAL="off" ;;
  *)        SET_ARG="--mode";  SET_VAL="$MODE" ;;
esac
OUT=$("$PY" "$SETTER" --config "$CFG" "$SET_ARG" "$SET_VAL" --out "$STAGE" 2>&1) || die "生成新配置失败：$OUT"
printf '%s\n' "$OUT" | sed 's/^/   /'
if printf '%s\n' "$OUT" | grep -q '^unchanged=1'; then
  say "   与规范串一致，无写入；清理暂存后退出"
  rm -rf "$BK" 2>/dev/null || true
  diskutil unmount "$ESP" >/dev/null 2>&1 || diskutil unmount "$MP" >/dev/null 2>&1 || true
  exit 0
fi
[ -f "$STAGE" ] || die "未生成暂存配置"
NEW_CHECK=$("$PY" "$SETTER" --config "$STAGE" --check 2>&1)
NEW_STATE=$(printf '%s\n' "$NEW_CHECK" | sed -n 's/^state=//p' | head -1)
NEW_SAFE=$(printf '%s\n' "$NEW_CHECK" | sed -n 's/^safe=//p' | head -1)
if [ -n "$TARGET_SAFE" ]; then
  [ "$NEW_SAFE" = "$TARGET_SAFE" ] || die "暂存配置 -x 状态不是 ${TARGET_SAFE}（实际 ${NEW_SAFE}）"
else
  [ "$NEW_STATE" = "$MODE" ] || die "暂存配置状态不是 ${MODE}（实际 ${NEW_STATE}）"
fi
say "   暂存配置状态校验通过"

say ""
say "== 5/5 rename 替换 + 复核 =="
WORK="$MP/EFI/OC/.igpu-state-work-$$"
mkdir "$WORK" 2>/dev/null || mkdir -p "$WORK" || die "无法创建工作目录"
RESTORE="$WORK/RESTORE-config.plist"
CFG_SWAPPED=0
COMMITTED=0
restore() {
  [ "$COMMITTED" -eq 1 ] && { rm -rf "$WORK" 2>/dev/null; return 0; }
  if [ "$CFG_SWAPPED" -eq 1 ]; then
    if cp "$BK/config.plist" "$RESTORE" 2>/dev/null \
       && [ "$(take_sha "$RESTORE")" = "$CFG_SHA" ] \
       && mv "$RESTORE" "$CFG" 2>/dev/null \
       && [ "$(take_sha "$CFG")" = "$CFG_SHA" ]; then
      printf '[恢复] config.plist 已还原并通过哈希复核（%s）\n' "$CFG_SHA" >&2
    else
      printf '[恢复失败] 活动配置未通过复核！手工恢复步骤：\n' >&2
      printf '  1) cp "%s/config.plist" "%s/RESTORE.plist"\n' "$BK" "$WORK" >&2
      printf '  2) shasum -a 256 "%s/RESTORE.plist"   # 应为 %s\n' "$WORK" "$CFG_SHA" >&2
      printf '  3) mv "%s/RESTORE.plist" "%s"\n' "$WORK" "$CFG" >&2
      printf '  4) sudo shutdown -r now\n' >&2
      printf '现场材料保留在：%s\n' "$WORK" >&2
      return 1
    fi
  fi
  rm -rf "$WORK" "$STAGE" 2>/dev/null
}
trap 'restore' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

CFG_SWAPPED=1
mv "$STAGE" "$CFG" || die "替换 config.plist 失败（退出时自动还原）"
FINAL=$("$PY" "$SETTER" --config "$CFG" --check 2>&1) || die "替换后读状态失败：$FINAL"
FINAL_STATE=$(printf '%s\n' "$FINAL" | sed -n 's/^state=//p' | head -1)
FINAL_SAFE=$(printf '%s\n' "$FINAL" | sed -n 's/^safe=//p' | head -1)
if [ -n "$TARGET_SAFE" ]; then
  [ "$FINAL_SAFE" = "$TARGET_SAFE" ] || die "替换后 -x 状态不是 ${TARGET_SAFE}（实际 ${FINAL_SAFE}）"
else
  [ "$FINAL_STATE" = "$MODE" ] || die "替换后状态不是 ${MODE}（实际 ${FINAL_STATE}）"
fi
plutil -lint "$CFG" >/dev/null 2>&1 || die "替换后 config.plist 语法不合法"
NEW_SHA=$(take_sha "$CFG") || die "读不到新 config 哈希"
COMMITTED=1
printf '%s\n' "$FINAL" | sed 's/^/   /'
say "   新 config 哈希 $NEW_SHA"
if [ -n "$TARGET_SAFE" ]; then
  say "   committed=1 target_x=$TARGET_SAFE 备份=$BK"
else
  say "   committed=1 target_mode=$MODE 备份=$BK"
fi

if ! sync; then
  say "⚠ sync 失败：配置已写入（committed=1），请手动执行 sync 后再重启"
  exit 12
fi
if ! diskutil unmount "$ESP" >/dev/null 2>&1 && ! diskutil unmount "$MP" >/dev/null 2>&1; then
  say "⚠ 卸载失败：配置已写入（committed=1），请手动 diskutil unmount $ESP 后再重启"
  exit 12
fi
say "   已卸载 ✓"
say ""
if [ -n "$TARGET_SAFE" ]; then
  say "安全模式已切到 ${TARGET_SAFE}。**必须重启**，重启后核对："
  say "   sysctl -n kern.safeboot           应为 1（safe-on）或 0（safe-off）"
  say "   sysctl -n kern.bootargs            -x 应存在（safe-on）或已消失（safe-off）"
  say "   igpu-driver 状态应保持切换前不变"
  say "   sudo sh onsite/02-collect.sh       采集加载、属性与启动证据"
else
  say "状态已切到 ${MODE}。**必须重启**，重启后核对："
  say "   sysctl -n kern.bootargs            应含 igpu-driver=${MODE}（normal 则不含）"
  say "   sudo sh onsite/02-collect.sh       采集加载与属性证据"
fi
case "$MODE" in
  off)      say "判据 d：kmutil 仍应看到 dev.igpu.probe，但 ioreg 无实例、无属性。" ;;
  verbose)  say "verbose 只影响日志量，属性仍应完整。" ;;
  normal)   say "normal 是等价性对照的基准态。" ;;
  prep)     say "prep 是 Phase-2a 只读取证模式：不发消息、不 terminate、不切 SURF；显示仍由 IONDRV 负责，重启后应保持 normal 画面。" ;;
  safe-on)  say "判据 e：重启后 sysctl kern.safeboot 必须为 1，并记录 kext 是否加载。" ;;
  safe-off) say "已去掉 -x；重启后 kern.safeboot 应回到 0。" ;;
esac