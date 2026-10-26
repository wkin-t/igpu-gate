#!/bin/bash
# run-cjk.sh —— 静态门禁：shell 脚本里的"未加花括号变量紧邻中文"
#
# 这个错误 bash -n 查不出来，但会在 macOS bash 3.2 + set -u 下直接退出。
# 本项目已经踩过三次，所以固化成门禁。
set -u
H=$(cd "$(dirname "$0")" && pwd)
KITROOT=$(cd "$H/../.." && pwd)
BUILD="${KITROOT}/igpu-build"
PY=python3
command -v python3 >/dev/null 2>&1 || PY=python

"${PY}" -I "${BUILD}/tools/check-cjk-var.py" "${BUILD}" "${KITROOT}/testkit" "${KITROOT}/macmini-run.sh" 2>&1 | tail -20
exit ${PIPESTATUS[0]}