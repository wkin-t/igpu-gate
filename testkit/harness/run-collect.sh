#!/bin/bash
set +u
H="$(cd "$(dirname "$0")" && pwd)"
# 让裸 `python` 解析到 testkit/bin/python（shim：exec python3）。
# macOS 26 没有 `python` 命令；本地 Windows 能跑是因为外部 PATH 里恰好有 shim——
# 那是环境巧合，不能当依赖（CI 上会直接失败）。
PATH="$H/../bin:$PATH"; export PATH
export PATH="$H/stubs:$PATH"
sh "$H/sync-bundle.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s  —— %s\n' "$1" "$2"; }

export FAKE_MP="$H/fake-esp"
mkdir -p "$FAKE_MP"
OC_LOG="$FAKE_MP/opencore-2026-10-20-055000.txt"
printf '773:107:604 00:182 OC: Prelinked injection IGPUProbe.kext (IGPUProbe Phase-1 probe) - Success\n774:107:786 00:182 OC: Prelinked injection IGPUProbe.kext v0.1.0\n' > "$OC_LOG"

reset_env() {
  export FAKE_PROBE=on FAKE_EXTRA_ARGS="" FAKE_SAFEBOOT=0 FAKE_LOG_FAIL=0 FAKE_LOG_BOOT_FAIL=0
  export FAKE_KM_PROBE=yes FAKE_INSTANCES=1 FAKE_IDV=Yes FAKE_GPUACCESS="none: MMIO reads only"
  export FAKE_REGS_READ=190 FAKE_REGS_SUSPECT=0 FAKE_PROBE_ERROR=""
  export FAKE_PREP_PROPS=0 FAKE_PREP_MODE="prep: read-only evidence" FAKE_PREP_EVIDENCE=Yes FAKE_PREP_READS=24
  export FAKE_STATE=present FAKE_STATE_KEYS=190 FAKE_STATE_LEN=4 FAKE_STATE_TYPE=data FAKE_REGS_TABLE=190
  export FAKE_PREP_ASSERT=pass FAKE_LOG_EVENTS=2 OC_MT_OFFSET=-60
  export FAKE_BOOTTIME="{ sec = 1760939400, usec = 0 } Mon Oct 20 05:50:00 2026"
}

set_mtime() {
  python -c "import os,sys; os.utime(sys.argv[1], (int(sys.argv[2]), int(sys.argv[2])))" "$1" "$2" 2>/dev/null \
    || touch -d "@$2" "$1" 2>/dev/null || true
}

run_case() {
  name="$1"
  set_mtime "$OC_LOG" $((1760939400 + ${OC_MT_OFFSET:--60}))
  rm -rf "$H/bundle"/results-collect-* 2>/dev/null
  OUT=$( sh "$H/bundle/onsite/02-collect.sh" 2>&1 ); RC=$?
  D=$(ls -d "$H/bundle"/results-collect-* 2>/dev/null | head -1)
  echo "$OUT" > "$H/last-collect-$name.log"
}

field() { grep "^$2=" "$1" 2>/dev/null | head -1 | sed "s/^$2=//"; }

reset_env
run_case normal
[ $RC -eq 0 ] && ok "C1 collect 返回 0" || bad "C1 collect 返回 0" "rc=$RC :: $(tail -2 "$H/last-collect-normal.log" | tr '\n' ' ')"
[ -s "$D/summary.txt" ] && ok "C1 生成 summary" || bad "C1 生成 summary" "无"
[ "$(field "$D/summary.txt" material_complete)" = "yes" ] && ok "C1 material_complete=yes" || bad "C1 material" "$(grep material_complete "$D/summary.txt")"
[ "$(field "$D/summary.txt" functional_ok)" = "yes" ] && ok "C1 functional_ok=yes" || bad "C1 functional" "$(grep functional_ok "$D/summary.txt")"
grep -q 'evidence_complete=yes' "$D/summary.txt" && ok "C1 evidence_complete=yes" || bad "C1 evidence_complete" "$(grep evidence_complete "$D/summary.txt")"
grep -q 'instances=1' "$D/summary.txt" && ok "C1 instances=1" || bad "C1 instances" "$(grep '^instances=' "$D/summary.txt")"
[ -s "$D/ioreg-full.txt" ] && ok "C1 全量 ioreg 落盘" || bad "C1 全量 ioreg" "缺失"
[ -s "$D/ioreg-probe.plist" ] && ok "C1 ioreg -a plist 落盘" || bad "C1 plist" "缺失"
[ -s "$D/MANIFEST.sha256" ] && ( cd "$D" && shasum -a 256 -c MANIFEST.sha256 >/dev/null 2>&1 ) && ok "C1 MANIFEST 自检通过" || bad "C1 MANIFEST" "缺失或校验失败"
[ "$(field "$D/summary.txt" state_verify)" = "ok" ] && ok "C1 state_verify=ok" || bad "C1 state_verify" "$(grep '^state_' "$D/summary.txt" | tr '\n' ' ')"
[ "$(field "$D/summary.txt" state_keys)" = "190" ] && ok "C1 state_keys=190" || bad "C1 state_keys" "$(grep '^state_keys=' "$D/summary.txt")"
[ "$(field "$D/summary.txt" oc_boot_bound)" = "ok" ] && ok "C1 oc_boot_bound=ok" || bad "C1 oc_bound" "$(grep '^oc_boot_bound=' "$D/summary.txt")"
[ "$(field "$D/summary.txt" log_events)" -gt 0 ] && ok "C1 log_events>0" || bad "C1 log_events" "$(grep '^log_events=' "$D/summary.txt")"
grep -q 'safeboot=0' "$D/summary.txt" && ok "C1 记录 safeboot" || bad "C1 safeboot" "缺失"
[ -s "$D/shutdown-cause.txt" ] && grep -q 'shutdown_cause=ok/' "$D/summary.txt" && ok "C1 记录关机原因" || bad "C1 shutdown cause" "缺失"
grep -q 'Prelinked injection IGPUProbe' "$D/injection-lines.txt" && ok "C1 OC 注入行" || bad "C1 OC 注入行" "缺失"
grep -q '  opencore-latest.txt$' "$D/MANIFEST.sha256" && grep -q '  injection-lines.txt$' "$D/MANIFEST.sha256" \
  && ok "C1 OC 证据进 MANIFEST" || bad "C1 OC 证据清单" "缺 opencore/injection 行"

# C2 off 态：无实例
reset_env; export FAKE_PROBE=off FAKE_EXTRA_ARGS=" igpu-driver=off"
run_case off
[ $RC -eq 0 ] && ok "C2 off 态返回 0" || bad "C2 off 态返回 0" "rc=$RC"
grep -q 'mode=off' "$D/summary.txt" && ok "C2 mode=off" || bad "C2 mode" "$(grep '^mode=' "$D/summary.txt")"
grep -q 'instances=0' "$D/summary.txt" && ok "C2 instances=0" || bad "C2 instances" "$(grep '^instances=' "$D/summary.txt")"
[ "$(field "$D/summary.txt" functional_ok)" = "yes" ] && ok "C2 off functional_ok=yes" || bad "C2 off functional" "$(grep functional_ok "$D/summary.txt")"
grep -q 'evidence_complete=yes' "$D/summary.txt" && ok "C2 off 证据完整" || bad "C2 off 证据" "$(grep evidence_complete "$D/summary.txt")"

# C3 安全模式
reset_env; export FAKE_SAFEBOOT=1 FAKE_EXTRA_ARGS=" -x"
run_case safe
grep -q 'safeboot=1' "$D/summary.txt" && ok "C3 记录 safeboot=1" || bad "C3 safeboot" "$(grep safeboot "$D/summary.txt")"

# C4 内核日志整体失败
reset_env; export FAKE_LOG_FAIL=1
run_case logfail
[ $RC -ne 0 ] && ok "C4 log 失败 → 不完整并返回非零" || bad "C4 log 失败未降级" "rc=0"
[ "$(field "$D/summary.txt" material_complete)" = "no" ] && ok "C4 material=no" || bad "C4 material" "$(grep material_complete "$D/summary.txt")"
grep -q 'evidence_complete=no' "$D/summary.txt" && ok "C4 log 失败不报完整" || bad "C4 不报完整" "$(grep evidence_complete "$D/summary.txt")"

# C7 prep 态：属性齐全
reset_env; export FAKE_EXTRA_ARGS=" igpu-driver=prep" FAKE_PREP_PROPS=1
run_case prep
grep -q 'mode=prep' "$D/summary.txt" && ok "C7 prep 模式识别" || bad "C7 prep 模式" "$(grep '^mode=' "$D/summary.txt")"
[ "$(field "$D/summary.txt" functional_ok)" = "yes" ] && ok "C7 prep functional_ok=yes" || bad "C7 prep functional" "$(grep functional_ok "$D/summary.txt")"
grep -q 'evidence_complete=yes' "$D/summary.txt" && ok "C7 prep 证据完整" || bad "C7 prep 完整性" "$(grep evidence_complete "$D/summary.txt")"
[ $RC -eq 0 ] && ok "C7 prep 返回 0" || bad "C7 prep 返回 0" "rc=$RC"
[ "$(field "$D/summary.txt" prep_verify)" = "ok" ] && ok "C7 prep_verify=ok" || bad "C7 prep_verify" "$(grep '^prep_verify=' "$D/summary.txt")"
[ "$(field "$D/summary.txt" state_dict)" = "missing" ] && ok "C7 prep 无 IGPUProbeState（协议差异）" || bad "C7 prep state_dict" "$(grep '^state_dict=' "$D/summary.txt")"

# C8 身份验证失败
reset_env; export FAKE_IDV=No
run_case identity
[ "$(field "$D/summary.txt" functional_ok)" = "no" ] && ok "C8 identity=No → functional=no" || bad "C8 identity" "$(grep functional_ok "$D/summary.txt")"
grep -q 'identity' "$D/summary.txt" && grep -q 'functional_fail=' "$D/summary.txt" && ok "C8 失败项可读" || bad "C8 失败项" "$(grep functional_fail "$D/summary.txt")"
[ $RC -ne 0 ] && ok "C8 返回非零" || bad "C8 返回非零" "rc=0"

# C9 读数不足 190
reset_env; export FAKE_REGS_READ=189
run_case regs189
[ "$(field "$D/summary.txt" functional_ok)" = "no" ] && ok "C9 RegsRead=189 → functional=no" || bad "C9 regs-read" "$(grep functional_ok "$D/summary.txt")"

# C10 可疑读数非零
reset_env; export FAKE_REGS_SUSPECT=1
run_case suspect
[ "$(field "$D/summary.txt" functional_ok)" = "no" ] && ok "C10 RegsSuspect=1 → functional=no" || bad "C10 suspect" "$(grep functional_ok "$D/summary.txt")"

# C11 ProbeError 出现
reset_env; export FAKE_PROBE_ERROR="BAR0 map failed"
run_case perr
[ "$(field "$D/summary.txt" functional_ok)" = "no" ] && ok "C11 ProbeError → functional=no" || bad "C11 probe-error" "$(grep functional_ok "$D/summary.txt")"
grep -q 'probe-error' "$D/summary.txt" && ok "C11 失败项含 probe-error" || bad "C11 失败项" "$(grep functional_fail "$D/summary.txt")"

# C12 实例数 2
reset_env; export FAKE_INSTANCES=2
run_case two
[ "$(field "$D/summary.txt" material_complete)" = "yes" ] && ok "C12 实例 2：材料仍齐全" || bad "C12 material" "$(grep material_complete "$D/summary.txt")"
[ "$(field "$D/summary.txt" functional_ok)" = "no" ] && ok "C12 实例 2 → functional=no" || bad "C12 functional" "$(grep functional_ok "$D/summary.txt")"

# C13 日志只能降级到 30m
reset_env; export FAKE_LOG_BOOT_FAIL=1
run_case fallback
[ "$(field "$D/summary.txt" log_mode)" = "fallback-30m" ] && ok "C13 log_mode=fallback-30m" || bad "C13 log_mode" "$(grep log_mode "$D/summary.txt")"
[ "$(field "$D/summary.txt" material_complete)" = "yes" ] && ok "C13 降级仍算材料齐全" || bad "C13 material" "$(grep material_complete "$D/summary.txt")"
[ "$(field "$D/summary.txt" functional_ok)" = "no" ] && ok "C13 降级不算功能验收" || bad "C13 functional" "$(grep functional_ok "$D/summary.txt")"
[ $RC -ne 0 ] && ok "C13 返回非零" || bad "C13 返回非零" "rc=0"

# C14 OC 日志里没有注入行
reset_env
printf '773:1 OC: something else\n' > "$OC_LOG"
run_case ocnone
[ "$(field "$D/summary.txt" oc_log)" = "unverified" ] && ok "C14 无注入行 → oc_log=unverified" || bad "C14 oc_log" "$(grep oc_log "$D/summary.txt")"
[ "$(field "$D/summary.txt" functional_ok)" = "no" ] && ok "C14 无注入行 → functional=no" || bad "C14 functional" "$(grep functional_ok "$D/summary.txt")"
printf '773:107:604 00:182 OC: Prelinked injection IGPUProbe.kext (IGPUProbe Phase-1 probe) - Success\n774:107:786 00:182 OC: Prelinked injection IGPUProbe.kext v0.1.0\n' > "$OC_LOG"

# C15 prep 证据不完整
reset_env; export FAKE_EXTRA_ARGS=" igpu-driver=prep" FAKE_PREP_PROPS=1 FAKE_PREP_EVIDENCE=No FAKE_PREP_READS=0
run_case prepbad
[ "$(field "$D/summary.txt" functional_ok)" = "no" ] && ok "C15 prep 证据缺失 → functional=no" || bad "C15 functional" "$(grep functional_ok "$D/summary.txt")"
grep -q 'prep-evidence\|prep-read-count' "$D/summary.txt" && ok "C15 失败项含 prep" || bad "C15 失败项" "$(grep functional_fail "$D/summary.txt")"

# C16 off 却有实例
reset_env; export FAKE_EXTRA_ARGS=" igpu-driver=off"
run_case offleak
[ "$(field "$D/summary.txt" material_complete)" = "no" ] && ok "C16 off 有实例 → material=no" || bad "C16 material" "$(grep material_complete "$D/summary.txt")"
[ $RC -ne 0 ] && ok "C16 返回非零" || bad "C16 返回非零" "rc=0"

# C17 OC 绑定不可判定（boottime 缺失）
reset_env; export FAKE_BOOTTIME="unknown"
run_case ocunknown
[ "$(field "$D/summary.txt" oc_boot_bound)" = "unknown" ] && ok "C17 OC 绑定 unknown" || bad "C17 oc_bound" "$(grep '^oc_boot_bound=' "$D/summary.txt")"
[ "$(field "$D/summary.txt" functional_ok)" = "no" ] && ok "C17 unknown 不算功能通过" || bad "C17 functional" "$(grep '^functional_ok=' "$D/summary.txt")"

# C18 OC 日志来自上一次启动（mtime 早于 boot 1 小时）
reset_env; export OC_MT_OFFSET=-3600
run_case ocstale
[ "$(field "$D/summary.txt" oc_boot_bound)" = "mismatch" ] && ok "C18 旧日志绑定 mismatch" || bad "C18 oc_bound" "$(grep '^oc_boot_bound=' "$D/summary.txt")"
[ "$(field "$D/summary.txt" functional_ok)" = "no" ] && ok "C18 mismatch 不算功能通过" || bad "C18 functional" "$(grep '^functional_ok=' "$D/summary.txt")"
export OC_MT_OFFSET=-60

# C19 注入失败特征不得算 ok
reset_env
printf '773:107:604 OC: Prelinked injection IGPUProbe.kext - Failed to inject (Invalid Parameter)\n' > "$OC_LOG"
run_case ocfail
[ "$(field "$D/summary.txt" oc_log)" = "failed" ] && ok "C19 注入失败 → oc_log=failed" || bad "C19 oc_log" "$(grep '^oc_log=' "$D/summary.txt")"
[ "$(field "$D/summary.txt" functional_ok)" = "no" ] && ok "C19 failed 不算功能通过" || bad "C19 functional" "$(grep '^functional_ok=' "$D/summary.txt")"
printf '773:107:604 00:182 OC: Prelinked injection IGPUProbe.kext (IGPUProbe Phase-1 probe) - Success\n774:107:786 00:182 OC: Prelinked injection IGPUProbe.kext v0.1.0\n' > "$OC_LOG"

# C20 本次启动 0 条探针日志
reset_env; export FAKE_LOG_EVENTS=0
run_case logzero
[ "$(field "$D/summary.txt" log_events)" = "0" ] && ok "C20 log_events=0" || bad "C20 log_events" "$(grep '^log_events=' "$D/summary.txt")"
[ "$(field "$D/summary.txt" functional_ok)" = "no" ] && ok "C20 0 事件不算功能通过" || bad "C20 functional" "$(grep '^functional_ok=' "$D/summary.txt")"

# C21 字典缺失
reset_env; export FAKE_STATE=missing
run_case statedict
[ "$(field "$D/summary.txt" state_dict)" = "missing" ] && ok "C21 state_dict=missing" || bad "C21 state_dict" "$(grep '^state_dict=' "$D/summary.txt")"
grep -q 'state-dict-missing' "$D/summary.txt" && ok "C21 失败项指明 state-dict-missing" || bad "C21 失败项" "$(grep '^functional_fail=' "$D/summary.txt")"
[ "$(field "$D/summary.txt" functional_ok)" = "no" ] && ok "C21 缺字典 → functional=no" || bad "C21 functional" "$(grep '^functional_ok=' "$D/summary.txt")"

# C22 键数 189
reset_env; export FAKE_STATE_KEYS=189
run_case state189
grep -q 'state-dict-keys=189' "$D/summary.txt" && ok "C22 键数 189 被拒" || bad "C22 键数" "$(grep '^functional_fail=' "$D/summary.txt")"

# C23 值不是 4 字节
reset_env; export FAKE_STATE_LEN=3
run_case statebadlen
grep -q 'state-dict-badlen=' "$D/summary.txt" && ok "C23 错长度被拒" || bad "C23 长度" "$(grep '^functional_fail=' "$D/summary.txt")"

# C24 RegsTable 不是 190
reset_env; export FAKE_REGS_TABLE=189
run_case regstable
grep -q 'regs-table=189' "$D/summary.txt" && ok "C24 RegsTable=189 被拒" || bad "C24 regs-table" "$(grep '^functional_fail=' "$D/summary.txt")"

# C25 prep 断言失败（A3）
reset_env; export FAKE_EXTRA_ARGS=" igpu-driver=prep" FAKE_PREP_PROPS=1 FAKE_PREP_ASSERT=fail
run_case prepassert
grep -q 'prep-assert-fail=A3' "$D/summary.txt" && ok "C25 prep A3 失败被拒" || bad "C25 prep assert" "$(grep '^functional_fail=' "$D/summary.txt")"
[ "$(field "$D/summary.txt" functional_ok)" = "no" ] && ok "C25 prep assert → functional=no" || bad "C25 functional" "$(grep '^functional_ok=' "$D/summary.txt")"
printf '\n===== PASS=%d  FAIL=%d =====\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]