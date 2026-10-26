"""Kext 注入前的符号层门禁（Phase 1 用）。

用法：
    python -I tools/kc_gate.py --kc <BootKernelExtensions.kc> [--kc <System...kc>] \
        --kext <IGPUProbe 二进制> [--timeout 600]

它回答三个问题，缺一不可：
  1) 这个二进制**是不是**一个 kext 主二进制（Mach-O 类型必须 MH_KEXT_BUNDLE）；
  2) 它有没有**可用且自洽的符号表**；
  3) 它的未定义符号能不能在给定内核集合里**全部解析**（missing == 0）。

为什么绕这一层而不直接看 kc_imports.py 的输出：
  - kc_imports.py 只遍历 LC_SYMTAB。文件没有该命令时它得到**空集合**，于是打印
    "0 imports, 0 missing" —— 看起来像通过。空集合必须判为无效输入。
  - 它读出 filetype 却不校验：dylib / 可执行文件同样可能"零 missing"。
  - `nundefsym` 属于 LC_DYSYMTAB，**不是** LC_SYMTAB 的字段；本门禁用
    "符号表存在且范围自洽 + 导入数 > 0" 代替那个计数，语义更直接。

2026-10-19 第四轮评审后加严（它实测出旧版可被伪符号表骗过）：
  - 一切结构检查失败都是 GATE-INVALID，不允许"带着半个符号表继续算"；
  - 规则：命令区必须完整覆盖 sizeofcmds；每条 cmdsize >= 8；LC_SYMTAB 必须
    cmdsize >= 24；symoff/nsyms*16 与 stroff/strsize 必须落在文件内；
    LC_SYMTAB **不得重复**；fat 表与切片范围必须自洽；截断文件直接 INVALID；
  - `MH_CIGAM_64`（需要字节交换）**明确不支持**，判 INVALID，不做半吊子解析；
  - helper 调用设 timeout 并要求退出码为 0，stderr 保留用于诊断。

退出码：0 = 通过；2 = 输入无效（GATE-INVALID）；3 = 符号缺失（GATE-FAIL）。
只读：不写文件、不改二进制。
"""

import argparse
import struct
import subprocess
import sys
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
MH_KEXT_BUNDLE = 11
CPU_TYPE_X86_64 = 0x01000007
LC_SYMTAB = 0x2
FAT_MAGIC = 0xCAFEBABE
SIZE_OF_SYMTAB_CMD = 24


def load_slice(buf):
    """返回 (x86_64 切片, 切片文件偏移, 说明) 或 (None, 0, 原因)。"""
    if len(buf) < 8:
        return None, 0, "文件太短（< 8 字节）"
    be = struct.unpack_from(">I", buf, 0)[0]
    if be == FAT_MAGIC:
        nfat = struct.unpack_from(">I", buf, 4)[0]
        if nfat == 0 or nfat > 32:
            return None, 0, f"fat 切片数异常：{nfat}"
        need = 8 + nfat * 20
        if len(buf) < need:
            return None, 0, f"fat 表被截断（需要 {need}，实际 {len(buf)}）"
        for i in range(nfat):
            cputype, _sub, off, size, _align = struct.unpack_from(">iiIII", buf, 8 + 20 * i)
            if off + size > len(buf):
                return None, 0, f"fat 切片 #{i} 越界（off={off} size={size} 文件={len(buf)}）"
            if cputype == CPU_TYPE_X86_64:
                return buf[off:off + size], off, f"fat 切片 #{i}"
        return None, 0, "fat 里没有 x86_64 切片"
    le = struct.unpack_from("<I", buf, 0)[0]
    if le == MH_CIGAM_64:
        return None, 0, "MH_CIGAM_64（需字节交换）本门禁不支持，按无效处理"
    if le == MH_MAGIC_64:
        return buf, 0, "thin"
    return None, 0, "不是 64 位 Mach-O（magic=0x%08x）" % le


def header_facts(img):
    if len(img) < 32:
        return None, ["头部被截断（< 32 字节）"]
    magic = struct.unpack_from("<I", img, 0)[0]
    if magic != MH_MAGIC_64:
        return None, ["切片不是小端 MH_MAGIC_64"]
    cputype = struct.unpack_from("<i", img, 4)[0]
    filetype = struct.unpack_from("<I", img, 12)[0]
    ncmds = struct.unpack_from("<I", img, 16)[0]
    sizeofcmds = struct.unpack_from("<I", img, 20)[0]
    return (cputype, filetype, ncmds, sizeofcmds), []


def symtab_facts(img, ncmds, sizeofcmds):
    """严格解析命令区。返回 (ok, nsyms, problems)。"""
    problems = []
    if ncmds > 4096:
        return False, 0, [f"ncmds={ncmds} 过大（防御损坏文件）"]
    if sizeofcmds <= 0:
        return False, 0, ["sizeofcmds=0 ⇒ 命令区为空"]
    start = 32
    end = start + sizeofcmds
    if end > len(img):
        return False, 0, [f"命令区越界（32+{sizeofcmds}={end} > 文件 {len(img)}）"]
    off = start
    found = 0
    nsyms = 0
    completed = True
    for idx in range(ncmds):
        if off + 8 > end:
            problems.append(f"第 {idx+1} 条命令头越界")
            completed = False
            break
        cmd, cmdsize = struct.unpack_from("<II", img, off)
        if cmdsize < 8:
            problems.append(f"第 {idx+1} 条 cmdsize={cmdsize} < 8")
            completed = False
            break
        if off + cmdsize > end:
            problems.append(f"第 {idx+1} 条命令越过命令区")
            completed = False
            break
        if cmd == LC_SYMTAB:
            found += 1
            if cmdsize < SIZE_OF_SYMTAB_CMD:
                problems.append(f"LC_SYMTAB cmdsize={cmdsize} < {SIZE_OF_SYMTAB_CMD}")
            else:
                symoff, n, stroff, strsize = struct.unpack_from("<IIII", img, off + 8)
                if symoff + n * 16 > len(img):
                    problems.append(f"符号表越界（symoff={symoff} nsyms={n} 文件={len(img)}）")
                if stroff + strsize > len(img):
                    problems.append(f"字符串表越界（stroff={stroff} strsize={strsize} 文件={len(img)}）")
                if n == 0:
                    problems.append("LC_SYMTAB.nsyms=0")
                nsyms = max(nsyms, n)
        off += cmdsize
    if completed and off != end:
        problems.append(f"命令未完整覆盖 sizeofcmds（走到 {off}，应为 {end}）")
    if found == 0:
        problems.append("没有 LC_SYMTAB")
    elif found > 1:
        problems.append(f"LC_SYMTAB 出现 {found} 次（正常应恰好 1 次）")
    return (not problems), nsyms, problems


def symtab_ranges(img, ncmds, sizeofcmds):
    """取第一个 LC_SYMTAB 的 (symoff, nsyms, stroff, strsize)。

    结构问题由 symtab_facts 负责报；这里只取范围供字符串表校验。
    """
    off = 32
    end = min(len(img), 32 + sizeofcmds)
    for _ in range(min(ncmds, 4096)):
        if off + 8 > end:
            break
        cmd, cmdsize = struct.unpack_from("<II", img, off)
        if cmd == LC_SYMTAB and cmdsize >= SIZE_OF_SYMTAB_CMD:
            return struct.unpack_from("<IIII", img, off + 8)
        if cmdsize < 8:
            break
        off += cmdsize
    return None


def symbol_name_problems(img, symoff, nsyms, stroff, strsize):
    """校验每个 nlist_64.strx 落在**声明的**字符串表内，且有终止 NUL。

    第五轮评审实测：helper 会跟随越界的 strx 读表外字节，从而把
    "1 imports / 1 resolved / 0 missing" 这种伪造输入算成通过。
    字符串表边界只能由这里守住。
    """
    problems = []
    if nsyms <= 0 or strsize <= 0:
        return problems
    for i in range(nsyms):
        pos = symoff + i * 16
        if pos + 4 > len(img):
            problems.append(f"符号 #{i} 的 nlist 越界")
            break
        strx = struct.unpack_from("<I", img, pos)[0]
        if strx >= strsize:
            problems.append(f"符号 #{i} 名称索引 strx={strx} 越界（strsize={strsize}）")
        elif img.find(b"\x00", stroff + strx, stroff + strsize) < 0:
            problems.append(f"符号 #{i} 名称缺终止 NUL（strx={strx}）")
        if len(problems) >= 3:
            problems.append("…（只列前 3 条）")
            break
    return problems


def run_kc_imports(kcs, kext, timeout):
    """返回 dict：rc/stdout/stderr/error/imports/resolved/missing。"""
    cmd = [sys.executable, "-I", str(Path(__file__).with_name("kc_imports.py"))]
    for kc in kcs:
        cmd += ["--kc", str(kc)]
    cmd.append(str(kext))
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"error": f"kc_imports 超时（>{timeout}s）"}
    out = {"rc": p.returncode, "stdout": p.stdout, "stderr": p.stderr,
           "error": None, "imports": None, "resolved": None, "missing": None,
           "kc_exports": [], "kc_none": []}
    for line in p.stdout.splitlines():
        # 每个 KC 的导出表读数：0 表示"读不到导出表"，必须与"符号真的缺"区分开
        if line.startswith("# ") and "exported symbols" in line:
            try:
                # 用 rsplit：Windows 盘符路径里有冒号，split(":", 1) 会切错位置
                head, tail = line.rsplit(":", 1)
                kc = head[2:].strip()
                n = int(tail.strip().split()[0])
                out["kc_exports"].append((kc, n))
                if n == 0:
                    out["kc_none"].append(kc)
            except (ValueError, IndexError):
                pass
        if line.startswith("## ") and " imports," in line:
            try:
                tail = line.rsplit(":", 1)[1].strip()
                parts = tail.split(",")
                out["imports"] = int(parts[0].split()[0])
                out["resolved"] = int(parts[1].split()[0])
                out["missing"] = int(parts[2].split()[0])
            except (IndexError, ValueError):
                pass
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kc", action="append", default=[])
    ap.add_argument("--kext", required=True)
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--allow-any-filetype", action="store_true",
                    help="仅用于诊断非 kext 二进制；正式门禁不得使用")
    a = ap.parse_args()

    print("== kc_gate v2 ==")
    print(f"kext   : {a.kext}")
    for kc in a.kc:
        print(f"kc     : {kc}")

    kext = Path(a.kext)
    if not kext.is_file():
        print("GATE-INVALID 文件不存在")
        return 2
    raw = kext.read_bytes()
    img, slice_off, note = load_slice(raw)
    if img is None:
        print(f"GATE-INVALID {note}")
        return 2
    facts, probs = header_facts(img)
    if facts is None:
        print("GATE-INVALID " + "；".join(probs))
        return 2
    cputype, filetype, ncmds, sizeofcmds = facts
    print(f"slice  : {note} @ file offset {slice_off}")
    print(f"cputype: 0x{cputype:08x} {'(x86_64 ✓)' if cputype == CPU_TYPE_X86_64 else '✗'}")
    print(f"filetype: {filetype} {'(MH_KEXT_BUNDLE ✓)' if filetype == MH_KEXT_BUNDLE else '✗'}")

    invalid = []
    if cputype != CPU_TYPE_X86_64:
        invalid.append("cputype 不是 x86_64")
    if filetype != MH_KEXT_BUNDLE and not a.allow_any_filetype:
        invalid.append(f"filetype={filetype}，要求 {MH_KEXT_BUNDLE}（MH_KEXT_BUNDLE）")

    sym_ok, nsyms, sym_problems = symtab_facts(img, ncmds, sizeofcmds)
    print(f"LC_SYMTAB: {'结构自洽' if sym_ok else '结构不合格'}  nsyms={nsyms}")
    for p in sym_problems:
        invalid.append(p)

    # 字符串表边界：helper 会跟随越界的 strx 读表外字节，把伪造输入算成通过
    rng = symtab_ranges(img, ncmds, sizeofcmds)
    if rng is None:
        invalid.append("取不到 LC_SYMTAB 范围 ⇒ 无法校验名称索引")
    else:
        name_probs = symbol_name_problems(img, *rng)
        print(f"名称索引: {'全部落在声明字符串表内' if not name_probs else '越界/无终止 NUL ' + str(len(name_probs)) + ' 处'}")
        invalid.extend(name_probs)

    if invalid:
        print("GATE-INVALID " + "；".join(invalid))
        return 2

    if not a.kc:
        print("GATE-INVALID 没有给 --kc，无法判符号解析")
        return 2
    r = run_kc_imports(a.kc, kext, a.timeout)
    if r["error"]:
        print(f"GATE-INVALID {r['error']}")
        return 2
    if r["rc"] != 0:
        print(f"GATE-INVALID helper 退出码 {r['rc']}（不是 0）")
        if r["stderr"].strip():
            print("  stderr: " + r["stderr"].strip().splitlines()[-1][:300])
        return 2
    if r["imports"] is None:
        print("GATE-INVALID 解析 helper 输出失败")
        print(r["stdout"][-800:])
        return 2
    if r["kc_exports"]:
        print("kc_exports: " + ", ".join(f"{kc}={n}" for kc, n in r["kc_exports"]))
    print(f"imports={r['imports']} resolved={r['resolved']} missing={r['missing']}")
    # 空导出表 ≠ 零缺失，也 ≠ 全部缺失：它是**无法判定**。旧实现把它算成
    # "313 个符号都缺"，于是 Dell 上 SystemKernelExtensions.kc 报了一个假 FAIL。
    if r["kc_exports"] and len(r["kc_none"]) == len(r["kc_exports"]):
        print("GATE-INVALID 给定的 KC 未提供可读导出符号表（exports=0）："
              "无法判定符号解析，既不是 PASS 也不是 FAIL")
        for kc in r["kc_none"]:
            print(f"  无导出表: {kc}")
        print("  （若这是非注入目标的集合，请改用承载该 kext 的集合重跑）")
        return 2
    if r["kc_none"]:
        print("注意：以下 KC 导出表不可读，其判定无效：" + ", ".join(r["kc_none"]))
    if r["imports"] <= 0:
        print("GATE-INVALID imports=0 ⇒ 空导入集合不是零缺失，是解析失败")
        print("  （策略假设：IGPUProbe 必然调用 IOKit/C++ 运行时，零导入视为解析失败）")
        return 2
    if r["missing"] != 0:
        print(f"GATE-FAIL {r['missing']} 个未定义符号**在给定的这些 KC 里**找不到"
              f" —— 仅针对所给 KC，不判断整体可加载性")
        for line in r["stdout"].splitlines():
            if "MISSING" in line:
                print("  " + line.strip())
        return 3
    print("GATE-PASS 符号层必要条件成立（不证明可加载/ABI 兼容/运行正常）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
