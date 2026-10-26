#!/bin/sh
# 20-dell-trip.sh —— Dell 现场一条龙（幂等、可恢复、失败留证）
#
#   sh onsite/20-dell-trip.sh                 # 每次开机跑同一条（非 root 会自动 sudo）
#   sh onsite/20-dell-trip.sh --status        # 只看进度（不需要 root）
#   sh onsite/20-dell-trip.sh --reset         # 清空进度重来
#   sh onsite/20-dell-trip.sh --continue-on-error
#
# 阶段：0 部署(KC门禁+A0离线判定+2a) → 1 normal 轮 → 2 off 轮（采完拔电）→ 3 normal 轮+导出
#
# 设计约束（现场没有人能 debug）：
#   · 关键步骤失败立即停、不推进、把日志与采集目录打包成 FAILED 目录；
#   · 可选步骤（A0 判定、A1 采集、U 盘导出）失败只告警；
#   · 每阶段结束只打印一句话"下一步做什么"；
#   · 阶段推进与"是否真的重启过"都要有证据，不靠人记。
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BUNDLE=$(cd "${HERE}/.." && pwd)
cd "${BUNDLE}" || { printf '%s\n' "FATAL 进不去 bundle 目录：${BUNDLE}"; exit 2; }

ORIG_ARGS=$*
ACTION=run
CONTINUE_ON_ERROR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --status) ACTION=status ;;
    --reset)  ACTION=reset ;;
    --continue-on-error) CONTINUE_ON_ERROR=1 ;;
    -h|--help)
      printf '%s\n' "用法：sh onsite/20-dell-trip.sh [--status|--reset|--continue-on-error]"
      exit 0 ;;
    *) printf '%s\n' "未知参数：${1}（试试 --status）" >&2; exit 2 ;;
  esac
  shift
done

# ---- 真实用户家目录（sudo 下 HOME 会变 /var/root）----
REAL_USER=${SUDO_USER:-$(id -un)}
REAL_HOME=$(dscl . -read "/Users/${REAL_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
case "${REAL_HOME}" in ""|*" "*) REAL_HOME=${HOME} ;; esac
[ -d "${REAL_HOME}" ] || REAL_HOME=${HOME}

STATE="${REAL_HOME}/.igpu-trip-phase"
BOOTF="${STATE}.boot"
LOG="${REAL_HOME}/igpu-trip-log.txt"

say()  { printf '%s\n' "$1"; }
log()  { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "${LOG}" 2>/dev/null || true; }
both() { log "$1"; say "$1"; }
warn() { log "WARN $1"; say "  ⚠ $1"; }

PHASE=$(cat "${STATE}" 2>/dev/null || echo 0)
case "${PHASE}" in ''|*[!0-9]*) PHASE=0 ;; esac

latest_collect() { ls -dt "${BUNDLE}"/results-collect-* 2>/dev/null | head -1; }

if [ "${ACTION}" = status ]; then
  say "当前阶段：${PHASE} / 4"
  say "进度文件：${STATE}   日志：${LOG}"
  say ""
  say "已采集："
  for d in "${BUNDLE}"/results-collect-* "${BUNDLE}"/results-fbdescribe-*; do
    [ -d "${d}" ] && say "  ${d}"
  done
  for d in "${REAL_HOME}"/igpu-trip-FAILED-*; do
    [ -d "${d}" ] && say "  (失败包) ${d}"
  done
  exit 0
fi
if [ "${ACTION}" = reset ]; then
  rm -f "${STATE}" "${BOOTF}"
  say "进度已清空（采集目录与日志保留）"
  exit 0
fi

# ---- 需要 root：写 ESP / 读内核日志 ----
if [ "$(id -u)" -ne 0 ]; then
  say "需要 root，正在用 sudo 重新运行……"
  # shellcheck disable=SC2086
  exec sudo -- /bin/sh "$0" ${ORIG_ARGS}
fi

# 注意：不能用 `s/.*sec = \([0-9]*\).*/\1/p` —— 贪婪前缀会匹配到 "usec = 0" 里的
# "sec = "，取到 0（实测踩过）。要求数字后面紧跟逗号即可排除 usec。
boot_epoch() { sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9][0-9]*\),.*/\1/p' | head -1; }

set_phase() {
  if ! printf '%s\n' "$1" > "${STATE}"; then
    say "✗ 进度文件写不进去：${STATE}（磁盘满/权限？）"
    exit 1
  fi
  boot_epoch > "${BOOTF}" 2>/dev/null || true
  sync 2>/dev/null || true
}

check_reboot() {
  _prev=$(cat "${BOOTF}" 2>/dev/null || true)
  _now=$(boot_epoch)
  [ -n "${_prev}" ] && [ -n "${_now}" ] || return 0
  [ "${_prev}" != "${_now}" ] || {
    say ""
    say "✗ 自上次步骤后**没有重启**（kern.boottime 未变）。"
    say "  请先按上一阶段的提示重启/断电，开机后再跑同一条命令。"
    exit 1
  }
  return 0
}

FAIL_EXTRA=""
make_fail_bundle() {
  TS=$(date '+%Y%m%d-%H%M%S')
  D="${REAL_HOME}/igpu-trip-FAILED-${TS}"
  mkdir -p "${D}" 2>/dev/null || { warn "建不了 ${D}，跳过打包"; return 0; }
  { printf 'phase=%s\nreason=%s\nstamp=%s\n' "$1" "$2" "${TS}"; } > "${D}/summary.txt" 2>/dev/null
  tail -150 "${LOG}" > "${D}/log-tail.txt" 2>/dev/null || true
  cp "${STATE}" "${D}/phase" 2>/dev/null || true
  if [ -n "${FAIL_EXTRA}" ] && [ -d "${FAIL_EXTRA}" ]; then
    cp -R "${FAIL_EXTRA}" "${D}/collect" 2>/dev/null || true
  fi
  say ""
  say "==================== 出错包已生成 ===================="
  say " 目录：${D}"
  say " 把这个目录带回来即可（含日志尾、采集结论、本阶段配置）。"
  say "======================================================"
}
die() { both "✗ 阶段 $1 失败：$2"; make_fail_bundle "$1" "$2"; exit 1; }
soft() { warn "$1（继续）"; }

show_collect_verdict() {
  D=$1
  [ -n "${D}" ] && [ -f "${D}/summary.txt" ] || { say "    （没有 summary.txt：${D:-无采集目录}）"; return 0; }
  say "    本轮采集结论："
  grep -E '^(mode|probe_loaded|instances|material_complete|material_fail|functional_ok|functional_fail|evidence_complete|oc_log|log_mode|shutdown_cause)=' "${D}/summary.txt" 2>/dev/null | sed 's/^/      /' || true
}

run_collect() {   # $1 = 阶段号, $2 = 轮次描述
  say ""
  say "-- 采集（${2}）--"
  if sh "${HERE}/02-collect.sh" >> "${LOG}" 2>&1; then
    both "  采集完成"
    return 0
  fi
  D=$(latest_collect)
  say "  ✗ 采集返回非 0，原因如下："
  show_collect_verdict "${D}"
  FAIL_EXTRA=${D}
  if [ "${CONTINUE_ON_ERROR}" -eq 1 ]; then
    soft "按 --continue-on-error 继续（本轮数据可能不完整）"
    return 0
  fi
  die "$1" "02-collect 失败（原因见上；数据不是零，但缺材料项）"
}

preflight() {
  MISSING=""
  for f in 02-collect.sh 04-state.sh 05-kcgate.sh 01-deploy.sh 09-grab.sh 13-fb-describe.sh 14-a0-gate.sh 15-pre2b-inventory.sh; do
    [ -f "${HERE}/${f}" ] || MISSING="${MISSING} onsite/${f}"
  done
  [ -f "${BUNDLE}/tools/add-kext-entry.py" ] || MISSING="${MISSING} tools/add-kext-entry.py"
  [ -f "${BUNDLE}/tools/kc_gate.py" ] || MISSING="${MISSING} tools/kc_gate.py"
  [ -d "${BUNDLE}/dist/IGPUProbe.kext" ] || MISSING="${MISSING} dist/IGPUProbe.kext"
  for t in diskutil plutil ioreg shasum; do
    command -v "${t}" >/dev/null 2>&1 || MISSING="${MISSING} ${t}(命令)"
  done
  # command -v 不够：没装 CLT 时 python3 是"假存在"，一运行就弹安装框
  python3 -c 'import plistlib, argparse, pathlib, xml.etree.ElementTree' >/dev/null 2>&1 \
    || MISSING="${MISSING} python3+plistlib(先 xcode-select --install)"
  nm -arch x86_64 /bin/ls >/dev/null 2>&1 \
    || MISSING="${MISSING} nm(先 xcode-select --install)"
  [ -w "${BUNDLE}" ] || MISSING="${MISSING} bundle目录不可写(${BUNDLE})"
  [ -w "${REAL_HOME}" ] || MISSING="${MISSING} 家目录不可写(${REAL_HOME})"
  if [ -n "${MISSING}" ]; then
    say "✗ 预检失败，缺这些：${MISSING}"
    say "  这不是你的操作问题：把这一行发回来即可。"
    log "PREFLIGHT FAIL:${MISSING}"
    exit 2
  fi
  say "  预检通过 ✓"
}

find_usb() {
  for v in /Volumes/*; do
    case "${v}" in
      *OCEFI*|*Recovery*|*"Macintosh HD"*) continue ;;
    esac
    [ -d "${v}" ] && [ -w "${v}" ] && { USBDIR=${v}; return 0; }
  done
  USBDIR=""
  return 1
}

export_results() {
  find_usb || true
  if [ -n "${USBDIR}" ]; then
    DEST="${USBDIR}/igpu-results-$(date '+%Y%m%d-%H%M')"
    if sh "${HERE}/09-grab.sh" --dest "${DEST}" >> "${LOG}" 2>&1; then
      both "  已导出到 U 盘：${DEST}"
      return 0
    fi
    warn "09-grab 导出异常，改用打包兜底"
  else
    warn "没检测到可写 U 盘"
  fi
  # 兜底：两个包（glob 必须在目标目录内展开，BSD tar 的 -C 不能配合另一目录的 glob）
  C_TGZ="${REAL_HOME}/igpu-collect-$(date '+%Y%m%d-%H%M').tar.gz"
  F_TGZ="${REAL_HOME}/igpu-fbdescribe-$(date '+%Y%m%d-%H%M').tar.gz"
  OK=1
  if ls -d "${BUNDLE}"/results-collect-* >/dev/null 2>&1; then
    ( cd "${BUNDLE}" && tar czf "${C_TGZ}" results-collect-* ) || OK=0
  fi
  if ls -d "${BUNDLE}"/results-fbdescribe-* >/dev/null 2>&1; then
    ( cd "${BUNDLE}" && tar czf "${F_TGZ}" results-fbdescribe-* ) || OK=0
  fi
  if [ "${OK}" -eq 1 ]; then
    both "  已打包：${C_TGZ}"
    both "          ${F_TGZ}（两个都带走）"
    return 0
  fi
  warn "打包失败；手工拷 ${BUNDLE}/results-collect-*、${BUNDLE}/results-fbdescribe-* 与 ${LOG}"
  return 1
}

say "=========================================================="
say " Dell 现场一条龙   阶段 ${PHASE} / 4"
say " 进度：${STATE}"
say " 日志：${LOG}"
say "=========================================================="
log "=== enter phase ${PHASE} ==="

if [ "${PHASE}" -eq 0 ]; then
  say ""
  say "[阶段 0] 部署（预检 → KC 门禁 → A0 离线判定 → 2a）"
  preflight

  say ""
  say "-- 0.1 找 EFI 分区 --"
  CAND=$(diskutil list 2>/dev/null | awk '/OCEFI/ {print $NF}' | sort -u)
  CNT=$(printf '%s\n' "${CAND}" | grep -c . 2>/dev/null || true)
  if [ "${CNT}" -ne 1 ]; then
    die 0 "OCEFI 候选数=${CNT}（必须恰好 1 个）。如果机器上还有别的卷叫 OCEFI，先把它的名字改掉"
  fi
  diskutil mount "${CAND}" >/dev/null 2>&1 || true
  ESP_MOUNT=$(diskutil info "${CAND}" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2}')
  [ -n "${ESP_MOUNT}" ] && [ -d "${ESP_MOUNT}" ] || die 0 "挂不上 ${CAND}（拿不到挂载点）"
  both "  EFI：${ESP_MOUNT}"

  say ""
  say "-- 0.2 KC 门禁（IGPUProbe，必须 PASS）--"
  if sh "${HERE}/05-kcgate.sh" >> "${LOG}" 2>&1; then
    both "  KC 门禁：PASS"
  else
    die 0 "KC 门禁未通过（GATE-INVALID 也按失败处理；日志里有 RESULT 行）"
  fi

  say ""
  say "-- 0.3 A0 离线判定（只读，不改 ESP、不需重启）--"
  if sh "${HERE}/14-a0-gate.sh" > "${REAL_HOME}/results-a0-gate.txt" 2>&1; then
    R=$(sed -n 's/^RESULT: //p' "${REAL_HOME}/results-a0-gate.txt" | tail -1)
    both "  A0 判定：${R:-无 RESULT 行（看 ${REAL_HOME}/results-a0-gate.txt）}"
  else
    R=$(sed -n 's/^RESULT: //p' "${REAL_HOME}/results-a0-gate.txt" 2>/dev/null | tail -1)
    soft "A0 判定不完整（${R:-无 RESULT}）；不影响 2a，文件留在 ${REAL_HOME}/results-a0-gate.txt"
  fi

  say ""
  say "-- 0.4 部署 2a（事务化；脚本结束时会把 ESP 卸载，属正常）--"
  if sh "${HERE}/01-deploy.sh" --reinject >> "${LOG}" 2>&1; then
    both "  2a 部署完成"
  else
    die 0 "01-deploy 失败（脚本应已自动回滚；日志末尾有原因）"
  fi

  set_phase 1
  say ""
  say "=========================================================="
  say " 下一步：重启"
  say "  · 在 OpenCore 菜单里选 macOS（不要选 Windows/内部盘）"
  say "  · U 盘保持插着（EFI 在它上面）"
  say " 开机登录后，再跑同一条命令："
  say "     sudo sh onsite/20-dell-trip.sh"
  say "=========================================================="
  exit 0
fi

if [ "${PHASE}" -eq 1 ]; then
  check_reboot
  say ""
  say "[阶段 1] 第 1 轮采集（normal）+ A1 基线"
  run_collect 1 "第 1 轮 normal"

  say ""
  say "-- A1：扫描面基线（只读）--"
  A1DIR="${BUNDLE}/results-fbdescribe-$(date -u '+%Y%m%dT%H%M%SZ')"
  if sh "${HERE}/13-fb-describe.sh" --outdir "${A1DIR}" >> "${LOG}" 2>&1; then
    both "  A1 采集完成：${A1DIR}"
  else
    soft "A1 采集异常（不影响 2a）"
  fi

  say ""
  say "-- 2b 前置证据包（只读，一次采完：KC 归属 / SIP / KDK / PCI BAR / EDID / 电源基线 / 崩溃通道）--"
  if sh "${HERE}/15-pre2b-inventory.sh" --outdir "${BUNDLE}/results-pre2b-$(date -u '+%Y%m%dT%H%M%SZ')" >> "${LOG}" 2>&1; then
    both "  pre2b 证据包完成"
  else
    soft "pre2b 证据包异常（不影响 2a）"
  fi

  say ""
  say "-- 切到 off 模式 --"
  if sh "${HERE}/04-state.sh" off >> "${LOG}" 2>&1; then
    both "  已切 off（下次启动生效）"
  else
    die 1 "切 off 失败（这一轮必须成功，否则三轮判物不完整）"
  fi

  sync 2>/dev/null || true
  set_phase 2
  say ""
  say "=========================================================="
  say " 下一步：重启（同样在 OpenCore 菜单选 macOS）"
  say " 开机登录后，再跑同一条命令："
  say "     sudo sh onsite/20-dell-trip.sh"
  say "=========================================================="
  exit 0
fi

if [ "${PHASE}" -eq 2 ]; then
  check_reboot
  say ""
  say "[阶段 2] 第 2 轮采集（off 模式）"
  run_collect 2 "第 2 轮 off"

  say ""
  say "-- 切回 normal（第 3 轮必须是 normal，否则三轮矩阵作废）--"
  if sh "${HERE}/04-state.sh" normal >> "${LOG}" 2>&1; then
    both "  已切回 normal（下次启动生效）"
  else
    die 2 "切回 normal 失败（第 3 轮会是 off，数据无效）"
  fi

  sync 2>/dev/null || true
  set_phase 3
  say ""
  say "=========================================================="
  say " 下一步：不要用关机命令！"
  say "   直接【拔电源】或【长按电源键 5 秒】强制断电，然后再开机。"
  say "   （这是故意制造断电冷启证据，别跳过）"
  say " 开机登录后，再跑同一条命令："
  say "     sudo sh onsite/20-dell-trip.sh"
  say "=========================================================="
  exit 0
fi

if [ "${PHASE}" -eq 3 ]; then
  check_reboot
  say ""
  say "[阶段 3] 第 3 轮采集（normal，兼断电冷启证据）"
  NOWARGS=$(sysctl -n kern.bootargs 2>/dev/null || true)
  case "${NOWARGS}" in
    *igpu-driver=off*|*igpu-driver=prep*|*igpu-driver=verbose*)
      die 3 "本次启动不是 normal 模式（kern.bootargs=${NOWARGS}）。回阶段 2 的说明切回 normal 再重启" ;;
  esac
  run_collect 3 "第 3 轮 normal（冷启）"

  say ""
  say "-- 导出 --"
  export_results || true

  set_phase 4
  say ""
  say "=========================================================="
  say " 全部完成 ✓"
  say ""
  say " 采集到的："
  for d in "${BUNDLE}"/results-collect-*; do [ -d "${d}" ] && say "   ${d}"; done
  for d in "${BUNDLE}"/results-fbdescribe-*; do [ -d "${d}" ] && say "   ${d}"; done
  say " A0 判定：${REAL_HOME}/results-a0-gate.txt"
  say " 日志：${LOG}"
  say ""
  say " 把这些带回来即可（U 盘导出或上面的 tar.gz 都行）。"
  say "=========================================================="
  exit 0
fi

say ""
say "本趟已完成（阶段 ${PHASE}）。把采集目录、A0 判定与日志带回来即可。"
say "要重跑整趟：sh onsite/20-dell-trip.sh --reset"
exit 0