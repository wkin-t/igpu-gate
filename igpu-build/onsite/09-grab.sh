#!/bin/sh
# 09-grab.sh —— 把现场采集与构建报告搬到 U 盘/指定目录（失败必须返回非零）
#
# 用法： sh onsite/09-grab.sh [--dest DIR]
#   默认源 = 脚本所在 kit 根（onsite/..），不是 ~/igpu-build
#   默认目标 = /Volumes/CLONEZILLA/igpu（存在时），否则 <kit>/evidence-export
# 导出内容：所有 results-collect-* 整目录（先验其 MANIFEST.sha256 自洽）、results-*/report.md 与
# summary.txt、config.plist 快照、dist/{SHA256SUMS,BUILD-REPORT*}、EXPECTED_BIN_SHA、kcgate-*.txt；
# 复制后逐文件复核 sha256、比对源/目标路径集合，生成并再复核 GRAB-MANIFEST。
# 没有 results-collect-* ⇒ 返回非零并说明缺什么。
set -u

BUNDLE=$(cd "$(dirname "$0")/.." && pwd)
DEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) [ $# -ge 2 ] || { printf '%s\n' '--dest 需要一个目录' >&2; exit 2; }; DEST=$2; shift 2 ;;
    --dest=*) DEST=${1#--dest=}; shift ;;
    -h|--help) printf '用法：sh onsite/09-grab.sh [--dest DIR]\n'; exit 0 ;;
    *) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ -z "$DEST" ]; then
  if [ -d /Volumes/CLONEZILLA ]; then DEST=/Volumes/CLONEZILLA/igpu; else DEST="$BUNDLE/evidence-export"; fi
fi
mkdir -p "$DEST" || { printf '无法创建 %s\n' "$DEST" >&2; exit 1; }
[ -w "$DEST" ] || { printf '%s 不可写\n' "$DEST" >&2; exit 1; }

TS=$(date +%Y%m%d-%H%M%S)
OUT="$DEST/grab-$TS"
mkdir -p "$OUT" || { printf '无法创建 %s\n' "$OUT" >&2; exit 1; }
MAN="$OUT/GRAB-MANIFEST"
: > "$MAN"

say() { printf '%s\n' "$1"; }
FAIL=0
add_manifest() {
  h=$1; rel=$2
  printf '%s  %s\n' "$h" "$rel" >> "$MAN"
}
sha() {
  h=$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}')
  [ -n "$h" ] || h=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
  printf '%s' "$h"
}

copy_file() {  # copy_file 源 目标相对名
  src=$1; rel=$2
  dst="$OUT/$rel"
  mkdir -p "$(dirname "$dst")" 2>/dev/null || { say "✗ 无法创建目录 $rel"; FAIL=1; return 1; }
  cp "$src" "$dst" 2>/dev/null || { say "✗ 复制失败 $src"; FAIL=1; return 1; }
  hs=$(sha "$src"); hd=$(sha "$dst")
  if [ -z "$hs" ] || [ "$hs" != "$hd" ]; then say "✗ 哈希不符 $rel"; FAIL=1; return 1; fi
  add_manifest "$hd" "$rel"
  say "   ✓ $rel"
}

copy_tree() {  # copy_tree 源目录 目标相对名
  src=$1; rel=$2
  [ -d "$src" ] || return 1
  mkdir -p "$(dirname "$OUT/$rel")" 2>/dev/null || { say "✗ 无法创建目录 $rel"; FAIL=1; return 1; }
  cp -R "$src" "$OUT/$rel" 2>/dev/null || { say "✗ 目录复制失败 $src"; FAIL=1; return 1; }
  SL="$OUT/.src-list.$$"; DL="$OUT/.dst-list.$$"; FE="$OUT/.find-err.$$"
  find "$src" -mindepth 1 2>"$FE" | sed "s#^${src}/##" | sort > "$SL"
  FRC=$?
  if [ "$FRC" -ne 0 ] || [ -s "$FE" ]; then
    say "✗ 遍历源目录出错：$rel"
    sed -n '1,10p' "$FE"
    FAIL=1
    rm -f "$SL" "$DL" "$FE"
    return 1
  fi
  ( cd "$OUT/$rel" && find . -mindepth 1 2>"$FE" | sed 's#^\./##' | sort ) > "$DL"
  if [ -s "$FE" ]; then
    say "✗ 遍历目标目录出错：$rel"
    sed -n '1,10p' "$FE"
    FAIL=1
    rm -f "$SL" "$DL" "$FE"
    return 1
  fi
  if ! diff -u "$SL" "$DL" > "$OUT/.tree-diff.$$" 2>&1; then
    say "✗ 源/目标路径集合不一致：$rel"
    sed -n '1,20p' "$OUT/.tree-diff.$$"
    FAIL=1
    rm -f "$SL" "$DL" "$FE" "$OUT/.tree-diff.$$"
    return 1
  fi
  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    hs=$(sha "$src/$sub"); hd=$(sha "$OUT/$rel/$sub")
    if [ -z "$hs" ] || [ "$hs" != "$hd" ]; then printf 'MISMATCH %s\n' "$rel/$sub"; fi
  done < "$SL" > "$OUT/.tree-check.$$" 2>/dev/null
  if [ -s "$OUT/.tree-check.$$" ]; then
    say "✗ 目录内文件哈希不符：$rel"
    sed -n '1,10p' "$OUT/.tree-check.$$"
    FAIL=1
    rm -f "$SL" "$DL" "$FE" "$OUT/.tree-diff.$$" "$OUT/.tree-check.$$"
    return 1
  fi
  rm -f "$SL" "$DL" "$FE" "$OUT/.tree-diff.$$" "$OUT/.tree-check.$$"
  ( cd "$OUT" && find "$rel" -type f 2>/dev/null | while IFS= read -r f; do printf '%s  %s\n' "$(sha "$f")" "$f"; done ) >> "$MAN"
  say "   ✓ $rel/（整目录，已逐文件复核）"
}

verify_collect_manifest() {
  d=$1
  m="$d/MANIFEST.sha256"
  if [ ! -f "$m" ]; then
    say "   ✗ 采集目录缺 MANIFEST.sha256：$d"
    return 1
  fi
  if ( cd "$d" && shasum -a 256 -c MANIFEST.sha256 >/dev/null 2>"$OUT/.mf.$$" ); then
    rm -f "$OUT/.mf.$$"; return 0
  fi
  if ( cd "$d" && sha256sum -c MANIFEST.sha256 >/dev/null 2>>"$OUT/.mf.$$" ); then
    rm -f "$OUT/.mf.$$"; return 0
  fi
  say "   ✗ MANIFEST 自校验失败：$d"
  sed -n '1,5p' "$OUT/.mf.$$"
  rm -f "$OUT/.mf.$$"
  return 1
}

say "== 1/5 环境 =="
{
  echo "## date"; date
  echo "## sw_vers"; sw_vers
  echo "## uname"; uname -a
  echo "## src"; echo "$BUNDLE"
  echo "## dest"; echo "$OUT"
} > "$OUT/env.txt" 2>&1 || { say "写 env.txt 失败"; exit 1; }
say "   kit 根=$BUNDLE"
say "   输出  =$OUT"

say ""
say "== 2/5 results-collect-* （现场采集）=="
N=0
for d in "$BUNDLE"/results-collect-*; do
  [ -d "$d" ] || continue
  N=$((N + 1))
  verify_collect_manifest "$d" || FAIL=1
  copy_tree "$d" "results/$(basename "$d")"
done
if [ "$N" -eq 0 ]; then
  say "✗ 没有任何 results-collect-* 可导出 —— 先在重启后跑 sudo sh onsite/02-collect.sh"
  FAIL=1
else
  say "   共 $N 个采集目录"
fi

say ""
say "== 3/5 构建报告 / 配置快照 =="
# A1 的扫描面基线（results-fbdescribe-*）整目录导出：里面有 ioreg-IOFramebuffer.plist
# 与 displays.txt，只搬 summary.txt 会丢掉原始证据。
for d in "$BUNDLE"/results-fbdescribe-*; do
  [ -d "$d" ] || continue
  copy_tree "$d" "fbdescribe/$(basename "$d")"
done
for d in "$BUNDLE"/results-*; do
  [ -d "$d" ] || continue
  case "$(basename "$d")" in results-collect-*) continue ;; results-fbdescribe-*) continue ;; esac
  for f in report.md summary.txt; do
    [ -f "$d/$f" ] && copy_file "$d/$f" "build/$(basename "$d")/$f"
  done
done
for f in "$BUNDLE"/config*.plist "$BUNDLE"/onsite/config*.plist /Volumes/OCEFI/EFI/OC/config.plist; do
  [ -f "$f" ] || continue
  copy_file "$f" "config/$(basename "$f")"
done
if ls "$BUNDLE"/config*.plist >/dev/null 2>&1 || [ -f /Volumes/OCEFI/EFI/OC/config.plist ]; then
  :
else
  say "   ⚠ 没有找到 config.plist 快照（不影响采集导出，但建议在 kit 根留一份）"
fi

say ""
say "== 4/5 交付身份与门禁证据 =="
for f in "$BUNDLE/EXPECTED_BIN_SHA" "$BUNDLE/dist/SHA256SUMS"; do
  [ -f "$f" ] || { say "   ⚠ 缺少 ${f}（身份证据不完整）"; continue; }
  copy_file "$f" "dist/$(basename "$f")"
done
for f in "$BUNDLE"/dist/BUILD-REPORT*; do
  [ -f "$f" ] || continue
  copy_file "$f" "dist/$(basename "$f")"
done
for f in "$BUNDLE"/kcgate-*.txt "$BUNDLE"/results-kcgate-*.txt; do
  [ -f "$f" ] || continue
  copy_file "$f" "kcgate/$(basename "$f")"
done

say ""
say "== 5/5 清单复核 =="
: > "$OUT/config-sha256.txt"
for f in "$OUT"/config/*.plist; do
  [ -f "$f" ] || continue
  printf '%s  %s\n' "$(sha "$f")" "config/$(basename "$f")" >> "$OUT/config-sha256.txt"
done
add_manifest "$(sha "$OUT/config-sha256.txt")" "config-sha256.txt"
add_manifest "$(sha "$OUT/env.txt")" "env.txt"

VERIFY_OK=yes
if [ -s "$MAN" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    h=${line%%  *}
    rel=${line#*  }
    if [ ! -f "$OUT/$rel" ]; then say "   ✗ 清单里的文件不存在：$rel"; VERIFY_OK=no; continue; fi
    hd=$(sha "$OUT/$rel")
    [ "$h" = "$hd" ] || { say "   ✗ 清单哈希不符：$rel"; VERIFY_OK=no; }
  done < "$MAN"
  if [ "$VERIFY_OK" = "yes" ]; then
    say "   GRAB-MANIFEST 复核通过（$(grep -c . "$MAN") 条）"
  else
    say "   ✗ GRAB-MANIFEST 复核失败"
    FAIL=1
  fi
else
  say "   ✗ 清单为空"
  FAIL=1
fi

say ""
say "输出目录：$OUT"
if [ "$FAIL" -ne 0 ]; then
  say ""
  say "⚠ 有材料没取到或校验失败（见上）。"
  exit 1
fi
say "全部材料已取到并通过哈希复核。"
exit 0
