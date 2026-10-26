#!/usr/bin/env python
"""生成 KC 夹具：把 kext 的未定义符号按指定方式导出成一个 Mach-O 内核集合。

为什么需要：真机上 BootKernelExtensions.kc 是 fileset、SystemKernelExtensions.kc
的导出表读不出来；两种形态的判定差异（PASS / FAIL / INVALID）必须能离线复现，
否则又会把"读不到导出表"当成"N 个符号缺失"。

用法：mk-kc-fixture.py <kext> <all|subset|none> <输出路径>
  all    : 顶层 LC_SYMTAB 导出全部导入符号  → 期望 GATE-PASS
  subset : 只导出前 5 个                     → 期望 GATE-FAIL
  none   : 不写 LC_SYMTAB（导出表不可读）    → 期望 GATE-INVALID
"""
import pathlib
import struct
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "igpu-build" / "tools"))
import kc_imports as K  # noqa: E402

MH_MAGIC_64 = 0xfeedfacf
CPU_TYPE_X86_64 = 0x01000007
MH_KEXT_BUNDLE = 11
LC_SYMTAB = 0x2
N_SECT_EXT = 0x0f


def build(kext, mode, out):
    imports = sorted(K.kext_imports(kext))
    names = imports if mode == "all" else (imports[:5] if mode == "subset" else [])
    if mode not in ("all", "subset", "none"):
        raise SystemExit("mode 必须是 all|subset|none")
    if mode != "none" and not names:
        raise SystemExit("kext 没有未定义符号，夹具无意义")
    strtab = b"\0"
    offs = {}
    for n in names:
        offs[n] = len(strtab)
        strtab += n.encode() + b"\0"
    if names:
        nlist = b"".join(struct.pack("<IBBhQ", offs[n], N_SECT_EXT, 1, 0, 0) for n in names)
        hdr_size, lc_size = 32, 24
        symoff = hdr_size + lc_size
        stroff = symoff + len(nlist)
        hdr = struct.pack("<IiiIIIII", MH_MAGIC_64, CPU_TYPE_X86_64, 3, MH_KEXT_BUNDLE, 1, lc_size, 0, 0)
        lc = struct.pack("<IIIIII", LC_SYMTAB, lc_size, symoff, len(names), stroff, len(strtab))
        pathlib.Path(out).write_bytes(hdr + lc + nlist + strtab)
    else:
        hdr = struct.pack("<IiiIIIII", MH_MAGIC_64, CPU_TYPE_X86_64, 3, MH_KEXT_BUNDLE, 0, 0, 0, 0)
        pathlib.Path(out).write_bytes(hdr)
    print("%s %d" % (mode, len(names)))


if __name__ == "__main__":
    build(sys.argv[1], sys.argv[2], sys.argv[3])