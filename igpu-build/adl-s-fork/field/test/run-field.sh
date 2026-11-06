#!/bin/bash
# run-field.sh —— adl-s-field.sh 的离线仿真（桩命令模拟 macOS，不需要 Apple 二进制）
#
# 覆盖：完整推进 start→p2-pass、未重启续跑必须停、一键回滚恢复原 config 并撤出 kext、
#       设备不符/未验证恢复 EFI/SIP 未生效 时不动现网、kmutil 失败自动撤出、
#       P1 失败、P2 失败、P2 期间崩溃重启后收集证据、HWCAPS 日志不符、--status 免 root。
set -u
H=$(cd "$(dirname "$0")" && pwd)
FIELD=$(cd "${H}/.." && pwd)
SCRIPT="${FIELD}/adl-s-field.sh"
P=0; F=0
ok() { P=$((P+1)); printf '  ✓ %s\n' "$1"; }
no() { F=$((F+1)); printf '  ✗ %s（%s）\n' "$1" "${2:-}"; [ -f "${T}/out.txt" ] && tail -8 "${T}/out.txt" | sed 's/^/     /'; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "期望 [$3] 实际 [$2]"; fi; }
PYBIN=$(command -v python3 2>/dev/null || command -v python)
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

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
d="$(dirname "$0")/desktop-manual-20260917/fix/session-20990101-000000-000000-accel-only"
mkdir -p "$d"
cat > "$d/igpu-log.txt" <<EOL
[IGPU] HWCAPS - GPU Sku: ${FAKE_SKU:-2}
[IGPU] HWCAPS - NumSlices:1      SliceCountFuse:0x1
[IGPU] HWCAPS - NumSubSlices:4   DualSubSliceCountFuse:0x3
[IGPU] HWCAPS - MaxEUPerSubSlice:8   EUDisableFuses:0x0  ExecutionUnitCount:32
[IGPU] HWCAPS - L3BankCount: 4
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
exec "${FAKE_PY}" - <<'EOP'
import os, plistlib, sys
iso = os.path.exists(os.path.join(os.environ["FAKE"], "applied-on-boot"))
dev = bytes.fromhex(os.environ.get("FAKE_DEVID", "ffff0000" if iso else "80460000"))
kids = [{"IOObjectClass": "IONDRVFramebuffer", "IORegistryEntryChildren": []}]
if os.path.exists(os.path.join(os.environ["FAKE"], "accel")):
    kids.append({"IOObjectClass": "IntelAccelerator", "IORegistryEntryChildren": []})
sys.stdout.buffer.write(plistlib.dumps([{"IOObjectClass": "IOPCIDevice", "device-id": dev,
    "revision-id": bytes.fromhex("0c000000"), "vendor-id": bytes.fromhex("86800000"), "IORegistryEntryChildren": kids}]))
EOP
EOS
  cat > "${B}/nvram" <<'EOS'
#!/bin/sh
case "$1" in
  -x) exec "${FAKE_PY}" -c "import plistlib,sys,os;v=os.environ.get('FAKE_CSR') or ('430a0000' if os.path.exists(os.environ['FAKE']+'/applied-on-boot') else '00000000');sys.stdout.buffer.write(plistlib.dumps({'csr-active-config':bytes.fromhex(v)}))" ;;
  *) echo "boot-args -v" ;;
esac
EOS
  cat > "${B}/diskutil" <<'EOS'
#!/bin/sh
case "$1" in
  list) echo "   1:  EFI OCEFI   200.0 MB   disk9s1" ;;
  info) printf '   Volume Name:  OCEFI\n   Partition Offset:  1048576 Bytes\n   Mount Point:  %s\n' "${FAKE}/ESP" ;;
  *) exit 0 ;;
esac
EOS
  cat > "${B}/kmutil" <<'EOS'
#!/bin/sh
case "$1" in
  install) echo "kmutil install $*" >> "${FAKE}/kmutil.log"; exit "${FAKE_KMUTIL_RC:-0}" ;;
  showloaded)
    [ "${2:-}" = "--collection" ] && exit 0
    if [ -d "${FAKE}/Extensions/ReimsTGLBoot.kext" ] && [ -z "${FAKE_RT_UNLOADED:-}" ]; then
      echo "  1 0 0 0 0 com.apple.driver.AppleIntelTGLGraphics (16.0.3) BBBB0000-0000-0000-0000-000000000002 <1>"; fi
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
echo "previous boot [IGPU] Failed to map Device ID"
EOS
  for s in csrutil chown sudo; do printf '#!/bin/sh\nexit 0\n' > "${B}/${s}"; done
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
reboot_sim() {  # 模拟重启：换开机标识；已写入的 config 在下一次开机生效
  echo "boot-$(date +%s)-$RANDOM" > "${T}/bootid"
  if grep -q allow3d "${T}/ESP/EFI/OC/config.plist"; then : > "${T}/applied-on-boot"; else rm -f "${T}/applied-on-boot"; fi
}
stage_now() { head -1 "${T}/root/STAGE" 2>/dev/null || echo start; }
to_p1() { run; reboot_sim; run; reboot_sim; run; }

echo "== 1 完整推进 =="
mk
run; chk "第 1 步退出 0" "$?" 0
chk "阶段 config-applied" "$(stage_now)" config-applied
grep -q allow3d "${T}/ESP/EFI/OC/config.plist" && ok "config 已写入增量" || no "config 未写入增量"
ls -d "${T}"/ESP/igpu-fork-backup-* >/dev/null 2>&1 && ok "ESP 备份目录存在" || no "无 ESP 备份目录"
run; chk "未重启续跑退出 3" "$?" 3
chk "未重启续跑阶段不变" "$(stage_now)" config-applied
reboot_sim; run; chk "第 2 步退出 0" "$?" 0
chk "阶段 installed" "$(stage_now)" installed
[ -d "${T}/Extensions/ReimsTGLBoot.kext" ] && [ -d "${T}/Extensions/ReimsADLManualActivation.kext" ] && ok "两个 kext 已放入" || no "kext 未放入"
grep -q update-all "${T}/kmutil.log" && ok "已重建 AuxKC" || no "未调用 kmutil install"
run; chk "安装后未重启续跑退出 3" "$?" 3
reboot_sim; run; chk "P1 退出 0" "$?" 0
chk "阶段 p1-pass" "$(stage_now)" p1-pass
run; chk "P2 退出 0" "$?" 0
chk "阶段 p2-pass" "$(stage_now)" p2-pass
grep -q 'P2=PASS' "${T}"/evidence/results-adl-s-p2-*/summary.txt && ok "证据 summary 记录 P2=PASS" || no "summary 无 P2=PASS"
env PATH="${B}:${PATH}" FAKE="${T}" FAKE_UID=501 IGPU_FIELD_ROOT="${T}/root" sh "${FORK}/field/adl-s-field.sh" --status > "${T}/st.txt" 2>&1
chk "--status 免 root" "$?" 0
grep -q 'stage=p2-pass' "${T}/st.txt" && ok "--status 报告阶段" || no "--status 内容不对"

echo "== 2 一键回滚 =="
run --rollback; chk "回滚退出 0" "$?" 0
chk "config 恢复到原样" "$(sha "${T}/ESP/EFI/OC/config.plist")" "${ORIG_SHA}"
[ ! -e "${T}/Extensions/ReimsTGLBoot.kext" ] && [ ! -e "${T}/Extensions/ReimsADLManualActivation.kext" ] && ok "kext 已撤出" || no "kext 仍在"
ls -d "${T}"/root/removed-rollback-*/ReimsTGLBoot.kext >/dev/null 2>&1 && ok "撤出的 kext 保留（不删除）" || no "撤出的 kext 不见了"
chk "阶段回到 start" "$(stage_now)" start
ls -d "${T}"/ESP/igpu-fork-backup-* >/dev/null 2>&1 && ok "ESP 备份目录仍保留" || no "ESP 备份被删"

echo "== 3 设备不符：不动现网 =="
mk; FAKE_DEVID=a3460000 run; chk "退出非 0" "$([ $? -ne 0 ] && echo y)" y
chk "config 未变" "$(sha "${T}/ESP/EFI/OC/config.plist")" "${ORIG_SHA}"
chk "阶段仍 start" "$(stage_now)" start

echo "== 4 恢复 EFI 未验证：不动现网 =="
mk; IGPU_RECOVERY_MARK="${T}/none.txt" run; chk "退出非 0" "$([ $? -ne 0 ] && echo y)" y
chk "config 未变" "$(sha "${T}/ESP/EFI/OC/config.plist")" "${ORIG_SHA}"
grep -q 'G4' "${T}/out.txt" && ok "提示门 G4" || no "未提示 G4"

echo "== 5 SIP 未生效：不装 kext =="
mk; run; reboot_sim; FAKE_CSR=00000000 run; chk "退出非 0" "$([ $? -ne 0 ] && echo y)" y
[ -z "$(ls "${T}/Extensions")" ] && ok "Extensions 为空" || no "Extensions 被写入"
chk "阶段仍 config-applied" "$(stage_now)" config-applied

echo "== 6 kmutil 失败：自动撤出 =="
mk; run; reboot_sim; FAKE_KMUTIL_RC=1 run; chk "退出非 0" "$([ $? -ne 0 ] && echo y)" y
[ -z "$(ls "${T}/Extensions")" ] && ok "kext 已撤出" || no "kext 残留"
chk "阶段 install-failed" "$(stage_now)" install-failed
run --rollback; chk "失败后回滚 config 恢复" "$(sha "${T}/ESP/EFI/OC/config.plist")" "${ORIG_SHA}"

echo "== 7 P1 失败 =="
mk; run; reboot_sim; run; reboot_sim; FAKE_RT_UNLOADED=1 run; chk "退出非 0" "$([ $? -ne 0 ] && echo y)" y
chk "阶段 p1-failed" "$(stage_now)" p1-failed
run; chk "失败终态不自动重试" "$?" 1

echo "== 8 P2 失败 =="
mk; to_p1; FAKE_P2_RC=1 run; chk "退出非 0" "$([ $? -ne 0 ] && echo y)" y
chk "阶段 p2-failed" "$(stage_now)" p2-failed
ls "${T}"/evidence/results-adl-s-p2-*/igpu-start.txt >/dev/null 2>&1 && ok "保留 igpu-start 输出" || no "缺 igpu-start 输出"

echo "== 9 P2 期间崩溃重启 =="
mk; to_p1; FAKE_P2_CRASH=1 run
chk "崩溃前阶段 p2-attempted" "$(stage_now)" p2-attempted
reboot_sim; echo "panic(cpu 0) IntelAccelerator" > "${T}/panic/Kernel-2099.panic"
run; chk "崩溃后退出 1" "$?" 1
chk "阶段 p2-crashed" "$(stage_now)" p2-crashed
ls "${T}"/evidence/results-adl-s-p2-crash-*/panic/Kernel-2099.panic >/dev/null 2>&1 && ok "崩溃报告已收集" || no "未收集崩溃报告"

echo "== 10 HWCAPS 不符 =="
mk; to_p1; FAKE_SKU=1 run; chk "退出非 0" "$([ $? -ne 0 ] && echo y)" y
chk "阶段 p2-failed" "$(stage_now)" p2-failed
grep -q 'hwcaps_missing=sku' "${T}"/evidence/results-adl-s-p2-*/hwcaps.txt && ok "指出 SKU 不符" || no "未指出 SKU"

echo "== 11 中文邻接变量门禁 =="
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
