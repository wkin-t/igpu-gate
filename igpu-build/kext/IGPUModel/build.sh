#!/bin/bash
# 构建并运行 IGPUModel 的单测（普通 host 代码，不需要 -mkernel、不需要 kext 工具链）
#
# 为什么这是"与容器无关"的部分：它只做算术与位域编解码，
# 不碰 IOKit、不碰 MMIO、不决定怎么被加载。
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
CXX="${CXX:-c++}"
OUT="$HERE/build"
mkdir -p "$OUT"

# 标准版本探测：CI 的 clang 用 c++17；本机老 g++ 只支持到 c++11 时自动降级
# （本文件只用 C++11 特性，降级不影响语义）。
STD=""
for s in c++17 c++14 c++11; do
  if printf 'int main(){}\n' | "$CXX" -std="$s" -x c++ -fsyntax-only - >/dev/null 2>&1; then
    STD="$s"; break
  fi
done
if [ -z "$STD" ]; then
  echo "FAIL 找不到可用的 C++ 标准（试过 c++17/14/11）" >&2
  exit 2
fi
echo "[1/3] 编译器：$("$CXX" --version 2>&1 | head -1)（标准 ${STD}）"

echo "[2/3] 编译模型 + 单测"
"$CXX" -std="$STD" -O2 -Wall -Wextra -Werror -I"$HERE" \
  "$HERE/IGPUModel.cpp" "$HERE/tests/model_test.cpp" -o "$OUT/model_test"

echo "[3/3] 运行单测"
"$OUT/model_test"