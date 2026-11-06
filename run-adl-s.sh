#!/bin/sh
# run-adl-s.sh —— ADL-S 现场包启动器：自己找 kit，参数原样转给 adl-s-field.sh
#
#   sh /路径/run-adl-s.sh               # 按阶段推进一步（自动提权）
#   sh /路径/run-adl-s.sh --status      # 看进度
#   sh /路径/run-adl-s.sh --rollback    # 一键回到部署前
set -u
SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || { printf '%s\n' "FAIL 无法确定本文件所在目录"; exit 2; }
TARGET=""
for base in "${SELF_DIR}/igpu-build" "${SELF_DIR}/01-kit/igpu-build" "${SELF_DIR}/../igpu-build" "${SELF_DIR}/../01-kit/igpu-build"; do
  if [ -f "${base}/adl-s-fork/field/adl-s-field.sh" ]; then TARGET="${base}/adl-s-fork/field/adl-s-field.sh"; break; fi
done
if [ -z "${TARGET}" ]; then
  printf '%s\n' "✗ 没找到 igpu-build/adl-s-fork/field/adl-s-field.sh"
  printf '%s\n' "  请把本文件放在与 igpu-build/ 同级的位置，或直接运行："
  printf '%s\n' "  sudo sh /完整路径/igpu-build/adl-s-fork/field/adl-s-field.sh"
  exit 2
fi
printf '找到：%s\n' "${TARGET}"
exec /bin/sh "${TARGET}" "$@"
