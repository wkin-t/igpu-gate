#!/bin/bash
# 构建 IGPULoadProbe.kext（Phase 2b-A0：只验证加载路径）
#
# 用法：  ./build.sh            # 产物：kext/IGPULoadProbe/IGPULoadProbe.kext
#         ARCH=x86_64 ./build.sh
#
# 与 IGPUProbe/build.sh 的差异：
#   * 不需要 regs.txt / gen-readset-header.py（本 kext 不读寄存器）
#   * 多一处硬门禁：必须能从二进制里看到对 IOGraphicsFamily 的未定义引用
#     （否则说明链接被优化掉了，A0 就失去意义）
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="${ARCH:-x86_64}"
OUT="$HERE/build"
KEXT="$HERE/IGPULoadProbe.kext"

echo "[1/4] 编译（arch=${ARCH}）"
mkdir -p "$OUT" "$KEXT/Contents/MacOS"
cd "$HERE"
xcrun clang++ -std=c++17 -arch "${ARCH}" -mkernel -fapple-kext -fno-exceptions -fno-rtti \
  -nostdinc++ -O2 -Wall -Wextra -DKERNEL=1 \
  -isysroot "$SDK" \
  -I"$HERE/compat-include" \
  -I"$SDK/System/Library/Frameworks/Kernel.framework/Headers" \
  -I"$SDK/System/Library/Frameworks/IOKit.framework/Headers" \
  -c IGPULoadProbe.cpp -o "$OUT/IGPULoadProbe.o" || exit 4

echo "[2/4] 链接（-kext）"
xcrun clang++ -arch "${ARCH}" -mkernel -nostdlib -static -Wl,-kext \
  -isysroot "$SDK" \
  -o "$KEXT/Contents/MacOS/IGPULoadProbe" "$OUT/IGPULoadProbe.o" || {
    echo "链接失败。禁止 -undefined dynamic_lookup / 删符号；先看是哪些 IOFramebuffer 符号缺。" >&2
    exit 5
  }

echo "[3/4] 组装 bundle"
cp "$HERE/Info.plist" "$KEXT/Contents/Info.plist"
chmod 755 "$KEXT/Contents/MacOS/IGPULoadProbe"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$KEXT/Contents/Info.plist"

echo "[4/4] 门禁"
# 4a：_kmod_info 必须已定义（否则 OC 注入时报 Invalid Parameter）
if ! nm -arch "${ARCH}" -gU "$KEXT/Contents/MacOS/IGPULoadProbe" 2>/dev/null \
     | awk 'NF>=3 && $3=="_kmod_info" && $2 ~ /^[A-Za-z]$/ { ok=1 } END { exit ok ? 0 : 1 }'; then
  echo "[FAIL] 产物里没有已定义的 _kmod_info" >&2
  exit 7
fi
echo "  _kmod_info 已定义 ✓"

# 4b：必须存在来自 IOFramebuffer/IOGraphicsFamily 的未定义符号（A0 的被测对象）
UNDEF="$(nm -arch "${ARCH}" -u "$KEXT/Contents/MacOS/IGPULoadProbe" 2>/dev/null | grep -c 'IOFramebuffer' || true)"
if [ "${UNDEF:-0}" -lt 1 ]; then
  echo "[FAIL] 二进制里没有对 IOFramebuffer 的未定义引用 —— 链接把它优化掉了，A0 失去意义" >&2
  nm -arch "${ARCH}" -u "$KEXT/Contents/MacOS/IGPULoadProbe" 2>&1 | head -20 >&2
  exit 8
fi
echo "  IOFramebuffer 未定义引用：${UNDEF} 个 ✓（A0 的被测依赖存在）"

echo
echo "产物：$KEXT"
echo "下一步："
echo "  file $KEXT/Contents/MacOS/IGPULoadProbe"
echo "  shasum -a 256 $KEXT/Contents/MacOS/IGPULoadProbe"