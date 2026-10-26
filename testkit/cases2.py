import os, plistlib, pathlib, shutil, subprocess, sys, tempfile
HERE = pathlib.Path(__file__).resolve().parent
HANDOFF = pathlib.Path(os.environ.get("IGPU_HANDOFF", str(HERE.parent / "igpu-build")))
SET = str(HANDOFF / "tools" / "set-bootargs.py")
BASE = pathlib.Path(os.environ.get("IGPU_LIVE_CONFIG", str(HERE / "live-config.plist")))
GUID = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
work = pathlib.Path(tempfile.mkdtemp(prefix="igpu-cases2-"))

def run(*a):
    r = subprocess.run([sys.executable, "-I", SET, *a], capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr
def load(p): return plistlib.loads(pathlib.Path(p).read_bytes())
def save(p, d): pathlib.Path(p).write_bytes(plistlib.dumps(d))
def mk(name, val):
    d = load(BASE); d["NVRAM"]["Add"][GUID]["boot-args"] = val
    p = work / f"{name}.plist"; save(p, d); return p
res = []
def check(n, c, d=""): res.append((n, bool(c), d))

# 裸同名参数：严格模式必须拒绝
p = mk("bare", "igpu-driver=off igpu-driver")
rc, out, err = run("--config", str(p), "--require-deployable")
check("裸 igpu-driver 被严格检查拒绝(11)", rc == 11, f"rc={rc}")
rc, out2, err = run("--config", str(p), "--check")
check("裸参数时 state 报告为 dirty", "state=dirty" in out2, out2.strip()[:80])

# 裸参数在 normal 下应被清除
rc, out, err = run("--config", str(p), "--mode", "normal", "--out", str(work/"o-bare.plist"))
got = load(work/"o-bare.plist")["NVRAM"]["Add"][GUID]["boot-args"] if rc == 0 else None
check("裸 igpu-driver 被清除", rc == 0 and got == "", f"rc={rc} got={got!r}")

# 拼写错误 igpu_driver=off 也要清掉
p = mk("typo", "-v igpu_driver=off")
rc, out, err = run("--config", str(p), "--mode", "normal", "--out", str(work/"o-typo.plist"))
got = load(work/"o-typo.plist")["NVRAM"]["Add"][GUID]["boot-args"] if rc == 0 else None
check("igpu_driver=off 被清除", rc == 0 and got == "-v", f"rc={rc} got={got!r}")

# 非规范空白：canonical=no，严格检查拒绝
p = mk("space", "-v  igpu-driver=off")
rc, out, err = run("--config", str(p), "--require-deployable")
check("非规范串被严格检查拒绝(11)", rc == 11, f"rc={rc}")
rc, out2, err = run("--config", str(p), "--check")
check("双空格非规范串 canonical=no", "canonical=no" in out2, out2.strip()[:100])

# DEL / C1 控制字符
p = mk("del", "-v\x7figpu-driver=off")
rc, out, err = run("--config", str(p), "--check")
check("DEL 控制字符被拒(4 或 XML 层 9)", rc in (4, 9), f"rc={rc}")
p = mk("c1", "-v\u0085igpu-driver=off")
rc, out, err = run("--config", str(p), "--check")
check("C1 控制字符被拒(4 或 XML 层 9)", rc in (4, 9), f"rc={rc}")

# plist 根下多值
text = BASE.read_text()
multi = text.replace("<plist version=\"1.0\">\n<dict>", "<plist version=\"1.0\">\n<dict><key>LOST</key><string>x</string></dict>\n<dict>", 1)
p = work / "multi.plist"; p.write_text(multi)
rc, out, err = run("--config", str(p), "--check")
check("根下多个值被拒(9)", rc == 9, f"rc={rc} err={err.strip()[:60]}")

# 非法 Base64
bad = text.replace("<data>", "<data>!!!!", 1)
p = work / "baddata.plist"; p.write_text(bad)
rc, out, err = run("--config", str(p), "--check")
check("非法 Base64 被拒(9)", rc == 9, f"rc={rc} err={err.strip()[:60]}")

bad = sorted([r for r in res if not r[1]], key=lambda x: x[0])
for n, okf, d in res:
    print(("PASS  " if okf else "FAIL  ") + n + ("" if okf else f"  —— {d}"))
print(f"\n===== PASS={len(res)-len(bad)}  FAIL={len(bad)} =====")
sys.exit(0 if not bad else 1)
