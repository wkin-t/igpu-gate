#!/bin/sh
# adl-s-field.sh —— ADL-S 8086:4680 现场一条命令（P1 开机隔离 + P2 只激活加速器）
#
#   sudo sh adl-s-field.sh              按当前阶段自动推进一步
#   sh adl-s-field.sh --status          看进度（不需要 root）
#   sudo sh adl-s-field.sh --rollback   一键回到部署前（config 还原、kext 撤出）
#
# 阶段：start → config-applied（重启）→ installed（重启）→ p1-pass → p2-pass
#       失败终态：p1-failed / p2-failed / p2-crashed / install-failed（都保留证据，都可 --rollback）
#
# 为什么分三次：SIP 放宽要重启才生效，未放宽时 kmutil 不收未签名 kext；AuxKC 也要重启才加载。
# 为什么 P2 失败能自愈：运行时匹配规则只活在本次开机的 IOCatalogue 里，重启即回到 P1 状态。
#
# 一律写 ${VAR}：macOS bash 3.2 会把紧邻的中文字节并进变量名（set -u 下直接退出）。
set -u

SELF=$0
FIELD_DIR=$(cd "$(dirname "$0")" && pwd -P)
FORK_SRC=${IGPU_FORK_SRC:-$(cd "${FIELD_DIR}/.." && pwd -P)}
PREBUILT="${FORK_SRC}/prebuilt"
ROOT=${IGPU_FIELD_ROOT:-/var/igpu-adl-s}
EXT_DIR=${IGPU_EXT_DIR:-/Library/Extensions}
TGL_INPUT=${IGPU_TGL_INPUT:-/Volumes/CLONEZILLA/igpu-tgl-input/AppleIntelTGLGraphics.kext}
EVIDENCE_ROOT=${IGPU_EVIDENCE_ROOT:-/Volumes/CLONEZILLA/igpu}
PANIC_DIR=${IGPU_PANIC_DIR:-/Library/Logs/DiagnosticReports}
EXPECT_BUILD=25G83
EXPECT_DEVICE=80460000
EXPECT_REVISION=0c000000
EXPECT_VENDOR=86800000
EXPECT_VOL=OCEFI
EXPECT_OFF=1048576
CSR_RELAXED=430a0000
TGL_ID=com.apple.driver.AppleIntelTGLGraphics
GATE_NAME=ReimsADLManualActivation.kext
RUNTIME_NAME=ReimsTGLBoot.kext
FIX_REL=desktop-manual-20260917/fix

STATE_FILE="${ROOT}/STAGE"
BOOT_FILE="${ROOT}/BOOT"
BACKUP_POINTER="${ROOT}/BACKUP"
TS=$(date +%Y%m%d-%H%M%S)
EV=""
MOUNT_POINT=""
ESP_DEV=""

PY=""
for _c in python3 python; do
  if command -v "${_c}" >/dev/null 2>&1 \
     && "${_c}" -c 'import plistlib, json, hashlib, argparse' >/dev/null 2>&1; then
    PY=${_c}; break
  fi
done

log() {
  printf '%s\n' "$1"
  if [ -n "${EV}" ]; then printf '%s\n' "$1" >> "${EV}/transcript.txt" 2>/dev/null; fi
}

take_sha() { _o=$(shasum -a 256 "$1" 2>/dev/null) || return 1; printf '%s' "${_o}" | awk '{print $1}'; }
kv() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }
stage() { if [ -f "${STATE_FILE}" ]; then head -1 "${STATE_FILE}"; else printf 'start\n'; fi; }
set_stage() { printf '%s\n' "$1" > "${STATE_FILE}" || die "写阶段文件失败：${STATE_FILE}"; sync; }
boot_id() { sysctl -n kern.bootsessionuuid 2>/dev/null; }
record_boot() { boot_id > "${BOOT_FILE}" || die "记录开机标识失败"; sync; }
same_boot() { [ -f "${BOOT_FILE}" ] && [ "$(head -1 "${BOOT_FILE}")" = "$(boot_id)" ]; }

summary() { [ -n "${EV}" ] && printf '%s\n' "$1" >> "${EV}/summary.txt"; }

die() {
  log ""
  log "[中止] $1"
  summary "result=stopped"
  summary "reason=$1"
  [ -n "${EV}" ] && log "证据目录：${EV}"
  unmount_esp
  exit "${2:-1}"
}

open_evidence() {
  _base=${EVIDENCE_ROOT}
  if ! mkdir -p "${_base}" 2>/dev/null || [ ! -w "${_base}" ]; then _base="${ROOT}/evidence"; fi
  mkdir -p "${_base}" || { printf '无法创建证据目录 %s\n' "${_base}" >&2; exit 1; }
  EV="${_base}/results-adl-s-$1-${TS}"
  mkdir -p "${EV}" || { printf '无法创建证据目录 %s\n' "${EV}" >&2; exit 1; }
  summary "phase=$1"
  summary "started=${TS}"
  summary "stage_at_start=$(stage)"
}

capture() {  # capture <文件名> <命令...>：保存输出，返回命令退出码
  _name=$1; shift
  "$@" > "${EV}/${_name}" 2>&1
}

snapshot_gfx() {  # snapshot_gfx <文件名>：抓 GFX0 子树并打印解析结果
  ioreg -r -n GFX0 -l -a > "${EV}/$1" 2>"${EV}/$1.err" || return 1
  "${PY}" "${FIELD_DIR}/field_check.py" gfx "${EV}/$1"
}

locate_esp() {
  _cand=$(diskutil list 2>/dev/null | awk -v v="${EXPECT_VOL}" '$0 ~ v {print $NF}' | sort -u)
  _n=$(printf '%s\n' "${_cand}" | grep -c . 2>/dev/null || true)
  [ "${_n}" -eq 1 ] || die "${EXPECT_VOL} 候选数=${_n}（必须恰好 1 个）"
  _info=$(diskutil info "${_cand}" 2>/dev/null)
  _vol=$(printf '%s\n' "${_info}" | awk -F': *' '/Volume Name/ {print $2}')
  _off=$(printf '%s\n' "${_info}" | awk -F': *' '/Partition Offset/ {print $2}' | awk '{print $1}')
  [ "${_vol}" = "${EXPECT_VOL}" ] || die "卷名不符：${_vol}"
  [ "${_off}" = "${EXPECT_OFF}" ] || die "分区偏移不符：${_off}"
  ESP_DEV=${_cand}
  diskutil mount "${ESP_DEV}" >/dev/null 2>&1 || true
  MOUNT_POINT=$(diskutil info "${ESP_DEV}" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2}')
  [ -n "${MOUNT_POINT}" ] && [ -d "${MOUNT_POINT}" ] || die "ESP 挂载失败"
  [ -f "${MOUNT_POINT}/EFI/OC/config.plist" ] || die "ESP 上没有 EFI/OC/config.plist"
  log "ESP ${ESP_DEV} ${_vol}/${_off} 挂载于 ${MOUNT_POINT}"
}

unmount_esp() {
  if [ -n "${ESP_DEV}" ]; then
    sync
    diskutil unmount "${ESP_DEV}" >/dev/null 2>&1 || log "⚠ ESP 卸载失败（内容已写入），可手动：diskutil unmount ${ESP_DEV}"
    ESP_DEV=""
  fi
}

# ---- 第 1 步：只改 OC 配置 --------------------------------------------------
do_config() {
  open_evidence config
  log "== 第 1 步：预检并写入 OpenCore 增量（改完需重启）=="
  [ -n "${PY}" ] || die "找不到可用的 python3（需要 Xcode Command Line Tools）"
  _build=$(sw_vers -buildVersion 2>/dev/null)
  [ "${_build}" = "${EXPECT_BUILD}" ] || die "系统版本 ${_build}，要求 ${EXPECT_BUILD}"
  _gfx=$(snapshot_gfx gfx-before.plist) || die "读不到 GFX0"
  printf '%s\n' "${_gfx}" > "${EV}/gfx-before.txt"
  [ "$(kv "${_gfx}" vendor_id)" = "${EXPECT_VENDOR}" ] || die "vendor-id 不符：$(kv "${_gfx}" vendor_id)"
  [ "$(kv "${_gfx}" device_id)" = "${EXPECT_DEVICE}" ] || die "device-id 不符：$(kv "${_gfx}" device_id)（要求未隔离的 0x4680）"
  [ "$(kv "${_gfx}" revision_id)" = "${EXPECT_REVISION}" ] || die "revision-id 不符：$(kv "${_gfx}" revision_id)"

  _home=$(eval printf '%s' "~${SUDO_USER:-root}")
  _mark=${IGPU_RECOVERY_MARK:-${_home}/RECOVERY-EFI-VERIFIED.txt}
  [ -f "${_mark}" ] || die "没有 ${_mark}：恢复 EFI 还没人工验证过（门 G4）。验证后执行 echo ok > ${_mark}"

  "${PY}" "${FIELD_DIR}/field_check.py" tgl-input "${TGL_INPUT}" >> "${EV}/transcript.txt" 2>&1 \
    || die "TGL 原料不对或缺失：${TGL_INPUT}"
  capture tgl-check.json "${PY}" "${FORK_SRC}/${FIX_REL}/prepare-deferred-runtime.py" --check-only "${TGL_INPUT}" \
    || die "TGL 原料未通过结构断言（详见 tgl-check.json）"
  log "TGL 原料结构断言通过"
  for _f in "${PREBUILT}/${GATE_NAME}/Contents/Info.plist" "${PREBUILT}/control" "${PREBUILT}/manual-gate-current.json"; do
    [ -f "${_f}" ] || die "缺预编译产物：${_f}"
  done
  "${PY}" "${FIELD_DIR}/field_check.py" receipt "${PREBUILT}/${GATE_NAME}" "${PREBUILT}/manual-gate-current.json" \
    >> "${EV}/transcript.txt" 2>&1 || die "预编译 kext 与收据不符"

  locate_esp
  _cfg="${MOUNT_POINT}/EFI/OC/config.plist"
  capture delta-check.txt "${PY}" "${FIELD_DIR}/oc_delta.py" check --config "${_cfg}" \
    || die "当前配置不能接受增量（详见 delta-check.txt）"

  _before=$(take_sha "${_cfg}") || die "读不到 config 哈希"
  _bk="${MOUNT_POINT}/igpu-fork-backup-${TS}-$$"
  mkdir "${_bk}" || die "无法创建 ESP 备份目录"
  cp "${_cfg}" "${_bk}/config.plist" || die "备份 config 失败"
  [ "$(take_sha "${_bk}/config.plist")" = "${_before}" ] || die "备份 config 哈希不符"
  mkdir -p "${ROOT}/config-backups" || die "无法创建本地备份目录"
  cp "${_cfg}" "${ROOT}/config-backups/config-${TS}.plist" || die "本地备份 config 失败"
  printf 'STATE=complete\nconfig_before_sha=%s\n' "${_before}" > "${_bk}/META" || die "写备份 META 失败"
  cp "${_cfg}" "${EV}/config-before.plist.txt" 2>/dev/null
  printf '%s\n%s\n' "$(basename "${_bk}")" "${_before}" > "${BACKUP_POINTER}" || die "写备份指针失败"
  log "改前备份：${_bk}（${_before}）"

  _staged="${_cfg}.staged-$$"
  if ! capture delta-apply.txt "${PY}" "${FIELD_DIR}/oc_delta.py" apply --config "${_cfg}" --out "${_staged}"; then
    rm -f "${_staged}"
    die "生成增量配置失败（现网未动，详见 delta-apply.txt）"
  fi
  _new=$(take_sha "${_staged}") || die "读不到暂存配置哈希"
  mv "${_staged}" "${_cfg}" || die "替换 config 失败（现网未动）"
  if [ "$(take_sha "${_cfg}")" != "${_new}" ] \
     || ! capture delta-verify.txt "${PY}" "${FIELD_DIR}/oc_delta.py" verify --config "${_cfg}" --orig "${_bk}/config.plist"; then
    cp "${_bk}/config.plist" "${_cfg}"
    die "替换后复核失败，已还原改前配置"
  fi
  log "配置已更新：${_before} → ${_new}"
  log "⚠ SIP 放宽是整机设置，Sonoma 也一起放宽（已确认接受）；--rollback 可恢复 00000000。"
  unmount_esp
  record_boot
  set_stage config-applied
  summary "result=ok"
  log ""
  log "下一步：重启进 Tahoe（sudo reboot），然后再跑同一条命令。"
  log "证据目录：${EV}"
}

# ---- 第 2 步：SIP 生效后安装 kext -------------------------------------------
restore_install() {  # 把已放进 Extensions 的 kext 撤到备份目录，不删除
  _dest="${ROOT}/removed-$1-${TS}"
  for _k in "${GATE_NAME}" "${RUNTIME_NAME}"; do
    if [ -d "${EXT_DIR}/${_k}" ]; then
      mkdir -p "${_dest}" && mv "${EXT_DIR}/${_k}" "${_dest}/" && log "已撤出 ${_k} → ${_dest}"
    fi
  done
}

do_install() {
  if same_boot; then
    log "配置已写入，但还没重启。请先 sudo reboot，再跑同一条命令。"
    exit 3
  fi
  open_evidence install
  log "== 第 2 步：确认 SIP 与隔离已生效，安装到 AuxKC（改完需重启）=="
  [ -n "${PY}" ] || die "找不到可用的 python3"
  nvram -x csr-active-config > "${EV}/nvram-csr.plist" 2>&1 || die "读不到 csr-active-config"
  _csr=$("${PY}" "${FIELD_DIR}/field_check.py" nvdata "${EV}/nvram-csr.plist" csr-active-config)
  [ "$(kv "${_csr}" csr-active-config)" = "${CSR_RELAXED}" ] \
    || die "SIP 未按预期放宽：$(kv "${_csr}" csr-active-config)（配置没生效，kext 未安装）"
  _args=$(sysctl -n kern.bootargs 2>/dev/null)
  printf '%s\n' "${_args}" > "${EV}/bootargs.txt"
  case " ${_args} " in *" -allow3d "*) : ;; *) die "boot-args 没有 -allow3d（配置没生效，kext 未安装）" ;; esac
  _gfx=$(snapshot_gfx gfx-isolated.plist) || die "读不到 GFX0"
  printf '%s\n' "${_gfx}" > "${EV}/gfx-isolated.txt"
  [ "$(kv "${_gfx}" device_id)" = "ffff0000" ] || die "隔离未生效：device-id=$(kv "${_gfx}" device_id)（kext 未安装）"
  [ "$(kv "${_gfx}" firmware_fb)" = "1" ] || die "固件帧缓冲不是 1 个：$(kv "${_gfx}" firmware_fb)（kext 未安装）"

  _fork="${ROOT}/fork"
  if [ -d "${_fork}" ]; then mv "${_fork}" "${ROOT}/fork-old-${TS}" || die "无法移开旧工作树"; fi
  _input="${ROOT}/tgl-input-${TS}/AppleIntelTGLGraphics.kext"
  mkdir -p "$(dirname "${_input}")" || die "无法创建 TGL 工作副本目录"
  ditto --norsrc --noextattr --noqtn "${FORK_SRC}" "${_fork}" 2>"${EV}/ditto-fork.err" || die "复制工作树失败"
  ditto --norsrc --noextattr --noqtn "${TGL_INPUT}" "${_input}" 2>"${EV}/ditto-tgl.err" || die "复制 TGL 原料失败"
  # 交换盘是 FAT32：AppleDouble 碎片会让 codesign --strict 失败
  find "${_fork}" "${_input}" -name '._*' -type f -exec rm -f {} + 2>/dev/null
  find "${_fork}" "${_input}" -name '.DS_Store' -type f -exec rm -f {} + 2>/dev/null

  _fix="${_fork}/${FIX_REL}"
  cp "${PREBUILT}/manual-gate-current.json" "${_fix}/manual-gate-current.json" || die "写收据失败"
  cp "${PREBUILT}/control" "${_fix}/manual-gate/control" || die "写控制工具失败"
  chmod 755 "${_fix}/manual-gate/control" || die "chmod 控制工具失败"
  capture prepare.json "${PY}" "${_fix}/prepare-deferred-runtime.py" "${_input}" \
    || die "打补丁失败（kext 未安装，详见 prepare.json）"
  log "TGL 运行时已生成并签名"

  if [ -e "${EXT_DIR}/${RUNTIME_NAME}" ] || [ -e "${EXT_DIR}/${GATE_NAME}" ]; then
    die "${EXT_DIR} 里已有同名 kext，拒绝覆盖（先 --rollback）"
  fi
  if ! ditto --norsrc --noextattr --noqtn "${_fix}/ReimsTGLManualRuntime.kext" "${EXT_DIR}/${RUNTIME_NAME}" 2>"${EV}/ditto-rt.err" \
     || ! ditto --norsrc --noextattr --noqtn "${PREBUILT}/${GATE_NAME}" "${EXT_DIR}/${GATE_NAME}" 2>"${EV}/ditto-gate.err"; then
    restore_install copy-failed
    set_stage install-failed
    die "复制 kext 失败，已撤出"
  fi
  for _k in "${RUNTIME_NAME}" "${GATE_NAME}"; do
    chown -R root:wheel "${EXT_DIR}/${_k}" && chmod -R go-w "${EXT_DIR}/${_k}" || {
      restore_install chown-failed; set_stage install-failed; die "设置 ${_k} 权限失败，已撤出"; }
  done
  if ! capture kmutil-install.txt kmutil install --update-all; then
    restore_install kmutil-failed
    capture kmutil-after-withdraw.txt kmutil install --update-all
    set_stage install-failed
    die "kmutil 重建 AuxKC 失败，kext 已撤出（详见 kmutil-install.txt）"
  fi
  capture csrutil.txt csrutil status
  log "AuxKC 已重建"
  record_boot
  set_stage installed
  summary "result=ok"
  log ""
  log "下一步：重启进 Tahoe（sudo reboot），然后再跑同一条命令。"
  log "若系统设置里弹出“系统软件已被阻止”，先批准再重启。"
  log "证据目录：${EV}"
}

# ---- 第 3 步：P1 判定 -------------------------------------------------------
do_p1() {
  if same_boot; then
    log "kext 已安装，但还没重启。请先 sudo reboot，再跑同一条命令。"
    exit 3
  fi
  open_evidence p1
  log "== 第 3 步：P1 判定（开机隔离 + AuxKC 已加载，GPU 不动）=="
  _fix="${ROOT}/fork/${FIX_REL}"
  capture showloaded.txt kmutil showloaded || die "kmutil showloaded 失败"
  capture kmutil-aux.txt kmutil showloaded --collection aux
  _gfx=$(snapshot_gfx gfx-p1.plist) || die "读不到 GFX0"
  printf '%s\n' "${_gfx}" > "${EV}/gfx-p1.txt"
  _rt_uuid=$("${PY}" "${FIELD_DIR}/field_check.py" json-field "${_fix}/deferred-runtime.json" candidate_uuid) || die "读不到运行时收据"
  _gate_uuid=$("${PY}" "${FIELD_DIR}/field_check.py" json-field "${_fix}/manual-gate-current.json" uuid) || die "读不到控制器收据"
  _gate_id=$("${PY}" "${FIELD_DIR}/field_check.py" json-field "${_fix}/manual-gate-current.json" identifier) || die "读不到控制器标识"
  _rt=$(kv "$("${PY}" "${FIELD_DIR}/field_check.py" loaded "${EV}/showloaded.txt" "${TGL_ID}" "${_rt_uuid}")" loaded)
  _gate=$(kv "$("${PY}" "${FIELD_DIR}/field_check.py" loaded "${EV}/showloaded.txt" "${_gate_id}" "${_gate_uuid}")" loaded)
  summary "runtime_loaded=${_rt}"
  summary "controller_loaded=${_gate}"
  summary "$(printf '%s' "${_gfx}" | tr '\n' ' ')"
  _why=""
  [ "${_rt}" = "yes" ] || _why="${_why} TGL运行时加载状态=${_rt}"
  [ "${_gate}" = "yes" ] || _why="${_why} 控制器加载状态=${_gate}"
  [ "$(kv "${_gfx}" device_id)" = "ffff0000" ] || _why="${_why} device-id=$(kv "${_gfx}" device_id)"
  [ "$(kv "${_gfx}" firmware_fb)" = "1" ] || _why="${_why} 固件帧缓冲=$(kv "${_gfx}" firmware_fb)"
  [ "$(kv "${_gfx}" accelerator)" = "0" ] || _why="${_why} 加速器已存在=$(kv "${_gfx}" accelerator)"
  [ "$(kv "${_gfx}" native_fb)" = "0" ] || _why="${_why} 原生帧缓冲=$(kv "${_gfx}" native_fb)"
  if [ -n "${_why}" ]; then
    set_stage p1-failed
    summary "P1=FAIL"
    die "P1 未通过：${_why}"
  fi
  record_boot
  set_stage p1-pass
  summary "P1=PASS"
  summary "result=ok"
  log ""
  log "P1 通过：kext 已加载、GPU 未被驱动、桌面仍走 IONDRV。"
  log "下一步是 P2，可能导致死机重启（重启后自动回到现在的状态）。"
  log "请先保存所有工作，再跑同一条命令。"
  log "证据目录：${EV}"
}

# ---- 第 4 步：P2 只激活加速器 ------------------------------------------------
do_p2() {
  open_evidence p2
  log "== 第 4 步：P2 只激活加速器（显示仍走 IONDRV，不重启桌面）=="
  record_boot
  # 先落盘再动 GPU：一旦死机，下次运行靠这个标记认出是 P2 崩的
  set_stage p2-attempted
  summary "attempt_boot=$(boot_id)"
  sync
  _fork="${ROOT}/fork"
  /bin/sh "${_fork}/igpu-start" --accel-only > "${EV}/igpu-start.txt" 2>&1
  _rc=$?
  summary "igpu_start_rc=${_rc}"
  _session=$(ls -dt "${_fork}/${FIX_REL}"/session-*-accel-only 2>/dev/null | head -1)
  if [ -n "${_session}" ]; then cp -R "${_session}" "${EV}/session" 2>/dev/null; fi
  _gfx=$(snapshot_gfx gfx-p2.plist) || _gfx=""
  printf '%s\n' "${_gfx}" > "${EV}/gfx-p2.txt"
  if [ "${_rc}" -ne 0 ] || [ ! -f "${EV}/session/result.json" ]; then
    set_stage p2-failed
    summary "P2=FAIL"
    die "P2 未通过：加速器没有进入隐藏就绪（退出码 ${_rc}）。重启即可回到 P1 状态。"
  fi
  _hw=$("${PY}" "${FIELD_DIR}/field_check.py" hwcaps "${EV}/session/igpu-log.txt" 2>&1)
  printf '%s\n' "${_hw}" > "${EV}/hwcaps.txt"
  if [ "$(kv "${_hw}" hwcaps)" != "ok" ]; then
    set_stage p2-failed
    summary "P2=PARTIAL"
    die "P2 部分通过：加速器起来了，但硬件能力日志不符（详见 hwcaps.txt）。"
  fi
  set_stage p2-pass
  summary "P2=PASS"
  summary "result=ok"
  log ""
  log "P2 通过：加速器隐藏就绪，SKU/EU/L3 日志符合预期，桌面未受影响。"
  log "请把证据目录带回：${EV}"
}

do_p2_crash_check() {
  if same_boot; then
    log "上次 P2 没有跑完但没有死机，重新执行。"
    do_p2
    return
  fi
  open_evidence p2-crash
  log "== 检测到 P2 期间机器重启：收集崩溃证据 =="
  mkdir -p "${EV}/panic"
  for _p in "${PANIC_DIR}"/*.panic "${PANIC_DIR}"/Kernel*; do
    [ -f "${_p}" ] && cp "${_p}" "${EV}/panic/" 2>/dev/null
  done
  capture nvram-panic.txt nvram -p
  capture log-previous-boot.txt log show --last boot --predicate 'eventMessage CONTAINS "[IGPU]"' --style compact
  _n=$(ls "${EV}/panic" 2>/dev/null | wc -l | tr -d ' ')
  set_stage p2-crashed
  summary "panic_files=${_n}"
  summary "P2=CRASHED"
  summary "result=stopped"
  log "P2 期间机器崩溃重启，收集到 ${_n} 份崩溃报告。不要重试，把证据目录带回分析。"
  log "证据目录：${EV}"
  exit 1
}

# ---- 回滚 -------------------------------------------------------------------
do_rollback() {
  open_evidence rollback
  log "== 回滚：还原 config、撤出 kext（SIP 恢复 00000000，重启后生效）=="
  [ -n "${PY}" ] || die "找不到可用的 python3"
  if [ -f "${BACKUP_POINTER}" ]; then
    _name=$(sed -n 1p "${BACKUP_POINTER}")
    _sha=$(sed -n 2p "${BACKUP_POINTER}")
    locate_esp
    _bk="${MOUNT_POINT}/${_name}"
    _cfg="${MOUNT_POINT}/EFI/OC/config.plist"
    [ -f "${_bk}/config.plist" ] || die "备份不存在：${_bk}"
    grep -q '^STATE=complete' "${_bk}/META" 2>/dev/null || die "备份不完整：${_bk}"
    [ "$(take_sha "${_bk}/config.plist")" = "${_sha}" ] || die "备份哈希不符，拒绝还原：${_bk}"
    _staged="${_cfg}.restore-$$"
    cp "${_bk}/config.plist" "${_staged}" || die "复制备份失败（现网未动）"
    mv "${_staged}" "${_cfg}" || die "还原 config 失败（现网未动）"
    [ "$(take_sha "${_cfg}")" = "${_sha}" ] || die "还原后哈希不符，请手工用 ${_bk}/config.plist 覆盖"
    log "config 已还原：${_sha}（备份保留在 ${_bk}）"
    unmount_esp
  else
    log "没有配置备份记录：配置未被本工具改过，跳过。"
  fi
  _had=no
  if [ -d "${EXT_DIR}/${GATE_NAME}" ] || [ -d "${EXT_DIR}/${RUNTIME_NAME}" ]; then _had=yes; fi
  restore_install rollback
  if [ "${_had}" = "yes" ]; then
    capture kmutil-rollback.txt kmutil install --update-all \
      || log "⚠ kmutil 重建失败（kext 已撤出、配置已还原；AuxKC 里残留的 kext 没有自动匹配规则，不影响开机）"
  fi
  rm -f "${BACKUP_POINTER}"
  set_stage start
  summary "result=rolled-back"
  log ""
  log "回滚完成。重启后 SIP 恢复全开、GPU 回到未隔离状态：sudo reboot"
  log "证据目录：${EV}"
}

show_status() {
  printf 'stage=%s\n' "$(stage)"
  if [ -f "${BACKUP_POINTER}" ]; then printf 'backup=%s\n' "$(sed -n 1p "${BACKUP_POINTER}")"; fi
  case "$(stage)" in
    start) printf 'next=sudo sh %s（写入 OC 配置）\n' "${SELF}" ;;
    config-applied) printf 'next=重启后再跑一次（安装 kext）\n' ;;
    installed) printf 'next=重启后再跑一次（P1 判定）\n' ;;
    p1-pass) printf 'next=保存工作后再跑一次（P2）\n' ;;
    p2-pass) printf 'next=把证据带回；不再需要操作\n' ;;
    *) printf 'next=把证据带回；可 sudo sh %s --rollback 回到部署前\n' "${SELF}" ;;
  esac
}

case "${1:-}" in
  --status) show_status; exit 0 ;;
  --rollback|"") : ;;
  *) printf '用法：sudo sh %s [--status|--rollback]\n' "${SELF}" >&2; exit 64 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then exec sudo /bin/sh "${SELF}" "$@"; fi
  printf '需要管理员权限：sudo sh %s\n' "${SELF}" >&2
  exit 77
fi
mkdir -p "${ROOT}" || { printf '无法创建 %s\n' "${ROOT}" >&2; exit 1; }
chmod 700 "${ROOT}" 2>/dev/null

if [ "${1:-}" = "--rollback" ]; then do_rollback; exit 0; fi

case "$(stage)" in
  start) do_config ;;
  config-applied) do_install ;;
  installed) do_p1 ;;
  p1-pass) do_p2 ;;
  p2-attempted) do_p2_crash_check ;;
  p2-pass) log "P2 已通过，无需再跑。"; show_status ;;
  *) log "当前阶段 $(stage) 是失败终态，不自动重试。"; show_status; exit 1 ;;
esac
