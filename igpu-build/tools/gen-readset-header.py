"""把 regs.txt（<name> <hex offset>）转成 kext 用的 C++ 表头。

用法：
    python -I tools/gen-readset-header.py \
        --regs G:/igpu/regs.txt \
        --out  kext/IGPUProbe/IGPUProbeState.hpp

为什么要生成而不是手抄：
  * 读集是**验收基线**（assets/07 关系表按项判定），手抄会出现"代码里 193 项、
    关系表里 195 项"这种对不上的情况；
  * 生成器会把**重复偏移**显式合并并打印，避免同一个 offset 读两遍还各记一名；
  * 每次改读集只需重跑生成器，diff 就是证据。

输出内容：`kIGPUProbeRegs[]`（name, offset, value）+ 计数常量。
`value` 是运行期结果槽：IGPUProbe.cpp 读寄存器后把值写回表里，再据此出报告；
因此表本身不能是 `const`（写成 const 会在编译期报 no member named 'value'）。
顺序保持 regs.txt 的原序（与票 06 的 tsv 同源同序）。
"""

import argparse
import re
import sys
from pathlib import Path

LINE_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s+(0x[0-9A-Fa-f]{1,8})\s*$")


def parse(regs_path):
    entries = []
    seen = {}
    dupes = []
    for lineno, raw in enumerate(regs_path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = LINE_RE.match(line)
        if not m:
            raise SystemExit(f"第 {lineno} 行格式不符: {raw!r}")
        name, off_s = m.group(1), m.group(2)
        off = int(off_s, 16)
        if not (0 <= off < 0x1000000):
            raise SystemExit(f"第 {lineno} 行偏移越界: {off_s}")
        if off in seen:
            dupes.append((off, seen[off], name))
            continue
        seen[off] = name
        entries.append((name, off))
    return entries, dupes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--regs", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    src = Path(a.regs)
    if not src.is_file():
        print(f"用法错误：读集不存在 {src}")
        return 2
    entries, dupes = parse(src)

    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "// 自动生成，请勿手改。",
        f"// 源: {src.name}（{len(entries)} 个唯一偏移；重复 {len(dupes)} 处已合并）",
        "// 生成器: tools/gen-readset-header.py",
        "#pragma once",
        "#include <IOKit/IOTypes.h>",
        "",
        "struct IGPUProbeReg {",
        "    const char *name;",
        "    UInt32      offset;",
        "    UInt32      value;",
        "};",
        "",
        f"static const UInt32 kIGPUProbeRegCount = {len(entries)};",
        "",
        "static IGPUProbeReg kIGPUProbeRegs[kIGPUProbeRegCount] = {",
    ]
    for name, off in entries:
        lines.append(f'    {{ "{name}", 0x{off:05X}, 0 }},')
    lines += ["};", ""]
    # 显式 newline="\n"：Windows 默认会把 \n 写成 \r\n，而 macOS 写 \n ⇒
    # 同一个生成器在两个平台产出不同字节，会让 SHA256SUMS 校验误判。这里统一成 LF。
    with open(out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")

    print(f"读集 : {src}  →  {out}")
    print(f"条目 : {len(entries)} 个唯一偏移" + (f"（合并重复 {len(dupes)} 处）" if dupes else ""))
    if dupes:
        print("重复明细：")
        for off, first, second in dupes:
            print(f"  0x{off:05X}  {first} / {second}")
    lo = min(o for _, o in entries)
    hi = max(o for _, o in entries)
    print(f"偏移范围 : 0x{lo:05X} .. 0x{hi:05X}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
