#!/bin/bash
# run-model.sh —— 编译并运行 kext/IGPUModel 的 C++ 单测
#
# 为什么放在 harness 里：模型库是"驱动要消费"的核心算术，必须能被 CI 和本机
# 各跑一次。没有 C++ 编译器时（例如只有 Git Bash 的 Windows）按 SKIP 处理，
# 不能因为环境缺失把整体判失败。
set -u
H=$(cd "$(dirname "$0")" && pwd)
BUILD=$(cd "$H/../../igpu-build" && pwd)
MODEL="${BUILD}/kext/IGPUModel"

if [ ! -f "${MODEL}/build.sh" ]; then
  printf 'FAIL 找不到 %s/build.sh\n' "${MODEL}"
  exit 1
fi

CXX_BIN="${CXX:-}"
if [ -z "${CXX_BIN}" ]; then
  for c in c++ clang++ g++ cc; do
    if command -v "${c}" >/dev/null 2>&1; then CXX_BIN=${c}; break; fi
  done
fi
if [ -z "${CXX_BIN}" ]; then
  printf 'SKIP 没有 C++ 编译器（模型单测交给 CI 跑）\n'
  printf '===== PASS=0  FAIL=0  SKIP=1 =====\n'
  exit 0
fi

OUT=$(cd "${MODEL}" && CXX="${CXX_BIN}" sh ./build.sh 2>&1)
RC=$?
printf '%s\n' "${OUT}" | tail -6
exit "${RC}"