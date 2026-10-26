#!/bin/sh
# 02-collect.sh —— 重启进 Tahoe 后一次性采集探针证据
#
# 用法： sudo sh onsite/02-collect.sh     （非 root 拿不到 OC 日志，material_complete 会是 no）
# 输出： <包根>/results-collect-<时间>/ ，若 U 盘 igpu 目录可写则再镜像一份
#
# 第四轮修订（codex F7/F8）：
#   · 完整性拆两段：material_complete（材料/工具/归档）+ functional_ok（探针功能验收）；
#     evidence_complete 只在两者都为 yes 时才 yes，避免"文件齐全但探针失败"被判通过。
#   · normal/verbose/prep 的功能判据：身份=Yes、GPUAccess 前缀、RegsRead=190、RegsSuspect=0、
#     无 ProbeError、**恰好 1 个实例**；prep 另加 PrepMode=prep / EvidenceComplete=Yes / PrepReadCount>0。
#   · 功能验收只接受本次启动的日志（log_mode=last-boot）；降级 fallback-30m 只算材料齐全。
#   · OC 日志必须含本次注入目标字符串，并与 kern.boottime 做 mtime 关联；否则 oc_log=unverified。
#   · opencore-latest.txt / injection-lines.txt 纳入 CORE_FILES，受 MANIFEST 保护。
#   · off 分支语义保持：已加载 + 0 实例。
#
# 第五轮修订（codex N1/N2/N11）：
#   · N1：结构化核验 ioreg -a plist 里的 IGPUProbeState（存在、恰好 190 键、每值 4 字节 data、
#     RegsTable=190）。这是验收侧的闭环：C++ 里 setProperty 失败在实机上只会表现为
#     "字典缺失/不全"，采集器必须能从 plist 看出来，不能只信 RegsRead 计数。
#   · N2：OC 绑定改用**源文件**的 mtime（复制前取），并要求落在 [boot-300s, boot+60s]；
#     注入行区分成功/失败特征；normal/verbose 必须存在本次启动的探针日志事件（LOG_EVENTS>0）。
#   · N11：prep 按自己的发布协议判定（PrepMode/EvidenceComplete/PrepReadCount/PrepAssert A1–A7），
#     不再要求 prep 不存在的 RegsRead/RegsSuspect。
set -u

BUNDLE=$(cd "$(dirname "$0")/.." && pwd)
TS=$(date +%Y%m%d-%H%M%S)
OUT="$BUNDLE/results-collect-$TS"
mkdir -p "$OUT" || { printf '无法创建 %s\n' "$OUT" >&2; exit 1; }

say() { printf '%s\n' "$1"; }
extract() { sed -n "s/.*\"$1\" = \(.*\)$/\1/p" "$2" 2>/dev/null | head -1; }
unquote() { v=${1:-}; v=${v#\"}; v=${v%\"}; printf '%s' "$v"; }
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true; }
# 结构化核验 plist 需要真实可用的 python3（Dell 上由 CLT 提供）。没有就明确失败，
# 不允许"解析不了当没看见"。
PY=""
for cand in python3 /usr/bin/python3 /usr/local/bin/python3; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import plistlib' >/dev/null 2>&1; then
    PY=$cand
    break
  fi
done

say "== 1/6 系统与启动参数 =="
{
  echo "## date"; date
  echo "## sw_vers"; sw_vers
  echo "## uname"; uname -a
  echo "## kern.bootargs"; sysctl kern.bootargs 2>&1
  echo "## kern.safeboot"; sysctl kern.safeboot 2>&1
  echo "## csrutil"; csrutil status 2>&1
} > "$OUT/system.txt" 2>&1
cat "$OUT/system.txt"

say ""
say "== 2/6 启动证据（先采，供完整性判定）=="
SAFE_RC=1; SAFEBOOT=""
SAFEBOOT=$(sysctl -n kern.safeboot 2>"$OUT/bootenv-safeboot.err"); SAFE_RC=$?
if [ -z "$SAFEBOOT" ]; then SAFEBOOT="unknown"; SAFE_RC=1; fi
BT_RC=1; BOOTTIME=""
BOOTTIME=$(sysctl -n kern.boottime 2>"$OUT/bootenv-boottime.err"); BT_RC=$?
if [ -z "$BOOTTIME" ]; then BOOTTIME="unknown"; BT_RC=1; fi
BOOT_EPOCH=$(printf '%s\n' "$BOOTTIME" | sed -n 's/.*[{ ]sec = \([0-9][0-9]*\).*/\1/p')
[ -n "$BOOT_EPOCH" ] || BOOT_EPOCH=""
say "   kern.safeboot=${SAFEBOOT}（rc=${SAFE_RC}）"
say "   kern.boottime=${BOOTTIME}（rc=${BT_RC}）"

say ""
say "== 3/6 kext 加载状态 =="
kmutil showloaded > "$OUT/kmutil-all.txt" 2>"$OUT/kmutil-all.err"
KM_RC=$?
grep -i 'igpu' "$OUT/kmutil-all.txt" > "$OUT/kmutil-igpu.txt" 2>/dev/null || true
PROBE_LINES=$(grep -c 'dev\.igpu\.probe' "$OUT/kmutil-all.txt" 2>/dev/null || true)
[ -n "$PROBE_LINES" ] || PROBE_LINES=0
PROBE_LOADED=no
[ "$PROBE_LINES" -ge 1 ] && PROBE_LOADED=yes
say "   kmutil rc=${KM_RC}，dev.igpu.probe 命中行数=${PROBE_LINES}（loaded=${PROBE_LOADED}）"
[ -s "$OUT/kmutil-igpu.txt" ] && cat "$OUT/kmutil-igpu.txt"

say ""
say "== 4/6 IORegistry =="
ioreg -r -c IGPUProbe -l -w0 > "$OUT/ioreg-instances.txt" 2>"$OUT/ioreg.err"
IO_RC=$?
INST=$(grep -c '^+-o IGPUProbe' "$OUT/ioreg-instances.txt" 2>/dev/null || true)
[ -n "$INST" ] || INST=0
say "   ioreg rc=${IO_RC}，实例数=$INST"
IDV=$(unquote "$(extract PhysicalIdentityVerified "$OUT/ioreg-instances.txt")")
GPU=$(unquote "$(extract GPUAccess "$OUT/ioreg-instances.txt")")
RRD=$(unquote "$(extract RegsRead "$OUT/ioreg-instances.txt")")
RSP=$(unquote "$(extract RegsSuspect "$OUT/ioreg-instances.txt")")
PERR=$(unquote "$(extract ProbeError "$OUT/ioreg-instances.txt")")
PMODE=$(unquote "$(extract PrepMode "$OUT/ioreg-instances.txt")")
PEC=$(unquote "$(extract EvidenceComplete "$OUT/ioreg-instances.txt")")
PRC=$(unquote "$(extract PrepReadCount "$OUT/ioreg-instances.txt")")
say "   PhysicalIdentityVerified = ${IDV:-（无）}"
say "   GPUAccess                = ${GPU:-（无）}"
say "   RegsRead                 = ${RRD:-（无）}"
say "   RegsSuspect              = ${RSP:-（无）}"
say "   ProbeError               = ${PERR:-（无）}"

ioreg -l -w0 > "$OUT/ioreg-full.txt" 2>"$OUT/ioreg-full.err"
IRF_RC=$?
IRF_BYTES=$(wc -c < "$OUT/ioreg-full.txt" 2>/dev/null | tr -d ' ')
[ -n "$IRF_BYTES" ] || IRF_BYTES=0
say "   ioreg 全量 rc=${IRF_RC}，${IRF_BYTES} B"

ioreg -a -r -c IGPUProbe -l > "$OUT/ioreg-probe.plist" 2>"$OUT/ioreg-probe.err"
IRP_RC=$?
IRP_BYTES=$(wc -c < "$OUT/ioreg-probe.plist" 2>/dev/null | tr -d ' ')
[ -n "$IRP_BYTES" ] || IRP_BYTES=0
say "   ioreg -a（plist）rc=${IRP_RC}，${IRP_BYTES} B"

STATE_DICT="unknown"
STATE_KEYS="unknown"
STATE_REGS_TABLE="unknown"
STATE_VERDICT="unavailable"
STATE_FAIL="state-verify-unavailable"
PREP_VERDICT="unavailable"
PREP_FAIL="prep-verify-unavailable"
PREP_ASSERT_FAIL="unknown"
if [ -z "$PY" ]; then
    say "   ⚠ 没有可用 python3：无法结构化核验 plist（功能验收判失败）"
else
    SV=$("$PY" - "$OUT/ioreg-probe.plist" 2>"$OUT/state-verify.err" <<'PYEOF'
import plistlib, sys

path = sys.argv[1]
try:
    obj = plistlib.loads(open(path, 'rb').read())
except Exception:
    print('entries=0')
    print('state_dict=unreadable')
    print('state_keys=0')
    print('regs_table=unknown')
    print('state_fail=state-dict-unreadable')
    print('state_verdict=fail')
    print('prep_mode=unknown')
    print('prep_evidence=no')
    print('prep_read_count=unknown')
    print('prep_assert_keys=0')
    print('prep_assert_fail=unknown')
    print('prep_fail=prep-unreadable')
    print('prep_verdict=fail')
    sys.exit(0)


def walk(o):
    if isinstance(o, dict):
        yield o
        for v in o.values():
            yield from walk(v)
    elif isinstance(o, list):
        for v in o:
            yield from walk(v)


entries = []
for d in walk(obj):
    if isinstance(d, dict) and (d.get('IOClass') == 'IGPUProbe'
                                or 'IGPUProbeState' in d or 'PrepMode' in d):
        entries.append(d)
print('entries=%d' % len(entries))

normal = [e for e in entries if 'IGPUProbeState' in e]
prep = [e for e in entries if 'PrepMode' in e]

fail = []
if not normal:
    fail.append('state-dict-missing')
elif len(normal) > 1:
    fail.append('state-dict-multi')
else:
    d = normal[0]
    t = d.get('IGPUProbeState')
    if not isinstance(t, dict):
        fail.append('state-dict-not-dict')
    else:
        print('state_keys=%d' % len(t))
        if len(t) != 190:
            fail.append('state-dict-keys=%d' % len(t))
        badtype = [k for k, v in t.items() if not isinstance(v, (bytes, bytearray))]
        badlen = [k for k, v in t.items()
                  if isinstance(v, (bytes, bytearray)) and len(v) != 4]
        if badtype:
            fail.append('state-dict-badtype=%s' % badtype[0])
        if badlen:
            fail.append('state-dict-badlen=%s' % badlen[0])
    rt = d.get('RegsTable')
    print('regs_table=%s' % ('unknown' if rt is None else rt))
    if rt != 190:
        fail.append('regs-table=%s' % ('missing' if rt is None else rt))
print('state_dict=%s' % ('present' if normal else 'missing'))
print('state_fail=%s' % (','.join(fail) if fail else 'none'))
print('state_verdict=%s' % ('fail' if fail else 'ok'))

pfail = []
if not prep:
    pfail.append('prep-mode-missing')
elif len(prep) > 1:
    pfail.append('prep-multi')
else:
    d = prep[0]
    pm = d.get('PrepMode')
    print('prep_mode=%s' % (pm if pm is not None else 'missing'))
    if not (isinstance(pm, str) and pm.startswith('prep')):
        pfail.append('prep-mode')
    ec = d.get('EvidenceComplete')
    ec_ok = (ec is True) or (isinstance(ec, str) and ec in ('Yes', 'true', '1'))
    print('prep_evidence=%s' % ('yes' if ec_ok else 'no'))
    if not ec_ok:
        pfail.append('prep-evidence')
    prc = d.get('PrepReadCount')
    print('prep_read_count=%s' % ('unknown' if prc is None else prc))
    if not isinstance(prc, int) or prc <= 0:
        pfail.append('prep-read-count')
    a = d.get('PrepAssert')
    if not isinstance(a, dict):
        print('prep_assert_keys=0')
        print('prep_assert_fail=missing')
        pfail.append('prep-assert-missing')
    else:
        print('prep_assert_keys=%d' % len(a))
        need = ('A1', 'A2', 'A3', 'A4', 'A5', 'A6', 'A7')
        missing = [k for k in need if k not in a]
        bad = [k for k in need
               if k in a and isinstance(a[k], str) and a[k].startswith('fail')]
        if missing:
            pfail.append('prep-assert-missing=%s' % '/'.join(missing))
        if bad:
            pfail.append('prep-assert-fail=%s' % '/'.join(bad))
        print('prep_assert_fail=%s' % (','.join(bad) if bad else 'none'))
print('prep_fail=%s' % (','.join(pfail) if pfail else 'none'))
print('prep_verdict=%s' % ('fail' if pfail else 'ok'))
PYEOF
) || SV=""
    printf '%s\n' "$SV" > "$OUT/state-verify.txt"
    sv() { printf '%s\n' "$SV" | sed -n "s/^$1=//p" | head -1; }
    STATE_DICT=$(sv state_dict); [ -n "$STATE_DICT" ] || STATE_DICT="unknown"
    STATE_KEYS=$(sv state_keys); [ -n "$STATE_KEYS" ] || STATE_KEYS="unknown"
    STATE_REGS_TABLE=$(sv regs_table); [ -n "$STATE_REGS_TABLE" ] || STATE_REGS_TABLE="unknown"
    STATE_VERDICT=$(sv state_verdict); [ -n "$STATE_VERDICT" ] || STATE_VERDICT="unavailable"
    STATE_FAIL=$(sv state_fail); [ -n "$STATE_FAIL" ] || STATE_FAIL="state-verify-unavailable"
    PREP_VERDICT=$(sv prep_verdict); [ -n "$PREP_VERDICT" ] || PREP_VERDICT="unavailable"
    PREP_FAIL=$(sv prep_fail); [ -n "$PREP_FAIL" ] || PREP_FAIL="prep-verify-unavailable"
    PREP_ASSERT_FAIL=$(sv prep_assert_fail); [ -n "$PREP_ASSERT_FAIL" ] || PREP_ASSERT_FAIL="unknown"
    say "   state: dict=${STATE_DICT} keys=${STATE_KEYS} regs_table=${STATE_REGS_TABLE} verdict=${STATE_VERDICT}"
    say "   state_fail=${STATE_FAIL}"
    say "   prep:  verdict=${PREP_VERDICT} assert_fail=${PREP_ASSERT_FAIL}"
    say "   prep_fail=${PREP_FAIL}"
fi

say ""
say "== 5/6 内核日志与关机原因（绑定本次启动）=="
LOG_MODE="failed"
log show --last boot --style compact --predicate 'eventMessage CONTAINS "IGPUProbe"' > "$OUT/igpu-log.txt" 2>"$OUT/igpu-log.err"
if [ $? -eq 0 ]; then
  LOG_MODE="last-boot"
else
  log show --last 30m --style compact --predicate 'eventMessage CONTAINS "IGPUProbe"' > "$OUT/igpu-log.txt" 2>"$OUT/igpu-log.err"
  if [ $? -eq 0 ]; then LOG_MODE="fallback-30m"; else LOG_MODE="failed"; fi
fi
LOG_EVENTS=$(grep -c 'IGPUProbe' "$OUT/igpu-log.txt" 2>/dev/null || true)
[ -n "$LOG_EVENTS" ] || LOG_EVENTS=0
say "   内核日志 mode=${LOG_MODE}，命中 ${LOG_EVENTS} 行"

SC_STATUS="query-failed"
log show --last boot --style compact --predicate 'eventMessage CONTAINS "shutdown cause"' > "$OUT/shutdown-cause.txt" 2>"$OUT/shutdown-cause.err"
if [ $? -eq 0 ]; then
  SC_STATUS="ok"
else
  log show --last 30m --style compact --predicate 'eventMessage CONTAINS "shutdown cause"' > "$OUT/shutdown-cause.txt" 2>"$OUT/shutdown-cause.err"
  [ $? -eq 0 ] && SC_STATUS="ok" || SC_STATUS="query-failed"
fi
SC_EVENTS=$(grep -c 'shutdown cause' "$OUT/shutdown-cause.txt" 2>/dev/null || true)
[ -n "$SC_EVENTS" ] || SC_EVENTS=0
if [ "$SC_STATUS" = "ok" ] && [ "$SC_EVENTS" -lt 1 ]; then SC_STATUS="no-match"; fi
say "   shutdown cause status=${SC_STATUS}，命中 ${SC_EVENTS} 行"

say ""
say "== 5b/6 OC 日志里的注入结果（关联本次启动）=="
OC_STATUS="not-found"
OC_BOUND="unknown"
OC_SRC=""
OC_SRC_MT="unknown"
CAND=$(diskutil list 2>/dev/null | awk '/OCEFI/ {print $NF}' | sort -u)
N=$(printf '%s\n' "$CAND" | grep -c . 2>/dev/null || true)
if [ "$N" -eq 1 ]; then
  ESP=$CAND
  diskutil mount "$ESP" >/dev/null 2>&1 || true
  MP=$(diskutil info "$ESP" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2}')
  if [ -n "$MP" ] && [ -d "$MP" ]; then
    LOG=$(ls -t "$MP"/opencore-*.txt 2>/dev/null | head -1)
    if [ -n "$LOG" ]; then
      if cp "$LOG" "$OUT/opencore-latest.txt" 2>/dev/null && [ -s "$OUT/opencore-latest.txt" ]; then
        grep -nE 'IGPUProbe|igpu-driver' "$LOG" > "$OUT/injection-lines.txt" 2>/dev/null || true
        # 绑定必须用**源文件**的 mtime：cp 会把副本 mtime 更新成采集时刻，
        # 用副本判断等于"永远刚写过"，旧启动的日志会被误当成本次（N2）。
        OC_SRC=$(basename "$LOG")
        SRC_MT=$(mtime_of "$LOG")
        OC_SRC_MT=${SRC_MT:-unknown}
        if [ -z "$BOOT_EPOCH" ] || [ -z "$SRC_MT" ]; then
          OC_BOUND="unknown"
        elif [ "$SRC_MT" -gt $((BOOT_EPOCH + 60)) ]; then
          OC_BOUND="mismatch"     # 日志写在启动之后 ⇒ 不是本次预启动日志
        elif [ "$SRC_MT" -lt $((BOOT_EPOCH - 900)) ]; then
          OC_BOUND="mismatch"     # 早于启动 15 分钟以上 ⇒ 上一次启动的残留
        else
          OC_BOUND="ok"
        fi
        if [ -s "$OUT/injection-lines.txt" ] \
           && grep -qiE 'Failed to inject|not permitted|Invalid Parameter|injection failed' "$OUT/injection-lines.txt" 2>/dev/null; then
          OC_STATUS="failed"
        elif [ -s "$OUT/injection-lines.txt" ] && [ "$OC_BOUND" = "ok" ] \
             && grep -qE 'IGPUProbe\.kext.*([Ss]uccess)' "$OUT/injection-lines.txt" 2>/dev/null; then
          # 只认"明确的成功注入记录"：OC 实际打印
          #   OC: Prelinked injection IGPUProbe.kext ... - Success
          # 仅提到探针名、boot-arg 或被禁用，都不算注入成功（codex N2）。
          OC_STATUS="ok"
        else
          OC_STATUS="unverified"
        fi
      else
        OC_STATUS="copy-failed"
      fi
      say "   最新日志：$(basename "$LOG")（oc_log=${OC_STATUS}, boot_bound=${OC_BOUND}）"
      if [ -s "$OUT/injection-lines.txt" ]; then cat "$OUT/injection-lines.txt"; else say "   （日志里没有 IGPUProbe/igpu-driver 注入行）"; fi
    else
      say "   ⚠ ESP 上没有 opencore-*.txt"
    fi
    diskutil unmount "$ESP" >/dev/null 2>&1 || true
  else
    OC_STATUS="mount-failed"
    say "   ⚠ ESP 挂载失败（非 root 时常见）—— 需要 OC 日志请用 sudo 重跑"
  fi
else
  say "   ⚠ OCEFI 候选数=${N}，跳过日志收集"
fi

say ""
say "== 6/6 完整性（两段式）、汇总与清单 =="
BOOTARGS=$(sysctl -n kern.bootargs 2>/dev/null || true)
MODE="normal"
case "$BOOTARGS" in
  *igpu-driver=off*) MODE="off" ;;
  *igpu-driver=verbose*) MODE="verbose" ;;
  *igpu-driver=prep*) MODE="prep" ;;
esac

# ---- 第一段：材料完整性（工具/文件/归档都在）----
MATERIAL="yes"
MAT_FAIL=""
mat_no() { MATERIAL="no"; MAT_FAIL="${MAT_FAIL}${MAT_FAIL:+,}$1"; }
[ "$KM_RC" -eq 0 ] || mat_no kmutil
[ "$IO_RC" -eq 0 ] || mat_no ioreg
{ [ "$IRF_RC" -eq 0 ] && [ "$IRF_BYTES" -gt 1000 ]; } || mat_no ioreg-full
{ [ "$IRP_RC" -eq 0 ] && [ "$IRP_BYTES" -gt 100 ]; } || mat_no ioreg-plist
case "$OC_STATUS" in ok|unverified|failed) : ;; *) mat_no oc-log ;; esac
[ -n "$PY" ] || mat_no python
[ "$SAFE_RC" -eq 0 ] || mat_no safeboot
[ "$BT_RC" -eq 0 ] || mat_no boottime
case "$LOG_MODE" in last-boot|fallback-30m) : ;; *) mat_no kernel-log ;; esac
[ "$SC_STATUS" = "ok" ] || mat_no shutdown-cause
[ "$PROBE_LOADED" = "yes" ] || mat_no probe-not-loaded
if [ "$MODE" = "off" ]; then
  [ "$INST" -eq 0 ] || mat_no off-has-instances
else
  [ "$INST" -ge 1 ] || mat_no no-instances
fi

# ---- 第二段：功能验收（探针真的工作）----
FUNC="yes"
FUNC_FAIL=""
func_no() { FUNC="no"; FUNC_FAIL="${FUNC_FAIL}${FUNC_FAIL:+,}$1"; }
if [ "$MODE" = "off" ]; then
  # off 的语义就是"行为 ≡ 无 kext"，功能上无可验收项；材料已要求 0 实例
  :
elif [ "$MODE" = "prep" ]; then
  # N11：prep 在 publishPrep() 后提前返回，不执行 snapshot/publishSummary，
  # 因此**没有** RegsRead/RegsSuspect/IGPUProbeState。按它自己的协议判定。
  [ "$INST" -eq 1 ] || func_no instances-not-1
  [ "$LOG_MODE" = "last-boot" ] || func_no log-not-this-boot
  [ "${LOG_EVENTS:-0}" -gt 0 ] || func_no log-no-events
  [ "$OC_STATUS" = "ok" ] || func_no oc-injection-unverified
  [ "$PREP_VERDICT" = "ok" ] || {
    _oldIFS=$IFS; IFS=,
    for _r in $PREP_FAIL; do [ -n "$_r" ] && func_no "$_r"; done
    IFS=$_oldIFS
  }
else
  [ "$IDV" = "Yes" ] || func_no identity
  case "$GPU" in "none: MMIO reads only"*) : ;; *) func_no gpuaccess ;; esac
  [ "$RRD" = "190" ] || func_no regs-read
  [ "$RSP" = "0" ] || func_no regs-suspect
  [ -z "$PERR" ] || func_no probe-error
  [ "$INST" -eq 1 ] || func_no instances-not-1
  [ "$LOG_MODE" = "last-boot" ] || func_no log-not-this-boot
  [ "${LOG_EVENTS:-0}" -gt 0 ] || func_no log-no-events
  [ "$OC_STATUS" = "ok" ] || func_no oc-injection-unverified
  # N1：字典必须存在且自洽；不能只看 RegsRead=190
  if [ "$STATE_VERDICT" != "ok" ]; then
    _oldIFS=$IFS; IFS=,
    for _r in $STATE_FAIL; do [ -n "$_r" ] && func_no "$_r"; done
    IFS=$_oldIFS
  fi
fi

EV_COMPLETE="yes"
{ [ "$MATERIAL" = "yes" ] && [ "$FUNC" = "yes" ]; } || EV_COMPLETE="no"

MIRROR_STATUS="skipped"
MIRROR=/Volumes/CLONEZILLA/igpu
write_summary() {
  {
    echo "collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "bootargs=$BOOTARGS"
    echo "mode=$MODE"
    echo "safeboot=$SAFEBOOT"
    echo "boottime=$BOOTTIME"
    echo "boot_epoch=${BOOT_EPOCH:-unknown}"
    echo "kmutil_rc=$KM_RC"
    echo "probe_loaded=$PROBE_LOADED"
    echo "ioreg_rc=$IO_RC"
    echo "ioreg_full_rc=$IRF_RC"
    echo "ioreg_full_bytes=$IRF_BYTES"
    echo "ioreg_probe_plist_rc=$IRP_RC"
    echo "ioreg_probe_plist_bytes=$IRP_BYTES"
    echo "log_mode=$LOG_MODE"
    echo "log_events=$LOG_EVENTS"
    echo "shutdown_cause=$SC_STATUS/$SC_EVENTS"
    echo "instances=$INST"
    echo "identity=${IDV:-unknown}"
    echo "gpuaccess=${GPU:-unknown}"
    echo "regs_read=${RRD:-unknown}"
    echo "regs_suspect=${RSP:-unknown}"
    echo "probe_error=${PERR:-none}"
    echo "prep_mode=${PMODE:-none}"
    echo "prep_evidence=${PEC:-none}"
    echo "prep_read_count=${PRC:-none}"
    echo "state_dict=$STATE_DICT"
    echo "state_keys=$STATE_KEYS"
    echo "regs_table=$STATE_REGS_TABLE"
    echo "state_verify=$STATE_VERDICT"
    echo "state_fail=$STATE_FAIL"
    echo "prep_verify=$PREP_VERDICT"
    echo "prep_fail=$PREP_FAIL"
    echo "prep_assert_fail=$PREP_ASSERT_FAIL"
    echo "oc_src=$OC_SRC"
    echo "oc_src_mtime=$OC_SRC_MT"
    echo "oc_log=$OC_STATUS"
    echo "oc_boot_bound=$OC_BOUND"
    echo "material_complete=$MATERIAL"
    echo "material_fail=${MAT_FAIL:-none}"
    echo "functional_ok=$FUNC"
    echo "functional_fail=${FUNC_FAIL:-none}"
    echo "evidence_complete=$EV_COMPLETE"
    echo "mirror=$MIRROR_STATUS"
    echo "manifest=$1"
  } > "$OUT/summary.txt"
}

CORE_FILES="system.txt bootenv-safeboot.err bootenv-boottime.err kmutil-all.txt kmutil-all.err kmutil-igpu.txt ioreg-instances.txt ioreg.err ioreg-full.txt ioreg-full.err ioreg-probe.plist ioreg-probe.err igpu-log.txt igpu-log.err shutdown-cause.txt shutdown-cause.err opencore-latest.txt injection-lines.txt state-verify.txt state-verify.err"
build_manifest() {
  MAN_OK=yes
  TMP="$OUT/.manifest.$$"
  : > "$TMP"
  for f in $CORE_FILES summary.txt; do
    [ -f "$OUT/$f" ] || continue
    H=$(shasum -a 256 "$OUT/$f" 2>/dev/null | awk '{print $1}')
    if [ -z "$H" ]; then MAN_OK=no; continue; fi
    printf '%s  %s\n' "$H" "$f" >> "$TMP"
  done
  [ -s "$TMP" ] || MAN_OK=no
  if [ "$MAN_OK" = "yes" ]; then
    mv "$TMP" "$OUT/MANIFEST.sha256" || MAN_OK=no
  else
    rm -f "$TMP"
  fi
  if [ "$MAN_OK" = "yes" ]; then
    ( cd "$OUT" && shasum -a 256 -c MANIFEST.sha256 >/dev/null 2>&1 ) || MAN_OK=no
  fi
  for f in system.txt kmutil-all.txt ioreg-instances.txt ioreg-full.txt ioreg-probe.plist summary.txt; do
    [ -f "$OUT/$f" ] || MAN_OK=no
    grep -q "  $f$" "$OUT/MANIFEST.sha256" 2>/dev/null || MAN_OK=no
  done
}

write_summary pending "$EV_COMPLETE"
build_manifest
if [ "$MAN_OK" != "yes" ]; then
  EV_COMPLETE="no"
  write_summary failed "$EV_COMPLETE"
  build_manifest
else
  write_summary ok "$EV_COMPLETE"
  build_manifest
fi

cat "$OUT/summary.txt"
[ "$MIRROR_STATUS" = "ok" ] && say "   已镜像到 $MIRROR/results-collect-${TS}（副本未做二次校验）"
[ "$MIRROR_STATUS" = "failed" ] && say "   ⚠ 镜像到 U 盘失败（本地清单仍有效）"

# 镜像放在最后：summary 与 MANIFEST 都写完之后再复制，避免 U 盘副本缺文件
if [ -d "$MIRROR" ] && [ -w "$MIRROR" ]; then
  if mkdir -p "$MIRROR/results-collect-$TS" 2>/dev/null && cp -R "$OUT"/. "$MIRROR/results-collect-$TS"/ 2>/dev/null; then
    MIRROR_STATUS="ok"
  else
    MIRROR_STATUS="failed"
  fi
fi

if [ "$MIRROR_STATUS" != "skipped" ]; then
  write_summary ok "$EV_COMPLETE"
  build_manifest
  if [ "$MIRROR_STATUS" = "ok" ]; then
    cp "$OUT/summary.txt" "$OUT/MANIFEST.sha256" "$MIRROR/results-collect-$TS/" 2>/dev/null || true
  fi
fi

say ""
say "采集完成：$OUT"
if [ "$EV_COMPLETE" != "yes" ]; then
  [ "$MATERIAL" = "no" ] && say "⚠ 材料不完整：${MAT_FAIL}"
  [ "$FUNC" = "no" ] && say "⚠ 功能验收未过：${FUNC_FAIL}"
  say "⚠ evidence_complete=no —— 把 summary.txt 与各 *.err 一起带回"
  exit 1
fi
exit 0