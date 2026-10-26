import re, sys, pathlib
pat = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*|[0-9])(?=[^\x00-\x7f])')
hits = 0
for p in sys.argv[1:]:
    path = pathlib.Path(p)
    try:
        t = path.read_text(encoding='utf-8')
    except UnicodeDecodeError:
        print(f"SKIP(非UTF8) {p}"); continue
    for i, line in enumerate(t.splitlines(), 1):
        for m in pat.finditer(line):
            print(f"{path.name}:{i}: ${m.group(1)} 后紧跟非ASCII -> {line.strip()[:80]}")
            hits += 1
print(f"共 {hits} 处")