#!/usr/bin/env python
"""重封 kit 的两份 SHA256SUMS（先 igpu-build，再顶层）。

为什么需要它：交付物里既有"不可变交付"（脚本、源码、docs、dist），也有"测试运行时会重写"
的产物（harness 的 bundle 副本、esp 夹具、report）。把它们混在同一份清单里，
跑一次测试就可能让清单失效。这里按目录边界分开：

  顶层清单  : 覆盖 igpu-build/（不含其自身清单）、macmini-run.sh、README、testkit 的
              稳定部分（脚本/stubs/夹具模板），**排除** testkit/harness/bundle/** 与
              esp*/fake-esp/**（harness 每次重写）、report-macmini.txt、__pycache__。
  build清单 : 覆盖 igpu-build 下除自身清单、构建中间产物（kext/IGPUProbe/build/**）外的
              全部文件；**包含 dist/**（若已构建）。

跑完必须用 `shasum -a 256 -c`（macOS）或 `sha256sum -c`（Linux/Windows）复核。
"""
import fnmatch
import hashlib
import os
import pathlib
import sys

KIT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[2])
BUILD = KIT / "igpu-build"

TOP_EXCLUDE_PREFIXES = (
    ".build-tmp/",
    ".review/",
    "testkit/harness/bundle/",
    "testkit/harness/esp/",
    "testkit/harness/esp2/",
    "testkit/harness/espr/",
    "testkit/harness/fake-esp/",
    "testkit/harness/localbk/",
    "testkit/harness/tpl/.tmp/",
    # 本地构建目录：CI 上没有这些文件，进清单必然对不上
    "igpu-build/kext/IGPUProbe/build/",
    "igpu-build/kext/IGPUModel/build/",
)
TOP_EXCLUDE_NAMES = {"report-macmini.txt", "SHA256SUMS"}
TOP_EXCLUDE_GLOBS = ("testkit/harness/last-*.log",)
# 任何 kext 的本地构建目录都不该进清单：CI 上没有这些文件，会立刻对不上。
BUILD_EXCLUDE_PREFIXES = ("kext/IGPUProbe/build/", "kext/IGPUModel/build/")
BUILD_EXCLUDE_NAMES = {"SHA256SUMS"}


def iter_files(base, prefixes, names):
    for p in sorted(base.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(base).as_posix()
        if any(rel.startswith(x) for x in prefixes):
            continue
        if rel in names or "__pycache__" in rel or rel.endswith(".pyc"):
            continue
        globs = globals().get("TOP_EXCLUDE_GLOBS", ()) if base == KIT else ()
        if any(fnmatch.fnmatch(rel, g) for g in globs):
            continue
        yield rel, p


def seal(base, out, prefixes, names):
    lines = []
    for rel, p in iter_files(base, prefixes, names):
        data = p.read_bytes()
        if not data:
            raise SystemExit("空文件，拒绝入清单: %s" % rel)
        lines.append("%s  %s" % (hashlib.sha256(data).hexdigest(), rel))
    out.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return len(lines)


n_build = seal(BUILD, BUILD / "SHA256SUMS", BUILD_EXCLUDE_PREFIXES, BUILD_EXCLUDE_NAMES)
n_top = seal(KIT, KIT / "SHA256SUMS", TOP_EXCLUDE_PREFIXES, TOP_EXCLUDE_NAMES)
print("igpu-build/SHA256SUMS: %d 条" % n_build)
print("SHA256SUMS:            %d 条" % n_top)