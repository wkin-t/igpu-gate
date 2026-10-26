#!/bin/sh
# N4：每轮测试前，从**已封存的权威源码**重建 bundle，再做桩替换。
#
# 只比"源 == 副本"不够：源文件被换掉而清单没更新时，同步仍会成功（codex N4）。
# 因此这里三步都做：
#   1) 源文件必须与 igpu-build/SHA256SUMS 登记值一致（封存身份绑定）；
#   2) 必需文件集合必须齐全（缺项直接失败，不再条件复制）；
#   3) 复制后再核副本哈希（防复制损坏）。
set -u
H=$(cd "$(dirname "$0")" && pwd)
KIT=$(cd "$H/../.." && pwd)
SRC="$KIT/igpu-build"
MAN="$SRC/SHA256SUMS"

[ -d "$SRC" ] || { echo "sync-bundle: 找不到权威源码 $SRC" >&2; exit 1; }
[ -f "$MAN" ] || { echo "sync-bundle: 缺 $MAN（未重封不能跑测试）" >&2; exit 1; }

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1; fi
}

B="$H/bundle"
rm -rf "$B"
mkdir -p "$B/onsite" "$B/tools" "$B/kext/IGPUProbe"

N=0
copy() {  # copy <相对路径>
  rel=$1
  [ -f "$SRC/$rel" ] || { echo "sync-bundle: 必需文件缺失 $rel" >&2; exit 1; }
  want=$(awk -v r="$rel" '$2 == r { print $1; exit }' "$MAN")
  [ -n "$want" ] || { echo "sync-bundle: 源未登记进清单 $rel" >&2; exit 1; }
  got=$(sha_of "$SRC/$rel") || { echo "sync-bundle: 无 sha 工具" >&2; exit 1; }
  [ "$got" = "$want" ] || { echo "sync-bundle: 源与清单不符 $rel（$got != $want）" >&2; exit 1; }
  mkdir -p "$(dirname "$B/$rel")"
  cp "$SRC/$rel" "$B/$rel" || { echo "sync-bundle: 复制失败 $rel" >&2; exit 1; }
  got=$(sha_of "$B/$rel") || exit 1
  [ "$got" = "$want" ] || { echo "sync-bundle: 副本哈希不符 $rel" >&2; exit 1; }
  N=$((N + 1))
}

# 必需集合是固定的：只枚举"现存文件"会让缺脚本的包继续通过（codex N4）。
for f in 00-build.sh 01-deploy.sh 02-collect.sh 03-rollback.sh 04-state.sh 05-kcgate.sh 09-grab.sh 10-probe.sh 12-loadprobe-check.sh 13-fb-describe.sh 14-a0-gate.sh 15-pre2b-inventory.sh 16-coding-readiness.sh 20-dell-trip.sh; do
  copy "onsite/$f"
done
for f in set-bootargs.py inject-probe.py check-kext-source.py kc_gate.py kc_imports.py add-kext-entry.py; do
  copy "tools/$f"
done
copy "kext/IGPUProbe/IGPUProbe.cpp"
copy "kext/IGPUProbe/IGPUProbeState.hpp"
copy "kext/IGPUProbe/Info.plist"
copy "EXPECTED_BIN_SHA"

echo "sync-bundle: ${N} 个文件已从封存源码重建（源与清单一致、副本已复核）"