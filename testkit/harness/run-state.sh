#!/bin/bash
# 04-state.sh 仿真（第二轮）：真实 config.plist + 桩件 + 真 python
set +u
H="$(cd "$(dirname "$0")" && pwd)"
# 让裸 `python` 解析到 testkit/bin/python（shim：exec python3）。
# macOS 26 没有 `python` 命令；本地 Windows 能跑是因为外部 PATH 里恰好有 shim——
# 那是环境巧合，不能当依赖（CI 上会直接失败）。
PATH="$H/../bin:$PATH"; export PATH
export PATH="$H/stubs:$PATH"
sh "$H/sync-bundle.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s  —— %s\n' "$1" "$2"; }
# macOS 没有 sha256sum（GNU coreutils），必须回退 shasum；否则在真 Mac 上跑直接失败
sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
REALCFG="$H/real-config.plist"
ORIG_SHA=$(sha "$REALCFG")
SET="$H/bundle/tools/set-bootargs.py"

setup() { rm -rf "$H/esp2"; mkdir -p "$H/esp2/EFI/OC"; cp "$REALCFG" "$H/esp2/EFI/OC/config.plist"; export FAKE_ESP="$H/esp2"; }
CFG="$H/esp2/EFI/OC/config.plist"
state_of() { python "$SET" --config "$1" --check 2>/dev/null | sed -n 's/^state=//p'; }
args_of()  { python "$SET" --config "$1" --check 2>/dev/null | sed -n "s/^boot-args=//p"; }
mutate()   { python - "$@" <<'PY'
import plistlib, pathlib, sys
p = pathlib.Path(sys.argv[1]); d = plistlib.loads(p.read_bytes())
mode = sys.argv[2]
if mode == "setargs": d["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]["boot-args"] = sys.argv[3]
elif mode == "rmdelete":
    g = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
    d["NVRAM"]["Delete"][g] = [x for x in d["NVRAM"]["Delete"][g] if x != "boot-args"]
elif mode == "disableprobe":
    for e in d["Kernel"]["Add"]:
        if str(e.get("BundlePath","")).startswith("IGPUProbe"): e["Enabled"] = False
p.write_bytes(plistlib.dumps(d))
PY
}

# T1 show
setup
OUT=$(bash "$H/bundle/onsite/04-state.sh" show 2>&1); RC=$?
[ $RC -eq 0 ] && ok "T1 show 返回 0" || bad "T1 show 返回 0" "rc=$RC"
[ "$(sha "$CFG")" = "$ORIG_SHA" ] && ok "T1 show 不改文件" || bad "T1 show 不改文件" "变了"
[ -z "$(ls -d "$H/esp2"/igpu-state-* 2>/dev/null)" ] && ok "T1 show 不建备份" || bad "T1 show 不建备份" "有备份"

# T2 off
setup
bash "$H/bundle/onsite/04-state.sh" off >/dev/null 2>&1; RC=$?
[ $RC -eq 0 ] && ok "T2 off 返回 0" || bad "T2 off 返回 0" "rc=$RC"
[ "$(state_of "$CFG")" = "off" ] && ok "T2 状态=off" || bad "T2 状态" "$(state_of "$CFG")"
BK=$(ls -d "$H/esp2"/igpu-state-* 2>/dev/null | head -1)
[ -n "$BK" ] && ok "T2 建 igpu-state-* 备份" || bad "T2 建备份" "无"
[ "$(sed -n 's/^STATE=//p' "$BK/STATE")" = "complete" ] && ok "T2 STATE=complete" || bad "T2 STATE" "$(cat "$BK/STATE")"
[ "$(sed -n 's/^TYPE=//p' "$BK/META")" = "config-state" ] && ok "T2 META TYPE=config-state" || bad "T2 META" "$(cat "$BK/META")"
[ "$(sed -n 's/^old_sha=//p' "$BK/META")" = "$ORIG_SHA" ] && ok "T2 META 记录旧哈希" || bad "T2 META old_sha" "不符"
[ "$(sha "$BK/config.plist")" = "$ORIG_SHA" ] && ok "T2 备份=改前配置" || bad "T2 备份内容" "不符"
[ -z "$(ls -d "$H/esp2"/igpu-backup-* 2>/dev/null)" ] && ok "T2 不产生 igpu-backup-*（不与回滚混淆）" || bad "T2 前缀隔离" "出现了 igpu-backup-*"

# T3 幂等
BEFORE=$(ls -d "$H/esp2"/igpu-state-* | wc -l | tr -d ' ')
bash "$H/bundle/onsite/04-state.sh" off >/dev/null 2>&1; RC=$?
AFTER=$(ls -d "$H/esp2"/igpu-state-* | wc -l | tr -d ' ')
[ $RC -eq 0 ] && ok "T3 重复 off 返回 0" || bad "T3 重复 off 返回 0" "rc=$RC"
[ "$BEFORE" = "$AFTER" ] && ok "T3 幂等不建新备份" || bad "T3 幂等" "$BEFORE -> $AFTER"

# T4 verbose：单 token
bash "$H/bundle/onsite/04-state.sh" verbose >/dev/null 2>&1
[ "$(state_of "$CFG")" = "verbose" ] && ok "T4 状态=verbose" || bad "T4 状态" "$(state_of "$CFG")"
[ "$(grep -o 'igpu-driver=' <<<"$(args_of "$CFG")" | wc -l | tr -d ' ')" = "1" ] && ok "T4 单 token" || bad "T4 单 token" "多个"

# T5 回 normal + 语义等价
bash "$H/bundle/onsite/04-state.sh" normal >/dev/null 2>&1
[ "$(state_of "$CFG")" = "normal" ] && ok "T5 状态=normal" || bad "T5 状态" "$(state_of "$CFG")"
EQU=$(python - "$REALCFG" "$CFG" <<'PY'
import plistlib, sys, pathlib
def load(p): return plistlib.loads(pathlib.Path(p).read_bytes())
def norm(d):
    d = plistlib.loads(plistlib.dumps(d))
    for g, kv in d.get("NVRAM", {}).get("Add", {}).items():
        if isinstance(kv, dict) and "boot-args" in kv: kv["boot-args"] = "<same>"
    return d
print("yes" if norm(load(sys.argv[1])) == norm(load(sys.argv[2])) else "no")
PY
)
[ "$EQU" = "yes" ] && ok "T5 语义等价" || bad "T5 语义等价" "no"

# T6 缺 NVRAM/Delete → 拒绝且不改文件
setup; mutate "$CFG" rmdelete
B4=$(sha "$CFG")
bash "$H/bundle/onsite/04-state.sh" off >/dev/null 2>&1; RC=$?
[ $RC -ne 0 ] && ok "T6 缺 Delete 时拒绝(rc≠0)" || bad "T6 缺 Delete 时拒绝" "rc=0"
[ "$(sha "$CFG")" = "$B4" ] && ok "T6 拒绝时未改文件" || bad "T6 拒绝时未改文件" "变了"

# T7 探针被禁用 → 严格预检拒绝
setup; mutate "$CFG" disableprobe
B7=$(sha "$CFG")
bash "$H/bundle/onsite/04-state.sh" off >/dev/null 2>&1; RC=$?
[ $RC -ne 0 ] && ok "T7 探针 Enabled=false 被拒" || bad "T7 探针禁用" "rc=0"
[ "$(sha "$CFG")" = "$B7" ] && ok "T7 拒绝时未改文件" || bad "T7 未改文件" "变了"

# T8 脏 token 归一化
setup; mutate "$CFG" setargs "-v -igpu-driver=off"
bash "$H/bundle/onsite/04-state.sh" off >/dev/null 2>&1; RC=$?
[ $RC -eq 0 ] && ok "T8 脏 token 下 off 返回 0" || bad "T8 脏 token" "rc=$RC"
[ "$(args_of "$CFG")" = "'-v igpu-driver=off'" ] && ok "T8 归一成规范串" || bad "T8 归一" "$(args_of "$CFG")"

# T9 safe-on：加 -x，igpu-driver 保持不变
setup; mutate "$CFG" setargs "-v igpu-driver=off"
bash "$H/bundle/onsite/04-state.sh" safe-on >/dev/null 2>&1; RC=$?
A=$(args_of "$CFG")
[ $RC -eq 0 ] && ok "T9 safe-on 返回 0" || bad "T9 safe-on 返回 0" "rc=$RC"
grep -q -- '-x' <<<"$A" && ok "T9 已加 -x" || bad "T9 已加 -x" "$A"
[ "$(state_of "$CFG")" = "off" ] && ok "T9 igpu-driver 保持 off" || bad "T9 保持 off" "$(state_of "$CFG")"

# T10 safe-off：去掉 -x，igpu-driver 仍不变
bash "$H/bundle/onsite/04-state.sh" safe-off >/dev/null 2>&1; RC=$?
A=$(args_of "$CFG")
[ $RC -eq 0 ] && ok "T10 safe-off 返回 0" || bad "T10 safe-off 返回 0" "rc=$RC"
grep -q -- '-x' <<<"$A" && bad "T10 -x 已移除" "仍有" || ok "T10 -x 已移除"
[ "$(state_of "$CFG")" = "off" ] && ok "T10 igpu-driver 仍 off" || bad "T10 仍 off" "$(state_of "$CFG")"

# T11 safe-on 幂等：不产生新备份
setup; mutate "$CFG" setargs "-v -x"
B3=$(ls -d "$H/esp2"/igpu-state-* 2>/dev/null | wc -l | tr -d ' ')
bash "$H/bundle/onsite/04-state.sh" safe-on >/dev/null 2>&1; RC=$?
A3=$(ls -d "$H/esp2"/igpu-state-* 2>/dev/null | wc -l | tr -d ' ')
[ $RC -eq 0 ] && ok "T11 已含 -x 时 safe-on 返回 0" || bad "T11 safe-on 幂等" "rc=$RC"
[ "$B3" = "$A3" ] && ok "T11 幂等不建备份" || bad "T11 幂等" "$B3 -> $A3"
# T12 prep：从 off 切到 prep，得到规范 igpu-driver=prep 且 off 被清掉
setup; mutate "$CFG" setargs "-v igpu-driver=off"
bash "$H/bundle/onsite/04-state.sh" prep >/dev/null 2>&1; RC=$?
A=$(args_of "$CFG")
[ $RC -eq 0 ] && ok "T12 prep 返回 0" || bad "T12 prep 返回 0" "rc=$RC"
grep -q 'igpu-driver=prep' <<<"$A" && ok "T12 boot-args 含 prep" || bad "T12 含 prep" "$A"
grep -q 'igpu-driver=off' <<<"$A" && bad "T12 旧状态已清除" "$A" || ok "T12 旧状态已清除"
[ "$(state_of "$CFG")" = "prep" ] && ok "T12 state=prep" || bad "T12 state" "$(state_of "$CFG")"

# T13 prep 幂等：不产生新备份
B4=$(ls -d "$H/esp2"/igpu-state-* 2>/dev/null | wc -l | tr -d ' ')
bash "$H/bundle/onsite/04-state.sh" prep >/dev/null 2>&1; RC=$?
A4=$(ls -d "$H/esp2"/igpu-state-* 2>/dev/null | wc -l | tr -d ' ')
[ $RC -eq 0 ] && ok "T13 prep 幂等返回 0" || bad "T13 幂等" "rc=$RC"
[ "$B4" = "$A4" ] && ok "T13 幂等不建备份" || bad "T13 幂等" "$B4 -> $A4"

# T14 prep → normal 可回退
bash "$H/bundle/onsite/04-state.sh" normal >/dev/null 2>&1; RC=$?
A5=$(args_of "$CFG")
[ $RC -eq 0 ] && ok "T14 prep→normal 返回 0" || bad "T14 回 normal" "rc=$RC"
grep -q 'igpu-driver' <<<"$A5" && bad "T14 已清掉 igpu-driver" "$A5" || ok "T14 已清掉 igpu-driver"
# T15 F4：--mode off --require-deployable 必须真的写盘
setup
T15B=$(sha "$CFG")
OUT=$(python3 "$SET" --config "$CFG" --mode off --require-deployable 2>&1); RC=$?
[ $RC -eq 0 ] && ok "T15 带 --mode 时返回 0" || bad "T15 返回 0" "rc=$RC :: $(echo "$OUT" | tail -2)"
[ "$(state_of "$CFG")" = "off" ] && ok "T15 实际写入 off（不是只校验）" || bad "T15 写入 off" "$(state_of "$CFG")"
[ "$(sha "$CFG")" != "$T15B" ] && ok "T15 文件确实改变" || bad "T15 文件改变" "哈希未变"
grep -q '^deployable=yes' <<<"$OUT" && ok "T15 回读 deployable=yes" || bad "T15 回读" "$(echo "$OUT" | tail -3)"

# T16 只给 --require-deployable（无 --mode/--set-x）⇒ 只校验，不改文件
setup
T16B=$(sha "$CFG")
OUT=$(python3 "$SET" --config "$CFG" --require-deployable 2>&1); RC=$?
[ $RC -eq 0 ] && ok "T16 只校验返回 0" || bad "T16 只校验" "rc=$RC"
[ "$(sha "$CFG")" = "$T16B" ] && ok "T16 只校验不改文件" || bad "T16 不改文件" "变了"
grep -q '^deployable=yes' <<<"$OUT" && ok "T16 输出 deployable=yes" || bad "T16 输出" "$(echo "$OUT" | tail -2)"

# T17 F4：脏 token + --mode normal --require-deployable ⇒ 先结构校验、再实际归一
setup; mutate "$CFG" setargs "-v -igpu-driver=off"
OUT=$(python3 "$SET" --config "$CFG" --mode normal --require-deployable 2>&1); RC=$?
[ $RC -eq 0 ] && ok "T17 脏 token 下归一返回 0（未被提前拒绝）" || bad "T17 归一返回" "rc=$RC :: $(echo "$OUT" | tail -2)"
[ "$(state_of "$CFG")" = "normal" ] && ok "T17 归一后 state=normal" || bad "T17 归一后状态" "$(state_of "$CFG")"
[ "$(args_of "$CFG")" = "'-v'" ] && ok "T17 脏 token 已清除，仅剩 -v" || bad "T17 脏 token" "$(args_of "$CFG")"

# T18 N7：缺 NVRAM/Delete/boot-args ⇒ --require-deployable 必须 deployable=no 且非 0
setup
python3 - "$CFG" <<'PYEOF'
import plistlib, sys
p = sys.argv[1]; d = plistlib.load(open(p, "rb"))
g = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
d["NVRAM"]["Delete"][g] = [x for x in d["NVRAM"]["Delete"][g] if x != "boot-args"]
open(p, "wb").write(plistlib.dumps(d))
PYEOF
T18B=$(sha "$CFG")
OUT=$(python3 "$SET" --config "$CFG" --require-deployable 2>&1); RC=$?
[ $RC -ne 0 ] && ok "T18 缺 Delete 时不可部署(rc≠0)" || bad "T18 缺 Delete" "rc=0"
grep -q '^deployable=no' <<<"$OUT" && ok "T18 输出 deployable=no" || bad "T18 输出" "$(echo "$OUT" | tail -3)"
grep -q 'NVRAM/Delete' <<<"$OUT" && ok "T18 报错指向 NVRAM/Delete" || bad "T18 原因" "$(echo "$OUT" | tail -3)"
[ "$(sha "$CFG")" = "$T18B" ] && ok "T18 被拒时文件未改" || bad "T18 文件未改" "变了"

printf '\n===== PASS=%d  FAIL=%d =====\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]