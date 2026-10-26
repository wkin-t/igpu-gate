import os, plistlib, pathlib, shutil, subprocess, sys, tempfile
HERE = pathlib.Path(__file__).resolve().parent
HANDOFF = pathlib.Path(os.environ.get("IGPU_HANDOFF", str(HERE.parent / "igpu-build")))
SET = str(HANDOFF / "tools" / "set-bootargs.py")
BASE = pathlib.Path(os.environ.get("IGPU_LIVE_CONFIG", str(HERE / "live-config.plist")))
GUID = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
work = pathlib.Path(tempfile.mkdtemp(prefix="igpu-cases-"))

def run(*args):
    r = subprocess.run([sys.executable, "-I", SET, *args], capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr

def load(p): return plistlib.loads(pathlib.Path(p).read_bytes())
def save(p, d): pathlib.Path(p).write_bytes(plistlib.dumps(d))

def mk(name, mutate):
    d = load(BASE); mutate(d); p = work / f"{name}.plist"; save(p, d); return p

def set_args(d, val): d["NVRAM"]["Add"][GUID]["boot-args"] = val

results = []
def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))

# 1 脏 token: -igpu-driver=off 请求 normal 应被清掉
p = mk("dirty-dash", lambda d: set_args(d, "-v -igpu-driver=off"))
rc, out, err = run("--config", str(p), "--mode", "normal", "--out", str(work/"o1.plist"))
got = load(work/"o1.plist")["NVRAM"]["Add"][GUID]["boot-args"] if rc == 0 else None
check("脏 token(-igpu-driver=off) 被清除", rc == 0 and got == "-v", f"rc={rc} got={got!r} err={err.strip()[:80]}")

# 2 大写 token
p = mk("upper", lambda d: set_args(d, "-v IGPU-DRIVER=OFF"))
rc, out, err = run("--config", str(p), "--mode", "normal", "--out", str(work/"o2.plist"))
got = load(work/"o2.plist")["NVRAM"]["Add"][GUID]["boot-args"] if rc == 0 else None
check("大写 IGPU-DRIVER=OFF 被清除", rc == 0 and got == "-v", f"rc={rc} got={got!r}")

# 3 重复 token
p = mk("dup", lambda d: set_args(d, "-v igpu-driver=off igpu-driver=verbose"))
rc, out, err = run("--config", str(p), "--mode", "verbose", "--out", str(work/"o3.plist"))
got = load(work/"o3.plist")["NVRAM"]["Add"][GUID]["boot-args"] if rc == 0 else None
check("重复 token 收敛为单个 canonical", rc == 0 and got == "-v igpu-driver=verbose", f"rc={rc} got={got!r}")

# 4 TAB 分隔
p = mk("tab", lambda d: set_args(d, "-v\tigpu-driver=off"))
rc, out, err = run("--config", str(p), "--mode", "normal", "--out", str(work/"o4.plist"))
got = load(work/"o4.plist")["NVRAM"]["Add"][GUID]["boot-args"] if rc == 0 else None
check("TAB 分隔的 token 被清除", rc == 0 and got == "-v", f"rc={rc} got={got!r}")

# 5 幂等：原文已等于规范串
p = mk("canon", lambda d: set_args(d, "-v igpu-driver=off"))
rc, out, err = run("--config", str(p), "--mode", "off")
check("规范串→同模式 幂等", rc == 0 and "unchanged=1" in out, f"rc={rc} out={out.strip()[:60]}")

# 6 错误 GUID（把 boot-args 挪到别的 GUID）
def bad_guid(d):
    d["NVRAM"]["Add"]["11111111-2222-3333-4444-555555555555"] = {"boot-args": "-v"}
p = mk("badguid", bad_guid)
rc, out, err = run("--config", str(p), "--mode", "off", "--out", str(work/"o6.plist"))
check("boot-args 出现在别的 GUID 时拒绝", rc == 5, f"rc={rc} err={err.strip()[:80]}")

# 7 缺 NVRAM/Delete
def no_del(d): d["NVRAM"]["Delete"][GUID] = [x for x in d["NVRAM"]["Delete"][GUID] if x != "boot-args"]
p = mk("nodel", no_del)
rc, out, err = run("--config", str(p), "--mode", "off", "--out", str(work/"o7.plist"))
check("缺 NVRAM/Delete 时拒绝写入(exit 10)", rc == 10, f"rc={rc} err={err.strip()[:80]}")

# 8 严格模式：Enabled=False
def dis(d): d["Kernel"]["Add"][-1]["Enabled"] = False
for e in d_probe if False else []: pass
def disable_probe(d):
    for e in d["Kernel"]["Add"]:
        if str(e.get("BundlePath","")).startswith("IGPUProbe"): e["Enabled"] = False
p = mk("disabled", disable_probe)
rc, out, err = run("--config", str(p), "--require-deployable")
check("strict：Enabled=False 被拒", rc == 3, f"rc={rc}")

# 9 strict：MinKernel 异常
def bad_min(d):
    for e in d["Kernel"]["Add"]:
        if str(e.get("BundlePath","")).startswith("IGPUProbe"): e["MinKernel"] = "99.0.0"
p = mk("badmin", bad_min)
rc, out, err = run("--config", str(p), "--require-deployable")
check("strict：MinKernel 异常被拒", rc == 3, f"rc={rc}")

# 10 strict：BootPath 后缀伪装
def suffix(d):
    for e in d["Kernel"]["Add"]:
        if str(e.get("BundlePath","")).startswith("IGPUProbe"): e["BundlePath"] = "IGPUProbe.kext.disabled"
p = mk("suffix", suffix)
rc, out, err = run("--config", str(p), "--require-deployable")
check("strict：BundlePath 后缀伪装被拒", rc == 3, f"rc={rc}")

# 11 strict：脏状态
p = mk("dirtystate", lambda d: set_args(d, "-v -igpu-driver=off"))
rc, out, err = run("--config", str(p), "--require-deployable")
check("strict：脏状态被拒(exit 11)", rc == 11, f"rc={rc} err={err.strip()[:80]}")

# 12 重复 key 的 XML 必须拒绝
text = BASE.read_text()
dup = text.replace("<key>boot-args</key>", "<key>boot-args</key><string>x</string><key>boot-args</key>", 1)
p = work / "dupkey.plist"; p.write_text(dup)
rc, out, err = run("--config", str(p), "--check")
check("重复 key 的 XML 被拒", rc == 9, f"rc={rc} err={err.strip()[:80]}")

# 13 未知元素必须拒绝
unk = text.replace("<plist version=\"1.0\">", "<plist version=\"1.0\"><foo/>", 1)
p = work / "unknown.plist"; p.write_text(unk)
rc, out, err = run("--config", str(p), "--check")
check("未知元素被拒", rc == 9, f"rc={rc} err={err.strip()[:80]}")

bad = [r for r in results if not r[1]]
for name, okflag, detail in results:
    print(("PASS  " if okflag else "FAIL  ") + name + ("" if okflag else f"  —— {detail}"))
print(f"\n===== PASS={len(results)-len(bad)}  FAIL={len(bad)} =====")
sys.exit(0 if not bad else 1)
