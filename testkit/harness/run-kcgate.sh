#!/bin/bash
# 05-kcgate.sh + tools/kc_gate.py 的离线回归：
# 判定必须落在"注入目标 KC"上，且"导出表读不出来"必须判 INVALID 而不是 N 个假缺失。
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

BUNDLE="$H/bundle"
sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1; fi
}
SRC_DIST="$H/../../igpu-build/dist"
KEXT="$SRC_DIST/IGPUProbe.kext/Contents/MacOS/IGPUProbe"
[ -f "$KEXT" ] || { echo "FAIL 找不到 dist 二进制：门禁必须有产物才能跑（先在 Mac 上 --build）"; exit 1; }
# 05-kcgate.sh 从 $BUNDLE/dist 取产物：这里把封存 dist 镜像进 bundle，
# 并用它自己的 dist/SHA256SUMS 先自校验（与部署路径同一份产物）。
rm -rf "$BUNDLE/dist"
mkdir -p "$BUNDLE/dist"
cp -R "$SRC_DIST/." "$BUNDLE/dist/" || { echo "FAIL dist 镜像失败"; exit 1; }
( cd "$BUNDLE/dist" && while read -r _h _rel; do [ -n "$_h" ] || continue; [ "$(sha_of "$_rel")" = "$_h" ] || exit 1; done < SHA256SUMS ) >/dev/null 2>&1 || { echo "FAIL dist/SHA256SUMS 自校验失败（门禁不得跳过）"; exit 1; }

T=$(mktemp -d 2>/dev/null || echo "$H/kcgate-tmp.$$")
mkdir -p "$T"
"$H/../bin/python" "$H/mk-kc-fixture.py" "$KEXT" all    "$T/kc-all"    >/dev/null || { echo "FAIL 夹具生成失败（python 不可用或脚本报错）"; exit 1; }
"$H/../bin/python" "$H/mk-kc-fixture.py" "$KEXT" subset "$T/kc-subset" >/dev/null
"$H/../bin/python" "$H/mk-kc-fixture.py" "$KEXT" none   "$T/kc-none"   >/dev/null

EXP_BAK=$(sha_of "$BUNDLE/dist/IGPUProbe.kext/Contents/MacOS/IGPUProbe")
printf '%s\n' "$EXP_BAK" > "$BUNDLE/EXPECTED_BIN_SHA"

run_gate() {  # run_gate <boot> <sys> [额外参数]
  OUT=$(IGPU_BOOT_KC="$1" IGPU_SYS_KC="$2" sh "$BUNDLE/onsite/05-kcgate.sh" $3 2>&1)
  RC=$?
}

# K1：注入目标全解析 + 另一个集合导出表不可读 ⇒ PASS（旧实现会 FAIL）
run_gate "$T/kc-all" "$T/kc-none"
[ $RC -eq 0 ] && ok "K1 注入目标 PASS、另一集合 INVALID ⇒ 整体 PASS" || bad "K1 rc" "rc=$RC :: $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
printf '%s' "$OUT" | grep -q 'RESULT: PASS' && ok "K1 输出 RESULT: PASS" || bad "K1 输出" "$(printf '%s' "$OUT" | grep RESULT | tail -1)"
printf '%s' "$OUT" | grep -q 'kc-none：INVALID' && ok "K1 不可读导出表判 INVALID" || bad "K1 INVALID" "$(printf '%s' "$OUT" | grep kc-none | tail -1)"

# K2：注入目标缺符号 ⇒ FAIL
run_gate "$T/kc-subset" "$T/kc-all"
[ $RC -ne 0 ] && printf '%s' "$OUT" | grep -q 'RESULT: FAIL' && ok "K2 注入目标缺符号 ⇒ FAIL" || bad "K2" "rc=$RC"

# K3：注入目标导出表不可读 ⇒ FAIL（INVALID 不能替代 PASS）
run_gate "$T/kc-none" "$T/kc-all"
[ $RC -ne 0 ] && printf '%s' "$OUT" | grep -q 'INVALID' && ok "K3 注入目标 INVALID ⇒ FAIL" || bad "K3" "rc=$RC"

# K4：严格模式要求两个都过
run_gate "$T/kc-all" "$T/kc-none" "--both-required"
[ $RC -ne 0 ] && ok "K4 --both-required 下另一集合 INVALID ⇒ FAIL" || bad "K4" "rc=$RC"

# K5：注入目标文件缺失 ⇒ FAIL + UNKNOWN
run_gate "$T/不存在.kc" "$T/kc-all"
[ $RC -ne 0 ] && printf '%s' "$OUT" | grep -q 'UNKNOWN' && ok "K5 注入目标缺失 ⇒ FAIL/UNKNOWN" || bad "K5" "rc=$RC"

# K6：身份白名单不匹配 ⇒ 拒绝执行（不检符号）
printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$BUNDLE/EXPECTED_BIN_SHA"
run_gate "$T/kc-all" "$T/kc-none"
[ $RC -ne 0 ] && printf '%s' "$OUT" | grep -q 'EXPECTED_BIN_SHA 不一致' && ok "K6 身份不符 ⇒ 拒绝" || bad "K6" "rc=$RC :: $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"
printf '%s\n' "$EXP_BAK" > "$BUNDLE/EXPECTED_BIN_SHA"

# K7：白名单多一行空行 ⇒ 拒绝（整文件单行约束）
printf '%s\n\n' "$EXP_BAK" > "$BUNDLE/EXPECTED_BIN_SHA"
run_gate "$T/kc-all" "$T/kc-none"
[ $RC -ne 0 ] && printf '%s' "$OUT" | grep -q '白名单格式非法' && ok "K7 白名单带空行 ⇒ 拒绝" || bad "K7" "rc=$RC"
printf '%s\n' "$EXP_BAK" > "$BUNDLE/EXPECTED_BIN_SHA"

rm -rf "$T"
echo ""
echo "===== PASS=$PASS  FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]