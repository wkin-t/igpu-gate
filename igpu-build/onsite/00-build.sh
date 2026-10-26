#!/bin/sh
# 00-build.sh —— 一键构建（内部就是 run-build.sh；只为统一入口、少敲字）
# 用法： sh onsite/00-build.sh
set -u
BUNDLE=$(cd "$(dirname "$0")/.." && pwd)
cd "$BUNDLE" || { echo "进不去 $BUNDLE" >&2; exit 1; }
[ -f run-build.sh ] || { echo "缺 run-build.sh，包不完整" >&2; exit 1; }
exec /bin/bash run-build.sh