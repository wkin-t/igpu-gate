#!/bin/bash
# 10-probe.sh（N8）的离线测试：目标优先、硬失败、现场分类。
# 注：这里只能验证脚本逻辑；真实 /Volumes、diskutil、df 行为仍需 Dell 实机。
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

ROOT=$(mktemp -d 2>/dev/null || echo "$H/probe-tmp.$$")
mkdir -p "$ROOT"
mk_esp() {  # mk_esp <名字> <config 文件> [额外动作]
  d="$ROOT/$1"
  mkdir -p "$d/EFI/OC"
  cp "$H/$2" "$d/EFI/OC/config.plist" || return 1
  : > "$d/EFI/OC/OpenCore.efi"
  printf '%s' "$d"
}
run_probe() { OUT=$(IGPU_ESP_ROOT="$1" sh "$H/bundle/onsite/10-probe.sh" $2 2>&1); RC=$?; }

# P1 injected
E1=$(mk_esp injected real-config.plist)
run_probe "$E1"
[ $RC -eq 0 ] && ok "P1 injected 返回 0" || bad "P1 rc" "rc=$RC :: $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
printf '%s' "$OUT" | grep -q 'classification=injected' && ok "P1 分类 injected" || bad "P1 分类" "$(printf '%s' "$OUT" | grep classification | tail -1)"
printf '%s' "$OUT" | grep -q 'probe_count=1' && ok "P1 probe_count=1" || bad "P1 probe_count" "$(printf '%s' "$OUT" | grep probe_count | tail -1)"

# P2 baseline
# 基线哈希由**夹具内容**决定（脱敏后与生产基线不同），显式传给 10-probe.sh。
# 这一步同时是"换 SMBIOS 序列号后基线哈希会变"的机制验证。
sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
E2=$(mk_esp baseline real-base.plist)
export IGPU_BASELINE_SHA=$(sha_of "$H/real-base.plist")
run_probe "$E2"
[ $RC -eq 0 ] && ok "P2 baseline 返回 0（基线是合法现场状态）" || bad "P2 rc" "rc=$RC"
printf '%s' "$OUT" | grep -q 'classification=baseline' && ok "P2 分类 baseline" || bad "P2 分类" "$(printf '%s' "$OUT" | grep classification | tail -1)"
unset IGPU_BASELINE_SHA
printf '%s' "$OUT" | grep -q 'reinject' && ok "P2 给出 --reinject 建议" || bad "P2 建议" "无"

# P3 没有 ESP
mkdir -p "$ROOT/empty"
run_probe "$ROOT/empty"
[ $RC -ne 0 ] && ok "P3 无 ESP → 非 0" || bad "P3 无 ESP" "rc=0"
printf '%s' "$OUT" | grep -q '没有找到任何 OC ESP' && ok "P3 明确报缺 ESP" || bad "P3 文案" "$(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"

# P4 显式 --config 不存在
run_probe "$E1" "--config $ROOT/nope.plist"
[ $RC -ne 0 ] && ok "P4 显式 config 不存在 → 非 0" || bad "P4 显式 config" "rc=0"
printf '%s' "$OUT" | grep -q '指定的 config 不存在' && ok "P4 明确报缺失" || bad "P4 文案" "$(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"

# P5 df 不可判定
run_probe "$E1" ""
FAKE_DF=unknown sh -c 'exit 0'   # 仅说明：下面用 env 传入
OUT=$(FAKE_DF=unknown IGPU_ESP_ROOT="$E1" sh "$H/bundle/onsite/10-probe.sh" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "P5 df 无输出 → 非 0" || bad "P5 df" "rc=0"
printf '%s' "$OUT" | grep -q '空间不可判定' && ok "P5 明确报不可判定" || bad "P5 文案" "$(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"

# P6 两个探针条目 → dirty
E6="$ROOT/dirty"; mkdir -p "$E6/EFI/OC"
python - "$H/real-config.plist" "$E6/EFI/OC/config.plist" <<'PYEOF'
import plistlib, sys
src, dst = sys.argv[1], sys.argv[2]
obj = plistlib.load(open(src, 'rb'))
adds = obj['Kernel']['Add']
probe = [a for a in adds if 'IGPUProbe.kext' in str(a.get('BundlePath', ''))][0]
adds.append(dict(probe))
open(dst, 'wb').write(plistlib.dumps(obj))
PYEOF
: > "$E6/EFI/OC/OpenCore.efi"
run_probe "$E6"
[ $RC -ne 0 ] && ok "P6 两条探针 → 非 0" || bad "P6 dirty" "rc=0"
printf '%s' "$OUT" | grep -q 'classification=dirty' && ok "P6 分类 dirty" || bad "P6 分类" "$(printf '%s' "$OUT" | grep classification | tail -1)"

# P7 config 解析失败
E7="$ROOT/broken"; mkdir -p "$E7/EFI/OC"
printf 'not a plist at all\n' > "$E7/EFI/OC/config.plist"
: > "$E7/EFI/OC/OpenCore.efi"
run_probe "$E7"
[ $RC -ne 0 ] && ok "P7 解析失败 → 非 0" || bad "P7 解析" "rc=0"
printf '%s' "$OUT" | grep -q 'config.plist 解析失败' && ok "P7 明确报解析失败" || bad "P7 文案" "$(printf '%s' "$OUT" | tail -4 | tr '\n' ' ')"

rm -rf "$ROOT"
printf '\n===== PASS=%d  FAIL=%d =====\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]