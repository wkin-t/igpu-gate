#!/bin/bash
# run-trip.sh —— onsite/20-dell-trip.sh 的离线回归
#
# 目的：现场不能"一跑就报错"。这里用桩命令模拟 macOS（diskutil/dscl/plutil/ioreg…
# 以及各 onsite 脚本），把 5 个阶段 + 3 类失败路径全跑一遍：
#   * 正常全程 0→4：阶段推进、状态文件、提示文案
#   * KC 门禁失败：必须停住、不推进、生成 FAILED 打包容错
#   * 部署失败    ：同上
#   * A0 kext 缺失：必须跳过并继续（soft 失败）
#   * 采集失败    ：默认必须停住；加 --continue-on-error 才继续
#   * --status / --reset
#   * 非 root 自提权路径
#
# 在真 macOS（bash 3.2）与 Linux/Git Bash（bash 5）上都能跑：只用 POSIX 工具。
set -u

H=$(cd "$(dirname "$0")" && pwd)
KITROOT=$(cd "$H/../.." && pwd)      # kit 根（含 igpu-build/ 与 testkit/）
BUILD="${KITROOT}/igpu-build"
TRIP="${BUILD}/onsite/20-dell-trip.sh"
P=0
F=0
ok() { P=$((P+1)); printf '  ✓ %s\n' "$1"; }
no() { F=$((F+1)); printf '  ✗ %s（%s）\n' "$1" "${2:-}"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "期望 [$3] 实际 [$2]"; fi; }

[ -f "${TRIP}" ] || { printf 'FAIL 找不到 %s\n' "${TRIP}"; exit 1; }
BASH_BIN=$(command -v bash || echo /bin/bash)

# ---------- 造一个可控的"假 macOS"沙箱 ----------
mk() {
  T=$(mktemp -d 2>/dev/null || mktemp -d -t triprep)
  B="${T}/bin"; K="${T}/kit"; HO="${T}/home"; ESP="${T}/ESP"
  mkdir -p "${B}" "${K}/onsite" "${K}/tools" "${K}/dist/IGPUProbe.kext" \
           "${K}/kext/IGPULoadProbe/IGPULoadProbe.kext/Contents" \
           "${HO}" "${ESP}/EFI/OC/Kexts" "${ESP}/EFI/OC"
  printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "${ESP}/EFI/OC/config.plist"

  # 真实脚本 + 真实 python 工具
  cp "${TRIP}" "${K}/onsite/20-dell-trip.sh"
  cp "${BUILD}/tools/add-kext-entry.py" "${K}/tools/" 2>/dev/null || printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "${K}/tools/add-kext-entry.py"
  printf 'x\n' > "${K}/kext/IGPULoadProbe/IGPULoadProbe.kext/Contents/Info.plist"

  # 桩：onsite 脚本
  for s in 01-deploy.sh 05-kcgate.sh 04-state.sh; do
    cat > "${K}/onsite/${s}" <<'EOS'
#!/bin/sh
case "$(basename "$0")" in
  05-kcgate.sh) exit "${FAKE_KCGATE_RC:-0}" ;;
  01-deploy.sh) exit "${FAKE_DEPLOY_RC:-0}" ;;
  04-state.sh)  exit "${FAKE_STATE_RC:-0}" ;;
esac
exit 0
EOS
  done
  cat > "${K}/onsite/02-collect.sh" <<'EOS'
#!/bin/sh
mkdir -p "${TEST_KIT}/results-collect-$(date +%s)"
exit "${FAKE_COLLECT_RC:-0}"
EOS
  cat > "${K}/onsite/09-grab.sh" <<'EOS'
#!/bin/sh
# 参数形如 --dest DIR
mkdir -p "$2" && echo "ok" > "$2/GRAB-MANIFEST"
exit 0
EOS
  cat > "${K}/onsite/12-loadprobe-check.sh" <<'EOS'
#!/bin/sh
echo "RESULT: LOADED"
exit "${FAKE_A0_RC:-0}"
EOS
  cat > "${K}/onsite/13-fb-describe.sh" <<'EOS'
#!/bin/sh
# 形如 --outdir DIR
mkdir -p "$2" && echo "stub" > "$2/summary.txt"
exit 0
EOS
  chmod +x "${K}"/onsite/*.sh

  # 桩：系统命令
  cat > "${B}/id" <<'EOS'
#!/bin/sh
case "${1:-}" in
  -u) if [ "${IGPU_TEST_ROOT:-0}" = 1 ]; then echo 0; else echo 501; fi ;;
  *)  echo "uid=501(t) gid=20(t) groups=20(t)" ;;
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
  info)  echo "   Mount Point: ${TEST_ESP}" ;;
  *)     exit 0 ;;
esac
EOS
  for c in plutil log kmutil; do
    printf '#!/bin/sh\nexit 0\n' > "${B}/${c}"
  done
  printf '#!/bin/sh\necho "<plist><dict/></plist>"\n' > "${B}/ioreg"
  printf '#!/bin/sh\necho "Displays: (stub)"\n' > "${B}/system_profiler"
  # python3 兜底（Windows/Git Bash 常常只有 python）
  if ! command -v python3 >/dev/null 2>&1; then
    printf '#!/bin/sh\nexec python "$@"\n' > "${B}/python3"
  fi
  chmod +x "${B}"/* 2>/dev/null || true

  export TEST_HOME="${HO}" TEST_ESP="${ESP}" TEST_KIT="${K}"
  PHASE_FILE="${HO}/.igpu-trip-phase"
  LOGF="${HO}/igpu-trip-log.txt"
}

cleanup() { [ -n "${T:-}" ] && [ -d "${T}" ] && rm -rf "${T}"; }
run() { ( PATH="${B}:${PATH}" HOME="${HO}" "${BASH_BIN}" "${K}/onsite/20-dell-trip.sh" "$@" ) >>"${T}/out.txt" 2>&1; echo $?; }
phase() { cat "${PHASE_FILE}" 2>/dev/null || echo none; }

printf '== 20-dell-trip.sh 离线回归 ==\n'

# ---- 用例 1：正常全程 ----
mk
r=$(run); chk "阶段0 退出码" "$r" "0"
chk "阶段0 后 phase" "$(phase)" "1"
r=$(run); chk "阶段1 退出码" "$r" "0"
chk "阶段1 后 phase" "$(phase)" "2"
r=$(run); chk "阶段2 退出码" "$r" "0"
chk "阶段2 后 phase" "$(phase)" "3"
r=$(run); chk "阶段3 退出码" "$r" "0"
chk "阶段3 后 phase" "$(phase)" "4"
if grep -q '全部完成' "${T}/out.txt"; then ok "阶段3 打印完成信息"; else no "阶段3 打印完成信息" "没看到『全部完成』"; fi
if grep -q '强制断电' "${T}/out.txt"; then ok "阶段2 提示断电冷启"; else no "阶段2 提示断电冷启"; fi
cleanup

# ---- 用例 2：KC 门禁失败必须停 ----
mk
r=$( FAKE_KCGATE_RC=1; export FAKE_KCGATE_RC; run )
chk "KC失败 退出码" "$r" "1"
chk "KC失败 不推进" "$(phase)" "none"
if ls -d "${HO}"/igpu-trip-FAILED-* >/dev/null 2>&1; then ok "KC失败 生成打包容错"; else no "KC失败 生成打包容错"; fi
cleanup

# ---- 用例 3：部署失败必须停 ----
mk
r=$( FAKE_DEPLOY_RC=1; export FAKE_DEPLOY_RC; run )
chk "部署失败 退出码" "$r" "1"
chk "部署失败 不推进" "$(phase)" "none"
cleanup

# ---- 用例 4：A0 kext 缺失 → 跳过并继续 ----
mk
rm -rf "${K}/kext/IGPULoadProbe/IGPULoadProbe.kext"
r=$(run)
chk "缺A0 退出码" "$r" "0"
chk "缺A0 仍推进" "$(phase)" "1"
if grep -q '跳过 A0' "${T}/out.txt"; then ok "缺A0 有提示"; else no "缺A0 有提示"; fi
cleanup

# ---- 用例 5：采集失败默认停 ----
mk
printf '1\n' > "${HO}/.igpu-trip-phase"
r=$( FAKE_COLLECT_RC=1; export FAKE_COLLECT_RC; run )
chk "采集失败 退出码" "$r" "1"
chk "采集失败 不推进" "$(phase)" "1"
cleanup

# ---- 用例 6：--continue-on-error 才继续 ----
mk
printf '1\n' > "${HO}/.igpu-trip-phase"
r=$( FAKE_COLLECT_RC=1; export FAKE_COLLECT_RC; run --continue-on-error )
chk "采集失败+继续 退出码" "$r" "0"
chk "采集失败+继续 推进" "$(phase)" "2"
cleanup

# ---- 用例 7：--status / --reset ----
mk
printf '2\n' > "${HO}/.igpu-trip-phase"
( PATH="${B}:${PATH}" HOME="${HO}" "${BASH_BIN}" "${K}/onsite/20-dell-trip.sh" --status ) >"${T}/st.txt" 2>&1
if grep -q '2 / 4' "${T}/st.txt"; then ok "--status 显示阶段"; else no "--status 显示阶段" "$(cat "${T}/st.txt" | head -3)"; fi
( PATH="${B}:${PATH}" HOME="${HO}" "${BASH_BIN}" "${K}/onsite/20-dell-trip.sh" --reset ) >/dev/null 2>&1
chk "--reset 清空进度" "$(phase)" "none"
cleanup

# ---- 用例 8：非 root 自提权 ----
mk
# 不设 IGPU_TEST_ROOT：id -u 返回 501 → 脚本应通过 sudo 桩重入
( unset IGPU_TEST_ROOT; PATH="${B}:${PATH}" HOME="${HO}" "${BASH_BIN}" "${K}/onsite/20-dell-trip.sh" ) >>"${T}/out.txt" 2>&1
rc=$?
chk "自提权 退出码" "${rc}" "0"
chk "自提权 后 phase" "$(phase)" "1"
cleanup

printf '===== PASS=%d  FAIL=%d =====\n' "${P}" "${F}"
[ "${F}" -eq 0 ] || exit 1
exit 0