#!/bin/bash
# run-trip.sh —— onsite/20-dell-trip.sh 的离线回归（用桩命令模拟 macOS）
#
# 覆盖：正常全程 0→4、KC 门禁失败、A0 门禁失败(soft)、部署失败、采集失败(默认停 / --continue-on-error)、
#       未重启就续跑必须停、第 2 轮后必须切回 normal、第 3 轮 boot-args 非 normal 必须停、
#       A1 落在 bundle 下、导出兜底 tar、--status 不需要 root、--reset、非 root 自提权。
set -u

H=$(cd "$(dirname "$0")" && pwd)
KITROOT=$(cd "$H/../.." && pwd)
BUILD="${KITROOT}/igpu-build"
TRIP="${BUILD}/onsite/20-dell-trip.sh"
P=0; F=0
ok() { P=$((P+1)); printf '  ✓ %s\n' "$1"; }
no() {
  F=$((F+1)); printf '  ✗ %s（%s）\n' "$1" "${2:-}"
  if [ -n "${T:-}" ] && [ -f "${T}/out.txt" ]; then
    printf '     --- 本次运行输出尾部 ---\n'
    tail -12 "${T}/out.txt" | sed 's/^/     /'
  fi
}
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "期望 [$3] 实际 [$2]"; fi; }

[ -f "${TRIP}" ] || { printf 'FAIL 找不到 %s\n' "${TRIP}"; exit 1; }
BASH_BIN=$(command -v bash || echo /bin/bash)

mk() {
  T=$(mktemp -d 2>/dev/null || mktemp -d -t triprep)
  B="${T}/bin"; K="${T}/kit"; HO="${T}/home"; ESPDIR="${T}/ESP"
  mkdir -p "${B}" "${K}/onsite" "${K}/tools" "${K}/dist/IGPUProbe.kext/Contents/MacOS" \
           "${K}/kext/IGPULoadProbe/IGPULoadProbe.kext/Contents/MacOS" \
           "${HO}" "${ESPDIR}/EFI/OC/Kexts"
  printf '<plist version="1.0"><dict/></plist>\n' > "${ESPDIR}/EFI/OC/config.plist"
  : > "${K}/dist/IGPUProbe.kext/Contents/MacOS/IGPUProbe"
  : > "${K}/kext/IGPULoadProbe/IGPULoadProbe.kext/Contents/MacOS/IGPULoadProbe"

  cp "${TRIP}" "${K}/onsite/20-dell-trip.sh"
  cp "${BUILD}/tools/add-kext-entry.py" "${K}/tools/" 2>/dev/null || printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "${K}/tools/add-kext-entry.py"
  cp "${BUILD}/tools/kc_gate.py" "${K}/tools/" 2>/dev/null || printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "${K}/tools/kc_gate.py"

  # --- onsite 桩 ---
  for s in 01-deploy.sh 05-kcgate.sh 04-state.sh; do
    cat > "${K}/onsite/${s}" <<'EOS'
#!/bin/sh
case "$(basename "$0")" in
  05-kcgate.sh) exit "${FAKE_KCGATE_RC:-0}" ;;
  01-deploy.sh) exit "${FAKE_DEPLOY_RC:-0}" ;;
  04-state.sh)  printf '%s\n' "${1:-}" >> "${TEST_HOME}/state-calls.txt"; exit "${FAKE_STATE_RC:-0}" ;;
esac
exit 0
EOS
  done
  cat > "${K}/onsite/02-collect.sh" <<'EOS'
#!/bin/sh
D="${TEST_KIT}/results-collect-$(date +%s)-$$"
mkdir -p "$D"
{
  echo "mode=${FAKE_MODE:-normal}"
  echo "probe_loaded=yes"
  echo "instances=1"
  echo "material_complete=${FAKE_MATERIAL:-yes}"
  echo "material_fail=${FAKE_MATERIAL_FAIL:-}"
  echo "functional_ok=yes"
  echo "functional_fail="
  echo "evidence_complete=yes"
  echo "oc_log=ok"
  echo "log_mode=ok"
  echo "shutdown_cause=normal"
} > "$D/summary.txt"
exit "${FAKE_COLLECT_RC:-0}"
EOS
  cat > "${K}/onsite/09-grab.sh" <<'EOS'
#!/bin/sh
mkdir -p "$2" && echo ok > "$2/GRAB-MANIFEST"
exit "${FAKE_GRAB_RC:-0}"
EOS
  cat > "${K}/onsite/12-loadprobe-check.sh" <<'EOS'
#!/bin/sh
echo "RESULT: LOADED"; exit 0
EOS
  cat > "${K}/onsite/13-fb-describe.sh" <<'EOS'
#!/bin/sh
mkdir -p "$2" && echo "fb_like_nodes=2" > "$2/summary.txt" && echo "stub" > "$2/ioreg.plist"
exit 0
EOS
  cat > "${K}/onsite/14-a0-gate.sh" <<'EOS'
#!/bin/sh
echo "RESULT: A0-CROSS-KC-IMPOSSIBLE"
exit "${FAKE_A0GATE_RC:-0}"
EOS
  chmod +x "${K}"/onsite/*.sh

  # --- 系统命令桩 ---
  cat > "${B}/id" <<'EOS'
#!/bin/sh
case "${1:-}" in
  -u) if [ "${IGPU_TEST_ROOT:-0}" = 1 ]; then echo 0; else echo 501; fi ;;
  *)  echo "uid=501(t) gid=20(t)" ;;
esac
EOS
  cat > "${B}/sudo" <<'EOS'
#!/bin/sh
[ "${1:-}" = "--" ] && shift
IGPU_TEST_ROOT=1 exec "$@"
EOS
  cat > "${B}/dscl" <<'EOS'
#!/bin/sh
echo "NFSHomeDirectory: ${TEST_HOME}"
EOS
  cat > "${B}/diskutil" <<'EOS'
#!/bin/sh
case "${1:-}" in
  list)  echo "/dev/disk9s1   Apple_APFS   OCEFI" ;;
  mount) echo "Volume OCEFI on disk9s1 mounted" ;;
  info)  echo "   Mount Point:               ${TEST_ESP}" ;;
  *)     exit 0 ;;
esac
EOS
  cat > "${B}/sysctl" <<'EOS'
#!/bin/sh
case "${1:-}" in
  -n) case "${2:-}" in
        kern.boottime) echo "{ sec = ${FAKE_BOOT_EPOCH:-1000}, usec = 0 } Wed Jan  1 00:00:00 2026" ;;
        kern.bootargs) echo "${FAKE_BOOTARGS:-}" ;;
        *) echo "" ;;
      esac ;;
  *) exit 0 ;;
esac
EOS
  for c in plutil log kmutil; do printf '#!/bin/sh\nexit 0\n' > "${B}/${c}"; done
  printf '#!/bin/sh\nexit 0\n' > "${B}/nm"
  printf '#!/bin/sh\necho "<plist><dict/></plist>"\n' > "${B}/ioreg"
  printf '#!/bin/sh\necho "Displays: (stub)"\n' > "${B}/system_profiler"
  printf '#!/bin/sh\necho "0000000000000000000000000000000000000000000000000000000000000000  x"\n' > "${B}/shasum"
  if ! command -v python3 >/dev/null 2>&1; then printf '#!/bin/sh\nexec python "$@"\n' > "${B}/python3"; fi
  chmod +x "${B}"/* 2>/dev/null || true

  export TEST_HOME="${HO}" TEST_ESP="${ESPDIR}" TEST_KIT="${K}"
  PHASE_FILE="${HO}/.igpu-trip-phase"
  STATE_CALLS="${HO}/state-calls.txt"
}

cleanup() { [ "${KEEP:-0}" = 1 ] && { printf '   (KEEP=1，沙箱保留：%s)\n' "${T}"; return 0; }; [ -n "${T:-}" ] && [ -d "${T}" ] && rm -rf "${T}"; }
run() { ( PATH="${B}:${PATH}" HOME="${HO}" "${BASH_BIN}" "${K}/onsite/20-dell-trip.sh" "$@" ) >>"${T}/out.txt" 2>&1; echo $?; }
phase() { cat "${PHASE_FILE}" 2>/dev/null || echo none; }

printf '== 20-dell-trip.sh 离线回归 ==\n'

# ---- 1) 正常全程 0→4（每次模拟一次重启：换 boot epoch）----
mk
r=$( FAKE_BOOT_EPOCH=1000; export FAKE_BOOT_EPOCH; run )
chk "阶段0 退出码" "$r" "0"; chk "阶段0→1" "$(phase)" "1"
r=$( FAKE_BOOT_EPOCH=2000; export FAKE_BOOT_EPOCH; run )
chk "阶段1 退出码" "$r" "0"; chk "阶段1→2" "$(phase)" "2"
if grep -q '^off$' "${STATE_CALLS}" 2>/dev/null; then ok "阶段1 切了 off"; else no "阶段1 切了 off" "$(cat "${STATE_CALLS}" 2>/dev/null)"; fi
r=$( FAKE_BOOT_EPOCH=3000; export FAKE_BOOT_EPOCH; run )
chk "阶段2 退出码" "$r" "0"; chk "阶段2→3" "$(phase)" "3"
if grep -q '^normal$' "${STATE_CALLS}" 2>/dev/null; then ok "阶段2 切回 normal"; else no "阶段2 切回 normal" "$(cat "${STATE_CALLS}")"; fi
r=$( FAKE_BOOT_EPOCH=4000 FAKE_BOOTARGS="keepsyms=1"; export FAKE_BOOT_EPOCH FAKE_BOOTARGS; run )
chk "阶段3 退出码" "$r" "0"; chk "阶段3→4" "$(phase)" "4"
if grep -q '全部完成' "${T}/out.txt"; then ok "阶段3 打印完成"; else no "阶段3 打印完成"; fi
if ls -d "${K}"/results-fbdescribe-* >/dev/null 2>&1; then ok "A1 落在 bundle 下"; else no "A1 落在 bundle 下"; fi
if ls "${HO}"/igpu-collect-*.tar.gz >/dev/null 2>&1; then ok "导出兜底 tar 生成"; else no "导出兜底 tar 生成"; fi
if grep -q 'A0 判定' "${T}/out.txt"; then ok "阶段0 打印 A0 判定"; else no "阶段0 打印 A0 判定"; fi
cleanup

# ---- 2) KC 门禁失败必须停 ----
mk
r=$( FAKE_BOOT_EPOCH=1000 FAKE_KCGATE_RC=1; export FAKE_BOOT_EPOCH FAKE_KCGATE_RC; run )
chk "KC失败 退出码" "$r" "1"; chk "KC失败 不推进" "$(phase)" "none"
if ls -d "${HO}"/igpu-trip-FAILED-* >/dev/null 2>&1; then ok "KC失败 生成出错包"; else no "KC失败 生成出错包"; fi
cleanup

# ---- 3) A0 门禁失败只告警（不阻塞 2a）----
mk
r=$( FAKE_BOOT_EPOCH=1000 FAKE_A0GATE_RC=3; export FAKE_BOOT_EPOCH FAKE_A0GATE_RC; run )
chk "A0失败 soft 退出码" "$r" "0"; chk "A0失败 仍推进" "$(phase)" "1"
cleanup

# ---- 4) 部署失败必须停 ----
mk
r=$( FAKE_BOOT_EPOCH=1000 FAKE_DEPLOY_RC=1; export FAKE_BOOT_EPOCH FAKE_DEPLOY_RC; run )
chk "部署失败 退出码" "$r" "1"; chk "部署失败 不推进" "$(phase)" "none"
cleanup

# ---- 5) 采集失败：默认停 + 打印结论 ----
mk
printf '1\n' > "${PHASE_FILE}"
r=$( FAKE_BOOT_EPOCH=2000 FAKE_COLLECT_RC=1 FAKE_MATERIAL=no FAKE_MATERIAL_FAIL="oc_log"; export FAKE_BOOT_EPOCH FAKE_COLLECT_RC FAKE_MATERIAL FAKE_MATERIAL_FAIL; run )
chk "采集失败 退出码" "$r" "1"; chk "采集失败 不推进" "$(phase)" "1"
if grep -q 'material_complete=no' "${T}/out.txt"; then ok "采集失败 打印结论"; else no "采集失败 打印结论"; fi
cleanup

# ---- 6) 采集失败 + --continue-on-error 才继续 ----
mk
printf '1\n' > "${PHASE_FILE}"
r=$( FAKE_BOOT_EPOCH=2000 FAKE_COLLECT_RC=1; export FAKE_BOOT_EPOCH FAKE_COLLECT_RC; run --continue-on-error )
chk "采集失败+继续 退出码" "$r" "0"; chk "采集失败+继续 推进" "$(phase)" "2"
cleanup

# ---- 7) 未重启就续跑必须停 ----
mk
printf '1\n' > "${PHASE_FILE}"
r=$( FAKE_BOOT_EPOCH=2000; export FAKE_BOOT_EPOCH; run )    # 第一次建立 boot epoch
chk "首跑 退出码" "$r" "0"
r=$( FAKE_BOOT_EPOCH=2000; export FAKE_BOOT_EPOCH; run )    # 同一 boot epoch 再跑
chk "未重启 退出码" "$r" "1"
if grep -q 'kern.boottime 未变' "${T}/out.txt"; then ok "未重启 有明确提示"; else no "未重启 有明确提示"; fi
cleanup

# ---- 8) 第 3 轮 boot-args 非 normal 必须停 ----
mk
printf '3\n' > "${PHASE_FILE}"
printf '2000\n' > "${PHASE_FILE}.boot"
r=$( FAKE_BOOT_EPOCH=3000 FAKE_BOOTARGS="igpu-driver=off keepsyms=1"; export FAKE_BOOT_EPOCH FAKE_BOOTARGS; run )
chk "第3轮模式错 退出码" "$r" "1"; chk "第3轮模式错 不推进" "$(phase)" "3"
cleanup

# ---- 9) --status 不需要 root / --reset ----
mk
printf '2\n' > "${PHASE_FILE}"
( PATH="${B}:${PATH}" HOME="${HO}" IGPU_TEST_ROOT=0 "${BASH_BIN}" "${K}/onsite/20-dell-trip.sh" --status ) >"${T}/st.txt" 2>&1
if grep -q '2 / 4' "${T}/st.txt"; then ok "--status 显示阶段"; else no "--status 显示阶段" "$(head -3 "${T}/st.txt")"; fi
( PATH="${B}:${PATH}" HOME="${HO}" IGPU_TEST_ROOT=0 "${BASH_BIN}" "${K}/onsite/20-dell-trip.sh" --reset ) >/dev/null 2>&1
chk "--reset 清空进度" "$(phase)" "none"
cleanup

# ---- 10) 非 root 自提权 ----
mk
( unset IGPU_TEST_ROOT; PATH="${B}:${PATH}" HOME="${HO}" FAKE_BOOT_EPOCH=1000 "${BASH_BIN}" "${K}/onsite/20-dell-trip.sh" ) >>"${T}/out.txt" 2>&1
chk "自提权 退出码" "$?" "0"; chk "自提权 后阶段" "$(phase)" "1"
cleanup

printf '===== PASS=%d  FAIL=%d =====\n' "${P}" "${F}"
[ "${F}" -eq 0 ] || exit 1
exit 0