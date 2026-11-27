#!/bin/sh
# adl-s-field.sh —— ADL-S 8086:4680 现场一条命令（P1 开机隔离 + P2 只激活加速器）
#
#   sudo sh adl-s-field.sh              按当前阶段自动推进一步
#   sudo sh adl-s-field.sh --status     看进度（状态目录只有 root 可读，不带 sudo 也会自动提权）
#   sudo sh adl-s-field.sh --rollback   受控撤出并回到部署前（跨重启核验集合排除后才还原 config）
#
# 阶段：start → config-applied（重启）→ installed（重启）→ [awaiting-approval（批准 + 重启）] → p1-pass → p2-pass
#       回滚中间态：rollback-pending-reboot / rollback-awaiting-approval → rollback-final-reboot → start
#       失败终态：p1-failed / approval-unresolved / p2-failed / p2-crashed / install-failed /
#                 config-interrupted / rollback-incomplete（都保留证据，可受控恢复）
#       p2-interrupted：P2 被 Ctrl-C/关终端打断，不是崩溃；重启后重跑会先复核 P1
#
# 为什么分阶段：SIP 放宽要重启才生效，未放宽时 kernelmanagerd 不收未签名 kext；AuxKC 也要重启才采用。
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
# 交换盘（U 盘 FAT32 分区）的根目录：从本脚本位置往上找含 igpu-tgl-input 的目录。
# 不能写死 /Volumes/CLONEZILLA：卷名可能变成 "CLONEZILLA 1"；环境变量也传不过 sudo。
find_usb_root() {
  _d=${FIELD_DIR}; _i=0
  while [ "${_i}" -lt 8 ]; do
    _d=$(dirname "${_d}")
    if [ -d "${_d}/igpu-tgl-input" ]; then printf '%s' "${_d}"; return 0; fi
    [ "${_d}" = "/" ] && break
    _i=$((_i + 1))
  done
  printf '%s' /Volumes/CLONEZILLA
}
USB_ROOT=${IGPU_USB_ROOT:-$(find_usb_root)}
TGL_INPUT=${IGPU_TGL_INPUT:-${USB_ROOT}/igpu-tgl-input/AppleIntelTGLGraphics.kext}
EVIDENCE_ROOT=${IGPU_EVIDENCE_ROOT:-${USB_ROOT}/igpu}
# Windows 侧恢复演练（双击“恢复Mac启动”选 1）成功后写在 U 盘根目录的凭证
DRILL_FILE=${IGPU_DRILL_FILE:-${USB_ROOT}/RECOVERY-DRILL-OK.txt}
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
# 新装的第三方 kext 要用户批准一次（上游部署文档同样如此），P1 用 awaiting-approval 阶段承接
CSR_RELAXED=03000000
TGL_ID=com.apple.driver.AppleIntelTGLGraphics
GATE_ID=lab.reims.ReimsADLManualActivation
BOOT_KC=${IGPU_BOOT_KC:-/System/Library/KernelCollections/BootKernelExtensions.kc}
SYSTEM_KC=${IGPU_SYSTEM_KC:-/System/Library/KernelCollections/SystemKernelExtensions.kc}
AUX_KC=${IGPU_AUX_KC:-/Library/KernelCollections/AuxiliaryKernelExtensions.kc}
GATE_NAME=ReimsADLManualActivation.kext
RUNTIME_NAME=ReimsTGLBoot.kext
FIX_REL=desktop-manual-20260917/fix

STATE_FILE="${ROOT}/STAGE"
BOOT_FILE="${ROOT}/BOOT"
BACKUP_POINTER="${ROOT}/BACKUP"
ESP_UUID_FILE="${ROOT}/ESP_UUID"
P2_MARK="${ROOT}/P2_ATTEMPT"
KMUTIL_DIRTY="${ROOT}/KMUTIL_DIRTY"
COPY_MARKER="${ROOT}/INSTALL_COPY_PENDING"
INSTALLED_KCS="${ROOT}/INSTALLED_SYSTEM_KCS"
ROLLBACK_KCS="${ROOT}/ROLLBACK_SYSTEM_KCS"
INSTALLED_RT_RECEIPT="${ROOT}/INSTALLED_RUNTIME_RECEIPT.json"
INSTALLED_GATE_RECEIPT="${ROOT}/INSTALLED_GATE_RECEIPT.json"
TS=$(date +%Y%m%d-%H%M%S)
EV=""
MOUNT_POINT=""
ESP_DEV=""
ESP_SRC=""
ESP_ERR=""
BOOT_ESP_STATE=""
BOOT_ESP_UUID=""
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

ext_present() { [ -e "$1" ] || [ -L "$1" ]; }
take_sha() {
  _o=$(shasum -a 256 "$1" 2>/dev/null) || return 1
  _h=$(printf '%s' "${_o}" | awk '{print $1}')
  printf '%s' "${_h}" | grep -Eq '^[0-9a-fA-F]{64}$' || return 1
  printf '%s' "${_h}" | tr 'A-F' 'a-f'
}
kv() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }
stage() { if [ -f "${STATE_FILE}" ]; then head -1 "${STATE_FILE}"; else printf 'start\n'; fi; }
set_stage() { printf '%s\n' "$1" > "${STATE_FILE}" || die "写阶段文件失败：${STATE_FILE}"; sync; }
boot_id() {
  _bid=$(sysctl -n kern.bootsessionuuid 2>/dev/null) || return 1
  [ -n "${_bid}" ] || return 1
  printf '%s' "${_bid}"
}
record_boot() {
  _rb=$(boot_id) || die "读取开机标识失败"
  printf '%s\n' "${_rb}" > "${BOOT_FILE}" || die "记录开机标识失败"
  sync
}
same_boot() {
  [ -s "${BOOT_FILE}" ] || return 1
  _sb=$(boot_id) || return 1
  [ "$(head -1 "${BOOT_FILE}")" = "${_sb}" ]
}
new_boot() {
  [ -s "${BOOT_FILE}" ] || return 1
  _nb=$(boot_id) || return 1
  [ "${_nb}" != "$(head -1 "${BOOT_FILE}")" ]
}

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
  # 父目录不存在说明 U 盘没挂上：不能 mkdir -p，否则会在系统盘上造出假的 /Volumes/... 目录
  if [ ! -d "$(dirname "${_base}")" ] || ! mkdir -p "${_base}" 2>/dev/null || [ ! -w "${_base}" ]; then _base="${ROOT}/evidence"; fi
  mkdir -p "${_base}" || { printf '无法创建证据目录 %s\n' "${_base}" >&2; exit 1; }
  EV="${_base}/results-adl-s-$1-${TS}-$$"
  mkdir -p "${EV}" || { printf '无法创建证据目录 %s\n' "${EV}" >&2; exit 1; }
  summary "phase=$1"
  summary "started=${TS}"
  summary "stage_at_start=$(stage)"
}

capture() {  # capture <文件名> <命令...>：保存输出，返回命令退出码
  _cap=$1; shift
  "$@" > "${EV}/${_cap}" 2>&1
}

kmutil_visible() {
  # rebuild/load 的系统提示必须在终端可见；管线状态由子进程单独落盘，不能误用 tee 的退出码。
  _kv_out=$1; shift
  _kv_status="${EV}/${_kv_out}.rc"
  rm -f "${_kv_status}"
  log "请求：kmutil $*"
  (
    kmutil "$@"
    _kv_child_rc=$?
    printf '%s\n' "${_kv_child_rc}" > "${_kv_status}"
  ) 2>&1 | tee "${EV}/${_kv_out}"
  if [ ! -s "${_kv_status}" ]; then
    summary "kmutil_status_missing=yes"
    return 137
  fi
  _kv_return=$(head -1 "${_kv_status}")
  printf '%s' "${_kv_return}" | grep -Eq '^[0-9]+$' || return 1
  case "${_kv_return}" in
    129) on_signal HUP ;;
    130) on_signal INT ;;
    143) on_signal TERM ;;
    *) return "${_kv_return}" ;;
  esac
}

verify_build_and_volume() {
  # 成功返回 0；失败把原因写进 BUILD_ERR，由调用方选择 die 或 rollback_stop。
  BUILD_ERR=""
  _cb=$(sw_vers -buildVersion 2>/dev/null) || { BUILD_ERR="读不到当前 macOS 版本"; return 1; }
  [ "${_cb}" = "${EXPECT_BUILD}" ] || { BUILD_ERR="当前系统 ${_cb} 不是 ${EXPECT_BUILD}，禁止安装或恢复写入"; return 1; }
  capture system-volume.txt diskutil info / || { BUILD_ERR="读不到当前系统卷身份，禁止写入"; return 1; }
  _cv=$(awk -F': *' '/^[[:space:]]*Volume UUID:/ {print $2}' "${EV}/system-volume.txt" | head -1 | tr 'a-f' 'A-F')
  printf '%s' "${_cv}" | grep -Eq '^[0-9A-F-]{36}$' || { BUILD_ERR="当前系统卷 UUID 无效，禁止写入"; return 1; }
  if [ -s "${ROOT}/SYSTEM_VOLUME_UUID" ]; then
    [ "$(head -1 "${ROOT}/SYSTEM_VOLUME_UUID")" = "${_cv}" ] || { BUILD_ERR="当前系统卷不是记录的试验目标，禁止安装或恢复"; return 1; }
  else
    printf '%s\n' "${_cv}" > "${ROOT}/SYSTEM_VOLUME_UUID" || { BUILD_ERR="记录目标系统卷失败"; return 1; }
  fi
  summary "target_volume_uuid=${_cv}"
  return 0
}

check_build() {
  verify_build_and_volume || die "${BUILD_ERR}"
}

check_kmutil_contract() {
  # HELP 是只读的，遇到版本差异先停，不能让宽松的仿真桩替未知参数背书。
  capture kmutil-load-help.txt kmutil load --help || return 1
  capture kmutil-rebuild-help.txt kmutil rebuild --help || return 1
  capture kmutil-inspect-help.txt kmutil inspect --help || return 1
  capture kmutil-showloaded-help.txt kmutil showloaded --help || return 1
  grep -q -- '--load-style' "${EV}/kmutil-load-help.txt" \
    && grep -q -- 'start-only' "${EV}/kmutil-load-help.txt" \
    && grep -q -- '--bundle-path' "${EV}/kmutil-load-help.txt" \
    && grep -q -- 'rebuild' "${EV}/kmutil-rebuild-help.txt" \
    && grep -q -- '--auxiliary-path' "${EV}/kmutil-inspect-help.txt" \
    && grep -q -- '--show-kext-uuids' "${EV}/kmutil-inspect-help.txt" \
    && grep -q -- '--collection' "${EV}/kmutil-showloaded-help.txt" \
    && grep -q -- '--show' "${EV}/kmutil-showloaded-help.txt"
}

take_system_kcs_pair() {
  _rs_b=$(take_sha "${BOOT_KC}") || return 1
  _rs_s=$(take_sha "${SYSTEM_KC}") || return 1
  printf '%s\n%s\n' "${_rs_b}" "${_rs_s}" > "$1" || return 1
}

verify_system_kcs_file() {
  [ -s "$1" ] || return 1
  _vk_b_exp=$(sed -n 1p "$1")
  _vk_s_exp=$(sed -n 2p "$1")
  printf '%s' "${_vk_b_exp}" | grep -Eq '^[0-9a-f]{64}$' || return 1
  printf '%s' "${_vk_s_exp}" | grep -Eq '^[0-9a-f]{64}$' || return 1
  _vk_b_cur=$(take_sha "${BOOT_KC}") || return 1
  _vk_s_cur=$(take_sha "${SYSTEM_KC}") || return 1
  [ "${_vk_b_cur}" = "${_vk_b_exp}" ] && [ "${_vk_s_cur}" = "${_vk_s_exp}" ]
}

approval_hint() {
  log "打开‘系统设置 → 隐私与安全性’。如果有系统软件提示，点‘允许’，再点提示里的‘重新启动’。"
  log "找不到提示不要盲目重启或重复安装，把当前证据带回。普通重启不等于已经批准。"
}

snapshot_gfx() {  # snapshot_gfx <文件名>：抓 GFX0 子树并打印解析结果
  ioreg -r -n GFX0 -l -a > "${EV}/$1" 2>"${EV}/$1.err" || return 1
  "${PY}" "${TOOLS}/field_check.py" gfx "${EV}/$1"
}

check_gfx_path() {  # check_gfx_path <文件名>：抓 IOService 平面整棵树，核对 GFX0 完整路径
  ioreg -p IOService -w0 > "${EV}/$1" 2>"${EV}/$1.err" || { printf 'gfx_path=ioreg-failed\ngfx_path_ok=no\n'; return 1; }
  "${PY}" "${TOOLS}/field_check.py" gfx-path "${EV}/$1" "${EXPECT_GFX_PATH}"
}

query_boot_esp() {
  # OC 仅在 ExposeSensitiveData 含 0x01 时发布 boot-path（现网基线 6 不含该位，不静默篡改配置）。
  # 因此区分三态：verified（存在且唯一定位 GPT UUID）、absent（NVRAM 无此键）、invalid（查询报错或内容异常/多分区）。
  BOOT_ESP_STATE=""
  BOOT_ESP_UUID=""
  _bp_dir=${EV:-${TOOLS}}
  _bp_plist="${_bp_dir}/boot-path-nvram.plist"
  _bp_err="${_bp_dir}/boot-path-nvram.err"
  nvram -x "${OC_VENDOR_GUID}:boot-path" > "${_bp_plist}" 2>"${_bp_err}"
  _bp_rc=$?
  if [ "${_bp_rc}" -eq 0 ]; then
    _bp_out=$("${PY}" "${TOOLS}/field_check.py" boot-path "${_bp_plist}" "${OC_VENDOR_GUID}:boot-path" 2>>"${_bp_err}")
    if [ "$?" -eq 0 ]; then
      _bp_uuid=$(kv "${_bp_out}" boot_esp_uuid)
      if printf '%s' "${_bp_uuid}" | grep -Eq '^[0-9A-F-]{36}$'; then
        BOOT_ESP_STATE=verified
        BOOT_ESP_UUID=${_bp_uuid}
        return 0
      fi
    elif grep -q 'NVRAM plist 没有指定的精确键' "${_bp_err}" 2>/dev/null; then
      BOOT_ESP_STATE=absent
      return 0
    fi
    BOOT_ESP_STATE=invalid
    return 1
  fi
  if grep -qiE 'not found|was not found' "${_bp_plist}" "${_bp_err}" 2>/dev/null; then
    BOOT_ESP_STATE=absent
    return 0
  fi
  BOOT_ESP_STATE=invalid
  return 1
}

# 分区 UUID 跨开机稳定，磁盘号（disk9s1）不稳定，卷名也可能重复。
# 每次定位都同时核查当前启动来源：一旦 boot-path 可读且与记录的 ESP 不符，立即拒绝。
locate_esp() {  # 成功返回 0；失败把原因写进 ESP_ERR，由调用方决定中止（部署）还是继续（回滚）
  ESP_ERR=""
  ESP_SRC=""
  query_boot_esp
  if [ "${BOOT_ESP_STATE}" = "invalid" ]; then
    ESP_ERR="读取或解析 NVRAM boot-path 失败（详见 boot-path-nvram.err）"
    return 1
  fi
  _want=""; _src=""
  if [ -s "${ESP_UUID_FILE}" ]; then
    _rec=$(head -1 "${ESP_UUID_FILE}" | tr 'a-f' 'A-F')
    if [ "${BOOT_ESP_STATE}" = "verified" ]; then
      if [ "${BOOT_ESP_UUID}" != "${_rec}" ]; then
        ESP_ERR="当前启动 ESP（${BOOT_ESP_UUID}）与记录的目标 ESP（${_rec}）不符"
        return 1
      fi
      _want=${_rec}; _src=recorded+boot-path
    else
      _want=${_rec}; _src=recorded
    fi
  else
    if [ "${BOOT_ESP_STATE}" = "verified" ]; then
      _want=${BOOT_ESP_UUID}; _src=boot-path
    else
      _src=volume-name
      _cand=$(diskutil list 2>/dev/null | awk -v v="${EXPECT_VOL}" '$0 ~ v {print $NF}' | sort -u)
      _n=$(printf '%s\n' "${_cand}" | grep -c . 2>/dev/null || true)
      if [ "${_n}" -ne 1 ]; then ESP_ERR="${EXPECT_VOL} 候选数=${_n}（必须恰好 1 个）"; return 1; fi
    fi
  fi
  if [ -n "${_want}" ]; then _cand=${_want}; fi
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
      _sig_wk=yes
      if ! withdraw_kexts interrupted; then _sig_wk=no; fi
      summary "source_withdrawn=${_sig_wk}"
      : > "${KMUTIL_DIRTY}"
      printf 'install-failed\n' > "${STATE_FILE}"
      if [ "${_sig_wk}" = "yes" ]; then
        rm -f "${COPY_MARKER}"
        log "安装中断，已撤出本事务安装源。请运行同一条命令或 --rollback 受控恢复。"
      else
        log "安装中断且撤出未完成。请运行 --rollback 受控恢复。"
      fi
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
  check_build
  _gfx=$(snapshot_gfx gfx-before.plist) || die "读不到 GFX0"
  printf '%s\n' "${_gfx}" > "${EV}/gfx-before.txt"
  [ "$(kv "${_gfx}" vendor_id)" = "${EXPECT_VENDOR}" ] || die "vendor-id 不符：$(kv "${_gfx}" vendor_id)"
  [ "$(kv "${_gfx}" device_id)" = "${EXPECT_DEVICE}" ] || die "device-id 不符：$(kv "${_gfx}" device_id)（要求未隔离的 0x4680）"
  [ "$(kv "${_gfx}" revision_id)" = "${EXPECT_REVISION}" ] || die "revision-id 不符：$(kv "${_gfx}" revision_id)"
  _path=$(check_gfx_path ioreg-tree-before.txt) || die "读不到 IOService 设备树"
  summary "$(printf '%s' "${_path}" | tr '\n' ' ')"
  [ "$(kv "${_path}" gfx_path_ok)" = "yes" ] || die "GFX0 路径不符：$(kv "${_path}" gfx_path)（控制器只认 ${EXPECT_GFX_PATH}）"

  if [ -n "${SUDO_USER:-}" ]; then
    _home=$(dscl . -read "/Users/${SUDO_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  else
    _home=${HOME:-/var/root}
  fi
  _mark=${IGPU_RECOVERY_MARK:-${_home}/RECOVERY-EFI-VERIFIED.txt}
  [ -f "${_mark}" ] || die "没有 ${_mark}：恢复通道还没确认过（门 G4）。请用 sh <U盘>/go.sh 运行，它会处理。"
  [ -f "${DRILL_FILE}" ] || die "没有 ${DRILL_FILE}：还没在 Windows 里演练过恢复（门 G4）。先按 F12 进 Windows，双击桌面上的“恢复Mac启动”选 1。"
  _drill_sha=$(sed -n 's/^live_sha=//p' "${DRILL_FILE}" | tr -d '\r' | head -1)
  summary "drill_live_sha=${_drill_sha}"

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
  # 演练时 Windows 看到的 config 必须就是现在要改的这份，否则 Windows 侧快照还原不回这里
  [ "$(printf '%s' "${_drill_sha}" | tr 'A-F' 'a-f')" = "${_before}" ] \
    || die "Windows 演练时的 config（${_drill_sha:-未记录}）不是现在这份（${_before}）。请重新在 Windows 里双击“恢复Mac启动”选 1 演练一次。"
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
owned_kext() {
  # 拒绝符号链接；未完 copy 仍须满足已暂存收据的路径白名单与可读 Info.plist 身份，已完成复制校验完整收据。
  [ -L "${EXT_DIR}/$1" ] && return 1
  [ -n "${PY}" ] || return 1
  if [ "${STEP}" = "install" ] || [ -f "${COPY_MARKER}" ]; then
    case "$1" in
      "${GATE_NAME}")
        [ -s "${INSTALLED_GATE_RECEIPT}" ] && "${PY}" "${TOOLS}/field_check.py" receipt \
          "${EXT_DIR}/$1" "${INSTALLED_GATE_RECEIPT}" --allow-partial >> "${EV}/ownership-checks.txt" 2>&1 ;;
      "${RUNTIME_NAME}")
        [ -s "${INSTALLED_RT_RECEIPT}" ] && "${PY}" "${TOOLS}/field_check.py" receipt \
          "${EXT_DIR}/$1" "${INSTALLED_RT_RECEIPT}" --allow-partial >> "${EV}/ownership-checks.txt" 2>&1 ;;
      *) return 1 ;;
    esac
    return "$?"
  fi
  case "$1" in
    "${GATE_NAME}")
      if [ -s "${INSTALLED_GATE_RECEIPT}" ]; then
        "${PY}" "${TOOLS}/field_check.py" receipt "${EXT_DIR}/$1" "${INSTALLED_GATE_RECEIPT}" >> "${EV}/ownership-checks.txt" 2>&1
      else
        "${PY}" "${TOOLS}/field_check.py" receipt "${EXT_DIR}/$1" \
          "${ROOT}/fork/${FIX_REL}/manual-gate-current.json" >> "${EV}/ownership-checks.txt" 2>&1
      fi ;;
    "${RUNTIME_NAME}")
      if [ -s "${INSTALLED_RT_RECEIPT}" ]; then
        "${PY}" "${TOOLS}/field_check.py" receipt "${EXT_DIR}/$1" "${INSTALLED_RT_RECEIPT}" >> "${EV}/ownership-checks.txt" 2>&1
      else
        _own_sha=$("${PY}" "${TOOLS}/field_check.py" json-field \
          "${ROOT}/fork/${FIX_REL}/deferred-runtime.json" candidate_sha256 2>/dev/null) || return 1
        _prep_info="${ROOT}/fork/${FIX_REL}/ReimsTGLManualRuntime.kext/Contents/Info.plist"
        [ -n "${_own_sha}" ] && [ -f "${_prep_info}" ] \
          && [ "$(take_sha "${EXT_DIR}/$1/Contents/MacOS/AppleIntelTGLGraphics")" = "${_own_sha}" ] \
          && [ "$(take_sha "${EXT_DIR}/$1/Contents/Info.plist")" = "$(take_sha "${_prep_info}")" ] \
          && "${PY}" -c 'import plistlib,sys; p=plistlib.load(open(sys.argv[1],"rb")); sys.exit(0 if isinstance(p,dict) and p.get("CFBundleIdentifier")=="com.apple.driver.AppleIntelTGLGraphics" and p.get("CFBundleVersion")=="16.0.3" and p.get("IOKitPersonalities")=={} else 1)' \
               "${EXT_DIR}/$1/Contents/Info.plist" >> "${EV}/ownership-checks.txt" 2>&1
      fi ;;
    *) return 1 ;;
  esac
}

withdraw_kexts() {  # 把已放进 Extensions 的 kext 撤到备份目录，不删除；任一个撤不掉返回非 0
  _dest="${ROOT}/removed-$1-${TS}"
  _wk=0
  for _k in "${GATE_NAME}" "${RUNTIME_NAME}"; do
    if ext_present "${EXT_DIR}/${_k}"; then
      if ! owned_kext "${_k}"; then
        log "⚠ ${_k} 与本事务完整收据不符或归属未知，拒绝移动"
        _wk=1
        continue
      fi
      if mkdir -p "${_dest}" && mv "${EXT_DIR}/${_k}" "${_dest}/"; then
        log "已撤出 ${_k} → ${_dest}"
      else
        log "⚠ 撤出 ${_k} 失败"
        _wk=1
      fi
    fi
  done
  if [ "${_wk}" -eq 0 ] && [ -f "${COPY_MARKER}" ] && [ "${STEP}" != "install" ]; then
    rm -f "${COPY_MARKER}"
  fi
  return "${_wk}"
}

do_install() {
  if same_boot; then
    log "配置已写入，但还没重启。请先重启，再跑同一条命令。"
    exit 3
  fi
  open_evidence install
  log "== 第 2 步：核对隔离并向 kernelmanagerd 请求装载（不重建 Boot/System）=="
  check_build
  [ -n "${PY}" ] || die "找不到可用的 python3"
  if [ -f "${KMUTIL_DIRTY}" ] || [ -f "${COPY_MARKER}" ]; then
    die "旧装载或复制事务尚未清理，先执行 --rollback，不替换旧工作树或收据"
  fi
  if ext_present "${EXT_DIR}/${RUNTIME_NAME}" || ext_present "${EXT_DIR}/${GATE_NAME}"; then
    die "${EXT_DIR} 里已有同名 kext 或残留链接，拒绝替换旧工作树或覆盖（先 --rollback）"
  fi
  check_kmutil_contract || die "kmutil 的只读帮助不符合已审查的装载契约，未装 kext；详见帮助文件"
  take_system_kcs_pair "${EV}/system-kc-before.txt" || die "读不到 Boot/System 集合指纹，未装 kext"
  capture install-before-all.txt kmutil showloaded --collection aux --show all \
    || die "读不到当前 AuxKC 可用组件，未装 kext"
  _clean=$("${PY}" "${TOOLS}/field_check.py" absent "${EV}/install-before-all.txt" loaded "${TGL_ID}" "${GATE_ID}" 2>&1) \
    || die "解析当前 AuxKC 可用组件失败，未装 kext（${_clean}）"
  [ "$(kv "${_clean}" identifiers_absent)" = "yes" ] \
    || die "已有目标组件或旧集合状态未知，先恢复旧事务，不重新装载（${_clean}）"
  capture install-before-running.txt kmutil showloaded || die "读不到未过滤内存清单，未装 kext"
  _running_clean=$("${PY}" "${TOOLS}/field_check.py" absent "${EV}/install-before-running.txt" loaded "${TGL_ID}" "${GATE_ID}" 2>&1) \
    || die "解析未过滤内存清单失败，未装 kext（${_running_clean}）"
  [ "$(kv "${_running_clean}" identifiers_absent)" = "yes" ] || die "目标可能在其他集合/内存中，先恢复，不重新装载"
  nvram -x csr-active-config > "${EV}/nvram-csr.plist" 2>&1 || die "读不到 csr-active-config"
  _csr=$("${PY}" "${TOOLS}/field_check.py" nvdata "${EV}/nvram-csr.plist" csr-active-config 2>>"${EV}/transcript.txt") \
    || die "解析 csr-active-config 失败"
  [ "$(kv "${_csr}" csr-active-config)" = "${CSR_RELAXED}" ] \
    || die "SIP 未按预期放宽：$(kv "${_csr}" csr-active-config)（配置没生效，kext 未安装）"
  _args=$(sysctl -n kern.bootargs 2>/dev/null) || die "读不到启动参数 kern.bootargs"
  printf '%s\n' "${_args}" > "${EV}/bootargs.txt"
  case " ${_args} " in *" -allow3d "*) : ;; *) die "boot-args 没有 -allow3d（配置没生效，kext 未安装）" ;; esac
  case " ${_args} " in *" -x "*) die "当前处于安全模式 -x，不安装试验 kext" ;; esac
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
  _rt_cand_uuid=$("${PY}" "${TOOLS}/field_check.py" json-field "${_fix}/deferred-runtime.json" candidate_uuid 2>/dev/null) \
    || die "读不到运行时候选 UUID"
  _gate_cand_uuid=$("${PY}" "${TOOLS}/field_check.py" json-field "${PREBUILT}/manual-gate-current.json" uuid 2>/dev/null) \
    || die "读不到控制器候选 UUID"
  capture runtime-info-check.txt "${PY}" "${TOOLS}/field_check.py" write-receipt \
    "${_fix}/ReimsTGLManualRuntime.kext" "${_rt_cand_uuid}" "${EV}/staged-runtime-receipt.json" --empty-personalities \
    || die "运行时元数据不符或自动 personality 没清空，未安装"
  capture gate-receipt-stage.txt "${PY}" "${TOOLS}/field_check.py" write-receipt \
    "${PREBUILT}/${GATE_NAME}" "${_gate_cand_uuid}" "${EV}/staged-gate-receipt.json" \
    || die "生成控制器安装收据失败，未安装"
  log "TGL 运行时已生成并签名"

  if ext_present "${EXT_DIR}/${RUNTIME_NAME}" || ext_present "${EXT_DIR}/${GATE_NAME}"; then
    die "${EXT_DIR} 里已有同名 kext，拒绝覆盖（先 --rollback）"
  fi
  cp "${EV}/staged-runtime-receipt.json" "${INSTALLED_RT_RECEIPT}" || die "保存运行时安装收据失败，未安装"
  cp "${EV}/staged-gate-receipt.json" "${INSTALLED_GATE_RECEIPT}" || die "保存控制器安装收据失败，未安装"
  cp "${EV}/system-kc-before.txt" "${INSTALLED_KCS}" || die "保存安装集合基线失败，未安装"
  printf 'boot=%s\nts=%s\n' "$(boot_id)" "${TS}" > "${COPY_MARKER}" || die "写复制事务标记失败，未复制"
  sync
  STEP=install
  if ! ditto --norsrc --noextattr --noqtn "${_fix}/ReimsTGLManualRuntime.kext" "${EXT_DIR}/${RUNTIME_NAME}" 2>"${EV}/ditto-rt.err" \
     || ! ditto --norsrc --noextattr --noqtn "${PREBUILT}/${GATE_NAME}" "${EXT_DIR}/${GATE_NAME}" 2>"${EV}/ditto-gate.err"; then
    _cp_wk=yes
    if ! withdraw_kexts copy-failed; then _cp_wk=no; fi
    : > "${KMUTIL_DIRTY}"
    [ "${_cp_wk}" = "yes" ] && rm -f "${COPY_MARKER}"
    STEP=""
    set_stage install-failed
    die "复制 kext 失败，撤出状态=${_cp_wk}"
  fi
  for _k in "${RUNTIME_NAME}" "${GATE_NAME}"; do
    if ! secure_tree "${EXT_DIR}/${_k}"; then
      _ch_wk=yes
      if ! withdraw_kexts chown-failed; then _ch_wk=no; fi
      : > "${KMUTIL_DIRTY}"
      [ "${_ch_wk}" = "yes" ] && rm -f "${COPY_MARKER}"
      STEP=""
      set_stage install-failed
      die "设置 ${_k} 权限失败，撤出状态=${_ch_wk}"
    fi
  done
  "${PY}" "${TOOLS}/field_check.py" receipt "${EXT_DIR}/${RUNTIME_NAME}" "${INSTALLED_RT_RECEIPT}" >> "${EV}/transcript.txt" 2>&1 \
    && "${PY}" "${TOOLS}/field_check.py" receipt "${EXT_DIR}/${GATE_NAME}" "${INSTALLED_GATE_RECEIPT}" >> "${EV}/transcript.txt" 2>&1 \
    || {
      _rc_wk=yes
      if ! withdraw_kexts verify-failed; then _rc_wk=no; fi
      : > "${KMUTIL_DIRTY}"
      [ "${_rc_wk}" = "yes" ] && rm -f "${COPY_MARKER}"
      STEP=""
      set_stage install-failed
      die "目标扩展复制后收据复核失败，撤出状态=${_rc_wk}"
    }
  : > "${KMUTIL_DIRTY}" || die "写入装载事务标记失败，不能发起请求"
  rm -f "${COPY_MARKER}"
  sync
  # Apple 安装指南要求一次调用包含全部包；start-only 不重播 GPU personality。
  kmutil_visible kmutil-load.txt load --load-style start-only \
    -p "${EXT_DIR}/${RUNTIME_NAME}" -p "${EXT_DIR}/${GATE_NAME}"
  _load_rc=$?
  summary "kmutil_load_rc=${_load_rc}"
  printf '%s\n' "${_load_rc}" > "${ROOT}/LOAD_REQUEST_RC" || die "保存装载结果失败"
  summary "kernelmanagerd_request=load"
  if ! verify_system_kcs_file "${INSTALLED_KCS}"; then
    summary "boot_system_unchanged=no"
    STEP=""
    set_stage install-failed
    die "Boot/System 集合指纹改变或读不到，停止；不自动修复系统集合"
  fi
  summary "boot_system_unchanged=yes"
  case "${_load_rc}" in
    0|28)
      STEP=""
      record_boot
      set_stage installed
      summary "result=load-requested-reboot-required"
      log "装载请求已处理，还未证明新 AuxKC 已采用或两份组件已加载。"
      approval_hint
      log "如果系统明确只要求重启，按它的提示重启；回来再跑同一条命令做 P1。"
      ;;
    27)
      STEP=""
      record_boot
      set_stage awaiting-approval
      summary "result=awaiting-approval"
      log "kmutil 返回 27：本次装载请求需要用户批准，包和事务记录保留。"
      approval_hint
      ;;
    *)
      STEP=""
      _withdraw_ok=yes
      if ! withdraw_kexts kmutil-failed; then _withdraw_ok=no; fi
      summary "source_withdrawn=${_withdraw_ok}"
      set_stage install-failed
      die "装载请求失败（原码 ${_load_rc}），安装源撤出状态=${_withdraw_ok}；缓存/暂存尚未核验。再次运行只进入受控回滚，不重新安装。"
      ;;
  esac
  capture csrutil.txt csrutil status
  log "证据目录：${EV}"
}

# ---- 第 3 步：P1 判定 -------------------------------------------------------
do_p1() {
  _entry=$(stage)
  if same_boot; then
    if [ "${_entry}" = "awaiting-approval" ]; then
      log "还在等批准：先在“系统设置 → 隐私与安全性”里点“允许”，按提示重启，再跑同一条命令。"
    else
      log "kext 已安装，但还没重启。请先 sudo reboot，再跑同一条命令。"
    fi
    exit 3
  fi
  open_evidence p1
  log "== 第 3 步：本次开机的 P1 证据核验 =="
  check_build
  [ -n "${PY}" ] || die "找不到可用的 python3"
  capture nvram-csr-p1.plist nvram -x csr-active-config || { set_stage p1-failed; die "P1 的 SIP 查询失败"; }
  _p1_csr=$("${PY}" "${TOOLS}/field_check.py" nvdata "${EV}/nvram-csr-p1.plist" csr-active-config 2>>"${EV}/transcript.txt") \
    || { set_stage p1-failed; die "P1 的 SIP 数据解析失败"; }
  _p1_args=$(sysctl -n kern.bootargs 2>/dev/null) || { set_stage p1-failed; die "P1 启动参数查询失败"; }
  printf '%s\n' "${_p1_args}" > "${EV}/bootargs-p1.txt"
  [ -s "${INSTALLED_KCS}" ] || { set_stage p1-failed; die "缺安装集合基线，旧事务证据未闭合，请 --rollback"; }
  verify_system_kcs_file "${INSTALLED_KCS}" || { set_stage p1-failed; die "P1 的 Boot/System 集合已变化，停止"; }
  _fix="${ROOT}/fork/${FIX_REL}"
  capture showloaded.txt kmutil showloaded || { set_stage p1-failed; die "kmutil showloaded 失败"; }
  capture kmutil-aux.txt kmutil showloaded --collection aux
  _gfx=$(snapshot_gfx gfx-p1.plist) || { set_stage p1-failed; die "读不到 GFX0"; }
  printf '%s\n' "${_gfx}" > "${EV}/gfx-p1.txt"
  _path=$(check_gfx_path ioreg-tree-p1.txt) || { set_stage p1-failed; die "读不到 IOService 设备树"; }
  printf '%s\n' "${_path}" > "${EV}/gfx-path-p1.txt"
  _rt_uuid=$("${PY}" "${TOOLS}/field_check.py" json-field "${_fix}/deferred-runtime.json" candidate_uuid) \
    || { set_stage p1-failed; die "读不到运行时收据"; }
  _gate_uuid=$("${PY}" "${TOOLS}/field_check.py" json-field "${_fix}/manual-gate-current.json" uuid) \
    || { set_stage p1-failed; die "读不到控制器收据"; }
  _gate_id=$("${PY}" "${TOOLS}/field_check.py" json-field "${_fix}/manual-gate-current.json" identifier) \
    || { set_stage p1-failed; die "读不到控制器标识"; }
  _rt=$(kv "$("${PY}" "${TOOLS}/field_check.py" loaded "${EV}/showloaded.txt" "${TGL_ID}" "${_rt_uuid}" 2>>"${EV}/transcript.txt")" loaded)
  _gate=$(kv "$("${PY}" "${TOOLS}/field_check.py" loaded "${EV}/showloaded.txt" "${_gate_id}" "${_gate_uuid}" 2>>"${EV}/transcript.txt")" loaded)
  summary "runtime_loaded=${_rt}"
  summary "controller_loaded=${_gate}"
  summary "$(printf '%s' "${_gfx}" | tr '\n' ' ')"
  summary "$(printf '%s' "${_path}" | tr '\n' ' ')"
  _why=""
  _load_why=""
  [ "$(kv "${_p1_csr}" csr-active-config)" = "${CSR_RELAXED}" ] || _why="${_why} SIP未按试验配置生效"
  case " ${_p1_args} " in *" -allow3d "*) : ;; *) _why="${_why} 缺-allow3d" ;; esac
  case " ${_p1_args} " in *" -x "*) _why="${_why} 安全模式" ;; esac
  if [ "${_gate}" = "yes" ]; then
    capture controller-p1.plist ioreg -r -c ReimsADLManualActivation -l -a || _why="${_why} 控制器查询失败"
    _p1_controller=$("${PY}" "${TOOLS}/field_check.py" controller "${EV}/controller-p1.plist" 2>&1)
    [ "$(kv "${_p1_controller}" controller_ready)" = "yes" ] || _why="${_why} 控制器服务未就绪"
  fi
  [ "${_rt}" = "yes" ] || _load_why="${_load_why} TGL运行时加载状态=${_rt}"
  [ "${_gate}" = "yes" ] || _load_why="${_load_why} 控制器加载状态=${_gate}"
  [ "$(kv "${_gfx}" device_id)" = "ffff0000" ] || _why="${_why} device-id=$(kv "${_gfx}" device_id)"
  [ "$(kv "${_gfx}" firmware_fb)" = "1" ] || _why="${_why} 固件帧缓冲=$(kv "${_gfx}" firmware_fb)"
  [ "$(kv "${_gfx}" accelerator)" = "0" ] || _why="${_why} 加速器已存在=$(kv "${_gfx}" accelerator)"
  [ "$(kv "${_gfx}" native_fb)" = "0" ] || _why="${_why} 原生帧缓冲=$(kv "${_gfx}" native_fb)"
  [ "$(kv "${_path}" gfx_path_ok)" = "yes" ] || _why="${_why} GFX0路径=$(kv "${_path}" gfx_path)（要求 ${EXPECT_GFX_PATH}）"
  if [ -n "${_why}${_load_why}" ]; then
    capture kmutil-aux-collection.txt kmutil inspect --show-kext-uuids -A "${AUX_KC}"
    capture kernelmanagerd-log.txt command log show --last boot --style compact \
      --predicate 'process == "kernelmanagerd" OR process == "syspolicyd" OR eventMessage CONTAINS "ReimsTGLBoot" OR eventMessage CONTAINS "ReimsADLManualActivation"'
    capture csrutil-p1.txt csrutil status
  fi
  # 等批准只由实际 load 返回27承接，不能从缺模块猜测，也不能把一次普通重启说成已批准。
  _only_missing=yes
  for _s in "${_rt}" "${_gate}"; do
    case "${_s}" in yes|no) : ;; *) _only_missing=no ;; esac
  done
  if [ -z "${_why}" ] && [ -n "${_load_why}" ] && [ "${_only_missing}" = "yes" ]; then
    set_stage approval-unresolved
    summary "P1=UNVERIFIED"
    summary "result=approval-unresolved"
    die "组件尚未进入本 Boot 可用状态：${_load_why}。是否已批准/重建未知，不再盲目重启；把政策与集合证据带回。"
  fi
  _why="${_load_why}${_why}"
  if [ -n "${_why}" ]; then
    set_stage p1-failed
    summary "P1=FAIL"
    if [ "${_entry}" = "awaiting-approval" ]; then
      die "P1 未通过：请求批准后的新 Boot 仍未满足证据门禁：${_why}；不把这次启动当成已批准（见政策与集合日志）。"
    fi
    die "P1 未通过：${_why}（见政策/集合日志）。不要运行 P2，需要恢复时使用 --rollback。"
  fi
  record_boot
  set_stage p1-pass
  summary "P1=PASS"
  summary "result=ok"
  log ""
  log "P1 证据门通过：本次两包身份、控制器服务、当前隔离与启动前提一致。"
  log "此刻注册表未见加速器/原生显示实例；这不证明此前从未碰硬件，GPU 功能仍未验证。"
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
  if ! same_boot; then
    log "历史 P1 不属于本次开机。先重新核验 P1，本次调用不运行 P2。"
    do_p1
    return
  fi
  open_evidence p2
  check_build
  log "== 第 4 步：P2 只激活加速器（显示仍走 IONDRV，不重启桌面）=="
  # 动 GPU 之前再确认一次部署状态且查询本身成功：非零查询结果一律 fail closed，绝不能跑 P2
  [ -n "${PY}" ] || die "找不到可用的 python3"
  _pre=""
  if ! nvram -x csr-active-config > "${EV}/nvram-csr-p2.plist" 2>&1; then
    _pre="${_pre} SIP查询失败"
    _csr=""
  else
    _csr=$("${PY}" "${TOOLS}/field_check.py" nvdata "${EV}/nvram-csr-p2.plist" csr-active-config 2>>"${EV}/transcript.txt") \
      || { _pre="${_pre} SIP解析失败"; _csr=""; }
  fi
  if _args=$(sysctl -n kern.bootargs 2>/dev/null); then
    printf '%s\n' "${_args}" > "${EV}/bootargs-p2.txt"
  else
    _pre="${_pre} bootargs查询失败"
    _args=""
  fi
  _gfx=$(snapshot_gfx gfx-p2-before.plist) || { _pre="${_pre} GFX0查询失败"; _gfx=""; }
  if [ -s "${INSTALLED_KCS}" ]; then
    verify_system_kcs_file "${INSTALLED_KCS}" || _pre="${_pre} Boot/System集合已变"
  else
    _pre="${_pre} 缺安装集合基线"
  fi
  [ "$(kv "${_csr}" csr-active-config)" = "${CSR_RELAXED}" ] || _pre="${_pre} SIP=$(kv "${_csr}" csr-active-config)"
  case " ${_args} " in *" -allow3d "*) : ;; *) _pre="${_pre} 缺-allow3d" ;; esac
  case " ${_args} " in *" -x "*) _pre="${_pre} 安全模式" ;; esac
  [ "$(kv "${_gfx}" device_id)" = "ffff0000" ] || _pre="${_pre} device-id=$(kv "${_gfx}" device_id)"
  if [ -n "${_pre}" ]; then
    summary "p2_precheck=${_pre}"
    die "部署状态未通过前置核验（${_pre}），不能跑 P2。如果在 Windows 里还原过，请执行 --rollback。"
  fi
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
  # 两种已知变体也算本工具写的：写入中途被打断（没记下改后哈希），以及 Windows 加了 -x 进安全模式
  if [ "${_ours}" = "no" ] && [ -f "${MOUNT_POINT}/${_name}/config.plist" ] && [ -n "${PY}" ] \
     && capture delta-verify-rollback.txt "${PY}" "${TOOLS}/oc_delta.py" verify --tolerate-safe-boot \
          --config "${_cfg}" --orig "${MOUNT_POINT}/${_name}/config.plist"; then
    _ours=yes
    log "现网 config 是本工具的增量（可能另加了 Windows 写的安全模式 -x），可以还原。"
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

rollback_stop() {
  STEP=""
  set_stage rollback-incomplete
  summary "result=rollback-incomplete"
  die "$1；为防卡开机不恢复 config（SIP 保持放宽），不清备份或 DIRTY。把证据带回，不无限重复同一失败命令。"
}

already_at_clean_baseline() {
  [ "$(stage)" = "start" ] || return 1
  [ ! -f "${BACKUP_POINTER}" ] && [ ! -f "${KMUTIL_DIRTY}" ] && [ ! -f "${COPY_MARKER}" ] || return 1
  ! ext_present "${EXT_DIR}/${GATE_NAME}" && ! ext_present "${EXT_DIR}/${RUNTIME_NAME}" || return 1
  capture baseline-aux-all.txt kmutil showloaded --collection aux --show all || return 1
  capture baseline-running.txt kmutil showloaded || return 1
  capture baseline-disk.txt kmutil inspect --show-kext-uuids -A "${AUX_KC}" || return 1
  _ba=$("${PY}" "${TOOLS}/field_check.py" absent "${EV}/baseline-aux-all.txt" loaded "${TGL_ID}" "${GATE_ID}" 2>&1) || return 1
  [ "$(kv "${_ba}" identifiers_absent)" = "yes" ] || return 1
  _br=$("${PY}" "${TOOLS}/field_check.py" absent "${EV}/baseline-running.txt" loaded "${TGL_ID}" "${GATE_ID}" 2>&1) || return 1
  [ "$(kv "${_br}" identifiers_absent)" = "yes" ] || return 1
  _bd=$("${PY}" "${TOOLS}/field_check.py" absent "${EV}/baseline-disk.txt" inspect "${TGL_ID}" "${GATE_ID}" --collection-path "${AUX_KC}" 2>&1) || return 1
  [ "$(kv "${_bd}" identifiers_absent)" = "yes" ] || return 1
  capture baseline-csr.plist nvram -x csr-active-config || return 1
  _bc=$("${PY}" "${TOOLS}/field_check.py" nvdata "${EV}/baseline-csr.plist" csr-active-config 2>&1) || return 1
  [ "$(kv "${_bc}" csr-active-config)" = "00000000" ] || return 1
  _bargs=$(sysctl -n kern.bootargs 2>/dev/null) || return 1
  case " ${_bargs} " in *" -allow3d "*|*" -x "*) return 1 ;; esac
  _bgfx=$(snapshot_gfx baseline-gfx.plist) || return 1
  [ "$(kv "${_bgfx}" device_id)" = "${EXPECT_DEVICE}" ] \
    && [ "$(kv "${_bgfx}" accelerator)" = "0" ] \
    && [ "$(kv "${_bgfx}" native_fb)" = "0" ] || return 1
  return 0
}

verify_rollback_system_kcs() {
  if [ -f "${INSTALLED_KCS}" ]; then
    verify_system_kcs_file "${INSTALLED_KCS}" \
      || rollback_stop "Boot/System 系统集合与安装前基线不一致或无法读取，拒绝洗白变化"
  fi
  if [ -f "${ROLLBACK_KCS}" ]; then
    verify_system_kcs_file "${ROLLBACK_KCS}" \
      || rollback_stop "Boot/System 系统集合与回滚基线不一致或无法读取"
  fi
}

do_rollback() {
  case "$(stage)" in
    rollback-pending-reboot|rollback-awaiting-approval) finish_rollback; return ;;
    rollback-final-reboot) finish_rollback_baseline; return ;;
  esac
  open_evidence rollback
  log "== 回滚：先撤安装源，再请求 AuxKC 重建；核验后才还原 config =="
  if ! verify_build_and_volume; then
    if [ "$(stage)" != "start" ] || [ -f "${BACKUP_POINTER}" ] || [ -f "${KMUTIL_DIRTY}" ] || [ -f "${COPY_MARKER}" ]; then
      rollback_stop "${BUILD_ERR}"
    fi
    die "${BUILD_ERR}"
  fi
  [ -n "${PY}" ] || rollback_stop "找不到可用的 python3，不能核验回滚"
  check_kmutil_contract || rollback_stop "kmutil 契约检查失败，未发重建请求"
  if already_at_clean_baseline; then
    summary "result=already-at-baseline"
    log "当前已在部署前基线，且集合/内存/磁盘均无试验组件残留，无需重复回滚。"
    log "证据目录：${EV}"
    return 0
  fi
  if [ -f "${INSTALLED_KCS}" ]; then
    verify_system_kcs_file "${INSTALLED_KCS}" \
      || rollback_stop "Boot/System 系统集合与安装前基线不一致或无法读取，拒绝重采样洗白变化"
    cp "${INSTALLED_KCS}" "${ROLLBACK_KCS}" || rollback_stop "同步安装集合基线失败"
    summary "original_system_baseline=verified"
  else
    summary "original_system_baseline=unverified-legacy"
    if [ -f "${ROLLBACK_KCS}" ]; then
      verify_system_kcs_file "${ROLLBACK_KCS}" \
        || rollback_stop "Boot/System 系统集合与首次回滚记录不一致或无法读取"
    else
      take_system_kcs_pair "${EV}/system-kc-before.txt" || rollback_stop "读不到 Boot/System 集合指纹"
      cp "${EV}/system-kc-before.txt" "${ROLLBACK_KCS}" || rollback_stop "保存集合基线失败"
    fi
  fi
  STEP=rollback
  set_stage rollback-incomplete
  : > "${KMUTIL_DIRTY}" || rollback_stop "写回滚事务标记失败"
  # 两包分别撤出；任一步失败都留证，但不能恢复 SIP。
  _rw=yes
  if ! withdraw_kexts rollback; then _rw=no; fi
  summary "source_withdrawn=${_rw}"
  [ "${_rw}" = "yes" ] || rollback_stop "安装源没有全部撤出"

  record_boot
  printf 'rebuild\n' > "${ROOT}/ROLLBACK_REQUEST" || rollback_stop "保存请求类型失败"
  sync
  kmutil_visible kmutil-rollback.txt rebuild
  _rebuild_rc=$?
  printf '%s\n' "${_rebuild_rc}" > "${ROOT}/ROLLBACK_REQUEST_RC"
  summary "kmutil_rebuild_rc=${_rebuild_rc}"
  verify_rollback_system_kcs
  summary "boot_system_unchanged=yes"
  STEP=""
  case "${_rebuild_rc}" in
    0|28)
      set_stage rollback-pending-reboot
      summary "result=rollback-pending-reboot"
      log "AuxKC 重建请求已处理，尚未证明新集合已采用。config 和恢复记录保留。"
      log "按系统提示重启进 Tahoe，回来再运行同一条命令；它只做回滚核验，不会安装或激活 GPU。"
      ;;
    27)
      set_stage rollback-awaiting-approval
      summary "result=rollback-awaiting-approval"
      log "回滚请求需要系统确认/批准。config 和恢复记录保留。"
      approval_hint
      ;;
    *) rollback_stop "AuxKC 重建请求失败（原码 ${_rebuild_rc}）" ;;
  esac
  log "证据目录：${EV}"
}

finish_rollback() {
  if ! new_boot; then
    log "回滚仍在等待系统确认/批准和重启，不再发相同请求。完成提示后重启，再运行同一条命令。"
    exit 3
  fi
  open_evidence rollback-check
  verify_build_and_volume || rollback_stop "${BUILD_ERR}"
  [ -n "${PY}" ] || rollback_stop "找不到可用的 python3"
  [ "$(head -1 "${ROOT}/ROLLBACK_REQUEST" 2>/dev/null)" = "rebuild" ] \
    || rollback_stop "回滚请求记录缺失，不能把新开机当作清理证明"
  [ -s "${ROLLBACK_KCS}" ] || rollback_stop "回滚集合基线缺失"
  verify_rollback_system_kcs
  ! ext_present "${EXT_DIR}/${GATE_NAME}" && ! ext_present "${EXT_DIR}/${RUNTIME_NAME}" \
    || rollback_stop "目标安装源又出现，不能恢复 SIP"
  capture rollback-aux-all.txt kmutil showloaded --collection aux --show all \
    || rollback_stop "AuxKC 可用组件查询失败"
  capture rollback-running.txt kmutil showloaded || rollback_stop "内存组件查询失败"
  capture rollback-disk.txt kmutil inspect --show-kext-uuids -A "${AUX_KC}" || rollback_stop "磁盘 AuxKC 查询失败"
  for _proof in rollback-aux-all.txt rollback-running.txt; do
    _pv=$("${PY}" "${TOOLS}/field_check.py" absent "${EV}/${_proof}" loaded "${TGL_ID}" "${GATE_ID}" 2>&1) \
      || rollback_stop "集合/内存排除解析失败：${_proof}（${_pv}）"
    printf '%s\n' "${_pv}" >> "${EV}/rollback-checks.txt"
    [ "$(kv "${_pv}" identifiers_absent)" = "yes" ] \
      || rollback_stop "集合/内存排除证据不足：${_proof}（${_pv}）"
  done
  _pd=$("${PY}" "${TOOLS}/field_check.py" absent "${EV}/rollback-disk.txt" inspect "${TGL_ID}" "${GATE_ID}" --collection-path "${AUX_KC}" 2>&1) \
    || rollback_stop "磁盘集合排除解析失败（${_pd}）"
  printf '%s\n' "${_pd}" >> "${EV}/rollback-checks.txt"
  [ "$(kv "${_pd}" identifiers_absent)" = "yes" ] || rollback_stop "磁盘集合排除证据不足（${_pd}）"
  # 标准 rebuild 按仍存在的安装源评估；源码已撤出且新启动/磁盘均排除后，不擅自清全局 staging/政策数据库。
  capture kernelmanagerd-after-rollback.txt command log show --last boot --style compact \
    --predicate 'process == "kernelmanagerd" OR process == "syspolicyd"'
  summary "source_absent=yes"
  summary "new_target_boot=$(boot_id)"
  summary "effective_aux_absent=yes"
  summary "running_absent=yes"
  summary "disk_aux_absent=yes"
  rollback_config || rollback_stop "config 还原核验失败"
  unmount_esp
  record_boot
  set_stage rollback-final-reboot
  summary "result=config-restored-final-reboot-required"
  log "新开机的集合/内存检查已排除目标，config 已还原；还没完成最后的 NVRAM 验证。"
  log "请再经 SanDisk/OpenCore 重启进 Tahoe，回来运行同一条命令做最后核验。"
  log "证据目录：${EV}"
}

finish_rollback_baseline() {
  if ! new_boot; then
    log "config 已还原，但要经 SanDisk/OpenCore 再启动一次才写回 NVRAM。请重启后运行同一条命令。"
    exit 3
  fi
  open_evidence rollback-final
  verify_build_and_volume || rollback_stop "${BUILD_ERR}"
  [ -n "${PY}" ] || rollback_stop "找不到可用的 python3"
  [ -s "${ROLLBACK_KCS}" ] || rollback_stop "最终核验缺少集合基线记录"
  verify_rollback_system_kcs
  summary "boot_system_unchanged=yes"
  ! ext_present "${EXT_DIR}/${GATE_NAME}" && ! ext_present "${EXT_DIR}/${RUNTIME_NAME}" \
    || rollback_stop "最终核验发现目标安装源残留"
  capture nvram-csr-final.plist nvram -x csr-active-config || rollback_stop "最终 SIP 查询失败"
  _fc=$("${PY}" "${TOOLS}/field_check.py" nvdata "${EV}/nvram-csr-final.plist" csr-active-config 2>>"${EV}/transcript.txt") \
    || rollback_stop "最终 SIP 数据解析失败"
  [ "$(kv "${_fc}" csr-active-config)" = "00000000" ] || rollback_stop "最终 SIP 尚未恢复基线"
  _fa=$(sysctl -n kern.bootargs 2>/dev/null) || rollback_stop "最终启动参数查询失败"
  case " ${_fa} " in *" -allow3d "*|*" -x "*) rollback_stop "最终启动参数仍有试验/安全模式标记" ;; esac
  _fg=$(snapshot_gfx gfx-final.plist) || rollback_stop "最终 GFX0 查询失败"
  [ "$(kv "${_fg}" device_id)" = "${EXPECT_DEVICE}" ] \
    && [ "$(kv "${_fg}" accelerator)" = "0" ] \
    && [ "$(kv "${_fg}" native_fb)" = "0" ] || rollback_stop "最终设备/实例未恢复基线"
  locate_esp || rollback_stop "最终 ESP 核验失败：${ESP_ERR}"
  summary "final_esp_source=${ESP_SRC}"
  if [ "${BOOT_ESP_STATE}" = "verified" ]; then
    summary "boot_source=verified-boot-path"
  else
    summary "boot_source=unverified-no-bootpath"
    log "注意：当前 OC 未发布 NVRAM boot-path（ExposeSensitiveData 未含 0x01），启动来源记为 unverified；已核验目标 ESP 配置与主板 NVRAM 基线。"
  fi
  if [ -f "${BACKUP_POINTER}" ]; then
    _final_before=$(sed -n 2p "${BACKUP_POINTER}")
    [ -n "${_final_before}" ] && [ "$(take_sha "${MOUNT_POINT}/EFI/OC/config.plist")" = "${_final_before}" ] \
      || rollback_stop "最终 config 已不是记录的基线版本"
  else
    _fdelta=$("${PY}" "${TOOLS}/oc_delta.py" status --config "${MOUNT_POINT}/EFI/OC/config.plist" 2>>"${EV}/transcript.txt") \
      || rollback_stop "最终 config 状态核验失败"
    [ "$(kv "${_fdelta}" delta)" = "absent" ] || rollback_stop "最终 config 仍含试验增量"
  fi
  unmount_esp
  capture rollback-final-aux-all.txt kmutil showloaded --collection aux --show all || rollback_stop "最终 AuxKC 可用组件查询失败"
  _fa_abs=$("${PY}" "${TOOLS}/field_check.py" absent "${EV}/rollback-final-aux-all.txt" loaded "${TGL_ID}" "${GATE_ID}" 2>&1) \
    || rollback_stop "最终 AuxKC 可用组件解析失败"
  [ "$(kv "${_fa_abs}" identifiers_absent)" = "yes" ] || rollback_stop "最终 AuxKC 可用组件仍含目标"
  capture rollback-final-running.txt kmutil showloaded || rollback_stop "最终内存组件查询失败"
  _fl=$("${PY}" "${TOOLS}/field_check.py" absent "${EV}/rollback-final-running.txt" loaded "${TGL_ID}" "${GATE_ID}" 2>&1) \
    || rollback_stop "最终内存组件解析失败"
  [ "$(kv "${_fl}" identifiers_absent)" = "yes" ] || rollback_stop "最终目标组件仍存在或证据未知"
  rm -f "${KMUTIL_DIRTY}" "${COPY_MARKER}" "${BACKUP_POINTER}" "${ESP_UUID_FILE}" "${P2_MARK}" "${ROOT}/CRASH_EV" \
    "${ROOT}/ROLLBACK_REQUEST" "${ROOT}/ROLLBACK_REQUEST_RC" "${ROLLBACK_KCS}" \
    "${ROOT}/LOAD_REQUEST_RC" "${INSTALLED_KCS}" "${INSTALLED_RT_RECEIPT}" "${INSTALLED_GATE_RECEIPT}" \
    "${ROOT}/SYSTEM_VOLUME_UUID"
  set_stage start
  summary "result=rolled-back"
  log "回滚完成：新集合排除目标、config/NVRAM/设备基线均已核验。不会在本次调用重新部署。"
  log "证据目录：${EV}"
}

show_status() {
  printf 'stage=%s\n' "$(stage)"
  printf 'persisted_stage=%s\n' "$(stage)"
  if [ -f "${BACKUP_POINTER}" ]; then printf 'backup=%s\n' "$(sed -n 1p "${BACKUP_POINTER}")"; fi
  case "$(stage)" in
    p1-pass|p2-pass|installed|awaiting-approval)
      open_evidence status
      _ss_ok=yes
      _ss_build=$(sw_vers -buildVersion 2>/dev/null) || { _ss_ok=no; _ss_build=""; }
      _ss_args=$(sysctl -n kern.bootargs 2>/dev/null) || { _ss_ok=no; _ss_args=""; }
      _ss_gfx=$(snapshot_gfx gfx-status.plist 2>/dev/null) || { _ss_ok=no; _ss_gfx=""; }
      _ss_csr=""
      if [ -n "${PY}" ] && capture csr-status.plist nvram -x csr-active-config; then
        _ss_csr=$("${PY}" "${TOOLS}/field_check.py" nvdata "${EV}/csr-status.plist" csr-active-config 2>/dev/null) \
          || { _ss_ok=no; _ss_csr=""; }
      else
        _ss_ok=no
      fi
      _ss_bid=$(boot_id) || { _ss_ok=no; _ss_bid=""; }
      _ss_state=unverified
      if [ "${_ss_ok}" = "yes" ] && [ -n "${_ss_gfx}" ] && [ -n "$(kv "${_ss_csr}" csr-active-config)" ]; then
        _ss_state=experiment-config-active
        [ "${_ss_build}" = "${EXPECT_BUILD}" ] || _ss_state=recovery-needed
        [ "$(kv "${_ss_gfx}" device_id)" = "ffff0000" ] || _ss_state=recovery-needed
        [ "$(kv "${_ss_csr}" csr-active-config)" = "${CSR_RELAXED}" ] || _ss_state=recovery-needed
        case " ${_ss_args} " in *" -allow3d "*) : ;; *) _ss_state=recovery-needed ;; esac
        case " ${_ss_args} " in *" -x "*) _ss_state=recovery-needed ;; esac
      fi
      if [ "${_ss_state}" = "experiment-config-active" ] && [ "$(stage)" = "p1-pass" ]; then
        if [ ! -s "${BOOT_FILE}" ] || [ "$(head -1 "${BOOT_FILE}")" != "${_ss_bid}" ]; then
          _ss_state=p1-expired
        fi
      fi
      printf 'observed_state=%s\n' "${_ss_state}"
      summary "observed_state=${_ss_state}"
      case "${_ss_state}" in
        recovery-needed) printf 'next=历史进度与当前配置不符，不运行P2；使用 --rollback 受控恢复\n'; return ;;
        unverified) printf 'next=当前状态读不到，带回status证据；不运行P2\n'; return ;;
        p1-expired) printf 'next=同一条命令先重新核验本Boot的P1，不直接运行P2\n'; return ;;
      esac ;;
  esac
  # panic 报告由开机后的服务异步写出，崩溃检测那一刻可能还没有：每次看状态都补收一次
  if [ "$(stage)" = "p2-crashed" ] && [ -f "${P2_MARK}" ] && [ -s "${ROOT}/CRASH_EV" ]; then
    _cev=$(head -1 "${ROOT}/CRASH_EV")
    if [ -d "${_cev}/panic" ]; then
      find "${PANIC_DIR}" -type f \( -name '*.panic' -o -name 'Kernel*' -o -name 'panic*' \) -newer "${P2_MARK}" -exec cp {} "${_cev}/panic/" \; 2>/dev/null
      printf 'panic_files=%s（%s）\n' "$(ls "${_cev}/panic" 2>/dev/null | wc -l | tr -d ' ')" "${_cev}/panic"
    fi
  fi
  case "$(stage)" in
    start)
      if [ -f "${KMUTIL_DIRTY}" ] || [ -f "${COPY_MARKER}" ]; then
        printf 'observed_state=dirty-markers-present\n'
        printf 'next=检测到未清理的装载/复制标记，再运行同一条命令进入受控回滚\n'
      else
        printf 'next=sudo sh %s（写入 OC 配置）\n' "${SELF}"
      fi ;;
    config-applied)
      if [ -f "${KMUTIL_DIRTY}" ] || [ -f "${COPY_MARKER}" ]; then
        printf 'observed_state=dirty-markers-present\n'
        printf 'next=检测到未完复制/装载事务，再运行同一条命令进入受控回滚\n'
      else
        printf 'next=重启后再跑一次（安装 kext）\n'
      fi ;;
    installed) printf 'next=重启后再跑一次（P1 判定）\n' ;;
    awaiting-approval) printf 'next=处理实际系统批准/重启提示，再运行；没提示就带回证据\n' ;;
    approval-unresolved) printf 'next=组件缺席原因未确认，带回政策和集合日志；不盲目重启\n' ;;
    p1-pass) printf 'next=保存工作后再跑一次（P2）\n' ;;
    p2-attempted) printf 'next=再跑一次（判断是崩溃还是被打断）\n' ;;
    p2-interrupted) printf 'next=重启后再跑一次（先复核 P1，不是崩溃）\n' ;;
    p2-pass) printf 'next=把证据带回；不再需要操作\n' ;;
    install-failed) printf 'next=再运行同一条命令（只进入受控回滚，不重装）\n' ;;
    rollback-pending-reboot) printf 'next=按系统提示重启后运行同一条命令（只核验回滚）\n' ;;
    rollback-awaiting-approval) printf 'next=先完成系统确认/批准并按提示重启，再运行同一条命令\n' ;;
    rollback-final-reboot) printf 'next=经 SanDisk/OpenCore 重启后运行同一条命令（最终基线核验）\n' ;;
    rollback-incomplete) printf 'next=回滚证据不足，保留当前状态；带回证据，不盲目重复\n' ;;
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
  start)
    if [ -f "${KMUTIL_DIRTY}" ] || [ -f "${COPY_MARKER}" ]; then do_rollback; else do_config; fi ;;
  config-applied)
    if [ -f "${KMUTIL_DIRTY}" ] || [ -f "${COPY_MARKER}" ]; then do_rollback; else do_install; fi ;;
  install-failed) do_rollback ;;
  rollback-pending-reboot|rollback-awaiting-approval) finish_rollback ;;
  rollback-final-reboot) finish_rollback_baseline ;;
  installed) do_p1 ;;
  awaiting-approval) do_p1 ;;
  p1-pass) do_p2 ;;
  p2-attempted) do_p2_crash_check ;;
  p2-interrupted) do_p2_interrupted ;;
  p2-pass) show_status ;;
  *) log "当前阶段 $(stage) 是失败终态，不自动重试。"; show_status; exit 1 ;;
esac
