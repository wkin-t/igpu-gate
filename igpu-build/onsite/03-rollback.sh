#!/bin/sh
# 03-rollback.sh —— 从 ESP 的完整备份还原 IGPUProbe.kext（可选还原基线 config）
#
# 用法（三种模式，互斥）：
#   sudo sh onsite/03-rollback.sh
#       只回滚 kext（不动 config / boot-args）。用于"回到部署前 kext 状态"但保留现有配置。
#   sudo sh onsite/03-rollback.sh --from-backup /Volumes/OCEFI/igpu-backup-YYYYMMDD-HHMMSS-$$
#       回到**该次部署之前**：恢复该备份 META 里的 config_before（并核对哈希），再按
#       EXISTED_KEXT 恢复/移除 kext。这是"完整撤销一次部署"。
#   sudo sh onsite/03-rollback.sh --config [基线文件]
#       回到**已知基线 config**（哈希必须 = 991c9de0…）；不带路径时在 ESP 上找唯一的
#       config-before-probe-*.plist。用于放弃探针、回到 Phase-1 之前。
#
# 事务模型（第三轮 codex 评审后修订）：
#   · 只认 `STATE=complete`（解析 `STATE=` 后的值，与 deploy 写入格式一致）；
#   · 所有材料在动现网之前验完；回滚前 config 的副本保存在**目标 ESP**上并要求哈希一致，
#     `--from` 指向只读卷也不影响恢复能力；
#   · 恢复意图位（MOVED/INSTALLED/CFG_SWAPPED）一律在 mv 之前置位，信号窗口不会漏恢复；
#   · 记录"进入本次回滚时是否存在当前 kext"，避免把备份的 EXISTED_KEXT 当成现场事实；
#   · 全部复核（含 plutil -lint）通过后才 COMMITTED=1，成功路径显式 exit 0。
set -u

EXPECT_VOL="OCEFI"
EXPECT_OFF="1048576"
# 同 01-deploy：换过 SMBIOS 身份后基线哈希会变，用 IGPU_BASELINE_SHA 覆盖
CFG_BASELINE="${IGPU_BASELINE_SHA:-991c9de090924d1bd68b2a1db4e104c91337286aae158c63fae98e301fae16e3}"

MODE=kext-only
FROM=""
BASE_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kext-only) MODE=kext-only ;;
    --from-backup)
      shift
      [ $# -ge 1 ] || { printf '%s\n' '--from-backup 需要备份目录' >&2; exit 2; }
      FROM=$1; MODE=deploy-before ;;
    --from)
      # 兼容旧名：语义等同 --from-backup
      shift
      [ $# -ge 1 ] || { printf '%s\n' '--from 需要备份目录' >&2; exit 2; }
      FROM=$1; MODE=deploy-before ;;
    --config)
      MODE=baseline
      if [ $# -ge 2 ]; then
        case "$2" in
          -*) : ;;
          *) BASE_ARG=$2; shift ;;
        esac
      fi ;;
    -h|--help)
      printf '%s\n' '用法：sudo sh onsite/03-rollback.sh [--kext-only | --from-backup DIR | --config [基线文件]]'
      printf '%s\n' '  --kext-only（默认）  只回滚/移除 kext，不动 config 与 boot-args'
      printf '%s\n' '  --from-backup DIR    回到该次部署前：恢复 META 的 config_before（核哈希）+ kext'
      printf '%s\n' '  --config [FILE]      回到已知基线 config（哈希必须是 991c9de0…）'
      exit 0 ;;
    *) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done


say() { printf '%s\n' "$1"; }
die() { printf '\n[中止] %s\n' "$1" >&2; exit "${2:-1}"; }
take_sha() { _o=$(shasum -a 256 "$1" 2>/dev/null) || return 1; printf '%s' "$_o" | awk '{print $1}'; }
state_of() { sed -n 's/^STATE=//p' "$1/STATE" 2>/dev/null | head -1; }

case "$MODE" in
  kext-only)
    say "模式：只回滚 kext（不改 config / boot-args）。"
    say "      要完整撤销一次部署用 --from-backup <igpu-backup-*>；要回到已知基线用 --config。"
    ;;
  deploy-before)
    say "模式：回到指定备份的部署前状态（config_before + kext）"
    ;;
  baseline)
    say "模式：回到已知基线 config（991c9de0… 哈希校验）+ kext"
    ;;
  *) die "内部错误：未知模式 ${MODE}" 2 ;;
esac
[ "$(id -u)" -eq 0 ] || die "需要写 ESP：sudo sh onsite/03-rollback.sh"

say "== 1/6 定位 ESP =="
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
say "== 2/6 挂载并挑选完整备份 =="
diskutil mount "$ESP" >/dev/null 2>&1 || true
MP=$(diskutil info "$ESP" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2}')
[ -n "$MP" ] && [ -d "$MP" ] || die "挂载失败：拿不到挂载点"
RO=$(diskutil info "$ESP" 2>/dev/null | awk -F': *' '/Read-Only Volume/ {print $2}')
[ "$RO" = "No" ] || die "ESP 卷不可写（Read-Only Volume=${RO:-未知}），无法回滚"
AVAIL=$(df -k "$MP" 2>/dev/null | awk 'NR>1 && NF>=4 {v=$4} END {print v}')
case "${AVAIL:-}" in ''|*[!0-9]*) die "读不到 ESP 剩余空间（df -k $MP 失败）" ;; esac
[ "$AVAIL" -ge 10240 ] || die "ESP 剩余空间不足：${AVAIL} KB（要求 ≥ 10 MB）"
[ -f "$MP/EFI/OC/config.plist" ] || die "ESP 上没有 EFI/OC/config.plist"
OLD_BK=$(ls -d "$MP"/igpu-backup-* 2>/dev/null | wc -l | tr -d ' ')
OLD_ST=$(ls -d "$MP"/igpu-state-* 2>/dev/null | wc -l | tr -d ' ')
say "   ESP 可写 ✓ 剩余 ${AVAIL} KB ✓ 旧备份：backup ${OLD_BK} / state ${OLD_ST}（只报告）"
if [ -n "$FROM" ]; then
  BK=$FROM
else
  BK=""
  for d in "$MP"/igpu-backup-*; do
    [ -d "$d" ] || continue
    [ "$(state_of "$d")" = "complete" ] || continue
    BK=$d
  done
fi
[ -n "$BK" ] && [ -d "$BK" ] || die "没有可用的完整备份（STATE=complete）"
[ "$(state_of "$BK")" = "complete" ] || die "备份不完整（$(state_of "$BK")），拒绝回滚"
say "   备份 $BK"

say ""
say "== 3/6 先验完所有材料（此时尚未改动现网）=="
DST="$MP/EFI/OC/Kexts/IGPUProbe.kext"
CFG="$MP/EFI/OC/config.plist"
EXISTED=$(sed -n 's/^EXISTED_KEXT=//p' "$BK/META" 2>/dev/null | head -1)
OB=""; OP=""
case "$EXISTED" in
  yes)
    [ -d "$BK/IGPUProbe.kext" ] || die "标记 EXISTED_KEXT=yes 但备份里没有 IGPUProbe.kext"
    OB=$(sed -n 's/^old_binary=//p' "$BK/SHA256.old" 2>/dev/null | head -1)
    OP=$(sed -n 's/^old_plist=//p'  "$BK/SHA256.old" 2>/dev/null | head -1)
    [ -n "$OB" ] && [ -n "$OP" ] || die "备份缺 SHA256.old 或为空"
    [ "$(take_sha "$BK/IGPUProbe.kext/Contents/MacOS/IGPUProbe")" = "$OB" ] || die "备份二进制哈希与记录不符"
    [ "$(take_sha "$BK/IGPUProbe.kext/Contents/Info.plist")" = "$OP" ] || die "备份 plist 哈希与记录不符"
    say "   备份二进制 $OB ✓  plist $OP ✓"
    ;;
  no) say "   备份标记 EXISTED_KEXT=no → 回滚将移除当前 kext" ;;
  *) die "备份缺 META/EXISTED_KEXT，拒绝猜测" ;;
esac

CFG_TARGET=""
CFG_TARGET_SHA=""
case "$MODE" in
  deploy-before)
    CFGB=$(sed -n 's/^config_before=//p' "$BK/META" 2>/dev/null | head -1)
    CFGB_SHA=$(sed -n 's/^config_before_sha=//p' "$BK/META" 2>/dev/null | head -1)
    [ -n "$CFGB_SHA" ] || die "备份 META 缺 config_before_sha，拒绝猜测"
    if [ -n "$CFGB" ] && [ -f "$CFGB" ]; then
      :
    elif [ -f "$BK/config.plist" ]; then
      CFGB="$BK/config.plist"
    else
      die "找不到该备份的 config_before（META 指向 ${CFGB:-空}，备份内也没有 config.plist）"
    fi
    CFG_TARGET=$CFGB
    CFG_TARGET_SHA=$(take_sha "$CFG_TARGET") || die "读不到 config_before 哈希"
    [ "$CFG_TARGET_SHA" = "$CFGB_SHA" ] || die "config_before 哈希与 META 不符（实际 ${CFG_TARGET_SHA}，记录 ${CFGB_SHA}），拒绝覆盖"
    plutil -lint "$CFG_TARGET" >/dev/null 2>&1 || die "config_before 语法不合法"
    say "   回到部署前 config：$CFG_TARGET_SHA ✓"
    ;;
  baseline)
    if [ -n "$BASE_ARG" ]; then
      BASE=$BASE_ARG
    else
      BASE=""
      for _b in "$MP"/EFI/OC/config-before-probe-*.plist; do
        [ -f "$_b" ] || continue
        [ -z "$BASE" ] || die "ESP 上有多个基线文件，请用 --config 显式指定一个"
        BASE=$_b
      done
    fi
    [ -n "$BASE" ] && [ -f "$BASE" ] || die "找不到基线文件（用 --config 指定）"
    CFG_TARGET=$BASE
    CFG_TARGET_SHA=$(take_sha "$CFG_TARGET") || die "读不到基线哈希"
    [ "$CFG_TARGET_SHA" = "$CFG_BASELINE" ] || die "基线哈希不是 ${CFG_BASELINE}（实际 ${CFG_TARGET_SHA}），拒绝覆盖"
    say "   基线 config $CFG_TARGET_SHA ✓"
    ;;
esac

TS=$(date +%Y%m%d-%H%M%S)
WORK="$MP/EFI/OC/.igpu-rollback-$TS-$$"
mkdir -p "$WORK" || die "无法创建工作目录 $WORK"
HELD="$WORK/IGPUProbe.kext.held"
NEWK="$WORK/IGPUProbe.kext.restore"
NEWC="$WORK/config.plist.new"
CFG_PREV="$WORK/config.plist.prev"

# 进入本次回滚时现场是否存在 kext —— 只认现场，不看备份标记
ENTRY_HAD_DST=0
[ -d "$DST" ] && ENTRY_HAD_DST=1
CFG_ENTRY_SHA=""
if [ "$MODE" != "kext-only" ]; then
  CFG_ENTRY_SHA=$(take_sha "$CFG") || die "读不到当前 config 哈希"
  cp "$CFG" "$CFG_PREV" || die "保存回滚前 config 到 $CFG_PREV 失败（拒绝继续）"
  [ "$(take_sha "$CFG_PREV")" = "$CFG_ENTRY_SHA" ] || die "回滚前 config 副本哈希不一致（拒绝继续）"
  say "   已保存回滚前 config: $CFG_ENTRY_SHA ✓"
fi

MOVED=0
INSTALLED=0
CFG_SWAPPED=0
COMMITTED=0
restore() {
  [ "$COMMITTED" -eq 1 ] && { rm -rf "$WORK" 2>/dev/null; return 0; }
  if [ "$CFG_SWAPPED" -eq 1 ] && [ -f "$CFG_PREV" ]; then
    cp "$CFG_PREV" "$CFG" 2>/dev/null \
      && printf '[恢复] config.plist 已还原为回滚前内容\n' >&2 \
      || printf '[恢复失败] 请手工用 %s 覆盖 %s\n' "$CFG_PREV" "$CFG" >&2
  fi
  if [ "$MOVED" -eq 1 ] && [ -d "$HELD" ]; then
    rm -rf "$DST" 2>/dev/null
    mv "$HELD" "$DST" 2>/dev/null \
      && printf '[恢复] 已撤销本次回滚，kext 回到回滚前状态\n' >&2 \
      || printf '[恢复失败] 回滚前的 kext 在 %s，请手工 mv 回 %s\n' "$HELD" "$DST" >&2
  elif [ "$INSTALLED" -eq 1 ] && [ "$ENTRY_HAD_DST" -eq 0 ] && [ -d "$DST" ]; then
    rm -rf "$DST" 2>/dev/null && printf '[恢复] 已移除本次回滚装入的 kext（回滚前本无 kext）\n' >&2
  fi
  rm -rf "$NEWK" "$NEWC" 2>/dev/null
}
trap 'restore' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

say ""
say "== 4/6 暂存恢复材料（仍不改动现网）=="
if [ "$EXISTED" = "yes" ]; then
  /usr/bin/ditto --norsrc --noextattr --noqtn "$BK/IGPUProbe.kext" "$NEWK" 2>/dev/null \
    || { rm -rf "$NEWK"; /bin/cp -R "$BK/IGPUProbe.kext" "$NEWK"; } || die "复制备份 kext 失败"
  [ "$(take_sha "$NEWK/Contents/MacOS/IGPUProbe")" = "$OB" ] || die "暂存 kext 二进制哈希不符"
  [ "$(take_sha "$NEWK/Contents/Info.plist")" = "$OP" ] || die "暂存 kext plist 哈希不符"
  DC=ok
  if ! dot_clean -m "$NEWK" >/dev/null 2>"$WORK/dot_clean.err"; then
    if ! /usr/sbin/dot_clean -m "$NEWK" >/dev/null 2>>"$WORK/dot_clean.err"; then
      DC=warn
      say "   ⚠ dot_clean 失败（已记入 $WORK/dot_clean.err，WARN）"
    fi
  fi
  printf 'dot_clean=%s\n' "$DC" >> "$WORK/DCINFO" 2>/dev/null || true
  say "   暂存 kext ✓"
fi
if [ "$MODE" != "kext-only" ]; then
  cp "$CFG_TARGET" "$NEWC" || die "暂存目标 config 失败"
  [ "$(take_sha "$NEWC")" = "$CFG_TARGET_SHA" ] || die "暂存 config 哈希不符"
  say "   暂存 config ✓"
fi

say ""
say "== 5/6 rename 就位 =="
if [ -d "$DST" ]; then
  MOVED=1
  mv "$DST" "$HELD" || { MOVED=0; die "移开当前 kext 失败（原样未动）"; }
fi
if [ "$EXISTED" = "yes" ]; then
  INSTALLED=1
  mv "$NEWK" "$DST" || die "安装备份 kext 失败（退出时自动撤销）"
  say "   kext 已还原"
else
  say "   当前 kext 已移出"
fi
if [ "$MODE" != "kext-only" ]; then
  CFG_SWAPPED=1
  mv "$NEWC" "$CFG" || die "覆盖 config.plist 失败（退出时自动撤销）"
  say "   config.plist 已覆盖"
fi

say ""
say "== 6/6 复核通过才提交 =="
if [ "$EXISTED" = "yes" ]; then
  [ "$(take_sha "$DST/Contents/MacOS/IGPUProbe")" = "$OB" ] || die "还原后二进制哈希不符"
  [ "$(take_sha "$DST/Contents/Info.plist")" = "$OP" ] || die "还原后 plist 哈希不符"
  plutil -lint "$DST/Contents/Info.plist" >/dev/null 2>&1 || die "还原后 plist 语法不合法"
else
  [ -d "$DST" ] && die "本应移除 kext，但目录仍存在"
fi
if [ "$MODE" != "kext-only" ]; then
  [ "$(take_sha "$CFG")" = "$CFG_TARGET_SHA" ] || die "还原后 config 哈希不符"
  plutil -lint "$CFG" >/dev/null 2>&1 || die "还原后 config 语法不合法"
fi
COMMITTED=1
say "   复核通过 ✓"
[ "$MOVED" -eq 1 ] && say "   回滚前的 kext 副本：${HELD}（保留在 ESP 上）"

sync || die "sync 失败（文件已就位，请手动 sync 后再重启）"
if ! diskutil unmount "$ESP" >/dev/null 2>&1 && ! diskutil unmount "$MP" >/dev/null 2>&1; then
  die "卸载失败（文件已就位）—— 请手动：diskutil unmount $ESP"
fi
say "   已卸载 ✓"
say ""
say "回滚完成。"
exit 0