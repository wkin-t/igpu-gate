#!/bin/bash
# 在 macOS（A 站）构建 IGPUProbe.kext。
#
# 用法：
#   ./build.sh                      # 包根布局：regs.txt 与 tools/ 在 ../../ 下
#   REGS=/path/to/regs.txt ./build.sh
#
# 2026-10-19 修正：脚本改为用**自身位置**推导包根，不再依赖当前工作目录。
# 原版按 cwd 写死 `../tools/gen-readset-header.py`，从 kext/IGPUProbe 跑会指向
# 不存在的 `kext/tools/`，必然在 [1/4] 失败（macOS 侧 agent 第 0 步复核时发现）。
#
# 状态：链接参数（-kext / 符号导出）仍属 best-effort，首次跑可能要按报错调整；
# 调整后请把结论回写到本文件与 kext/IGPUProbe/README.md。
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GEN="$ROOT/tools/gen-readset-header.py"
REGS="${REGS:-$ROOT/regs.txt}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="${ARCH:-x86_64}"
OUT="$HERE/build"
KEXT="$HERE/IGPUProbe.kext"

for f in "$GEN" "$REGS"; do
  if [ ! -e "$f" ]; then
    echo "缺少依赖：$f" >&2
    echo "（可用环境变量指定读集：REGS=/path/to/regs.txt ./build.sh）" >&2
    exit 2
  fi
done

# 不需要外部库：_kmod_info 由源码里的 KMOD_EXPLICIT_DECL 产生（见 IGPUProbe.cpp 末尾）。
# 曾误以为要链 MacKernelSDK 的 libkmod.a —— 实测那是**未定义引用**（c_start.o 引 _kmod_info），
# 光加 `-l kmod` 不会产生定义。

echo "[1/4] 生成读集头文件（可复算；改了 regs.txt 必须重跑）"
echo "      生成器: $GEN"
echo "      读集  : $REGS"
python3 "$GEN" --regs "$REGS" --out "$HERE/IGPUProbeState.hpp" || exit 3

echo "[2/4] 编译（-fapple-kext -mkernel，arch=${ARCH}）"
mkdir -p "$OUT" "$KEXT/Contents/MacOS"
cd "$HERE"
# -DKERNEL=1：内核头用 `#if !KERNEL` 区分内核 / DriverKit 两个分支。不定义时会把
#   PCIDriverKit 的用户态类体（OSClassLoadInformation、New/Dispatch override）拉进来，
#   编译必然报 "unknown type name 'OSClassLoadInformation'"。
# -I"$HERE/compat-include"：macOS 26/27 SDK 已无独立 IOMemoryMap.h，需要一层零内容转发头。
# 注：`${ARCH}` 的花括号是必需的——bash 3.2 + C.UTF-8 下 `$ARCH）` 会把全角括号的字节并进变量名，
#   `set -u` 判 unbound（这个坑在 macOS 侧实测踩到过）。
xcrun clang++ -std=c++17 -arch "$ARCH" -mkernel -fapple-kext -fno-exceptions -fno-rtti \
  -nostdinc++ -O2 -Wall -Wextra -DKERNEL=1 \
  -isysroot "$SDK" \
  -I"$HERE/compat-include" \
  -I"$SDK/System/Library/Frameworks/Kernel.framework/Headers" \
  -I"$SDK/System/Library/Frameworks/IOKit.framework/Headers" \
  -c IGPUProbe.cpp -o "$OUT/IGPUProbe.o" || exit 4

echo "[3/4] 链接（-kext）"
# -static：Xcode kext 目标的标准链接方式（见 Lilu 工程 OTHER_LDFLAGS = "-static"）。
# _kmod_info 由源码里的 KMOD_EXPLICIT_DECL 产生，不需要 -l kmod。
xcrun clang++ -arch "$ARCH" -mkernel -nostdlib -static -Wl,-kext \
  \
  -isysroot "$SDK" \
  -o "$KEXT/Contents/MacOS/IGPUProbe" "$OUT/IGPUProbe.o" || {
    echo "链接失败 —— 读 README 的「已知未知」，允许按报错调参数，" >&2
    echo "但禁止 -undefined dynamic_lookup / -Wl,-undefined,suppress / 删符号。" >&2
    exit 5
  }

echo "[4/4] 组装 bundle"
cp "$HERE/Info.plist" "$KEXT/Contents/Info.plist"
chmod 755 "$KEXT/Contents/MacOS/IGPUProbe"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$KEXT/Contents/Info.plist"

# 后置硬门禁：_kmod_info 必须是**已定义的外部数据符号**。
# 不能用 `strings | grep`：未定义符号（U _kmod_info）同样会出现在字符串表里，
# 独立同名字符串也会命中 —— 那是假绿（codex 评审 2026-10-20 指出）。
# nm -gU = 只看外部符号且排除 undefined；再要求类型是数据/代码段字母。
if ! nm -arch "$ARCH" -gU "$KEXT/Contents/MacOS/IGPUProbe" 2>/dev/null \
     | awk 'NF>=3 && $3=="_kmod_info" && $2 ~ /^[A-Za-z]$/ { ok=1 } END { exit ok ? 0 : 1 }'; then
  echo "[FAIL] 产物里没有『已定义』的 _kmod_info —— OpenCore 会以 Invalid Parameter 拒绝注入" >&2
  echo "       诊断：nm -arch $ARCH -gU <bin> | grep -i kmod" >&2
  nm -arch "$ARCH" -gU "$KEXT/Contents/MacOS/IGPUProbe" 2>&1 | grep -i kmod >&2 || true
  echo "       检查 IGPUProbe.cpp 末尾的 KMOD_EXPLICIT_DECL 是否还在、是否被链接器丢弃" >&2
  exit 7
fi
echo "  _kmod_info 已定义 ✓"

echo
echo "产物：$KEXT"
echo "下一步（缺一不可）："
echo "  file $KEXT/Contents/MacOS/IGPUProbe            # 期望 Mach-O 64-bit kext bundle x86_64"
echo "  kextutil -n -print-diagnostics $KEXT           # 期望无未解析符号"
echo "  shasum -a 256 $KEXT/Contents/MacOS/IGPUProbe"