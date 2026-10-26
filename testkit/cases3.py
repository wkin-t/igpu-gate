import contextlib, importlib.util, io, os, pathlib, plistlib, shutil, sys, tempfile
HERE = pathlib.Path(__file__).resolve().parent
ROOT = pathlib.Path(os.environ.get("IGPU_HANDOFF", str(HERE.parent / "igpu-build")))
INJ = ROOT / "tools" / "inject-probe.py"
LIVE = pathlib.Path(os.environ.get("IGPU_LIVE_CONFIG", str(HERE / "live-config.plist")))
GUID = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
WORK = pathlib.Path(tempfile.mkdtemp(prefix="igpu-cases3-"))

spec = importlib.util.spec_from_file_location("inject_probe", INJ)
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)

PASS = FAIL = 0
def ok(n, c, d=""):
    global PASS, FAIL
    if c: PASS += 1; print(f"PASS  {n}")
    else: FAIL += 1; print(f"FAIL  {n}  —— {d}")

def load(p): return plistlib.loads(pathlib.Path(p).read_bytes())
def save(p, d): pathlib.Path(p).write_bytes(plistlib.dumps(d))

def run(args):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        rc = mod.run(args)
    return rc, buf.getvalue()

def baseline(path):
    d = load(LIVE)
    d["Kernel"]["Add"] = [e for e in d["Kernel"]["Add"]
                          if not str(e.get("BundlePath","")).startswith("IGPUProbe.kext")]
    save(path, d); return path

def probes(d):
    return [e for e in d["Kernel"]["Add"] if str(e.get("BundlePath","")).startswith("IGPUProbe.kext")]

base = baseline(WORK / "base.plist")
rc, out = run(["--config", str(base)])
ok("1 基线注入返回 0", rc == 0, f"rc={rc} {out[:120]}")
d = load(base)
ok("2 注入后探针恰 1 条", len(probes(d)) == 1, f"条数={len(probes(d))}")
ok("3 Delete 含 boot-args", any(str(x)=="boot-args" for x in d["NVRAM"]["Delete"][GUID]))
ok("4 条目字段与期望一致", probes(d)[0] == mod.EXPECT, f"{probes(d)[0]}")
ok("5 输出 injected=1", "injected=1" in out)

before = base.read_bytes()
rc, out = run(["--config", str(base)])
ok("6 重复注入幂等返回 0", rc == 0 and "idempotent=1" in out, f"rc={rc} {out[:120]}")
ok("7 幂等不改文件", base.read_bytes() == before)

d = load(base); d["Kernel"]["Add"][-1]["Comment"] = "改过的注释"; diff = WORK / "diff.plist"; save(diff, d)
h = diff.read_bytes()
rc, out = run(["--config", str(diff)])
ok("8 字段不同被拒(5)", rc == 5, f"rc={rc}")
ok("9 拒绝时不改文件", diff.read_bytes() == h)

d = load(base); d["Kernel"]["Add"].append(dict(mod.EXPECT)); dup = WORK / "dup.plist"; save(dup, d)
rc, _ = run(["--config", str(dup)])
ok("10 多条探针被拒(4)", rc == 4, f"rc={rc}")

d = load(base); d["Kernel"].pop("Add"); noadd = WORK / "noadd.plist"; save(noadd, d)
rc, _ = run(["--config", str(noadd)])
ok("11 缺 Kernel/Add 被拒(3)", rc == 3, f"rc={rc}")

d = load(base); d["Kernel"]["Add"] = {"x": 1}; notlist = WORK / "notlist.plist"; save(notlist, d)
rc, _ = run(["--config", str(notlist)])
ok("12 Kernel/Add 非数组被拒(3)", rc == 3, f"rc={rc}")

d = load(base); d["NVRAM"]["Delete"].pop(GUID); nod = WORK / "nodelete.plist"; save(nod, d)
rc, out = run(["--config", str(nod)])
d2 = load(nod)
ok("13 缺 Delete/GUID 时补 boot-args", rc == 0 and GUID in d2["NVRAM"]["Delete"]
   and any(str(x)=="boot-args" for x in d2["NVRAM"]["Delete"][GUID]), f"rc={rc}")

base2 = baseline(WORK / "base2.plist"); h0 = base2.read_bytes()
rc, out = run(["--config", str(base2), "--dry-run"])
ok("14 --dry-run 返回 0", rc == 0, f"rc={rc}")
ok("15 --dry-run 不落盘", base2.read_bytes() == h0)
ok("16 --dry-run 报告 would_write=yes", "would_write=yes" in out)

base3 = baseline(WORK / "base3.plist"); h3 = base3.read_bytes()
real_replace = pathlib.Path.replace
def boom(self, target):
    raise OSError("模拟 rename 失败")
pathlib.Path.replace = boom
try:
    rc, out = run(["--config", str(base3)])
finally:
    pathlib.Path.replace = real_replace
ok("17 原子写失败返回 6", rc == 6, f"rc={rc} {out[:120]}")
ok("18 原子写失败原文件不变", base3.read_bytes() == h3)
ok("19 原子写失败无残留临时文件", not list(WORK.glob("base3.plist.inj-*")))

print(f"\n===== PASS={PASS}  FAIL={FAIL} =====")
sys.exit(0 if FAIL == 0 else 1)
