#!/bin/sh
# run-trip.sh —— 现场启动器：自己找 kit，自己提权，你只需要跑这一个文件
#
#   sh /路径/run-trip.sh              # 正常推进
#   sh /路径/run-trip.sh --status     # 看进度（不需要 root）
#   sh /路径/run-trip.sh --reset      # 从头再来
#
# 为什么需要它：直接 `sh onsite/20-dell-trip.sh` 依赖"当前在哪个目录"和
# "路径有多深"，现场很容易撞到 "No such file or directory"。
# 这里从自身位置逐级向上/向下找 onsite/20-dell-trip.sh，找到就把参数原样转过去。
set -u

SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || {
  printf '%s\n' "FAIL 无法确定本文件所在目录"
  exit 2
}

say() { printf '%s\n' "$1"; }
TARGET=""

# 1) 常见布局：本文件旁边就是 igpu-build / onsite
for base in "${SELF_DIR}" "${SELF_DIR}/igpu-build" "${SELF_DIR}/01-kit" "${SELF_DIR}/01-kit/igpu-build" \
            "${SELF_DIR}/../igpu-build" "${SELF_DIR}/../01-kit/igpu-build" \
            "${SELF_DIR}/../../igpu-build" "${SELF_DIR}/../../01-kit/igpu-build"; do
  if [ -f "${base}/onsite/20-dell-trip.sh" ]; then TARGET="${base}/onsite/20-dell-trip.sh"; break; fi
done

# 2) 兜底：在自身目录上下 4 层里找（不依赖 find 的 -maxdepth 语义差异）
if [ -z "${TARGET}" ]; then
  for d in "${SELF_DIR}" "${SELF_DIR}/.." "${SELF_DIR}/../.." "${SELF_DIR}/../../.."; do
    [ -d "${d}" ] || continue
    for sub in "" "/01-kit" "/01-kit/igpu-build" "/igpu-build"; do
      if [ -f "${d}${sub}/onsite/20-dell-trip.sh" ]; then TARGET="${d}${sub}/onsite/20-dell-trip.sh"; break; fi
    done
    [ -n "${TARGET}" ] && break
  done
fi

if [ -z "${TARGET}" ]; then
  say "✗ 没找到 onsite/20-dell-trip.sh"
  say "  在本文件所在目录里看到了："
  ls -1 "${SELF_DIR}" 2>/dev/null | sed -n '1,15p' | sed 's/^/    /'
  say ""
  say "  请把本文件放到下面任意一种位置后重试："
  say "    · 与 igpu-build/ 同级                （例如 ~/run-trip.sh 与 ~/igpu-build/）"
  say "    · 交付包根目录                        （里面应有 01-kit/igpu-build/onsite/）"
  say "  或者直接给出完整路径："
  say "    sudo sh /完整路径/igpu-build/onsite/20-dell-trip.sh"
  exit 2
fi

say "找到：${TARGET}"
# --status / --reset 不需要 root；其余交给脚本自己提权
case "${1:-}" in
  --status|--reset) exec /bin/sh "${TARGET}" "$@" ;;
esac

if command -v sudo >/dev/null 2>&1; then
  exec sudo /bin/sh "${TARGET}" "$@"
fi
if [ "$(id -u)" -eq 0 ]; then
  exec /bin/sh "${TARGET}" "$@"
fi
say "✗ 找不到 sudo，而且当前不是 root。"
say "  用 root 再跑一次： su - 然后 sh ${TARGET}"
exit 2