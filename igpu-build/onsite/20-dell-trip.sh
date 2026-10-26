#!/bin/sh
# 20-dell-trip.sh —— Dell 现场一条龙（幂等、可恢复、失败自动留证）
#
#   sudo sh onsite/20-dell-trip.sh            # 正常推进（每次开机跑同一条）
#   sh onsite/20-dell-trip.sh --status        # 只看进度，不动任何东西
#   sh onsite/20-dell-trip.sh --reset         # 清空进度，从头再来
#   sh onsite/20-dell-trip.sh --continue-on-error
#                                             # 采集类步骤失败也继续推进（不推荐，但不会卡死）
#
# 设计原则（现场没人能帮你 debug，所以）：
#   1) 非 root 自动 sudo 重启自己，不需要记 sudo；
#   2) 关键步骤失败**立即停**、不推进阶段、并把日志+状态打包成 FAILED 目录；
#   3) 非关键步骤（A0 判定 / 扫描面采集 / U 盘导出）失败只告警，继续往下走；
#   4) 每个阶段结束都打印"下一步该做什么"，只有一句话；
#   5) 所有判断都基于显式文件与退出码，不依赖人的记忆。
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
KIT=$(cd "${HERE}/.." && pwd)
cd "${KIT}" || { printf '%s\n' "FATAL 进不去 kit 目录：${KIT}"; exit 2; }

# ---------- 自提权（普通用户跑也能继续） ----------
if [ "$(id -u)" -ne 0 ]; then
  printf '%s\n' "需要 root 权限，正在用 sudo 重新运行……"
  exec sudo -- /bin/sh "$0" "$@"
fi

# ---------- 真实用户家目录（sudo 下 HOME 会变成 /var/root） ----------
REAL_USER=${SUDO_USER:-$(id -un)}
REAL_HOME=$(dscl . -read "/Users/${REAL_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
case "${REAL_HOME}" in ""|*" "*|*/*/*/*) REAL_HOME=${HOME} ;; esac
[ -d "${REAL_HOME}" ] || REAL_HOME=${HOME}

STATE="${REAL_HOME}/.igpu-trip-phase"
LOG="${REAL_HOME}/igpu-trip-log.txt"
CONTINUE_ON_ERROR=0

# ---------- 参数 ----------
ACTION=run
while [ $# -gt 0 ]; do
  case "$1" in
    --status) ACTION=status; shift ;;
    --reset)  ACTION=reset;  shift ;;
    --continue-on-error) CONTINUE_ON_ERROR=1; shift ;;
    -h|--help)
      printf '%s\n' "用法：sudo sh onsite/20-dell-trip.sh [--status|--reset|--continue-on-error]"
      exit 0 ;;
    *) printf '%s\n' "未知参数：$1（试试 --status）" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$1"; }
log()  { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "${LOG}" 2>/dev/null || true; }
both() { log "$1"; say "$1"; }
warn() { log "WARN $1"; say "  ⚠ $1"; }

PHASE=$(cat "${STATE}" 2>/dev/null || echo 0)
case "${PHASE}" in ''|*[!0-9]*) PHASE=0 ;; esac

if [ "${ACTION}" = status ]; then
  say "当前阶段：${PHASE} / 4"
  say "进度文件：${STATE}"
  say "日志：${LOG}"
  say ""
  say "已被覆盖的阶段："
  for f in "${KIT}"/results-collect-* "${REAL_HOME}"/results-fbdescribe-* "${KIT}"/results-fbdescribe-*; do
    [ -d "$f" ] && say "  $f"
  done
  exit 0
fi
if [ "${ACTION}" = reset ]; then
  rm -f "${STATE}"
  say "进度已清空（日志保留：${LOG}）"
  exit 0
fi

# ---------- 失败打包（现场唯一需要的兜底） ----------
make_fail_bundle() {
  # $1 = 阶段号, $2 = 原因
  TS=$(date '+%Y%m%d-%H%M%S')
  D="${REAL_HOME}/igpu-trip-FAILED-${TS}"
  mkdir -p "${D}" 2>/dev/null || { warn "建不了 ${D}，跳过打包"; return 0; }
  {
    printf 'phase=%s\nreason=%s\nstamp=%s\n' "$1" "$2" "${TS}"
    printf 'kit=%s\nesp=%s\n' "${KIT}" "${ESP_MOUNT:-未挂载}"
  } > "${D}/summary.txt" 2>/dev/null
  tail -120 "${LOG}" > "${D}/log-tail.txt" 2>/dev/null || true
  cp "${STATE}" "${D}/phase" 2>/dev/null || true
  say ""
  say "==================== 出错包已生成 ===================="
  say " 目录：${D}"
  say " 你只要把这个目录带回来（或把 summary.txt 内容发我）即可，"
  say " 不需要现场排查。"
  say "======================================================"
}

die() {  # 关键失败：不推进阶段
  both "✗ 阶段 $1 失败：$2"
  make_fail_bundle "$1" "$2"
  exit 1
}
soft() { # 非关键失败：告警后继续
  warn "$1（继续）"
  [ "${CONTINUE_ON_ERROR}" -eq 1 ] || true
}

# ---------- 预检：缺什么一次说清 ----------
preflight() {
  MISSING=""
  for f in 02-collect.sh 04-state.sh 05-kcgate.sh 01-deploy.sh 09-grab.sh; do
    [ -f "${HERE}/${f}" ] || MISSING="${MISSING} onsite/${f}"
  done
  [ -f "${KIT}/tools/add-kext-entry.py" ] || MISSING="${MISSING} tools/add-kext-entry.py"
  [ -d "${KIT}/dist/IGPUProbe.kext" ] || MISSING="${MISSING} dist/IGPUProbe.kext"
  for t in diskutil python3 plutil ioreg; do
    command -v "${t}" >/dev/null 2>&1 || MISSING="${MISSING} ${t}(命令)"
  done
  if [ -n "${MISSING}" ]; then
    say "✗ 预检失败，缺这些：${MISSING}"
    say "  说明 kit 不完整（不是你的操作问题）。把这个提示发我即可。"
    log "PREFLIGHT FAIL:${MISSING}"
    exit 2
  fi
  say "  预检通过 ✓"
}

# ---------- U 盘/导出兜底 ----------
find_usb() {
  for v in /Volumes/*; do
    case "${v}" in
      *OCEFI*|*Recovery*|*"Macintosh HD"*|*"Macintosh HD - Data"*) continue ;;
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
  TGZ="${REAL_HOME}/igpu-results-$(date '+%Y%m%d-%H%M').tar.gz"
  if tar czf "${TGZ}" -C "${REAL_HOME}" results-fbdescribe-* 2>/dev/null \
     || tar czf "${TGZ}" results-fbdescribe-* 2>/dev/null; then
    both "  已打包：${TGZ}（拷走这一个文件即可）"
    return 0
  fi
  warn "打包也失败了；请手工拷 ${KIT}/results-collect-* 与 ${REAL_HOME}/results-fbdescribe-*"
  return 1
}

say "=========================================================="
say " Dell 现场一条龙   阶段 ${PHASE} / 4"
say " 进度：${STATE}"
say " 日志：${LOG}"
say "=========================================================="
log "=== enter phase ${PHASE} ==="

# ================= 阶段 0：部署 =================
if [ "${PHASE}" -eq 0 ]; then
  say ""
  say "[阶段 0] 部署（预检 → KC 门禁 → 2a → A0 kext）"
  preflight

  say ""
  say "-- 0.1 找 EFI 分区 --"
  ESP_MOUNT=""
  CAND=$(diskutil list 2>/dev/null | awk '/OCEFI/ {print $NF}' | sort -u)
  CNT=$(printf '%s\n' "${CAND}" | grep -c . 2>/dev/null || true)
  if [ "${CNT}" -eq 1 ]; then
    diskutil mount "${CAND}" >/dev/null 2>&1 || true
    MP=$(diskutil info "${CAND}" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2}')
    [ -n "${MP}" ] && [ -d "${MP}" ] && ESP_MOUNT=${MP}
  fi
  [ -n "${ESP_MOUNT}" ] || die 0 "找不到/挂不上 OCEFI 分区（候选数 ${CNT}）"
  both "  EFI：${ESP_MOUNT}"

  say ""
  say "-- 0.2 KC 门禁（必须 PASS）--"
  if sh "${HERE}/05-kcgate.sh" >> "${LOG}" 2>&1; then
    both "  KC 门禁：PASS"
  else
    RC=$?
    die 0 "KC 门禁未通过（rc=${RC}；GATE-INVALID 也按失败处理，别硬上）"
  fi

  say ""
  say "-- 0.3 部署 2a（失败会自动回滚）--"
  if sh "${HERE}/01-deploy.sh" --reinject >> "${LOG}" 2>&1; then
    both "  2a 部署完成"
  else
    die 0 "01-deploy 失败（脚本应已回滚；日志末尾有原因）"
  fi

  say ""
  say "-- 0.4 部署 A0 kext（可选步骤，失败不影响本趟采集）--"
  A0=""
  for cand in "${KIT}/kext/IGPULoadProbe/IGPULoadProbe.kext" "${REAL_HOME}/IGPULoadProbe.kext"; do
    [ -d "${cand}" ] && { A0=${cand}; break; }
  done
  if [ -z "${A0}" ]; then
    soft "没找到 IGPULoadProbe.kext，跳过 A0（2a 采集照常）"
  elif cp -R "${A0}" "${ESP_MOUNT}/EFI/OC/Kexts/" >> "${LOG}" 2>&1 \
    && python3 "${KIT}/tools/add-kext-entry.py" --config "${ESP_MOUNT}/EFI/OC/config.plist" --name IGPULoadProbe >> "${LOG}" 2>&1 \
    && python3 "${KIT}/tools/add-kext-entry.py" --config "${ESP_MOUNT}/EFI/OC/config.plist" --name IGPULoadProbe --check >> "${LOG}" 2>&1; then
    both "  A0 kext 已就位"
  else
    soft "A0 部署失败（可能是 config 结构不同）；下次开机跳过 A0 判定即可"
  fi

  printf '%s\n' 1 > "${STATE}"
  say ""
  say "=========================================================="
  say " 下一步：重启这台机器（不要改任何开关）"
  say " 开机登录后，再跑同一条命令："
  say "     sudo sh onsite/20-dell-trip.sh"
  say "=========================================================="
  exit 0
fi

# ================= 阶段 1 =================
if [ "${PHASE}" -eq 1 ]; then
  say ""
  say "[阶段 1] 第 1 轮采集（normal）+ A0 判定 + A1 基线"

  if sh "${HERE}/02-collect.sh" >> "${LOG}" 2>&1; then
    both "  第 1 轮采集完成"
  else
    [ "${CONTINUE_ON_ERROR}" -eq 1 ] || die 1 "02-collect 第 1 轮失败"
    soft "第 1 轮采集失败，按 --continue-on-error 继续"
  fi

  say ""
  if [ -f "${HERE}/12-loadprobe-check.sh" ]; then
    if sh "${HERE}/12-loadprobe-check.sh" >> "${LOG}" 2>&1; then
      both "  A0：LOADED（kext 加载成功）"
    else
      soft "A0 未通过（详见日志 RESULT 行；不影响后续采集）"
    fi
  else
    soft "没有 12-loadprobe-check.sh，跳过 A0 判定"
  fi

  say ""
  if [ -f "${HERE}/13-fb-describe.sh" ]; then
    if sh "${HERE}/13-fb-describe.sh" --outdir "${REAL_HOME}/results-fbdescribe-$(date -u '+%Y%m%dT%H%M%SZ')" >> "${LOG}" 2>&1; then
      both "  A1 基线采集完成"
    else
      soft "A1 采集异常（不影响 2a）"
    fi
  else
    soft "没有 13-fb-describe.sh，跳过 A1"
  fi

  say ""
  say "-- 切到 off 模式 --"
  if sh "${HERE}/04-state.sh" off >> "${LOG}" 2>&1; then
    both "  已切 off"
  else
    die 1 "切 off 失败（这一轮必须成功，否则 3 轮判物不完整）"
  fi

  printf '%s\n' 2 > "${STATE}"
  say ""
  say "=========================================================="
  say " 下一步：重启"
  say " 开机登录后，再跑同一条命令："
  say "     sudo sh onsite/20-dell-trip.sh"
  say "=========================================================="
  exit 0
fi

# ================= 阶段 2 =================
if [ "${PHASE}" -eq 2 ]; then
  say ""
  say "[阶段 2] 第 2 轮采集（off 模式）"
  if sh "${HERE}/02-collect.sh" >> "${LOG}" 2>&1; then
    both "  第 2 轮采集完成"
  else
    [ "${CONTINUE_ON_ERROR}" -eq 1 ] || die 2 "02-collect 第 2 轮失败"
    soft "第 2 轮采集失败，按 --continue-on-error 继续"
  fi
  printf '%s\n' 3 > "${STATE}"
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

# ================= 阶段 3 =================
if [ "${PHASE}" -eq 3 ]; then
  say ""
  say "[阶段 3] 第 3 轮采集（normal，兼断电冷启证据）"
  if sh "${HERE}/02-collect.sh" >> "${LOG}" 2>&1; then
    both "  第 3 轮采集完成"
  else
    [ "${CONTINUE_ON_ERROR}" -eq 1 ] || die 3 "02-collect 第 3 轮失败"
    soft "第 3 轮采集失败，按 --continue-on-error 继续"
  fi

  say ""
  say "-- 导出 --"
  export_results || true

  printf '%s\n' 4 > "${STATE}"
  say ""
  say "=========================================================="
  say " 全部完成 ✓"
  say ""
  say " 采集到的（阶段 3 结束时的清单）："
  for f in "${KIT}"/results-collect-*; do
    [ -d "$f" ] && say "   $f"
  done
  for f in "${REAL_HOME}"/results-fbdescribe-*; do
    [ -d "$f" ] && say "   $f"
  done
  say ""
  say " 把上面这些目录（或导出到 U 盘/桌面的压缩包）带回来即可；"
  say " 日志也一起：${LOG}"
  say "=========================================================="
  exit 0
fi

# ================= 阶段 4 =================
if [ "${PHASE}" -ge 4 ]; then
  say ""
  say "本趟已完成（阶段 ${PHASE}）。"
  say "把采集目录与 ${LOG} 带回来即可。"
  say "要重跑整趟：sudo sh onsite/20-dell-trip.sh --reset"
  exit 0
fi