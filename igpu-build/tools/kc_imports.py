"""Check a kext's undefined imports against the symbols exported in kernel collections.

Usage: python -I kc_imports.py --kc BootKernelExtensions.kc --kc SystemKernelExtensions.kc
                               [--kernel kernel] <kext-binary>...
For each kext binary prints how many imports resolve, and which ones do not,
with the fileset entry (bundle id) that exports each resolved symbol.
Read-only; handles thin or fat x86_64 Mach-O and MH_FILESET collections.
"""
import argparse
import collections
import struct

MH_MAGIC_64 = 0xfeedfacf
LC_SYMTAB = 0x2
LC_FILESET_ENTRY = 0x80000035
N_STAB, N_TYPE, N_EXT, N_UNDF, N_SECT, N_ABS, N_INDR = 0xe0, 0x0e, 0x01, 0x0, 0xe, 0x2, 0xa


def thin(buf):
    if struct.unpack_from('>I', buf, 0)[0] == 0xcafebabe:
        for i in range(struct.unpack_from('>I', buf, 4)[0]):
            cpu, _, off, size, _ = struct.unpack_from('>iiIII', buf, 8 + 20 * i)
            if cpu == 0x01000007:
                return buf[off:off + size], off
        raise SystemExit('no x86_64 slice')
    return buf, 0


def load_commands(buf, base):
    magic, _, _, ftype, ncmds, _, _, _ = struct.unpack_from('<IiiIIIII', buf, base)
    if magic != MH_MAGIC_64:
        raise ValueError(f'not a 64-bit Mach-O at {base:#x}')
    p = base + 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', buf, p)
        yield cmd, p, size
        p += size


def symbols(buf, symtab_cmd_off, file_base=0):
    symoff, nsyms, stroff, strsize = struct.unpack_from('<IIII', buf, symtab_cmd_off + 8)
    symoff += file_base
    stroff += file_base
    for i in range(nsyms):
        strx, ntype, nsect, ndesc, nvalue = struct.unpack_from('<IBBhQ', buf, symoff + 16 * i)
        end = buf.index(b'\0', stroff + strx)
        yield buf[stroff + strx:end].decode('utf-8', 'replace'), ntype, nvalue


def exported(buf, base, file_base):
    out = set()
    for cmd, p, _ in load_commands(buf, base):
        if cmd == LC_SYMTAB:
            for name, ntype, _ in symbols(buf, p, file_base):
                if ntype & N_STAB:
                    continue
                if ntype & N_EXT and (ntype & N_TYPE) in (N_SECT, N_ABS, N_INDR):
                    out.add(name)
    return out


def kc_exports(path):
    """返回 (table, meta)。

    meta = {"entries": fileset 子项数, "source": "fileset"|"top-level"|"none"}

    为什么要回退：有些内核集合不是 MH_FILESET（没有 LC_FILESET_ENTRY），
    导出符号在**顶层** LC_SYMTAB 里。旧实现只扫 fileset 子项，对这类文件
    静默返回空表，调用方再把空表当成"全部符号都缺"，于是报出 313 个假缺失。
    空表必须能被区分出来，不能和"真的缺"混为一谈。
    """
    buf = open(path, 'rb').read()
    table = collections.defaultdict(set)
    entries = 0
    for cmd, p, _ in load_commands(buf, 0):
        if cmd == LC_FILESET_ENTRY:
            entries += 1
            _, fileoff, name_off = struct.unpack_from('<QQI', buf, p + 8)
            name = buf[p + name_off:buf.index(b'\0', p + name_off)].decode()
            for sym in exported(buf, fileoff, 0):
                table[sym].add(name)
    if table:
        return table, {"entries": entries, "source": "fileset"}
    for sym in exported(buf, 0, 0):
        table[sym].add("top-level")
    if table:
        return table, {"entries": entries, "source": "top-level"}
    return table, {"entries": entries, "source": "none"}


def kext_imports(path):
    buf, _ = thin(open(path, 'rb').read())
    imports = set()
    for cmd, p, _ in load_commands(buf, 0):
        if cmd == LC_SYMTAB:
            for name, ntype, _ in symbols(buf, p):
                if not ntype & N_STAB and ntype & N_EXT and (ntype & N_TYPE) == N_UNDF:
                    imports.add(name)
    return imports


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--kc', action='append', default=[])
    ap.add_argument('--kernel')
    ap.add_argument('--dump-owner', action='append', default=[], help='print the entry exporting this symbol')
    ap.add_argument('kexts', nargs='*')
    a = ap.parse_args()
    table = collections.defaultdict(set)
    for kc in a.kc:
        t, meta = kc_exports(kc)
        if len(t) == 0:
            print(f'# {kc}: 0 exported symbols (NO_EXPORT_TABLE source={meta["source"]} '
                  f'fileset_entries={meta["entries"]})')
        else:
            print(f'# {kc}: {len(t)} exported symbols (source={meta["source"]})')
        for s, owners in t.items():
            table[s] |= owners
    if a.kernel:
        kbuf, _ = thin(open(a.kernel, 'rb').read())
        for s in exported(kbuf, 0, 0):
            table[s].add('kernel(file)')
    for s in a.dump_owner:
        print(f'owner {s}: {sorted(table.get(s, []))}')
    for k in a.kexts:
        imp = kext_imports(k)
        missing = sorted(s for s in imp if s not in table)
        owners = collections.Counter(o for s in imp if s in table for o in table[s])
        print(f'\n## {k}: {len(imp)} imports, {len(imp) - len(missing)} resolved, {len(missing)} missing')
        print('   providers:', ', '.join(f'{o}({n})' for o, n in owners.most_common()))
        for s in missing:
            print('   MISSING', s)


if __name__ == '__main__':
    main()
