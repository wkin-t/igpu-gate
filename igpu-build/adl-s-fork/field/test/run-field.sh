#!/bin/bash
# run-field.sh —— adl-s-field.sh 的离线仿真（桩命令模拟 macOS，不需要 Apple 二进制）
#
# 覆盖：完整推进 start→p2-pass、未重启续跑必须停、回滚（先撤 kext、每步失败继续、
#       rollback-incomplete、哈希核对、按分区 UUID 找 ESP）、设备不符/路径不符/未验证恢复 EFI/
#       SIP 未生效 时不动现网、kmutil 失败自动撤出、P1 失败、P2 失败（probe 失败与 start 卡住分开）、
#       [IGPU] 全量分类、P2 崩溃按时间过滤证据、Ctrl-C 与崩溃分开、信号 trap、--status 走 sudo、
#       工作副本权限、csr 取值、补丁控制流断言。
set -u
H=$(cd "$(dirname "$0")" && pwd)
FIELD=$(cd "${H}/.." && pwd)
REPO=$(cd "${FIELD}/.." && pwd)
SCRIPT="${FIELD}/adl-s-field.sh"
P=0; F=0
ok() { P=$((P+1)); printf '  ✓ %s\n' "$1"; }
no() { F=$((F+1)); printf '  ✗ %s（%s）\n' "$1" "${2:-}"; [ -f "${T}/out.txt" ] && tail -8 "${T}/out.txt" | sed 's/^/     /'; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "期望 [$3] 实际 [$2]"; fi; }
has() { if grep -q -- "$2" $3 2>/dev/null; then ok "$1"; else no "$1" "$3 里没有 [$2]"; fi; }
lacks() { if grep -q -- "$2" $3 2>/dev/null; then no "$1" "$3 里不该有 [$2]"; else ok "$1"; fi; }
PYBIN=$(command -v python3 2>/dev/null || command -v python)
REAL_MV=$(command -v mv)
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }
ESP_UUID=11111111-2222-4333-8444-555555555555

mk() {
  T=$(mktemp -d 2>/dev/null || mktemp -d -t fieldsim)
  B="${T}/bin"; ESP="${T}/ESP"; FORK="${T}/fork"; EXT="${T}/Extensions"
  mkdir -p "${B}" "${ESP}/EFI/OC" "${EXT}" "${T}/home" "${T}/panic" \
           "${FORK}/field" "${FORK}/prebuilt/ReimsADLManualActivation.kext/Contents/MacOS" \
           "${FORK}/desktop-manual-20260917/fix/manual-gate" "${T}/tgl/AppleIntelTGLGraphics.kext/Contents/MacOS"
  cp "${SCRIPT}" "${FIELD}/oc_delta.py" "${FIELD}/field_check.py" "${FORK}/field/"
  cp "${H}/fixture-config.plist" "${ESP}/EFI/OC/config.plist"
  ORIG_SHA=$(sha "${ESP}/EFI/OC/config.plist")
  echo ok > "${T}/home/RECOVERY-EFI-VERIFIED.txt"
  echo boot-1 > "${T}/bootid"
  printf 'gate-binary' > "${FORK}/prebuilt/ReimsADLManualActivation.kext/Contents/MacOS/ReimsADLManualActivation"
  printf '<plist version="1.0"><dict/></plist>\n' > "${FORK}/prebuilt/ReimsADLManualActivation.kext/Contents/Info.plist"
  printf 'control' > "${FORK}/prebuilt/control"
  "${PYBIN}" - "${FORK}/prebuilt" <<'EOP'
import hashlib, json, pathlib, sys
b = pathlib.Path(sys.argv[1]); k = b / "ReimsADLManualActivation.kext"
h = {r: hashlib.sha256((k / r).read_bytes()).hexdigest() for r in ("Contents/MacOS/ReimsADLManualActivation", "Contents/Info.plist")}
(b / "manual-gate-current.json").write_text(json.dumps({"identifier": "lab.reims.ReimsADLManualActivation", "uuid": "AAAA0000-0000-0000-0000-000000000001", "hashes": h}))
EOP
  printf 'tgl' > "${T}/tgl/AppleIntelTGLGraphics.kext/Contents/MacOS/AppleIntelTGLGraphics"
  "${PYBIN}" -c "import plistlib,sys;open(sys.argv[1],'wb').write(plistlib.dumps({'CFBundleIdentifier':'com.apple.driver.AppleIntelTGLGraphics','CFBundleVersion':'16.0.0'}))" \
    "${T}/tgl/AppleIntelTGLGraphics.kext/Contents/Info.plist"

  # 桩：补丁脚本（真脚本需要 Apple 二进制，CI 无法提供）
  cat > "${FORK}/desktop-manual-20260917/fix/prepare-deferred-runtime.py" <<'EOP'
import json, pathlib, sys, os
if os.environ.get("FAKE_PREPARE_RC", "0") != "0": sys.exit(int(os.environ["FAKE_PREPARE_RC"]))
if sys.argv[1] == "--check-only": print(json.dumps({"ok": True})); sys.exit(0)
base = pathlib.Path(__file__).resolve().parent
k = base / "ReimsTGLManualRuntime.kext/Contents/MacOS"; k.mkdir(parents=True)
(k / "AppleIntelTGLGraphics").write_bytes(b"patched")
(base / "deferred-runtime.json").write_text(json.dumps({"candidate_uuid": "bbbb0000000000000000000000000002"}))
print("{}")
EOP
  # 桩：igpu-start --accel-only
  cat > "${FORK}/igpu-start" <<'EOS'
#!/bin/sh
[ -n "${FAKE_P2_CRASH:-}" ] && { echo crash > "${FAKE}/crashed"; kill -9 "${PPID}"; exit 0; }
[ -n "${FAKE_P2_SIGNAL:-}" ] && { kill "-${FAKE_P2_SIGNAL}" "${PPID}"; exit 130; }
d="$(dirname "$0")/desktop-manual-20260917/fix/session-$(date +%Y%m%d-%H%M%S)-${$}-accel-only"
mkdir -p "$d"
if [ -n "${FAKE_P2_PREFLIGHT:-}" ]; then
  echo '{"stage": "preflight", "error": "Unsupported macOS build"}' > "$d/failure.json"; exit 1
fi
[ -n "${FAKE_P2_FAILURE_OUTCOME:-}" ] && echo "{\"stage\": \"accel-only\", \"outcome\": \"${FAKE_P2_FAILURE_OUTCOME}\"}" > "$d/failure.json"
case "${FAKE_P2_OUTCOME:-returned}" in
  none) : ;;
  stuck) : > "${FAKE}/accel"; : > "${FAKE}/accel-busy" ;;
  *) : > "${FAKE}/accel" ;;
esac
if [ "${FAKE_P2_OUTCOME:-returned}" != "none" ] || [ -n "${FAKE_P2_FOUND_ONLY:-}" ]; then
  [ -z "${FAKE_NO_FOUND:-}" ] && echo "2099-01-01 kernel[0:1] [IGPU] IntelAccelerator::probe: Found device with ID ${FAKE_FOUND_ID:-0x46808086}, revision 0xc, PCH id 0x7a80, PCH rev 0x11 at PCI 0:2:0" >> "$d/igpu-log.txt"
fi
cat >> "$d/igpu-log.txt" <<EOL
[IGPU] HWCAPS - GPU Sku: ${FAKE_SKU:-2}
[IGPU] HWCAPS - NumSlices:1      SliceCountFuse:0x1
[IGPU] HWCAPS - NumSubSlices:4   DualSubSliceCountFuse:0x3
[IGPU] HWCAPS - MaxEUPerSubSlice:8   EUDisableFuses:0x0  ExecutionUnitCount:32
[IGPU] HWCAPS - L3BankCount: ${FAKE_L3:-4}
[IGPU] Graphics Firmware Version: 70.1.1.0
[IGPU] Skipping RC6 Ctx Base, it is not in WOPCM range.
${FAKE_IGPU_EXTRA:-}
EOL
[ "${FAKE_P2_RC:-0}" = 0 ] && echo '{}' > "$d/result.json"
exit "${FAKE_P2_RC:-0}"
EOS

  # 系统命令桩
  cat > "${B}/id" <<'EOS'
#!/bin/sh
[ "$1" = "-u" ] && { echo "${FAKE_UID:-0}"; exit 0; }; exec /usr/bin/id "$@"
EOS
  cat > "${B}/sw_vers" <<'EOS'
#!/bin/sh
echo "${FAKE_BUILD:-25G83}"
EOS
  cat > "${B}/sysctl" <<'EOS'
#!/bin/sh
case "$2" in
  kern.bootsessionuuid) cat "${FAKE}/bootid" ;;
  kern.bootargs) if grep -q allow3d "${FAKE}/ESP/EFI/OC/config.plist" && [ -z "${FAKE_NO_ALLOW3D:-}" ]; then echo "-v -allow3d"; else echo "-v"; fi ;;
esac
EOS
  cat > "${B}/ioreg" <<'EOS'
#!/bin/sh
if [ "$1" = "-p" ]; then
  printf '+-o Root  <class IORegistryEntry, id 0x100000100, retain 28>\n'
  printf '  +-o iMac20,2  <class IOPlatformExpertDevice, id 0x100000110, registered, matched, active, busy 0 (1 ms), retain 40>\n'
  printf '    +-o AppleACPIPlatformExpert  <class AppleACPIPlatformExpert, id 0x100000111, registered, matched, active, busy 0 (1 ms), retain 40>\n'
  printf '    | +-o %s  <class IOACPIPlatformDevice, id 0x100000120, registered, matched, active, busy 0 (1 ms), retain 40>\n' "${FAKE_ROOT_BRIDGE:-PC00}"
  printf '    | | +-o AppleACPIPCI  <class AppleACPIPCI, id 0x100000121, registered, matched, active, busy 0 (1 ms), retain 40>\n'
  printf '    | | | +-o %s  <class IOPCIDevice, id 0x100000122, registered, matched, active, busy 0 (1 ms), retain 40>\n' "${FAKE_GFX_NODE:-GFX0@2}"
  printf '    | | | | +-o IONDRVFramebuffer  <class IONDRVFramebuffer, id 0x100000123, registered, matched, active, busy 0 (1 ms), retain 40>\n'
  printf '    +-o IOResources  <class IOResources, id 0x100000112, registered, matched, active, busy 0 (1 ms), retain 40>\n'
  exit 0
fi
exec "${FAKE_PY}" - <<'EOP'
import os, plistlib, sys
fake = os.environ["FAKE"]
iso = os.path.exists(os.path.join(fake, "applied-on-boot"))
dev = bytes.fromhex(os.environ.get("FAKE_DEVID", "ffff0000" if iso else "80460000"))
kids = [{"IOObjectClass": "IONDRVFramebuffer", "IORegistryEntryChildren": []}]
if os.path.exists(os.path.join(fake, "accel")):
    kids.append({"IOObjectClass": "IntelAccelerator", "IOServiceState": 0, "IORegistryEntryChildren": []})
busy = 1 if os.path.exists(os.path.join(fake, "accel-busy")) else 0
sys.stdout.buffer.write(plistlib.dumps([{"IOObjectClass": "IOPCIDevice", "IOServiceBusyState": busy, "device-id": dev,
    "revision-id": bytes.fromhex("0c000000"), "vendor-id": bytes.fromhex("86800000"), "IORegistryEntryChildren": kids}]))
EOP
EOS
  cat > "${B}/nvram" <<'EOS'
#!/bin/sh
case "$1" in
  -x) exec "${FAKE_PY}" -c "import plistlib,sys,os;v=os.environ.get('FAKE_CSR') or ('03000000' if os.path.exists(os.environ['FAKE']+'/applied-on-boot') else '00000000');sys.stdout.buffer.write(plistlib.dumps({'csr-active-config':bytes.fromhex(v)}))" ;;
  *:boot-path)
    [ -n "${FAKE_NO_BOOTPATH:-}" ] && exit 1
    printf '%s\tPciRoot(0x0)/Pci(0x14,0x0)/USB(0x1,0x0)/HD(1,GPT,%s,0x800,0x64000)/\\EFI\\BOOT\\BOOTx64.EFI\n' "$1" "${FAKE_BOOT_UUID:-11111111-2222-4333-8444-555555555555}" ;;
  aapl,panic-info) echo "aapl,panic-info fake" ;;
  *) echo "boot-args -v" ;;
esac
EOS
  cat > "${B}/diskutil" <<'EOS'
#!/bin/sh
echo "diskutil $*" >> "${FAKE}/diskutil.log"
case "$1" in
  list)
    echo "   1:  EFI OCEFI   200.0 MB   ${FAKE_DISK:-disk9s1}"
    [ -n "${FAKE_DECOY_ESP:-}" ] && echo "   1:  EFI OCEFI   200.0 MB   disk7s1"
    exit 0 ;;
  info)
    [ -n "${FAKE_DISKUTIL_FAIL:-}" ] && exit 1
    case "$2" in
      11111111-2222-4333-8444-555555555555|"${FAKE_DISK:-disk9s1}") : ;;
      *) exit 1 ;;
    esac
    printf '   Volume Name:  OCEFI\n   Partition Offset:  1048576 Bytes\n   Disk / Partition UUID:  11111111-2222-4333-8444-555555555555\n   Volume UUID:  99999999-0000-4000-8000-000000000000\n   Mount Point:  %s\n' "${FAKE}/ESP" ;;
  *) exit 0 ;;
esac
EOS
  cat > "${B}/kmutil" <<'EOS'
#!/bin/sh
case "$1" in
  install)
    echo "kmutil install $*" >> "${FAKE}/kmutil.log"
    [ -n "${FAKE_KMUTIL_SIGNAL:-}" ] && { kill "-${FAKE_KMUTIL_SIGNAL}" "${PPID}"; exit 130; }
    exit "${FAKE_KMUTIL_RC:-0}" ;;
  showloaded)
    [ "${2:-}" = "--collection" ] && exit 0
    if [ -d "${FAKE}/Extensions/ReimsTGLBoot.kext" ] && [ -z "${FAKE_RT_UNLOADED:-}" ]; then
      if [ -n "${FAKE_RT_WRONG_UUID:-}" ]; then
        echo "  1 0 0 0 0 com.apple.driver.AppleIntelTGLGraphics (16.0.3) CCCC0000-0000-0000-0000-000000000009 <1>"
      else
        echo "  1 0 0 0 0 com.apple.driver.AppleIntelTGLGraphics (16.0.3) BBBB0000-0000-0000-0000-000000000002 <1>"
      fi; fi
    if [ -d "${FAKE}/Extensions/ReimsADLManualActivation.kext" ]; then
      echo "  2 0 0 0 0 lab.reims.ReimsADLManualActivation (0.2.2) AAAA0000-0000-0000-0000-000000000001 <1>"; fi ;;
esac
EOS
  cat > "${B}/ditto" <<'EOS'
#!/bin/sh
while [ "${1#--}" != "$1" ]; do shift; done
mkdir -p "$(dirname "$2")" && cp -R "$1" "$2"
EOS
  cat > "${B}/log" <<'EOS'
#!/bin/sh
echo "log $*" >> "${FAKE}/log-args.txt"
echo "[IGPU] IntelAccelerator::probe: Found device with ID 0x46808086, revision 0xc, PCH id 0x7a80, PCH rev 0x11 at PCI 0:2:0"
echo "[IGPU] Failed to load graphics firmware binary, STATUS = 0x00000001"
echo "2099-01-01 kernel: Previous shutdown cause: 5"
EOS
  cat > "${B}/chown" <<'EOS'
#!/bin/sh
echo "chown $*" >> "${FAKE}/chown.log"
exit "${FAKE_CHOWN_RC:-0}"
EOS
  cat > "${B}/sudo" <<'EOS'
#!/bin/sh
echo "sudo $*" >> "${FAKE}/sudo.log"
FAKE_UID=0 exec "$@"
EOS
  cat > "${B}/mv" <<EOS
#!/bin/sh
if [ -n "\${FAKE_MV_FAIL:-}" ]; then
  case "\$*" in *"\${FAKE_MV_FAIL}"*) exit 1 ;; esac
fi
"${REAL_MV}" "\$@"; _rc=\$?
if [ -n "\${FAKE_MV_SIGNAL:-}" ]; then
  case "\$*" in *"\${FAKE_MV_SIGNAL}"*) kill -INT "\${PPID}" ;; esac
fi
exit \${_rc}
EOS
  printf '#!/bin/sh\nexit 0\n' > "${B}/csrutil"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "${PYBIN}" > "${B}/python3"
  if ! command -v shasum >/dev/null 2>&1; then
    printf '#!/bin/sh\n[ "$1" = "-a" ] && shift 2\nexec sha256sum "$@"\n' > "${B}/shasum"
  fi
  chmod +x "${B}"/* "${FORK}/igpu-start"
}

run() {  # run [参数...]
  env PATH="${B}:${PATH}" FAKE="${T}" FAKE_PY="${PYBIN}" HOME="${T}/home" \
      IGPU_FORK_SRC="${FORK}" IGPU_FIELD_ROOT="${T}/root" IGPU_EXT_DIR="${T}/Extensions" \
      IGPU_TGL_INPUT="${T}/tgl/AppleIntelTGLGraphics.kext" IGPU_EVIDENCE_ROOT="${T}/evidence" \
      IGPU_PANIC_DIR="${T}/panic" IGPU_RECOVERY_MARK="${IGPU_RECOVERY_MARK:-${T}/home/RECOVERY-EFI-VERIFIED.txt}" \
      sh "${FORK}/field/adl-s-field.sh" "$@" > "${T}/out.txt" 2>&1
}
reboot_sim() {  # 模拟重启：换开机标识；已写入的 config 在下一次开机生效；运行时状态消失
  echo "boot-$(date +%s)-$RANDOM" > "${T}/bootid"
  rm -f "${T}/accel" "${T}/accel-busy"
  if grep -q allow3d "${T}/ESP/EFI/OC/config.plist"; then : > "${T}/applied-on-boot"; else rm -f "${T}/applied-on-boot"; fi
}
stage_now() { head -1 "${T}/root/STAGE" 2>/dev/null || echo start; }
to_p1() { run; reboot_sim; run; reboot_sim; run; }
ev() { printf '%s' "${T}/evidence/results-adl-s-$1-*/$2"; }
cfgsha() { sha "${T}/ESP/EFI/OC/config.plist"; }

echo "== 1 完整推进 =="
mk
run; chk "第 1 步退出 0" "$?" 0
chk "阶段 config-applied" "$(stage_now)" config-applied
grep -q allow3d "${T}/ESP/EFI/OC/config.plist" && ok "config 已写入增量" || no "config 未写入增量"
ls -d "${T}"/ESP/igpu-fork-backup-* >/dev/null 2>&1 && ok "ESP 备份目录存在" || no "无 ESP 备份目录"
chk "记录了分区 UUID" "$(head -1 "${T}/root/ESP_UUID" 2>/dev/null)" "${ESP_UUID}"
has "记录 ESP 来源" 'esp_source=boot-path' "$(ev config summary.txt)"
[ -z "$(ls -d "${T}"/root/tools-* 2>/dev/null)" ] && ok "辅助脚本副本已清理" || no "辅助脚本副本残留"
has "辅助脚本从 root 副本执行" "chown -R root:wheel ${T}/root/tools-" "${T}/chown.log"
"${PYBIN}" -c "
import plistlib,sys
c=plistlib.load(open(sys.argv[1],'rb'))
v=c['NVRAM']['Add']['7C436110-AB2A-4BBB-A880-FE41995C9F82']['csr-active-config']
sys.exit(0 if v==bytes.fromhex('03000000') else 1)" "${T}/ESP/EFI/OC/config.plist" && ok "csr-active-config=03000000" || no "csr 取值不对"
has "提示 Sonoma 也受影响" 'Sonoma' "${T}/out.txt"
has "提示 WriteFlash" 'WriteFlash' "${T}/out.txt"
run; chk "未重启续跑退出 3" "$?" 3
chk "未重启续跑阶段不变" "$(stage_now)" config-applied
reboot_sim; run; chk "第 2 步退出 0" "$?" 0
chk "阶段 installed" "$(stage_now)" installed
[ -d "${T}/Extensions/ReimsTGLBoot.kext" ] && [ -d "${T}/Extensions/ReimsADLManualActivation.kext" ] && ok "两个 kext 已放入" || no "kext 未放入"
grep -q update-all "${T}/kmutil.log" && ok "已重建 AuxKC" || no "未调用 kmutil install"
has "工作副本 chown 给 root" "chown -R root:wheel ${T}/root/fork" "${T}/chown.log"
has "TGL 工作副本 chown 给 root" "chown -R root:wheel ${T}/root/tgl-input-" "${T}/chown.log"
_w=$(find "${T}/root/fork" -type f -perm -o+w 2>/dev/null | wc -l | tr -d ' ')
chk "工作副本无他人可写文件" "${_w}" 0
run; chk "安装后未重启续跑退出 3" "$?" 3
reboot_sim; run; chk "P1 退出 0" "$?" 0
chk "阶段 p1-pass" "$(stage_now)" p1-pass
has "P1 记录完整 GFX0 路径" 'gfx_path=IOService:/AppleACPIPlatformExpert/PC00/AppleACPIPCI/GFX0@2' "$(ev p1 summary.txt)"
run; chk "P2 退出 0" "$?" 0
chk "阶段 p2-pass" "$(stage_now)" p2-pass
S="$(ev p2 summary.txt)"
has "证据 summary 记录 P2=PASS" 'P2=PASS' "${S}"
has "记录 Found device 的 ID" 'found_device_id=0x46808086' "${S}"
has "记录 revision" 'found_revision=0xc' "${S}"
has "SKU/L3 记为补丁生效" 'patch_effective=yes' "${S}"
has "结果记为 start 返回" 'p2_outcome=start-returned' "${S}"
has "声明未证明 GPU 功能" 'gpu_function_proven=no' "${S}"
has "记录固件版本" 'firmware_version=70.1.1.0' "${S}"
has "输出措辞是 start 返回成功" 'start 返回成功' "${T}/out.txt"
lacks "输出不再说隐藏就绪" '隐藏就绪' "${T}/out.txt"
has "固件行被分类" '^firmware	\[IGPU\] Graphics Firmware Version' "$(ev p2 igpu-classified.txt)"
chk "良性 WOPCM 行不算失败" "$(grep -c '^fail\|,fail' $(ev p2 igpu-classified.txt))" 0
env PATH="${B}:${PATH}" FAKE="${T}" FAKE_UID=501 IGPU_FIELD_ROOT="${T}/root" sh "${FORK}/field/adl-s-field.sh" --status > "${T}/st.txt" 2>&1
chk "--status 退出 0" "$?" 0
has "--status 走 sudo" '--status' "${T}/sudo.log"
has "--status 报告阶段" 'stage=p2-pass' "${T}/st.txt"

echo "== 2 一键回滚 =="
run --rollback; chk "回滚退出 0" "$?" 0
chk "config 恢复到原样" "$(cfgsha)" "${ORIG_SHA}"
[ ! -e "${T}/Extensions/ReimsTGLBoot.kext" ] && [ ! -e "${T}/Extensions/ReimsADLManualActivation.kext" ] && ok "kext 已撤出" || no "kext 仍在"
ls -d "${T}"/root/removed-rollback-*/ReimsTGLBoot.kext >/dev/null 2>&1 && ok "撤出的 kext 保留（不删除）" || no "撤出的 kext 不见了"
chk "阶段回到 start" "$(stage_now)" start
ls -d "${T}"/ESP/igpu-fork-backup-* >/dev/null 2>&1 && ok "ESP 备份目录仍保留" || no "ESP 备份被删"
_l1=$(grep -n '撤出' "${T}/out.txt" | head -1 | cut -d: -f1); _l2=$(grep -n 'config 已还原' "${T}/out.txt" | head -1 | cut -d: -f1)
[ -n "${_l1}" ] && [ -n "${_l2}" ] && [ "${_l1}" -lt "${_l2}" ] && ok "先撤 kext 后还原 config" || no "回滚顺序不对" "${_l1}/${_l2}"

echo "== 3 设备不符：不动现网 =="
mk; FAKE_DEVID=a3460000 run; chk "退出非 0" "$([ $? -ne 0 ] && echo y)" y
chk "config 未变" "$(cfgsha)" "${ORIG_SHA}"
chk "阶段仍 start" "$(stage_now)" start

echo "== 4 恢复 EFI 未验证：不动现网 =="
mk; IGPU_RECOVERY_MARK="${T}/none.txt" run; chk "退出非 0" "$([ $? -ne 0 ] && echo y)" y
chk "config 未变" "$(cfgsha)" "${ORIG_SHA}"
grep -q 'G4' "${T}/out.txt" && ok "提示门 G4" || no "未提示 G4"

echo "== 5 SIP 未生效：不装 kext =="
mk; run; reboot_sim; FAKE_CSR=00000000 run; chk "退出非 0" "$([ $? -ne 0 ] && echo y)" y
[ -z "$(ls "${T}/Extensions")" ] && ok "Extensions 为空" || no "Extensions 被写入"
chk "阶段仍 config-applied" "$(stage_now)" config-applied
FAKE_CSR=430a0000 run; chk "旧值 430a0000 同样不算放宽" "$([ $? -ne 0 ] && echo y)" y

echo "== 6 kmutil 失败：自动撤出 =="
mk; run; reboot_sim; FAKE_KMUTIL_RC=1 run; chk "退出非 0" "$([ $? -ne 0 ] && echo y)" y
[ -z "$(ls "${T}/Extensions")" ] && ok "kext 已撤出" || no "kext 残留"
chk "阶段 install-failed" "$(stage_now)" install-failed
run --rollback; chk "失败后回滚 config 恢复" "$(cfgsha)" "${ORIG_SHA}"
has "kmutil 失败后回滚仍重建 AuxKC" 'install' "${T}/kmutil.log"

echo "== 7 P1：等批准与失败 =="
mk; run; reboot_sim; run; reboot_sim; FAKE_RT_UNLOADED=1 run; chk "只是没加载：退出 0" "$?" 0
chk "阶段 awaiting-approval" "$(stage_now)" awaiting-approval
has "提示去系统设置批准" '隐私与安全性' "${T}/out.txt"
has "summary 记 AWAITING" 'P1=AWAITING-APPROVAL' "$(ev p1 summary.txt)"
has "等批准也留 kernelmanagerd 证据" 'log show --last boot' "${T}/log-args.txt"
FAKE_RT_UNLOADED=1 run; chk "没重启就重跑：退出 3" "$?" 3
chk "阶段不变" "$(stage_now)" awaiting-approval
env PATH="${B}:${PATH}" FAKE="${T}" FAKE_UID=0 IGPU_FIELD_ROOT="${T}/root" sh "${FORK}/field/adl-s-field.sh" --status > "${T}/st.txt" 2>&1
has "--status 指引批准" '点“允许”' "${T}/st.txt"
reboot_sim; FAKE_RT_UNLOADED=1 run; chk "批准重启后仍没加载：退出非 0" "$([ $? -ne 0 ] && echo y)" y
chk "只给一次机会：p1-failed" "$(stage_now)" p1-failed
has "说明是批准后仍未加载" '批准并重启后' "${T}/out.txt"
run; chk "失败终态不自动重试" "$?" 1
mk; run; reboot_sim; run; reboot_sim; FAKE_RT_UNLOADED=1 run
reboot_sim; run; chk "批准后加载：退出 0" "$?" 0
chk "阶段 p1-pass" "$(stage_now)" p1-pass
run; chk "随后 P2 可跑" "$?" 0
chk "阶段 p2-pass" "$(stage_now)" p2-pass
mk; run; reboot_sim; run; reboot_sim; FAKE_RT_WRONG_UUID=1 run; chk "版本不对不算等批准" "$([ $? -ne 0 ] && echo y)" y
chk "直接 p1-failed" "$(stage_now)" p1-failed
mk; run; reboot_sim; run; reboot_sim; FAKE_RT_UNLOADED=1 FAKE_GFX_NODE=IGPU@2 run; chk "没加载且路径不符：不算等批准" "$([ $? -ne 0 ] && echo y)" y
chk "直接 p1-failed" "$(stage_now)" p1-failed
mk; to_p1; FAKE_P2_SIGNAL=INT run; reboot_sim; FAKE_RT_UNLOADED=1 run; chk "P2 中断后复核时没加载：不进等批准" "$([ $? -ne 0 ] && echo y)" y
chk "直接 p1-failed" "$(stage_now)" p1-failed

echo "== 7b GFX0 路径不符 =="
mk; FAKE_GFX_NODE=IGPU@2 run; chk "第 1 步拒绝" "$([ $? -ne 0 ] && echo y)" y
chk "路径不符时 config 未变" "$(cfgsha)" "${ORIG_SHA}"
chk "路径不符时阶段仍 start" "$(stage_now)" start
mk; run; reboot_sim; run; reboot_sim; FAKE_ROOT_BRIDGE='PC00@0' run; chk "P1 拒绝" "$([ $? -ne 0 ] && echo y)" y
chk "阶段 p1-failed" "$(stage_now)" p1-failed
has "指出路径不符" 'GFX0路径=IOService:/AppleACPIPlatformExpert/PC00@0/' "${T}/out.txt"
EXPECT=$(sed -n "s/^EXPECT_GFX_PATH='\(.*\)'$/\1/p" "${SCRIPT}")
GATE="${REPO}/desktop-manual-20260917/fix/manual-gate/gate.cpp"
has "现场路径与 gate.cpp 的 kPCIPath 一致" "kPCIPath=\"${EXPECT}\"" "${GATE}"

echo "== 8 P2 失败：probe 失败与 start 卡住分开 =="
mk; to_p1; FAKE_P2_OUTCOME=none FAKE_P2_RC=1 run; chk "probe 失败退出非 0" "$([ $? -ne 0 ] && echo y)" y
chk "阶段 p2-failed" "$(stage_now)" p2-failed
ls "${T}"/evidence/results-adl-s-p2-*/igpu-start.txt >/dev/null 2>&1 && ok "保留 igpu-start 输出" || no "缺 igpu-start 输出"
has "判为 probe-failed" 'p2_outcome=probe-failed' "$(ev p2 summary.txt)"
has "探测未进入 probe" 'p2_probe_entered=no' "$(ev p2 summary.txt)"
has "输出说 probe 失败" 'probe 失败' "${T}/out.txt"
mk; to_p1; FAKE_P2_OUTCOME=none FAKE_P2_FOUND_ONLY=1 FAKE_P2_RC=1 run
has "probe 见到设备但实例没留下判 start-failed" 'p2_outcome=start-failed' "$(ev p2 summary.txt)"
mk; to_p1; FAKE_P2_OUTCOME=none FAKE_P2_FOUND_ONLY=1 FAKE_P2_RC=1 FAKE_IGPU_EXTRA='[IGPU] Failing probe (-allow3d is NOT set in boot-arg)!' run
has "probe 明确拒绝判 probe-failed" 'p2_outcome=probe-failed' "$(ev p2 summary.txt)"
mk; to_p1; FAKE_P2_OUTCOME=stuck FAKE_P2_RC=1 run; chk "start 卡住退出非 0" "$([ $? -ne 0 ] && echo y)" y
has "判为 start-stuck" 'p2_outcome=start-stuck' "$(ev p2 summary.txt)"
has "输出说 start 卡住" 'start 卡住' "${T}/out.txt"
mk; to_p1; FAKE_P2_OUTCOME=stuck run; chk "退出码 0 但总线仍忙也不算过" "$([ $? -ne 0 ] && echo y)" y
chk "阶段 p2-failed" "$(stage_now)" p2-failed
mk; to_p1; FAKE_P2_PREFLIGHT=1 FAKE_P2_OUTCOME=none FAKE_P2_RC=1 run
has "预检失败不说成 probe 失败" 'p2_outcome=preflight-failed' "$(ev p2 summary.txt)"
has "输出说 GPU 未动" 'GPU 未动' "${T}/out.txt"
mk; to_p1; FAKE_P2_OUTCOME=none FAKE_P2_RC=1 FAKE_P2_FAILURE_OUTCOME=start-stuck run
has "采用 session 记录的 outcome" 'p2_outcome=start-stuck' "$(ev p2 summary.txt)"

echo "== 9 P2 期间崩溃重启：按时间过滤 =="
mk; to_p1
echo "old panic" > "${T}/panic/Kernel-1999.panic"; touch -t 200001010000 "${T}/panic/Kernel-1999.panic"
FAKE_P2_CRASH=1 run
chk "崩溃前阶段 p2-attempted" "$(stage_now)" p2-attempted
reboot_sim; echo "panic(cpu 0) IntelAccelerator" > "${T}/panic/Kernel-2099.panic"
touch -t 209901010000 "${T}/panic/Kernel-2099.panic"
run; chk "崩溃后退出 1" "$?" 1
chk "阶段 p2-crashed" "$(stage_now)" p2-crashed
ls "${T}"/evidence/results-adl-s-p2-crash-*/panic/Kernel-2099.panic >/dev/null 2>&1 && ok "本次崩溃报告已收集" || no "未收集崩溃报告"
ls "${T}"/evidence/results-adl-s-p2-crash-*/panic/Kernel-1999.panic >/dev/null 2>&1 && no "更早的崩溃报告被混入" || ok "更早的崩溃报告未混入"
has "记录忽略的旧报告数" 'panic_files_older_ignored=1' "$(ev p2-crash summary.txt)"
has "判为 panic" 'crash_kind=panic' "$(ev p2-crash summary.txt)"
has "日志从尝试时间读起" 'log show --start' "${T}/log-args.txt"
lacks "不再用 --last boot" '--last' "${T}/log-args.txt"
has "崩溃日志也分类" '^firmware,fail	' "$(ev p2-crash igpu-classified.txt)"

echo "== 9b 重启但没有本次崩溃报告 =="
mk; to_p1
echo "old panic" > "${T}/panic/Kernel-1999.panic"; touch -t 200001010000 "${T}/panic/Kernel-1999.panic"
FAKE_P2_CRASH=1 run
reboot_sim; run; chk "退出 1" "$?" 1
has "判为 no-panic-report" 'crash_kind=no-panic-report' "$(ev p2-crash summary.txt)"
has "提示可能断电或硬死机" '硬死机' "${T}/out.txt"
has "记录关机原因" 'shutdown_cause=5' "$(ev p2-crash summary.txt)"
echo "late panic" > "${T}/panic/panic-full-2099.panic"; touch -t 209901010000 "${T}/panic/panic-full-2099.panic"
env PATH="${B}:${PATH}" FAKE="${T}" FAKE_UID=0 IGPU_FIELD_ROOT="${T}/root" IGPU_PANIC_DIR="${T}/panic" sh "${FORK}/field/adl-s-field.sh" --status > "${T}/st.txt" 2>&1
ls "${T}"/evidence/results-adl-s-p2-crash-*/panic/panic-full-2099.panic >/dev/null 2>&1 && ok "--status 补收晚写出的报告" || no "--status 没补收"
has "--status 报告份数" 'panic_files=1' "${T}/st.txt"

echo "== 9c 进程被杀但本次开机还在：不是崩溃 =="
mk; to_p1; FAKE_P2_CRASH=1 run
run; chk "退出 3" "$?" 3
chk "阶段 p2-interrupted" "$(stage_now)" p2-interrupted
ls -d "${T}"/evidence/results-adl-s-p2-crash-* >/dev/null 2>&1 && no "不该生成崩溃证据" || ok "没有生成崩溃证据"

echo "== 10 HWCAPS 不符 =="
mk; to_p1; FAKE_SKU=1 run; chk "退出非 0" "$([ $? -ne 0 ] && echo y)" y
chk "阶段 p2-failed" "$(stage_now)" p2-failed
grep -q 'hwcaps_missing=sku' "${T}"/evidence/results-adl-s-p2-*/hwcaps.txt && ok "指出 SKU 不符" || no "未指出 SKU"
has "SKU 不符记为补丁未生效" 'patch_effective=no' "$(ev p2 summary.txt)"
has "记为 PARTIAL" 'P2=PARTIAL' "$(ev p2 summary.txt)"
mk; to_p1; FAKE_L3=0 run
has "L3 不符记为补丁未生效" 'patch_effective=no' "$(ev p2 summary.txt)"
mk; to_p1; FAKE_NO_FOUND=1 run; chk "缺 Found device 不算过" "$([ $? -ne 0 ] && echo y)" y
has "记录缺 Found device" 'found_device_id=missing' "$(ev p2 summary.txt)"
mk; to_p1; FAKE_FOUND_ID=0x46a38086 run; chk "设备 ID 不对不算过" "$([ $? -ne 0 ] && echo y)" y

echo "== 10b [IGPU] 全量分类：GuC/firmware/fail =="
mk; to_p1; FAKE_IGPU_EXTRA='[IGPU] GuC: Failed to load graphics firmware binary, STATUS = 0x1' run
chk "失败行让 P2 不通过" "$(stage_now)" p2-failed
has "判 PARTIAL（start 返回成功）" 'P2=PARTIAL' "$(ev p2 summary.txt)"
has "计入 fail" 'igpu_fail=1' "$(ev p2 summary.txt)"
has "计入 guc" 'igpu_guc=1' "$(ev p2 summary.txt)"
has "一行可同时带三个标签" '^guc,firmware,fail	' "$(ev p2 igpu-classified.txt)"
_cls=$(wc -l < $(ev p2 igpu-classified.txt) | tr -d ' ')
_raw=$(grep -c '\[IGPU\]' "${T}"/evidence/results-adl-s-p2-*/session/igpu-log.txt)
chk "每条 [IGPU] 都进了分类文件" "${_cls}" "${_raw}"
mk; to_p1; FAKE_P2_OUTCOME=none FAKE_P2_FOUND_ONLY=1 FAKE_P2_RC=1 run
has "P2 失败时同样留分类结果" 'igpu_lines=' "$(ev p2 summary.txt)"
mk; to_p1; FAKE_IGPU_EXTRA='[IGPU] RC6 is disabled on this SKU; invalid hint ignored' run; chk "良性 warn 行不让 P2 失败" "$?" 0
has "warn 单独计数" 'igpu_warn=1' "$(ev p2 summary.txt)"
has "warn 不计入 fail" 'igpu_fail=0' "$(ev p2 summary.txt)"

echo "== 11 Ctrl-C 与崩溃分开 =="
mk; to_p1; FAKE_P2_SIGNAL=INT run; chk "Ctrl-C 退出 130" "$?" 130
chk "阶段 p2-interrupted" "$(stage_now)" p2-interrupted
has "说明不是崩溃" '不是崩溃' "${T}/out.txt"
has "记录中断信号" 'interrupted_by=INT' "$(ev p2 summary.txt)"
run; chk "同一开机不许重试" "$?" 3
chk "阶段不变" "$(stage_now)" p2-interrupted
reboot_sim; run; chk "重启后复核 P1" "$?" 0
chk "回到 p1-pass" "$(stage_now)" p1-pass
ls -d "${T}"/evidence/results-adl-s-p2-crash-* >/dev/null 2>&1 && no "不该判崩溃" || ok "没有判崩溃"
run; chk "复核后 P2 可再跑" "$?" 0
chk "阶段 p2-pass" "$(stage_now)" p2-pass
mk; to_p1; FAKE_P2_SIGNAL=TERM run; chk "TERM 退出 130" "$?" 130
chk "TERM 同样不算崩溃" "$(stage_now)" p2-interrupted

echo "== 12 其他步骤的 trap =="
mk; run; reboot_sim; FAKE_KMUTIL_SIGNAL=INT run; chk "安装时中断退出 130" "$?" 130
[ -z "$(ls "${T}/Extensions")" ] && ok "kext 已撤出" || no "kext 残留"
chk "阶段 install-failed" "$(stage_now)" install-failed
run --rollback; chk "中断后回滚退出 0" "$?" 0
has "kext 已撤时回滚仍重建 AuxKC" 'kmutil install' "${T}/kmutil.log"
chk "中断后回滚 config 恢复" "$(cfgsha)" "${ORIG_SHA}"
mk; FAKE_MV_SIGNAL=config.plist run; chk "写 config 后中断退出 130" "$?" 130
chk "阶段 config-interrupted" "$(stage_now)" config-interrupted
has "中断后 ESP 被卸载" 'diskutil unmount' "${T}/diskutil.log"
run --rollback; chk "回滚退出 0" "$?" 0
chk "config 恢复" "$(cfgsha)" "${ORIG_SHA}"
mk; run; reboot_sim; run; FAKE_KMUTIL_SIGNAL=INT run --rollback; chk "回滚时中断退出 130" "$?" 130
chk "阶段 rollback-incomplete" "$(stage_now)" rollback-incomplete

echo "== 13 回滚每步失败都继续 =="
mk; to_p1; FAKE_KMUTIL_RC=1 run --rollback; chk "kmutil 失败退出 1" "$?" 1
chk "阶段 rollback-incomplete" "$(stage_now)" rollback-incomplete
grep -q allow3d "${T}/ESP/EFI/OC/config.plist" && ok "kmutil 失败时不还原 config（SIP 保持放宽，防卡开机）" || no "kmutil 失败时 config 被还原了"
has "说明为何不还原" '为防卡开机' "${T}/out.txt"
[ -f "${T}/root/BACKUP" ] && ok "备份指针保留" || no "备份指针被删"
has "summary 记 rollback-incomplete" 'result=rollback-incomplete' "$(ev rollback summary.txt)"
run; chk "rollback-incomplete 不自动推进" "$?" 1
run --rollback; chk "再回滚成功" "$?" 0
chk "这次 config 恢复" "$(cfgsha)" "${ORIG_SHA}"
chk "阶段回到 start" "$(stage_now)" start
[ ! -f "${T}/root/KMUTIL_DIRTY" ] && ok "AuxKC 重建标记已清" || no "AuxKC 重建标记残留"

mk; to_p1; FAKE_DISKUTIL_FAIL=1 run --rollback; chk "ESP 找不到退出 1" "$?" 1
[ ! -e "${T}/Extensions/ReimsTGLBoot.kext" ] && ok "ESP 失败前已撤 kext" || no "kext 还在"
chk "阶段 rollback-incomplete" "$(stage_now)" rollback-incomplete
run --rollback; chk "ESP 恢复后回滚成功" "$?" 0
chk "config 恢复" "$(cfgsha)" "${ORIG_SHA}"

mk; to_p1; FAKE_MV_FAIL=ReimsTGLBoot run --rollback; chk "kext 撤不掉退出 1" "$?" 1
[ -e "${T}/Extensions/ReimsTGLBoot.kext" ] && ok "（桩确实让它撤不掉）" || no "桩未生效"
grep -q allow3d "${T}/ESP/EFI/OC/config.plist" && ok "kext 撤不掉时不还原 config" || no "kext 撤不掉时 config 被还原了"
chk "阶段 rollback-incomplete" "$(stage_now)" rollback-incomplete
run --rollback; chk "撤得掉之后回滚成功" "$?" 0
chk "config 恢复" "$(cfgsha)" "${ORIG_SHA}"

echo "== 14 回滚前核对 config 哈希 =="
mk; to_p1
printf '<!-- 用户手改 -->\n' >> "${T}/ESP/EFI/OC/config.plist"; EDITED=$(cfgsha)
run --rollback; chk "config 被改过退出 1" "$?" 1
chk "被改过的 config 不被覆盖" "$(cfgsha)" "${EDITED}"
[ ! -e "${T}/Extensions/ReimsTGLBoot.kext" ] && ok "kext 仍已撤出" || no "kext 还在"
chk "阶段 rollback-incomplete" "$(stage_now)" rollback-incomplete
ls "${T}"/evidence/results-adl-s-rollback-*/config-unexpected.plist.txt >/dev/null 2>&1 && ok "现网副本存进证据" || no "没存现网副本"
mk; run; rm -rf "${T}"/ESP/igpu-fork-backup-*
run --rollback; chk "ESP 备份丢失时退出 0" "$?" 0
chk "改用本地备份还原" "$(cfgsha)" "${ORIG_SHA}"
run --rollback; chk "重复回滚无副作用" "$?" 0
chk "重复回滚后 config 不变" "$(cfgsha)" "${ORIG_SHA}"
mk; run; sed -i.bak '3s/.*//' "${T}/root/BACKUP"
run --rollback; chk "缺改后哈希时按 备份+增量 核对后还原" "$?" 0
chk "config 恢复" "$(cfgsha)" "${ORIG_SHA}"
mk; run; sed -i.bak '3s/.*//' "${T}/root/BACKUP"
"${PYBIN}" -c "
import plistlib,sys
p=sys.argv[1]; c=plistlib.load(open(p,'rb')); c['Misc']['Boot']['Timeout']=99
open(p,'wb').write(plistlib.dumps(c))" "${T}/ESP/EFI/OC/config.plist"; EDITED=$(cfgsha)
run --rollback; chk "缺改后哈希且被人改过：拒绝" "$?" 1
chk "被人改过的 config 不被覆盖" "$(cfgsha)" "${EDITED}"

echo "== 15 按分区 UUID 定位 ESP =="
mk; FAKE_NO_BOOTPATH=1 run; chk "无 boot-path 时按卷名唯一候选" "$?" 0
chk "仍记录分区 UUID" "$(head -1 "${T}/root/ESP_UUID")" "${ESP_UUID}"
mk; FAKE_NO_BOOTPATH=1 FAKE_DECOY_ESP=1 run; chk "无 boot-path 且两个同名卷：拒绝" "$([ $? -ne 0 ] && echo y)" y
chk "拒绝时 config 未变" "$(cfgsha)" "${ORIG_SHA}"
mk; FAKE_BOOT_UUID=AAAAAAAA-2222-4333-8444-555555555555 run; chk "booted 分区不是目标：拒绝" "$([ $? -ne 0 ] && echo y)" y
chk "拒绝时 config 未变" "$(cfgsha)" "${ORIG_SHA}"
mk; run; reboot_sim; FAKE_DISK=disk4s1 FAKE_DECOY_ESP=1 FAKE_NO_BOOTPATH=1 run --rollback; chk "磁盘号变了且有同名卷，回滚仍成功" "$?" 0
chk "config 恢复" "$(cfgsha)" "${ORIG_SHA}"
has "回滚按 UUID 查询" "diskutil info ${ESP_UUID}" "${T}/diskutil.log"

echo "== 16 工作副本权限失败：不继续 =="
mk; run; reboot_sim; FAKE_CHOWN_RC=1 run; chk "chown 失败退出非 0" "$([ $? -ne 0 ] && echo y)" y
[ -z "$(ls "${T}/Extensions")" ] && ok "kext 未安装" || no "kext 被安装"

echo "== 17 补丁控制流断言 =="
if "${PYBIN}" "${REPO}/desktop-manual-20260917/fix/test_prepare_chain.py" > "${T:-/tmp}/chain.txt" 2>&1; then ok "probe 比较链：0x46808086 落到 SKU 2"; else no "probe 比较链断言失败" "$(tail -5 "${T}/chain.txt")"; fi

echo "== 18 中文邻接变量门禁 =="
if "${PYBIN}" - "${SCRIPT}" <<'EOP'
import re, sys
bad = [(i, l) for i, l in enumerate(open(sys.argv[1], encoding="utf-8"), 1)
       if re.search(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]", l)]
for i, l in bad: print(f"  line {i}: {l.rstrip()}")
sys.exit(1 if bad else 0)
EOP
then ok "无 \$VAR 紧邻非 ASCII"; else no "存在 \$VAR 紧邻非 ASCII"; fi

echo ""
echo "通过 ${P}，失败 ${F}"
[ "${F}" -eq 0 ]
