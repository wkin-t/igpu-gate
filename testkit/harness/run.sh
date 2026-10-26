#!/bin/bash
# 事务脚本仿真（干净版）：桩件在 PATH 最前，被测脚本把绝对路径替换为桩名
set +u
H="$(cd "$(dirname "$0")" && pwd)"
# 让裸 `python` 解析到 testkit/bin/python（shim：exec python3）。
# macOS 26 没有 `python` 命令；本地 Windows 能跑是因为外部 PATH 里恰好有 shim——
# 那是环境巧合，不能当依赖（CI 上会直接失败）。
PATH="$H/../bin:$PATH"; export PATH
export PATH="$H/stubs:$PATH"
sh "$H/sync-bundle.sh" || exit 1
export FAKE_ESP="$H/esp"
export IGPU_BACKUP_DIR="$H/localbk"
rm -rf "$H/localbk"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s  —— %s\n' "$1" "$2"; }
# macOS 没有 sha256sum（GNU coreutils），必须回退 shasum；否则在真 Mac 上跑直接失败
sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

echo "stub 解析: ditto=$(command -v ditto) nm=$(command -v nm) diskutil=$(command -v diskutil) id=$(command -v id)"

TPL="$H/tpl"
rm -rf "$TPL"; mkdir -p "$TPL/EFI/OC/Kexts/IGPUProbe.kext/Contents/MacOS"
# 用真实 plist 当夹具：部署脚本现在会解析配置（分类 baseline/injected/dirty），
# 纯文本占位文件会被 XML 严格校验拒绝，覆盖不到真实分支。
cp "$H/real-config.plist" "$TPL/EFI/OC/config.plist"
cp "$H/real-base.plist"   "$TPL/EFI/OC/config-before-probe-20261019.plist"
printf 'OLD-BINARY\n'      > "$TPL/EFI/OC/Kexts/IGPUProbe.kext/Contents/MacOS/IGPUProbe"
printf 'OLD-PLIST\n'       > "$TPL/EFI/OC/Kexts/IGPUProbe.kext/Contents/Info.plist"
mkdir -p "$H/bundle/kext/IGPUProbe/IGPUProbe.kext/Contents/MacOS"
printf 'NEW-BINARY\n'      > "$H/bundle/kext/IGPUProbe/IGPUProbe.kext/Contents/MacOS/IGPUProbe"
printf 'NEW-PLIST\n'       > "$H/bundle/kext/IGPUProbe/IGPUProbe.kext/Contents/Info.plist"

CD=$(sha "$TPL/EFI/OC/config.plist")
CB=$(sha "$TPL/EFI/OC/config-before-probe-20261019.plist")

mk() {
  sed -e "s/d902a3378ba7c8115c8a8888ae2abec096ec4f991dd5b0c0b410f47b76a36fbd/$CD/g" \
      -e "s/991c9de090924d1bd68b2a1db4e104c91337286aae158c63fae98e301fae16e3/$CB/g" \
      -e "s#/usr/libexec/PlistBuddy#PlistBuddy#g" \
      -e "s#/usr/bin/ditto#ditto#g" \
      -e "s#/usr/bin/dot_clean#dot_clean#g" \
      "$1" > "$2"
  chmod 755 "$2"
  if [ ! -s "$2" ]; then echo "ABORT 生成失败 $2"; exit 1; fi
}
mk "$H/bundle/onsite/01-deploy.sh"   "$H/bundle/onsite/deploy.sh"
mk "$H/bundle/onsite/03-rollback.sh" "$H/bundle/onsite/rollback.sh"
grep -n 'ditto\|dot_clean\|PlistBuddy' "$H/bundle/onsite/deploy.sh" | head -4

reset_esp() { rm -rf "$H/esp"; cp -R "$TPL" "$H/esp"; }
DST="$H/esp/EFI/OC/Kexts/IGPUProbe.kext/Contents/MacOS/IGPUProbe"
NEWHASH=$(sha "$H/bundle/kext/IGPUProbe/IGPUProbe.kext/Contents/MacOS/IGPUProbe")
# N3：部署现在强制读取 bundle/EXPECTED_BIN_SHA；harness 的假产物逐轮登记。
set_expected() { printf '%s\n' "$1" > "$H/bundle/EXPECTED_BIN_SHA"; }
set_expected "$NEWHASH"

# S1 部署成功
reset_esp
OUT=$(bash "$H/bundle/onsite/deploy.sh" 2>&1); RC=$?
[ $RC -eq 0 ] && ok "S1 部署返回 0" || bad "S1 部署返回 0" "rc=$RC :: $(echo "$OUT" | tail -2 | tr '\n' ' ')"
[ "$(sha "$DST" 2>/dev/null)" = "$NEWHASH" ] && ok "S1 新 kext 已就位" || bad "S1 新 kext 已就位" "哈希不符"
BK=$(ls -d "$H/esp"/igpu-backup-* 2>/dev/null | head -1)
[ -n "$BK" ] && ok "S1 备份目录已建" || bad "S1 备份目录已建" "无"
[ "$(sed -n 's/^STATE=//p' "$BK/STATE" 2>/dev/null)" = "complete" ] && ok "S1 STATE=complete" || bad "S1 STATE=complete" "$(cat "$BK/STATE" 2>/dev/null)"
grep -q '^old_binary=.\+' "$BK/SHA256.old" 2>/dev/null && ok "S1 SHA256.old 完整" || bad "S1 SHA256.old 完整" "缺"
[ "$(sed -n 's/^EXISTED_KEXT=//p' "$BK/META" 2>/dev/null)" = "yes" ] && ok "S1 META=yes" || bad "S1 META=yes" "$(cat "$BK/META" 2>/dev/null)"
[ "$(sha "$H/esp/EFI/OC/config.plist")" = "$CD" ] && ok "S1 config 未变" || bad "S1 config 未变" "变了"
ls "$H/esp/EFI/OC/Kexts"/.IGPUProbe.kext.* >/dev/null 2>&1 && bad "S1 无残留暂存目录" "仍有" || ok "S1 无残留暂存目录"

# S2 缺 _kmod_info 拒绝
reset_esp
FAKE_NM_UNDEFINED=1 bash "$H/bundle/onsite/deploy.sh" >/dev/null 2>&1; RC=$?
[ $RC -ne 0 ] && ok "S2 缺 _kmod_info 拒绝(rc≠0)" || bad "S2 缺 _kmod_info 拒绝" "rc=0"
[ "$(head -c 10 "$DST")" = "OLD-BINARY" ] && ok "S2 原 kext 未动" || bad "S2 原 kext 未动" "内容变"
[ -z "$(ls -d "$H/esp"/igpu-backup-* 2>/dev/null)" ] && ok "S2 未产生备份" || bad "S2 未产生备份" "有备份"

# S3 回滚成功
reset_esp
bash "$H/bundle/onsite/deploy.sh" >/dev/null 2>&1
OUT=$(bash "$H/bundle/onsite/rollback.sh" 2>&1); RC=$?
[ $RC -eq 0 ] && ok "S3 回滚返回 0" || bad "S3 回滚返回 0" "rc=$RC"
grep -q '只回滚 kext' <<<"$OUT" && ok "S3 默认模式声明只回滚 kext" || bad "S3 模式声明" "$(echo "$OUT" | head -2 | tr '\n' ' ')"
[ "$(head -c 10 "$DST" 2>/dev/null)" = "OLD-BINARY" ] && ok "S3 kext 回到回滚前" || bad "S3 kext 回到回滚前" "$(head -c 30 "$DST" 2>/dev/null)"
[ "$(sha "$H/esp/EFI/OC/config.plist")" = "$CD" ] && ok "S3 config 未变" || bad "S3 config 未变" "变了"

# S4 拒绝 partial
reset_esp
bash "$H/bundle/onsite/deploy.sh" >/dev/null 2>&1
BK=$(ls -d "$H/esp"/igpu-backup-* | head -1)
printf 'STATE=partial\n' > "$BK/STATE"
bash "$H/bundle/onsite/rollback.sh" --from "$BK" >/dev/null 2>&1; RC=$?
[ $RC -ne 0 ] && ok "S4 --from 拒绝 partial" || bad "S4 --from 拒绝 partial" "rc=0"
bash "$H/bundle/onsite/rollback.sh" >/dev/null 2>&1; RC=$?
[ $RC -ne 0 ] && ok "S4 自动扫描拒绝 partial" || bad "S4 自动扫描拒绝 partial" "rc=0"

# S5 --config
reset_esp
bash "$H/bundle/onsite/deploy.sh" >/dev/null 2>&1
bash "$H/bundle/onsite/rollback.sh" --config >/dev/null 2>&1; RC=$?
[ $RC -eq 0 ] && ok "S5 --config 返回 0" || bad "S5 --config 返回 0" "rc=$RC"
[ "$(sha "$H/esp/EFI/OC/config.plist")" = "$CB" ] && ok "S5 config 回到基线" || bad "S5 config 回到基线" "$(sha "$H/esp/EFI/OC/config.plist")"
[ "$(head -c 10 "$DST" 2>/dev/null)" = "OLD-BINARY" ] && ok "S5 kext 同时还原" || bad "S5 kext 同时还原" "不对"

# S6 部署前本来没有 kext
reset_esp
rm -rf "$H/esp/EFI/OC/Kexts/IGPUProbe.kext"
bash "$H/bundle/onsite/deploy.sh" >/dev/null 2>&1; RC=$?
BK=$(ls -d "$H/esp"/igpu-backup-* 2>/dev/null | head -1)
[ "$(sed -n 's/^EXISTED_KEXT=//p' "$BK/META" 2>/dev/null)" = "no" ] && ok "S6 META=no" || bad "S6 META=no" "rc=$RC"
bash "$H/bundle/onsite/rollback.sh" >/dev/null 2>&1; RC=$?
[ $RC -eq 0 ] && ok "S6 回滚返回 0" || bad "S6 回滚返回 0" "rc=$RC"
[ ! -d "$H/esp/EFI/OC/Kexts/IGPUProbe.kext" ] && ok "S6 回滚后 kext 被移除" || bad "S6 回滚后 kext 被移除" "目录仍在"

# ---- S5R/S6R/S7R：--reinject（真实 plist 配置，走 inject-probe.py）----
RLIVE="$H/real-config.plist"
RBASE="$H/real-base.plist"

mkreal_esp() {
  rm -rf "$H/espr"; mkdir -p "$H/espr/EFI/OC/Kexts/IGPUProbe.kext/Contents/MacOS"
  cp "$1" "$H/espr/EFI/OC/config.plist"
  printf 'OLD-BINARY\n' > "$H/espr/EFI/OC/Kexts/IGPUProbe.kext/Contents/MacOS/IGPUProbe"
  printf 'OLD-PLIST\n'  > "$H/espr/EFI/OC/Kexts/IGPUProbe.kext/Contents/Info.plist"
}
SETTER="$H/bundle/tools/set-bootargs.py"
field() { python3 "$SETTER" --config "$1" --check 2>/dev/null | sed -n "s/^$2=//p" | head -1; }

# S5R 基线 + --reinject ⇒ 成功、条目 1 条、boot-args 规范 normal、kext 就位
mkreal_esp "$RBASE"
OUT=$(FAKE_ESP="$H/espr" bash "$H/bundle/onsite/deploy.sh" --reinject 2>&1); RC=$?
[ $RC -eq 0 ] && ok "S5R 基线+--reinject 返回 0" || bad "S5R 基线+--reinject 返回 0" "rc=$RC :: $(echo "$OUT" | tail -3 | tr '\n' ' ')"
[ "$(field "$H/espr/EFI/OC/config.plist" probe_count)" = "1" ] && ok "S5R 探针条目恰 1 条" || bad "S5R 探针条目" "$(field "$H/espr/EFI/OC/config.plist" probe_count)"
[ "$(field "$H/espr/EFI/OC/config.plist" state)" = "normal" ] && ok "S5R boot-args 归一到 normal" || bad "S5R 归一到 normal" "$(field "$H/espr/EFI/OC/config.plist" state)"
[ "$(field "$H/espr/EFI/OC/config.plist" canonical)" = "yes" ] && ok "S5R boot-args 规范串" || bad "S5R canonical" "$(field "$H/espr/EFI/OC/config.plist" canonical)"
[ "$(sha "$H/espr/EFI/OC/Kexts/IGPUProbe.kext/Contents/MacOS/IGPUProbe")" = "$NEWHASH" ] && ok "S5R kext 已就位" || bad "S5R kext 已就位" "哈希不符"
BKR=$(ls -dt "$H/espr"/igpu-backup-* 2>/dev/null | head -1)
[ -n "$BKR" ] && [ "$(sed -n 's/^config_before_sha=//p' "$BKR/META")" = "$CB" ] && ok "S5R config_before 哈希=基线" || bad "S5R config_before" "$(sed -n 's/^config_before_sha=//p' "$BKR/META" 2>/dev/null)"
[ "$(sha "$BKR/config.plist" 2>/dev/null)" = "$CB" ] && ok "S5R 备份文件就是改前基线" || bad "S5R 备份内容" "不符"
[ "$(sed -n 's/^config_after_sha=//p' "$BKR/META")" = "$(sha "$H/espr/EFI/OC/config.plist")" ] && ok "S5R META 记录 config_after" || bad "S5R config_after" "$(sed -n 's/^config_after_sha=//p' "$BKR/META" 2>/dev/null)"

# S6R 基线不带 flag ⇒ 非 0 且提示 --reinject，配置不被改
mkreal_esp "$RBASE"
H_BEFORE=$(sha "$H/espr/EFI/OC/config.plist")
OUT=$(FAKE_ESP="$H/espr" bash "$H/bundle/onsite/deploy.sh" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "S6R 基线无 flag 被拒(rc≠0)" || bad "S6R 基线无 flag 被拒" "rc=0"
grep -q -- '--reinject' <<<"$OUT" && ok "S6R 提示 --reinject" || bad "S6R 提示 --reinject" "$(echo "$OUT" | tail -2 | tr '\n' ' ')"
[ "$(sha "$H/espr/EFI/OC/config.plist")" = "$H_BEFORE" ] && ok "S6R 被拒时配置未变" || bad "S6R 配置未变" "变了"
grep -q 'ESP 外' <<<"$OUT" && ok "S6R 提示改前手工备份" || bad "S6R 手工备份提示" "$(echo "$OUT" | tail -3)"

# S7R 已注入态再 --reinject ⇒ 幂等、条目仍 1 条、配置哈希不变
mkreal_esp "$RLIVE"
H1=$(sha "$H/espr/EFI/OC/config.plist")
OUT=$(FAKE_ESP="$H/espr" bash "$H/bundle/onsite/deploy.sh" --reinject 2>&1); RC=$?
[ $RC -eq 0 ] && ok "S7R 已注入态再 --reinject 返回 0" || bad "S7R 再 --reinject" "rc=$RC :: $(echo "$OUT" | tail -2 | tr '\n' ' ')"
[ "$(sha "$H/espr/EFI/OC/config.plist")" = "$H1" ] && ok "S7R 幂等：配置哈希不变" || bad "S7R 幂等" "哈希变了"
[ "$(field "$H/espr/EFI/OC/config.plist" probe_count)" = "1" ] && ok "S7R 条目仍 1 条" || bad "S7R 条目数" "$(field "$H/espr/EFI/OC/config.plist" probe_count)"
# S8 暂存校验失败（桩注入器让 --verify-staged 返回 9）⇒ 配置与 kext 均未变
BAD="$H/badbundle"
rm -rf "$BAD"; cp -R "$H/bundle" "$BAD"
cat > "$BAD/tools/inject-probe.py" <<EOF
import runpy, sys
REAL = r"$H/bundle/tools/inject-probe.py"
if "--verify-staged" in sys.argv:
    sys.stderr.write("forced staged failure")
    sys.exit(9)
sys.argv[0] = REAL
runpy.run_path(REAL, run_name="__main__")
EOF
mkreal_esp "$RBASE"
S8B=$(sha "$H/espr/EFI/OC/config.plist")
OUT=$(FAKE_ESP="$H/espr" bash "$BAD/onsite/deploy.sh" --reinject 2>&1); RC=$?
[ $RC -ne 0 ] && ok "S8 暂存校验失败被拒(rc≠0)" || bad "S8 暂存失败" "rc=0"
[ "$(sha "$H/espr/EFI/OC/config.plist")" = "$S8B" ] && ok "S8 失败时配置未变" || bad "S8 配置未变" "变了"
[ "$(head -c 10 "$H/espr/EFI/OC/Kexts/IGPUProbe.kext/Contents/MacOS/IGPUProbe")" = "OLD-BINARY" ] && ok "S8 失败时 kext 未变" || bad "S8 kext 未变" "变了"
rm -rf "$BAD"

# S9 N3：白名单必须是文件；env 只能复述；签名产物同样必须登记
mkreal_esp "$RLIVE"
rm -f "$H/bundle/EXPECTED_BIN_SHA"
OUT=$(FAKE_ESP="$H/espr" bash "$H/bundle/onsite/deploy.sh" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "S9 缺白名单文件被拒" || bad "S9 缺白名单文件" "rc=0"
grep -q 'EXPECTED_BIN_SHA' <<<"$OUT" && ok "S9 提示补齐 EXPECTED_BIN_SHA" || bad "S9 缺文件提示" "$(echo "$OUT" | tail -2)"

set_expected "0000000000000000000000000000000000000000000000000000000000000000"
OUT=$(FAKE_ESP="$H/espr" bash "$H/bundle/onsite/deploy.sh" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "S9 白名单哈希不符被拒" || bad "S9 哈希不符" "rc=0"

set_expected "$NEWHASH"
OUT=$(FAKE_ESP="$H/espr" FAKE_SIGNED=1 bash "$H/bundle/onsite/deploy.sh" 2>&1); RC=$?
[ $RC -eq 0 ] && ok "S9 签名产物+匹配白名单放行" || bad "S9 签名+白名单" "rc=$RC :: $(echo "$OUT" | tail -2)"
grep -q '签名=yes' <<<"$OUT" && ok "S9 提示签名状态" || bad "S9 签名提示" "$(echo "$OUT" | tail -2)"

mkreal_esp "$RLIVE"
OUT=$(FAKE_ESP="$H/espr" IGPU_EXPECTED_BIN_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" bash "$H/bundle/onsite/deploy.sh" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "S9 env 与文件不同被拒" || bad "S9 env 不同" "rc=0"
grep -q '只能复述' <<<"$OUT" && ok "S9 env 差异提示" || bad "S9 env 提示" "$(echo "$OUT" | tail -2)"

mkreal_esp "$RLIVE"
OUT=$(FAKE_ESP="$H/espr" IGPU_EXPECTED_BIN_SHA="$NEWHASH" bash "$H/bundle/onsite/deploy.sh" 2>&1); RC=$?
[ $RC -eq 0 ] && ok "S9 env 与文件一致放行" || bad "S9 env 一致" "rc=$RC :: $(echo "$OUT" | tail -2)"
set_expected "$NEWHASH"

# S10 已注入 off 态 + --reinject ⇒ 归一到 normal
mkreal_esp "$RLIVE"
python3 - "$H/espr/EFI/OC/config.plist" <<'PYEOF'
import plistlib, sys
p = sys.argv[1]; d = plistlib.load(open(p, "rb"))
d["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]["boot-args"] = "-v igpu-driver=off"
open(p, "wb").write(plistlib.dumps(d))
PYEOF
OUT=$(FAKE_ESP="$H/espr" bash "$H/bundle/onsite/deploy.sh" --reinject 2>&1); RC=$?
[ $RC -eq 0 ] && ok "S10 off 态 --reinject 返回 0" || bad "S10 off 态 reinject" "rc=$RC :: $(echo "$OUT" | tail -2)"
[ "$(field "$H/espr/EFI/OC/config.plist" state)" = "normal" ] && ok "S10 归一到 normal" || bad "S10 归一到 normal" "$(field "$H/espr/EFI/OC/config.plist" state)"
grep -q 'igpu-driver=off' <<<"$(field "$H/espr/EFI/OC/config.plist" boot-args)" && bad "S10 旧 off token 已清除" "仍在" || ok "S10 旧 off token 已清除"

# S17 N6：--from-backup 恢复该次部署的 config_before 与旧 kext
mkreal_esp "$RBASE"
OUT=$(FAKE_ESP="$H/espr" bash "$H/bundle/onsite/deploy.sh" --reinject 2>&1); RC=$?
[ $RC -eq 0 ] && ok "S17 预置：基线 reinject 成功" || bad "S17 预置" "rc=$RC :: $(echo "$OUT" | tail -2)"
BKR3=$(ls -dt "$H/espr"/igpu-backup-* 2>/dev/null | head -1)
OUT=$(FAKE_ESP="$H/espr" bash "$H/bundle/onsite/rollback.sh" --from-backup "$BKR3" 2>&1); RC=$?
[ $RC -eq 0 ] && ok "S17 --from-backup 返回 0" || bad "S17 --from-backup" "rc=$RC :: $(echo "$OUT" | tail -3 | tr '\n' ' ')"
[ "$(sha "$H/espr/EFI/OC/config.plist")" = "$CB" ] && ok "S17 config 回到部署前基线" || bad "S17 config 回滚" "$(sha "$H/espr/EFI/OC/config.plist")"
[ "$(head -c 10 "$H/espr/EFI/OC/Kexts/IGPUProbe.kext/Contents/MacOS/IGPUProbe" 2>/dev/null)" = "OLD-BINARY" ] && ok "S17 kext 回到旧件" || bad "S17 kext 回滚" "不对"

# S11 F2：探针条目 2 条 ⇒ dirty，拒绝且不改配置
mkreal_esp "$RLIVE"
python3 - "$H/espr/EFI/OC/config.plist" <<'PYEOF'
import plistlib, sys
p = sys.argv[1]; d = plistlib.load(open(p, "rb"))
probe = [e for e in d["Kernel"]["Add"] if str(e.get("BundlePath", "")).startswith("IGPUProbe.kext")][0]
d["Kernel"]["Add"].append(dict(probe))
open(p, "wb").write(plistlib.dumps(d))
PYEOF
S11B=$(sha "$H/espr/EFI/OC/config.plist")
OUT=$(FAKE_ESP="$H/espr" bash "$H/bundle/onsite/deploy.sh" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "S11 多条探针被拒(rc≠0)" || bad "S11 多条探针" "rc=0"
grep -q '探针条目' <<<"$OUT" && ok "S11 报错说明条目数" || bad "S11 报错原因" "$(echo "$OUT" | tail -2)"
[ "$(sha "$H/espr/EFI/OC/config.plist")" = "$S11B" ] && ok "S11 被拒时配置未变" || bad "S11 配置未变" "变了"

# S12 F2：无探针但哈希不认识 ⇒ dirty（不能靠哈希碰运气）
mkreal_esp "$RLIVE"
python3 - "$H/espr/EFI/OC/config.plist" <<'PYEOF'
import plistlib, sys
p = sys.argv[1]; d = plistlib.load(open(p, "rb"))
d["Kernel"]["Add"] = [e for e in d["Kernel"]["Add"] if not str(e.get("BundlePath", "")).startswith("IGPUProbe.kext")]
d["TEST-UNKNOWN-KEY"] = "dirty"
open(p, "wb").write(plistlib.dumps(d))
PYEOF
S12B=$(sha "$H/espr/EFI/OC/config.plist")
OUT=$(FAKE_ESP="$H/espr" bash "$H/bundle/onsite/deploy.sh" --reinject 2>&1); RC=$?
[ $RC -ne 0 ] && ok "S12 无探针且非基线被拒(rc≠0)" || bad "S12 dirty" "rc=0"
[ "$(sha "$H/espr/EFI/OC/config.plist")" = "$S12B" ] && ok "S12 被拒时配置未变" || bad "S12 配置未变" "变了"

# S13 F14：ESP 只读 ⇒ 拒绝，且不产生备份
mkreal_esp "$RLIVE"
OUT=$(FAKE_ESP="$H/espr" FAKE_RO=Yes bash "$H/bundle/onsite/deploy.sh" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "S13 只读 ESP 被拒(rc≠0)" || bad "S13 只读" "rc=0"
grep -q 'Read-Only' <<<"$OUT" && ok "S13 报错指出只读" || bad "S13 报错" "$(echo "$OUT" | tail -2)"
[ -z "$(ls -d "$H/espr"/igpu-backup-* 2>/dev/null)" ] && ok "S13 被拒时未建备份" || bad "S13 未建备份" "有"

# S15 N7：已注入但非 normal，且没有 --reinject ⇒ 拒绝并提示
mkreal_esp "$RLIVE"
python3 - "$H/espr/EFI/OC/config.plist" <<'PYEOF'
import plistlib, sys
p = sys.argv[1]; d = plistlib.load(open(p, "rb"))
d["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]["boot-args"] = "-v igpu-driver=off"
open(p, "wb").write(plistlib.dumps(d))
PYEOF
S15B=$(sha "$H/espr/EFI/OC/config.plist")
OUT=$(FAKE_ESP="$H/espr" bash "$H/bundle/onsite/deploy.sh" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "S15 已注入 off 无 --reinject 被拒" || bad "S15 无 reinject" "rc=0"
grep -q '未达可部署状态' <<<"$OUT" && ok "S15 报错说明状态不达标" || bad "S15 报错原因" "$(echo "$OUT" | tail -3 | tr '\n' ' ')"
[ "$(sha "$H/espr/EFI/OC/config.plist")" = "$S15B" ] && ok "S15 被拒时配置未变" || bad "S15 配置未变" "变了"

# S16 N7：缺 NVRAM/Delete/boot-args 时 --reinject 也必须拒绝，且现网未被改
mkreal_esp "$RLIVE"
python3 - "$H/espr/EFI/OC/config.plist" <<'PYEOF'
import plistlib, sys
p = sys.argv[1]; d = plistlib.load(open(p, "rb"))
g = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
d["NVRAM"]["Delete"][g] = [x for x in d["NVRAM"]["Delete"][g] if x != "boot-args"]
open(p, "wb").write(plistlib.dumps(d))
PYEOF
S16B=$(sha "$H/espr/EFI/OC/config.plist")
OUT=$(FAKE_ESP="$H/espr" bash "$H/bundle/onsite/deploy.sh" --reinject 2>&1); RC=$?
[ $RC -ne 0 ] && ok "S16 缺 Delete 的 reinject 被拒" || bad "S16 缺 Delete" "rc=0"
[ "$(sha "$H/espr/EFI/OC/config.plist")" = "$S16B" ] && ok "S16 被拒时配置未变" || bad "S16 配置未变" "变了"

# S18 N5/N3：存在 dist/ 时默认用它，并用 dist/SHA256SUMS 复核两项；篡改清单必须拒绝
rm -rf "$H/bundle/dist"; mkdir -p "$H/bundle/dist/IGPUProbe.kext/Contents/MacOS"
printf 'DIST-BINARY\n' > "$H/bundle/dist/IGPUProbe.kext/Contents/MacOS/IGPUProbe"
printf 'DIST-PLIST\n'  > "$H/bundle/dist/IGPUProbe.kext/Contents/Info.plist"
{
  printf '%s  %s\n' "$(sha "$H/bundle/dist/IGPUProbe.kext/Contents/MacOS/IGPUProbe")" "IGPUProbe.kext/Contents/MacOS/IGPUProbe"
  printf '%s  %s\n' "$(sha "$H/bundle/dist/IGPUProbe.kext/Contents/Info.plist")" "IGPUProbe.kext/Contents/Info.plist"
} > "$H/bundle/dist/SHA256SUMS"
DISTHASH=$(sha "$H/bundle/dist/IGPUProbe.kext/Contents/MacOS/IGPUProbe")
set_expected "$DISTHASH"
mkreal_esp "$RLIVE"
OUT=$(FAKE_ESP="$H/espr" bash "$H/bundle/onsite/deploy.sh" 2>&1); RC=$?
[ $RC -eq 0 ] && ok "S18 dist 默认产物部署返回 0" || bad "S18 dist 部署" "rc=$RC :: $(echo "$OUT" | tail -3 | tr '\n' ' ')"
grep -q '默认使用 dist' <<<"$OUT" && ok "S18 打印使用 dist" || bad "S18 产物选择提示" "$(echo "$OUT" | head -6 | tr '\n' ' ')"
[ "$(head -c 11 "$H/espr/EFI/OC/Kexts/IGPUProbe.kext/Contents/MacOS/IGPUProbe" 2>/dev/null)" = "DIST-BINARY" ] && ok "S18 装入的是 dist 二进制" || bad "S18 装入产物" "不对"
printf '0000000000000000000000000000000000000000000000000000000000000000  IGPUProbe.kext/Contents/MacOS/IGPUProbe\n' > "$H/bundle/dist/SHA256SUMS"
mkreal_esp "$RLIVE"
OUT=$(FAKE_ESP="$H/espr" bash "$H/bundle/onsite/deploy.sh" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "S18 dist 清单被篡改时拒绝" || bad "S18 dist 篡改" "rc=0"
grep -q 'dist/SHA256SUMS' <<<"$OUT" && ok "S18 报错指向 dist/SHA256SUMS" || bad "S18 篡改提示" "$(echo "$OUT" | tail -3 | tr '\n' ' ')"
rm -rf "$H/bundle/dist"; set_expected "$NEWHASH"

# S14 F3：配置已替换、kext 已就位后失败 ⇒ 必须整体回滚（config 与 kext 都回到改前）
mkreal_esp "$RBASE"
rm -f "$H/plutil.cnt"
OUT=$(FAKE_ESP="$H/espr" FAKE_PLUTIL_FAIL_AT=3 FAKE_PLUTIL_COUNTER="$H/plutil.cnt" bash "$H/bundle/onsite/deploy.sh" --reinject 2>&1); RC=$?
[ $RC -ne 0 ] && ok "S14 提交前失败返回非 0" || bad "S14 rc" "rc=0"
[ "$(sha "$H/espr/EFI/OC/config.plist")" = "$CB" ] && ok "S14 config 已回滚到改前基线" || bad "S14 config 回滚" "$(sha "$H/espr/EFI/OC/config.plist")"
[ "$(head -c 10 "$H/espr/EFI/OC/Kexts/IGPUProbe.kext/Contents/MacOS/IGPUProbe")" = "OLD-BINARY" ] && ok "S14 kext 已回滚" || bad "S14 kext 回滚" "变了"
BKR2=$(ls -dt "$H/espr"/igpu-backup-* 2>/dev/null | head -1)
[ "$(sed -n 's/^STATE=//p' "$BKR2/STATE" 2>/dev/null)" = "partial" ] && ok "S14 备份保持 partial（未提交）" || bad "S14 STATE" "$(sed -n 's/^STATE=//p' "$BKR2/STATE" 2>/dev/null)"

printf '\n===== PASS=%d  FAIL=%d =====\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]