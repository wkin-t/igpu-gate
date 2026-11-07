#!/bin/sh
# adl-s-field.sh —— ADL-S 8086:4680 现场一条命令（P1 开机隔离 + P2 只激活加速器）
#
#   sudo sh adl-s-field.sh              按当前阶段自动推进一步
#   sudo sh adl-s-field.sh --status     看进度（状态目录只有 root 可读，不带 sudo 也会自动提权）
#   sudo sh adl-s-field.sh --rollback   一键回到部署前（先撤 kext，再还原 config）
#
# 阶段：start → config-applied（重启）→ installed（重启）→ p1-pass → p2-pass
#       失败终态：p1-failed / p2-failed / p2-crashed / install-failed / config-interrupted /
#                 rollback-incomplete（都保留证据，都可 --rollback）
#       p2-interrupted：P2 被 Ctrl-C/关终端打断，不是崩溃；重启后重跑会先复核 P1
#
# 为什么分三次：SIP 放宽要重启才生效，未放宽时 kmutil 不收未签名 kext；AuxKC 也要重启才加载。
# 为什么 P2 失败能自愈：运行时匹配规则只活在本次开机的 IOCatalogue 里，重启即回到 P1 状态。
#
# 一律写 ${VAR}：macOS bash 3.2 会把紧邻的中文字节并进变量名（set -u 下直接退出）。
set -u

SELF=$0
FIELD_DIR=$(cd "$(dirname "$0")" && pwd -P)
# 辅助脚本先复制到 root 专属目录再执行：交换盘是 FAT32，任何人都能改那里的文件
TOOLS=${FIELD_DIR}
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
# 必须与 manual-gate/gate.cpp 的 kPCIPath 逐字一致：控制器用 strcmp 比对，不符时 SelfTest 永远起不来
EXPECT_GFX_PATH='IOService:/AppleACPIPlatformExpert/PC00/AppleACPIPCI/GFX0@2'
OC_VENDOR_GUID=4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102
# 0x3 = CSR_ALLOW_UNTRUSTED_KEXTS | CSR_ALLOW_UNRESTRICTED_FS。不含 0x200（UNAPPROVED_KEXTS）：
# 第三方 kext 可能要在“系统设置”里批准，未经真机验证；P1 失败时会抓 kernelmanagerd 日志区分
CSR_RELAXED=03000000
TGL_ID=com.apple.driver.AppleIntelTGLGraphics
GATE_NAME=ReimsADLManualActivation.kext
RUNTIME_NAME=ReimsTGLBoot.kext
FIX_REL=desktop-manual-20260917/fix

STATE_FILE="${ROOT}/STAGE"
BOOT_FILE="${ROOT}/BOOT"
BACKUP_POINTER="${ROOT}/BACKUP"
ESP_UUID_FILE="${ROOT}/ESP_UUID"
P2_MARK="${ROOT}/P2_ATTEMPT"
KMUTIL_DIRTY="${ROOT}/KMUTIL_DIRTY"
TS=$(date +%Y%m%d-%H%M%S)
EV=""
MOUNT_POINT=""
ESP_DEV=""
ESP_ERR=""
STEP=""
CONFIG_PATH=""
CONFIG_STAGED=""
CONFIG_BEFORE=""
ROLLBACK_BAD=""

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

summary() { if [ -n "${EV}" ]; then printf '%s\n' "$1" >> "${EV}/summary.txt"; fi; }

die() {
  log ""
  log "[中止] $1"
  summary "result=stopped"
  summary "reason=$1"
  if [ -n "${EV}" ]; then log "证据目录：${EV}"; fi
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
  _cap=$1; shift
  "$@" > "${EV}/${_cap}" 2>&1
}

snapshot_gfx() {  # snapshot_gfx <文件名>：抓 GFX0 子树并打印解析结果
  ioreg -r -n GFX0 -l -a > "${EV}/$1" 2>"${EV}/$1.err" || return 1
  "${PY}" "${TOOLS}/field_check.py" gfx "${EV}/$1"
}

check_gfx_path() {  # check_gfx_path <文件名>：抓 IOService 平面整棵树，核对 GFX0 完整路径
  ioreg -p IOService -w0 > "${EV}/$1" 2>"${EV}/$1.err" || { printf 'gfx_path=ioreg-failed\ngfx_path_ok=no\n'; return 1; }
  "${PY}" "${TOOLS}/field_check.py" gfx-path "${EV}/$1" "${EXPECT_GFX_PATH}"
}

booted_esp_uuid() {
  # OC 只在 Misc/Security/ExposeSensitiveData 含 0x01 时才暴露本次启动分区（默认 6 = 0x2|0x4 不含）。
  # 取不到就输出空，由调用方退回"卷名唯一"；值若是 UTF-16，nvram 会打出 %00，同样提取失败、退回。
  nvram "${OC_VENDOR_GUID}:boot-path" 2>/dev/null \
    | sed -n 's/.*GPT,\([0-9A-Fa-f-]\{36\}\),.*/\1/p' | head -1
}

# 分区 UUID 跨开机稳定，磁盘号（disk9s1）不稳定，卷名也可能重复：一旦记录过 UUID，就只认它。
locate_esp() {  # 成功返回 0；失败把原因写进 ESP_ERR，由调用方决定中止（部署）还是继续（回滚）
  ESP_ERR=""
  _want=""; _src=""
  if [ -s "${ESP_UUID_FILE}" ]; then
    _want=$(head -1 "${ESP_UUID_FILE}"); _src=recorded
  else
    _want=$(booted_esp_uuid)
    if [ -n "${_want}" ]; then _src=boot-path; fi
  fi
  if [ -n "${_want}" ]; then
    _cand=${_want}
  else
    _src=volume-name
    _cand=$(diskutil list 2>/dev/null | awk -v v="${EXPECT_VOL}" '$0 ~ v {print $NF}' | sort -u)
    _n=$(printf '%s\n' "${_cand}" | grep -c . 2>/dev/null || true)
    if [ "${_n}" -ne 1 ]; then ESP_ERR="${EXPECT_VOL} 候选数=${_n}（必须恰好 1 个）"; return 1; fi
  fi
  _info=$(diskutil info "${_cand}" 2>/dev/null) || { ESP_ERR="diskutil info ${_cand} 失败（来源 ${_src}）"; return 1; }
  _vol=$(printf '%s\n' "${_info}" | awk -F': *' '/Volume Name/ {print $2}')
  _off=$(printf '%s\n' "${_info}" | awk -F': *' '/Partition Offset/ {print $2}' | awk '{print $1}')
  _uuid=$(printf '%s\n' "${_info}" | awk -F': *' '/Disk \/ Partition UUID/ {print $2}')
  if [ "${_vol}" != "${EXPECT_VOL}" ]; then ESP_ERR="卷名不符：${_vol}（来源 ${_src}）"; return 1; fi
  if [ "${_off}" != "${EXPECT_OFF}" ]; then ESP_ERR="分区偏移不符：${_off}（来源 ${_src}）"; return 1; fi
  if [ -z "${_uuid}" ]; then ESP_ERR="读不到分区 UUID：${_cand}"; return 1; fi
  if [ -n "${_want}" ] && [ "$(printf '%s' "${_uuid}" | tr 'a-f' 'A-F')" != "$(printf '%s' "${_want}" | tr 'a-f' 'A-F')" ]; then
    ESP_ERR="分区 UUID 不符：期望 ${_want}，实际 ${_uuid}"; return 1
  fi
  ESP_DEV=${_uuid}
  ESP_SRC=${_src}
  diskutil mount "${ESP_DEV}" >/dev/null 2>&1 || true
  MOUNT_POINT=$(diskutil info "${ESP_DEV}" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2}')
  if [ -z "${MOUNT_POINT}" ] || [ ! -d "${MOUNT_POINT}" ]; then ESP_ERR="ESP 挂载失败：${ESP_DEV}"; return 1; fi
  if [ ! -f "${MOUNT_POINT}/EFI/OC/config.plist" ]; then ESP_ERR="ESP 上没有 EFI/OC/config.plist"; return 1; fi
  log "ESP ${ESP_DEV} ${_vol}/${_off}（来源 ${_src}）挂载于 ${MOUNT_POINT}"
  return 0
}

unmount_esp() {
  if [ -n "${ESP_DEV}" ]; then
    sync
    diskutil unmount "${ESP_DEV}" >/dev/null 2>&1 || log "⚠ ESP 卸载失败（内容已写入），可手动：diskutil unmount ${ESP_DEV}"
    ESP_DEV=""
  fi
}

# 工作副本来自 FAT32 交换盘（所有人可写）。之后以 root 身份执行它，所以必须先收回写权限。
secure_tree() {
  chown -R root:wheel "$1" && chmod -R go-w "$1"
}

# ---- 信号：Ctrl-C / 关终端 / kill ---------------------------------------------
on_signal() {
  trap '' INT TERM HUP
  log ""
  log "[中断] 收到 $1（Ctrl-C 或终端被关闭），这不是崩溃。当前步骤：${STEP:-无}"
  summary "interrupted_by=$1"
  summary "interrupted_step=${STEP:-none}"
  case "${STEP}" in
    config)
      if [ -n "${CONFIG_STAGED}" ]; then rm -f "${CONFIG_STAGED}"; fi
      if [ -n "${CONFIG_BEFORE}" ] && [ "$(take_sha "${CONFIG_PATH}")" != "${CONFIG_BEFORE}" ]; then
        printf 'config-interrupted\n' > "${STATE_FILE}"
        log "config 可能已被替换。请执行 --rollback 回到部署前。"
      else
        log "现网 config 未变，可以直接重跑。"
      fi
      ;;
    install)
      withdraw_kexts interrupted
      printf 'install-failed\n' > "${STATE_FILE}"
      log "已撤出 kext。请执行 --rollback 回到部署前。"
      ;;
    p2)
      collect_p2_session
      printf 'p2-interrupted\n' > "${STATE_FILE}"
      log "GPU 可能已开始初始化，不要原地重试。重启后再跑同一条命令（会先复核 P1）。"
      ;;
    rollback)
      printf 'rollback-incomplete\n' > "${STATE_FILE}"
      log "回滚没有跑完。请再执行一次 --rollback。"
      ;;
  esac
  sync
  summary "result=interrupted"
  if [ -n "${EV}" ]; then log "证据目录：${EV}"; fi
  unmount_esp
  exit 130
}
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP
trap 'unmount_esp' EXIT

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
  _path=$(check_gfx_path ioreg-tree-before.txt)
  summary "$(printf '%s' "${_path}" | tr '\n' ' ')"
  [ "$(kv "${_path}" gfx_path_ok)" = "yes" ] || die "GFX0 路径不符：$(kv "${_path}" gfx_path)（控制器只认 ${EXPECT_GFX_PATH}）"

  _home=$(eval printf '%s' "~${SUDO_USER:-root}")
  _mark=${IGPU_RECOVERY_MARK:-${_home}/RECOVERY-EFI-VERIFIED.txt}
  [ -f "${_mark}" ] || die "没有 ${_mark}：恢复 EFI 还没人工验证过（门 G4）。验证后执行 echo ok > ${_mark}"

  "${PY}" "${TOOLS}/field_check.py" tgl-input "${TGL_INPUT}" >> "${EV}/transcript.txt" 2>&1 \
    || die "TGL 原料不对或缺失：${TGL_INPUT}"
  capture tgl-check.json "${PY}" "${FORK_SRC}/${FIX_REL}/prepare-deferred-runtime.py" --check-only "${TGL_INPUT}" \
    || die "TGL 原料未通过结构断言（详见 tgl-check.json）"
  log "TGL 原料结构断言通过（含 probe 比较链：0x46808086 → SKU 2）"
  for _f in "${PREBUILT}/${GATE_NAME}/Contents/Info.plist" "${PREBUILT}/control" "${PREBUILT}/manual-gate-current.json"; do
    [ -f "${_f}" ] || die "缺预编译产物：${_f}"
  done
  "${PY}" "${TOOLS}/field_check.py" receipt "${PREBUILT}/${GATE_NAME}" "${PREBUILT}/manual-gate-current.json" \
    >> "${EV}/transcript.txt" 2>&1 || die "预编译 kext 与收据不符"

  locate_esp || die "${ESP_ERR}"
  summary "esp_source=${ESP_SRC}"
  summary "esp_uuid=${ESP_DEV}"
  _cfg="${MOUNT_POINT}/EFI/OC/config.plist"
  capture delta-check.txt "${PY}" "${TOOLS}/oc_delta.py" check --config "${_cfg}" \
    || die "当前配置不能接受增量（详见 delta-check.txt）"

  _before=$(take_sha "${_cfg}") || die "读不到 config 哈希"
  _bk="${MOUNT_POINT}/igpu-fork-backup-${TS}-$$"
  mkdir "${_bk}" || die "无法创建 ESP 备份目录"
  cp "${_cfg}" "${_bk}/config.plist" || die "备份 config 失败"
  [ "$(take_sha "${_bk}/config.plist")" = "${_before}" ] || die "备份 config 哈希不符"
  mkdir -p "${ROOT}/config-backups" || die "无法创建本地备份目录"
  _local="${ROOT}/config-backups/config-${TS}.plist"
  cp "${_cfg}" "${_local}" || die "本地备份 config 失败"
  printf 'STATE=complete\nconfig_before_sha=%s\n' "${_before}" > "${_bk}/META" || die "写备份 META 失败"
  cp "${_cfg}" "${EV}/config-before.plist.txt" 2>/dev/null
  printf '%s\n' "${ESP_DEV}" > "${ESP_UUID_FILE}" || die "写分区 UUID 失败"
  write_pointer "$(basename "${_bk}")" "${_before}" "" "${_local}" || die "写备份指针失败"
  log "改前备份：${_bk}（${_before}）"

  CONFIG_PATH=${_cfg}; CONFIG_BEFORE=${_before}; CONFIG_STAGED="${_cfg}.staged-$$"; STEP=config
  _staged=${CONFIG_STAGED}
  if ! capture delta-apply.txt "${PY}" "${TOOLS}/oc_delta.py" apply --config "${_cfg}" --out "${_staged}"; then
    rm -f "${_staged}"
    die "生成增量配置失败（现网未动，详见 delta-apply.txt）"
  fi
  _new=$(take_sha "${_staged}") || die "读不到暂存配置哈希"
  # 先记下"改后哈希"再替换：回滚靠它判断 config 有没有被别人动过
  write_pointer "$(basename "${_bk}")" "${_before}" "${_new}" "${_local}" || die "写备份指针失败"
  mv "${_staged}" "${_cfg}" || die "替换 config 失败（现网未动）"
  if [ "$(take_sha "${_cfg}")" != "${_new}" ] \
     || ! capture delta-verify.txt "${PY}" "${TOOLS}/oc_delta.py" verify --config "${_cfg}" --orig "${_bk}/config.plist"; then
    cp "${_bk}/config.plist" "${_cfg}"
    die "替换后复核失败，已还原改前配置"
  fi
  log "配置已更新：${_before} → ${_new}"
  log "⚠ 这个 OC 启动的所有系统都受影响：SIP 放宽（csr=${CSR_RELAXED}）、GFX0 隔离（device-id=FFFF）、-allow3d。Sonoma 也一样（已确认接受）。"
  log "⚠ WriteFlash=true 时 csr 会写进主板 NVRAM：回滚后要再经这个 OC 启动一次才写回 00000000，直接从别的启动项进系统不会恢复。"
  STEP=""
  unmount_esp
  record_boot
  set_stage config-applied
  summary "result=ok"
  log ""
  log "下一步：重启进 Tahoe（sudo reboot），然后再跑同一条命令。"
  log "证据目录：${EV}"
}

write_pointer() {  # write_pointer <备份目录名> <改前哈希> <改后哈希> <本地备份路径>
  printf '%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$4" > "${BACKUP_POINTER}"
}

# ---- 第 2 步：SIP 生效后安装 kext -------------------------------------------
withdraw_kexts() {  # 把已放进 Extensions 的 kext 撤到备份目录，不删除；任一个撤不掉返回非 0
  _dest="${ROOT}/removed-$1-${TS}"
  _wk=0
  for _k in "${GATE_NAME}" "${RUNTIME_NAME}"; do
    if [ -e "${EXT_DIR}/${_k}" ]; then
      if mkdir -p "${_dest}" && mv "${EXT_DIR}/${_k}" "${_dest}/"; then
        log "已撤出 ${_k} → ${_dest}"
      else
        log "⚠ 撤出 ${_k} 失败"
        _wk=1
      fi
    fi
  done
  return "${_wk}"
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
  _csr=$("${PY}" "${TOOLS}/field_check.py" nvdata "${EV}/nvram-csr.plist" csr-active-config)
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
  secure_tree "${_fork}" || die "收回工作副本写权限失败（${_fork}）"
  secure_tree "${_input}" || die "收回 TGL 工作副本写权限失败（${_input}）"
  chmod 755 "${_fix}/manual-gate/control" || die "chmod 控制工具失败"
  capture prepare.json "${PY}" "${_fix}/prepare-deferred-runtime.py" "${_input}" \
    || die "打补丁失败（kext 未安装，详见 prepare.json）"
  secure_tree "${_fork}" || die "收回工作副本写权限失败（${_fork}）"
  log "TGL 运行时已生成并签名"

  if [ -e "${EXT_DIR}/${RUNTIME_NAME}" ] || [ -e "${EXT_DIR}/${GATE_NAME}" ]; then
    die "${EXT_DIR} 里已有同名 kext，拒绝覆盖（先 --rollback）"
  fi
  STEP=install
  if ! ditto --norsrc --noextattr --noqtn "${_fix}/ReimsTGLManualRuntime.kext" "${EXT_DIR}/${RUNTIME_NAME}" 2>"${EV}/ditto-rt.err" \
     || ! ditto --norsrc --noextattr --noqtn "${PREBUILT}/${GATE_NAME}" "${EXT_DIR}/${GATE_NAME}" 2>"${EV}/ditto-gate.err"; then
    withdraw_kexts copy-failed
    set_stage install-failed
    die "复制 kext 失败，已撤出"
  fi
  for _k in "${RUNTIME_NAME}" "${GATE_NAME}"; do
    secure_tree "${EXT_DIR}/${_k}" || {
      withdraw_kexts chown-failed; set_stage install-failed; die "设置 ${_k} 权限失败，已撤出"; }
  done
  : > "${KMUTIL_DIRTY}"
  if ! capture kmutil-install.txt kmutil install --update-all; then
    withdraw_kexts kmutil-failed
    if capture kmutil-after-withdraw.txt kmutil install --update-all; then rm -f "${KMUTIL_DIRTY}"; fi
    set_stage install-failed
    die "kmutil 重建 AuxKC 失败，kext 已撤出（详见 kmutil-install.txt）"
  fi
  STEP=""
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
  _path=$(check_gfx_path ioreg-tree-p1.txt)
  printf '%s\n' "${_path}" > "${EV}/gfx-path-p1.txt"
  _rt_uuid=$("${PY}" "${TOOLS}/field_check.py" json-field "${_fix}/deferred-runtime.json" candidate_uuid) || die "读不到运行时收据"
  _gate_uuid=$("${PY}" "${TOOLS}/field_check.py" json-field "${_fix}/manual-gate-current.json" uuid) || die "读不到控制器收据"
  _gate_id=$("${PY}" "${TOOLS}/field_check.py" json-field "${_fix}/manual-gate-current.json" identifier) || die "读不到控制器标识"
  _rt=$(kv "$("${PY}" "${TOOLS}/field_check.py" loaded "${EV}/showloaded.txt" "${TGL_ID}" "${_rt_uuid}")" loaded)
  _gate=$(kv "$("${PY}" "${TOOLS}/field_check.py" loaded "${EV}/showloaded.txt" "${_gate_id}" "${_gate_uuid}")" loaded)
  summary "runtime_loaded=${_rt}"
  summary "controller_loaded=${_gate}"
  summary "$(printf '%s' "${_gfx}" | tr '\n' ' ')"
  summary "$(printf '%s' "${_path}" | tr '\n' ' ')"
  _why=""
  [ "${_rt}" = "yes" ] || _why="${_why} TGL运行时加载状态=${_rt}"
  [ "${_gate}" = "yes" ] || _why="${_why} 控制器加载状态=${_gate}"
  [ "$(kv "${_gfx}" device_id)" = "ffff0000" ] || _why="${_why} device-id=$(kv "${_gfx}" device_id)"
  [ "$(kv "${_gfx}" firmware_fb)" = "1" ] || _why="${_why} 固件帧缓冲=$(kv "${_gfx}" firmware_fb)"
  [ "$(kv "${_gfx}" accelerator)" = "0" ] || _why="${_why} 加速器已存在=$(kv "${_gfx}" accelerator)"
  [ "$(kv "${_gfx}" native_fb)" = "0" ] || _why="${_why} 原生帧缓冲=$(kv "${_gfx}" native_fb)"
  [ "$(kv "${_path}" gfx_path_ok)" = "yes" ] || _why="${_why} GFX0路径=$(kv "${_path}" gfx_path)（要求 ${EXPECT_GFX_PATH}）"
  if [ -n "${_why}" ]; then
    # 区分"加载失败"与"等用户批准"：csr=03000000 不含 CSR_ALLOW_UNAPPROVED_KEXTS，第三方 kext 可能在等批准
    capture kmutil-aux-collection.txt kmutil inspect --show-aux
    capture kernelmanagerd-log.txt command log show --last boot --style compact \
      --predicate 'process == "kernelmanagerd" OR process == "syspolicyd" OR eventMessage CONTAINS "ReimsTGLBoot" OR eventMessage CONTAINS "ReimsADLManualActivation"'
    capture csrutil-p1.txt csrutil status
    set_stage p1-failed
    summary "P1=FAIL"
    die "P1 未通过：${_why}。若系统设置里有“系统软件已被阻止”，那是等批准，不是加载失败（见 kernelmanagerd-log.txt）。"
  fi
  record_boot
  set_stage p1-pass
  summary "P1=PASS"
  summary "result=ok"
  log ""
  log "P1 通过：kext 已加载、GFX0 路径与控制器一致、GPU 未被驱动、桌面仍走 IONDRV。"
  log "下一步是 P2，可能导致死机重启（重启后自动回到现在的状态）。"
  log "请先保存所有工作，再跑同一条命令。"
  log "证据目录：${EV}"
}

# ---- 第 4 步：P2 只激活加速器 ------------------------------------------------
collect_p2_session() {  # 只收本次尝试产生的会话目录，避免把上次的结果当成这次的
  if [ ! -f "${P2_MARK}" ] || [ -z "${EV}" ] || [ -e "${EV}/session" ]; then return 0; fi
  _session=$(find "${ROOT}/fork/${FIX_REL}" -maxdepth 1 -type d -name 'session-*-accel-only' -newer "${P2_MARK}" 2>/dev/null | sort | tail -1)
  if [ -n "${_session}" ]; then cp -R "${_session}" "${EV}/session" 2>/dev/null; fi
}

p2_outcome_text() {
  case "$1" in
    preflight-failed) printf '%s' "预检未过：igpu-start 在动 GPU 之前就停下了（详见 session/failure.json），GPU 未动" ;;
    probe-failed) printf '%s' "probe 失败：没有 IntelAccelerator 实例（设备被 probe 拒绝，或匹配没有运行）" ;;
    start-failed) printf '%s' "start 失败：probe 见到了设备，但实例没有留下（start 返回了失败）" ;;
    start-stuck) printf '%s' "start 卡住：IntelAccelerator 实例存在，但 start 没有返回（总线仍忙）" ;;
    start-returned) printf '%s' "start 返回成功，但会话没有写出结果" ;;
    published) printf '%s' "加速器被发布了（这个模式绝不应发布）" ;;
    *) printf '%s' "状态未知：读不到 GFX0" ;;
  esac
}

do_p2() {
  open_evidence p2
  log "== 第 4 步：P2 只激活加速器（显示仍走 IONDRV，不重启桌面）=="
  record_boot
  # 先落盘再动 GPU：一旦死机，下次运行靠这些标记认出是 P2 崩的、以及崩溃证据的起始时间
  date '+%Y-%m-%d %H:%M:%S' > "${P2_MARK}" || die "写尝试时间失败"
  set_stage p2-attempted
  STEP=p2
  summary "attempt_boot=$(boot_id)"
  summary "attempt_time=$(head -1 "${P2_MARK}")"
  sync
  _fork="${ROOT}/fork"
  /bin/sh "${_fork}/igpu-start" --accel-only > "${EV}/igpu-start.txt" 2>&1
  _rc=$?
  summary "igpu_start_rc=${_rc}"
  collect_p2_session
  _gfx=$(snapshot_gfx gfx-p2.plist) || _gfx=""
  printf '%s\n' "${_gfx}" > "${EV}/gfx-p2.txt"
  _log="${EV}/session/igpu-log.txt"
  _oc=$("${PY}" "${TOOLS}/field_check.py" p2-outcome "${EV}/gfx-p2.plist" "${_log}" 2>&1)
  printf '%s\n' "${_oc}" > "${EV}/p2-outcome.txt"
  _outcome=$(kv "${_oc}" p2_outcome)
  summary "p2_outcome=${_outcome:-unknown}"
  summary "p2_probe_entered=$(kv "${_oc}" p2_probe_entered)"
  # 不论成败都把 [IGPU] 全量分类：失败时这才是主要证据
  _hw=$("${PY}" "${TOOLS}/field_check.py" hwcaps "${_log}" --out "${EV}/igpu-classified.txt" 2>&1)
  printf '%s\n' "${_hw}" > "${EV}/hwcaps.txt"
  printf '%s\n' "${_hw}" | grep -E '^(found_device_id|found_revision|patch_effective|hw_topology|igpu_lines|igpu_guc|igpu_firmware|igpu_fail|igpu_warn|firmware_version|hwcaps)=' >> "${EV}/summary.txt"
  if [ "${_rc}" -ne 0 ] || [ ! -f "${EV}/session/result.json" ] || [ "${_outcome}" != "start-returned" ]; then
    STEP=""
    set_stage p2-failed
    summary "P2=FAIL"
    die "P2 未通过（退出码 ${_rc}）：$(p2_outcome_text "${_outcome}")。重启即可回到 P1 状态。"
  fi
  if [ "$(kv "${_hw}" hwcaps)" != "ok" ]; then
    STEP=""
    set_stage p2-failed
    summary "P2=PARTIAL"
    die "P2 部分通过：start 返回成功，但日志判据不符（缺：$(kv "${_hw}" hwcaps_missing)；失败行 $(kv "${_hw}" igpu_fail) 条，详见 hwcaps.txt、igpu-classified.txt）。"
  fi
  STEP=""
  set_stage p2-pass
  summary "P2=PASS"
  summary "gpu_function_proven=no"
  summary "result=ok"
  log ""
  log "P2 通过：IntelAccelerator 的 start 返回成功，桌面未受影响。"
  log "  探测到设备 $(kv "${_hw}" found_device_id) rev $(kv "${_hw}" found_revision)；SKU 2 / L3Bank 4 只说明补丁生效；[IGPU] 失败行 0 条。"
  log "  这不证明 GPU 能工作：GuC/固件/命令提交都没有被验证。GuC $(kv "${_hw}" igpu_guc) 行、固件 $(kv "${_hw}" igpu_firmware) 行，全量分类见 igpu-classified.txt。"
  log "请把证据目录带回：${EV}"
}

do_p2_crash_check() {
  if same_boot; then
    # 进程被杀（kill -9、强退终端）来不及走 trap，但这次开机还在，说明不是崩溃
    set_stage p2-interrupted
    log "上次 P2 没有跑完，但本次开机还在：是进程被打断，不是崩溃。"
    log "GPU 可能已开始初始化，不要原地重试。请先 sudo reboot，再跑同一条命令。"
    exit 3
  fi
  open_evidence p2-crash
  log "== 检测到 P2 期间机器重启：收集崩溃证据 =="
  mkdir -p "${EV}/panic"
  # 只收这次尝试之后写出的报告：目录里更早的 panic 与这次无关，混进来会误导判断
  _older=0
  _cause=""
  if [ -f "${P2_MARK}" ]; then
    _attempt=$(head -1 "${P2_MARK}")
    find "${PANIC_DIR}" -type f \( -name '*.panic' -o -name 'Kernel*' -o -name 'panic*' \) -newer "${P2_MARK}" -exec cp {} "${EV}/panic/" \; 2>/dev/null
    _older=$(find "${PANIC_DIR}" -type f \( -name '*.panic' -o -name 'Kernel*' -o -name 'panic*' \) ! -newer "${P2_MARK}" 2>/dev/null | wc -l | tr -d ' ')
  else
    _attempt=""
    find "${PANIC_DIR}" -type f \( -name '*.panic' -o -name 'Kernel*' -o -name 'panic*' \) -exec cp {} "${EV}/panic/" \; 2>/dev/null
    log "⚠ 缺尝试时间标记，无法按时间过滤崩溃报告"
  fi
  capture nvram-panic.txt nvram aapl,panic-info
  if [ -n "${_attempt}" ]; then
    # --last boot 只覆盖崩溃之后这次开机，看不到崩溃前的日志；必须从尝试时间读起。
    # 必须写 command log：本脚本的 log() 函数会遮蔽系统命令
    capture log-since-attempt.txt command log show --start "${_attempt}" --predicate 'eventMessage CONTAINS "[IGPU]"' --style compact
    # 关机原因区分正常重启（5）与 panic/断电：kill -9 后用户自己重启，也会走到这里
    capture shutdown-cause.txt command log show --start "${_attempt}" --style compact --predicate 'eventMessage CONTAINS "Previous shutdown cause"'
    if [ -n "${PY}" ]; then
      "${PY}" "${TOOLS}/field_check.py" hwcaps "${EV}/log-since-attempt.txt" --out "${EV}/igpu-classified.txt" > "${EV}/hwcaps.txt" 2>&1
      grep -E '^(found_device_id|igpu_lines|igpu_guc|igpu_firmware|igpu_fail|igpu_warn|firmware_version)=' "${EV}/hwcaps.txt" >> "${EV}/summary.txt"
    fi
    _cause=$(sed -n 's/.*Previous shutdown cause: *\(-\{0,1\}[0-9][0-9]*\).*/\1/p' "${EV}/shutdown-cause.txt" | tail -1)
    summary "shutdown_cause=${_cause:-unknown}"
  fi
  _n=$(ls "${EV}/panic" 2>/dev/null | wc -l | tr -d ' ')
  if [ "${_n}" -gt 0 ]; then _kind=panic; else _kind=no-panic-report; fi
  set_stage p2-crashed
  summary "attempt_time=${_attempt}"
  summary "panic_files=${_n}"
  summary "panic_files_older_ignored=${_older}"
  summary "crash_kind=${_kind}"
  summary "P2=CRASHED"
  summary "result=stopped"
  if [ "${_kind}" = "panic" ]; then
    log "P2 期间机器崩溃重启，收集到本次尝试之后的 ${_n} 份崩溃报告（另有 ${_older} 份更早的已忽略）。不要重试，把证据目录带回分析。"
  else
    log "P2 期间机器重启，但没有本次尝试之后的崩溃报告：可能是硬死机、强制断电或手动重启（关机原因 ${_cause:-unknown}，5 为正常关机）。"
    log "崩溃报告可能开机后才写出：几分钟后执行 --status 会再补收一次。不要重试，把证据目录带回分析。"
  fi
  printf '%s\n' "${EV}" > "${ROOT}/CRASH_EV"
  log "证据目录：${EV}"
  exit 1
}

do_p2_interrupted() {
  if same_boot; then
    log "P2 在这次开机里被打断过（不是崩溃）。不能原地重试，请先 sudo reboot，再跑同一条命令。"
    exit 3
  fi
  log "P2 上次被打断，已重启。先复核 P1。"
  do_p1
}

# ---- 回滚 -------------------------------------------------------------------
rollback_fail() {
  ROLLBACK_BAD="${ROLLBACK_BAD}；$1"
  log "⚠ 回滚步骤失败：$1（继续做后面的步骤）"
}

rollback_config() {  # 还原 config；失败只报告，不中止
  if [ ! -f "${BACKUP_POINTER}" ]; then
    log "没有配置备份记录：配置未被本工具改过，跳过。"
    return 0
  fi
  _name=$(sed -n 1p "${BACKUP_POINTER}")
  _sha=$(sed -n 2p "${BACKUP_POINTER}")
  _after=$(sed -n 3p "${BACKUP_POINTER}")
  _local=$(sed -n 4p "${BACKUP_POINTER}")
  if ! locate_esp; then rollback_fail "找不到 ESP：${ESP_ERR}"; return 1; fi
  _cfg="${MOUNT_POINT}/EFI/OC/config.plist"
  _cur=$(take_sha "${_cfg}")
  if [ -n "${_cur}" ] && [ "${_cur}" = "${_sha}" ]; then
    log "config 已经是改前版本（${_sha}），不用还原。"
    return 0
  fi
  # 现网既不是改前也不是本工具写入的版本：说明有人动过，盖回去会吃掉别人的改动。
  # 没记下改后哈希时（写入中途被打断），退而核对"现网 = 备份 + 本工具增量"。
  _ours=no
  if [ -n "${_cur}" ] && [ "${_cur}" = "${_after}" ]; then _ours=yes; fi
  if [ "${_ours}" = "no" ] && [ -z "${_after}" ] && [ -f "${MOUNT_POINT}/${_name}/config.plist" ] && [ -n "${PY}" ] \
     && capture delta-verify-rollback.txt "${PY}" "${TOOLS}/oc_delta.py" verify --config "${_cfg}" --orig "${MOUNT_POINT}/${_name}/config.plist"; then
    _ours=yes
  fi
  if [ "${_ours}" = "no" ]; then
    cp "${_cfg}" "${EV}/config-unexpected.plist.txt" 2>/dev/null
    rollback_fail "config 哈希 ${_cur:-读不到} 不是本工具写入的 ${_after:-（未记录）}，拒绝覆盖（现网副本已存进证据目录）"
    return 1
  fi
  _src="${MOUNT_POINT}/${_name}/config.plist"
  if [ ! -f "${_src}" ] || ! grep -q '^STATE=complete' "${MOUNT_POINT}/${_name}/META" 2>/dev/null \
     || [ "$(take_sha "${_src}")" != "${_sha}" ]; then
    log "⚠ ESP 备份不可用：${MOUNT_POINT}/${_name}，改用本地备份。"
    _src=${_local}
    if [ ! -f "${_src}" ] || [ "$(take_sha "${_src}")" != "${_sha}" ]; then
      rollback_fail "ESP 备份与本地备份都不可用（期望哈希 ${_sha}），拒绝还原"
      return 1
    fi
  fi
  _staged="${_cfg}.restore-$$"
  if ! cp "${_src}" "${_staged}"; then rollback_fail "复制备份失败（现网未动）"; return 1; fi
  if ! mv "${_staged}" "${_cfg}"; then rm -f "${_staged}"; rollback_fail "还原 config 失败（现网未动）"; return 1; fi
  if [ "$(take_sha "${_cfg}")" != "${_sha}" ]; then
    rollback_fail "还原后哈希不符，请手工用 ${_src} 覆盖"
    return 1
  fi
  log "config 已还原：${_sha}（备份保留在 ${MOUNT_POINT}/${_name}）"
  return 0
}

do_rollback() {
  open_evidence rollback
  log "== 回滚：先撤 kext，再还原 config（任一步失败都继续，重启后 SIP 恢复 00000000）=="
  STEP=rollback
  printf 'rollback-incomplete\n' > "${STATE_FILE}" || log "⚠ 写阶段文件失败：${STATE_FILE}"
  sync

  # 先撤 kext：若先还原 config，SIP 恢复全开后 AuxKC 里的未签名 kext 可能卡开机。
  # 同理，kext 这一步没成功时绝不还原 config（SIP 保持放宽），否则正好得到这个危险组合。
  _kext_ok=yes
  _had=no
  if [ -e "${EXT_DIR}/${GATE_NAME}" ] || [ -e "${EXT_DIR}/${RUNTIME_NAME}" ] || [ -f "${KMUTIL_DIRTY}" ]; then _had=yes; fi
  if ! withdraw_kexts rollback; then rollback_fail "kext 没有全部撤出 ${EXT_DIR}"; _kext_ok=no; fi
  if [ "${_had}" = "yes" ]; then
    : > "${KMUTIL_DIRTY}"
    if capture kmutil-rollback.txt kmutil install --update-all; then
      rm -f "${KMUTIL_DIRTY}"
      log "AuxKC 已重建"
    else
      rollback_fail "kmutil 重建 AuxKC 失败（详见 kmutil-rollback.txt）"
      _kext_ok=no
    fi
  fi

  if [ "${_kext_ok}" = "yes" ]; then
    rollback_config
  else
    rollback_fail "为防卡开机，kext 撤出并重建 AuxKC 成功之前不还原 config（SIP 保持放宽）"
  fi
  unmount_esp

  STEP=""
  if [ -n "${ROLLBACK_BAD}" ]; then
    set_stage rollback-incomplete
    summary "result=rollback-incomplete"
    summary "reason=${ROLLBACK_BAD}"
    log ""
    log "回滚没有完全成功${ROLLBACK_BAD}"
    log "备份指针已保留，可以再执行一次 --rollback；仍失败就把证据目录带回。"
    log "证据目录：${EV}"
    exit 1
  fi
  rm -f "${BACKUP_POINTER}" "${ESP_UUID_FILE}" "${P2_MARK}" "${ROOT}/CRASH_EV"
  set_stage start
  summary "result=rolled-back"
  log ""
  log "回滚完成。重启后 SIP 恢复全开、GPU 回到未隔离状态：sudo reboot"
  log "注意：要经这个 OC 启动一次才会把 csr 写回 00000000（WriteFlash=true 时它留在主板 NVRAM 里）。"
  log "证据目录：${EV}"
}

show_status() {
  printf 'stage=%s\n' "$(stage)"
  if [ -f "${BACKUP_POINTER}" ]; then printf 'backup=%s\n' "$(sed -n 1p "${BACKUP_POINTER}")"; fi
  # panic 报告由开机后的服务异步写出，崩溃检测那一刻可能还没有：每次看状态都补收一次
  if [ "$(stage)" = "p2-crashed" ] && [ -f "${P2_MARK}" ] && [ -s "${ROOT}/CRASH_EV" ]; then
    _cev=$(head -1 "${ROOT}/CRASH_EV")
    if [ -d "${_cev}/panic" ]; then
      find "${PANIC_DIR}" -type f \( -name '*.panic' -o -name 'Kernel*' -o -name 'panic*' \) -newer "${P2_MARK}" -exec cp {} "${_cev}/panic/" \; 2>/dev/null
      printf 'panic_files=%s（%s）\n' "$(ls "${_cev}/panic" 2>/dev/null | wc -l | tr -d ' ')" "${_cev}/panic"
    fi
  fi
  case "$(stage)" in
    start) printf 'next=sudo sh %s（写入 OC 配置）\n' "${SELF}" ;;
    config-applied) printf 'next=重启后再跑一次（安装 kext）\n' ;;
    installed) printf 'next=重启后再跑一次（P1 判定）\n' ;;
    p1-pass) printf 'next=保存工作后再跑一次（P2）\n' ;;
    p2-attempted) printf 'next=再跑一次（判断是崩溃还是被打断）\n' ;;
    p2-interrupted) printf 'next=重启后再跑一次（先复核 P1，不是崩溃）\n' ;;
    p2-pass) printf 'next=把证据带回；不再需要操作\n' ;;
    rollback-incomplete) printf 'next=再执行 sudo sh %s --rollback；仍失败就把证据带回\n' "${SELF}" ;;
    *) printf 'next=把证据带回；可 sudo sh %s --rollback 回到部署前\n' "${SELF}" ;;
  esac
}

case "${1:-}" in
  --status|--rollback|"") : ;;
  *) printf '用法：sudo sh %s [--status|--rollback]\n' "${SELF}" >&2; exit 64 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then exec sudo /bin/sh "${SELF}" "$@"; fi
  printf '需要管理员权限：sudo sh %s\n' "${SELF}" >&2
  exit 77
fi
mkdir -p "${ROOT}" || { printf '无法创建 %s\n' "${ROOT}" >&2; exit 1; }
chmod 700 "${ROOT}" 2>/dev/null

TOOLS="${ROOT}/tools-$$"
rm -rf "${TOOLS}"
if ! mkdir "${TOOLS}" || ! cp "${FIELD_DIR}/field_check.py" "${FIELD_DIR}/oc_delta.py" "${TOOLS}/" \
   || ! secure_tree "${TOOLS}"; then
  printf '无法准备辅助脚本副本：%s\n' "${TOOLS}" >&2; exit 1
fi
trap 'unmount_esp; rm -rf "${TOOLS}"' EXIT
if [ "${1:-}" = "--status" ]; then show_status; exit 0; fi
if [ "${1:-}" = "--rollback" ]; then do_rollback; exit 0; fi

case "$(stage)" in
  start) do_config ;;
  config-applied) do_install ;;
  installed) do_p1 ;;
  p1-pass) do_p2 ;;
  p2-attempted) do_p2_crash_check ;;
  p2-interrupted) do_p2_interrupted ;;
  p2-pass) log "P2 已通过，无需再跑。"; show_status ;;
  *) log "当前阶段 $(stage) 是失败终态，不自动重试。"; show_status; exit 1 ;;
esac
