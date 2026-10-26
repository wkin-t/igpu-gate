#!/usr/bin/env python3
"""cases4.py —— fbmodel.py / pre2b-decode.py 的单元测试（纯离线，构造合成证据）

为什么单独一套：这两个文件是"驱动要消费的模型"，一旦算错，后面 2b-A2/A5 的
判断全错。这里用**合成 EDID/寄存器/证据目录**把边界锁死，不依赖真机数据。
"""

import json
import os
import plistlib
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
BUNDLE = HERE.parent / "igpu-build"
sys.path.insert(0, str(BUNDLE / "tools"))
import fbmodel  # noqa: E402

PASS = 0
FAIL = 0


def ok(name):
    global PASS
    PASS += 1
    print("  ✓ %s" % name)


def bad(name, detail=""):
    global FAIL
    FAIL += 1
    print("  ✗ %s%s" % (name, ("（%s）" % detail) if detail else ""))


def check(name, cond, detail=""):
    ok(name) if cond else bad(name, detail)


def expect_raises(name, fn):
    try:
        fn()
    except Exception:
        ok(name)
        return
    bad(name, "没有抛异常")


def dtd_bytes(f, hactive, hblank, vactive, vblank):
    pclk10 = f // 10
    d = bytearray(18)
    d[0] = pclk10 & 0xFF
    d[1] = (pclk10 >> 8) & 0xFF
    d[2] = hactive & 0xFF
    d[3] = hblank & 0xFF
    d[4] = (((hactive >> 8) & 0x0F) << 4) | ((hblank >> 8) & 0x0F)
    d[5] = vactive & 0xFF
    d[6] = vblank & 0xFF
    d[7] = (((vactive >> 8) & 0x0F) << 4) | ((vblank >> 8) & 0x0F)
    return bytes(d)


def make_edid(timing=(148500, 1920, 280, 1080, 45)):
    edid = bytearray(128)
    edid[0:8] = bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
    mfg = 0x04CA
    edid[8] = (mfg >> 8) & 0xFF
    edid[9] = mfg & 0xFF
    edid[17] = 30
    edid[18] = 1
    edid[19] = 4
    edid[54:72] = dtd_bytes(*timing)
    return bytes(edid)


def write_probe_plist(path, registers):
    state = {k: int(v).to_bytes(4, "little") for k, v in registers.items()}
    doc = {"IORegistry": [{"IOClass": "IGPUProbe", "IGPUProbeState": state}]}
    path.write_bytes(plistlib.dumps(doc))


def make_bundle(root, rounds=("normal", "off", "normal"), a0="A0-CROSS-KC-IMPOSSIBLE",
                with_edid=True, names_as_numbers=False, recovery=True):
    b = pathlib.Path(root) / "igpu-build"
    b.mkdir(parents=True, exist_ok=True)
    (b / "regs.txt").write_text("PIPESRC_A 0x6001C\nPLANE_SIZE_1_A 0x70190\n"
                                "PLANE_STRIDE_1_A 0x70188\nPLANE_SURF_1_A 0x7019C\n",
                                encoding="utf-8")

    for i, mode in enumerate(rounds, start=1):
        d = b / ("results-collect-2026010%d" % i)
        d.mkdir()
        loaded = "no" if mode == "off" else "yes"
        (d / "summary.txt").write_text(
            "mode=%s\nprobe_loaded=%s\ninstances=%d\nmaterial_complete=yes\n"
            "functional_ok=yes\noc_log=ok\nshutdown_cause=normal\n"
            % (mode, loaded, 0 if mode == "off" else 1), encoding="utf-8")
        if mode == "normal":
            if names_as_numbers:
                # 键为十进制偏移：0x6001C=393244，0x70190=459152，0x70188=459144，0x7019C=459164
                regs = {"393244": 0x077F0437, "459152": 0x0437077F,
                        "459144": 0x00000078, "459164": 0x10000000}
            else:
                regs = {"PIPESRC_A": 0x077F0437, "PLANE_SIZE_1_A": 0x0437077F,
                        "PLANE_STRIDE_1_A": 0x00000078, "PLANE_SURF_1_A": 0x10000000}
            write_probe_plist(d / "ioreg-probe.plist", regs)

    pre = b / "results-pre2b-20260101"
    pre.mkdir()
    (pre / "INDEX.txt").write_text("sip: enabled\n", encoding="utf-8")
    (pre / "01-env.txt").write_text("System Software Overview:\n", encoding="utf-8")
    (pre / "02-kc.txt").write_text(
        "com.apple.iokit.IOGraphicsFamily system\n"
        "com.apple.iokit.IOPCIFamily boot\n", encoding="utf-8")
    (pre / "03-auxkc.txt").write_text(
        "drwxr-xr-x /Library/Extensions\n"
        "/System/Volumes/Preboot/x/boot/y/System/Library/KernelCollections/AuxiliaryKernelExtensions.kc\n",
        encoding="utf-8")
    if with_edid:
        edid = make_edid()
        doc = {"IORegistry": [{"IOClass": "IODisplayConnect",
                               "IOEDIDData": edid}]}
        (pre / "10-ioreg-IODisplayConnect.plist").write_bytes(plistlib.dumps(doc))

    fb = b / "results-fbdescribe-20260101"
    fb.mkdir()
    (fb / "summary.txt").write_text("fb_like_nodes=2\n", encoding="utf-8")

    if a0:
        (b.parent / "results-a0-gate.txt").write_text("RESULT: %s\n" % a0, encoding="utf-8")
    if recovery:
        (b.parent / "RECOVERY-EFI-VERIFIED.txt").write_text("ok\n", encoding="utf-8")
    return b


def add_posix_imports():
    sys.path.insert(0, str(BUNDLE / "tools"))


print("== cases4：模型与解码器 ==")

# ---- fbmodel：位域编解码 ----
check("PIPESRC 解码", fbmodel.decode_pipesrc(0x077F0437) == (1920, 1080))
check("PLANE_SIZE 解码（字段顺序相反）", fbmodel.decode_plane_size(0x0437077F) == (1920, 1080))
check("stride 解码", fbmodel.decode_stride(0x00000078) == 7680)
check("PIPESRC 编码", fbmodel.pipesrc_reg(1920, 1080) == 0x077F0437)
check("PLANE_SIZE 编码", fbmodel.plane_size_reg(1920, 1080) == 0x0437077F)
check("stride 编码", fbmodel.stride_reg_value(7680) == 0x78)
expect_raises("stride 未对齐必须抛异常", lambda: fbmodel.stride_reg_value(7681))
check("RGB565 stride", fbmodel.stride_bytes(
    fbmodel.Timing(74250, 1280, 370, 720, 30), "RGB565") == 2560)

t = fbmodel.Timing(148500, 1920, 280, 1080, 45)
check("htotal/vtotal", (t.htotal, t.vtotal) == (2200, 1125))
check("刷新率约 60Hz", abs(t.refresh_hz - 60.0) < 0.1)
plan = fbmodel.plan_for(t, "XRGB8888")
check("计划 stride=7680", plan.stride == 7680)
check("计划 fb_bytes", plan.fb_bytes == 7680 * 1080)
check("计划 PIPESRC 复现实测", plan.pipesrc == 0x077F0437)
check("计划 PLANE_SIZE 复现实测", plan.plane_size == 0x0437077F)

# ---- EDID ----
edid = make_edid()
pref = fbmodel.edid_preferred_timing(edid)
check("EDID 首选时序", pref is not None and (pref.hactive, pref.vactive) == (1920, 1080),
      str(pref))
check("EDID 只有 1 个有效 DTD", len(fbmodel.edid_all_dtds(edid)) == 1)

# ---- compare ----
m = fbmodel.Measured(pipesrc=0x077F0437, plane_size=0x0437077F,
                     plane_stride=0x78, plane_surf=0x10000000)
check("与实测完全一致", fbmodel.compare(plan, m) == [])
check("stride 不符要报差异",
      len(fbmodel.compare(plan, fbmodel.Measured(plane_stride=0x80))) == 1)
check("SURF 未对齐要报差异",
      len(fbmodel.compare(plan, fbmodel.Measured(plane_surf=0x12345678))) == 1)
check("未知项不报差异", fbmodel.compare(plan, fbmodel.Measured()) == [])

# ---- 解码器：正常 ----
add_posix_imports()
import importlib
dec = importlib.import_module("pre2b-decode")

with tempfile.TemporaryDirectory() as tmp:
    b = make_bundle(tmp)
    model = dec.build_model(b)
    check("解码器 G1 通过", model["gates"]["G1_2a"] == "PASS", str(model["gates"]))
    check("解码器容器=AuxKC", model["container"]["route"] == "aux-kc",
          str(model["container"]))
    check("解码器 G3 通过", model["gates"]["G3_a1_baseline"] == "PASS")
    check("解码器 G4 通过", model["gates"]["G4_rollback"] == "PASS")
    check("解码器读到 4 个寄存器", model["scanout"]["registers_read"] == 4,
          str(model["scanout"]["registers_read"]))
    check("解码器实测 1920x1080",
          model["scanout"]["measured_decoded"]["pipesrc_wh"] == [1920, 1080])
    check("解码器计划与实测无差异", model["scanout"]["diffs"] == [],
          str(model["scanout"]["diffs"]))
    check("模型可序列化为 JSON", bool(json.dumps(model, ensure_ascii=False)))

# ---- 解码器：数字键 + regs.txt 映射 ----
with tempfile.TemporaryDirectory() as tmp:
    b = make_bundle(tmp, names_as_numbers=True)
    model = dec.build_model(b)
    check("数字键也能解出寄存器", model["scanout"]["registers_read"] == 4,
          str(model["scanout"]["registers_read"]))
    check("数字键解出 1920x1080",
          model["scanout"]["measured_decoded"]["pipesrc_wh"] == [1920, 1080])

# ---- 解码器：轮次不足 ----
with tempfile.TemporaryDirectory() as tmp:
    b = make_bundle(tmp, rounds=("normal",))
    model = dec.build_model(b)
    check("轮次不足 G1=FAIL", model["gates"]["G1_2a"] == "FAIL")
    check("轮次不足进 unknowns", any("轮采集" in u for u in model["unknowns"]),
          str(model["unknowns"]))

# ---- 解码器：A0 符号存在 -> OC 注入 ----
with tempfile.TemporaryDirectory() as tmp:
    b = make_bundle(tmp, a0="A0-SYMBOLS-PRESENT")
    model = dec.build_model(b)
    check("A0 有符号 -> 容器=OC 注入", model["container"]["route"] == "oc-injection")

# ---- 解码器：A0 无效 ----
with tempfile.TemporaryDirectory() as tmp:
    b = make_bundle(tmp, a0="GATE-INVALID")
    model = dec.build_model(b)
    check("A0 无效 -> 容器未定", model["container"]["route"] is None)
    check("A0 无效 -> G2=FAIL", model["gates"]["G2_container"] == "FAIL")

# ---- 解码器：没有 EDID ----
with tempfile.TemporaryDirectory() as tmp:
    b = make_bundle(tmp, with_edid=False)
    model = dec.build_model(b)
    check("缺 EDID -> G3=FAIL", model["gates"]["G3_a1_baseline"] == "FAIL")
    check("缺 EDID -> unknowns 提到 EDID",
          any("EDID" in u for u in model["unknowns"]), str(model["unknowns"]))

# ---- 解码器 CLI 能写出 model.json ----
with tempfile.TemporaryDirectory() as tmp:
    b = make_bundle(tmp)
    out = pathlib.Path(tmp) / "model.json"
    rc = subprocess.call([sys.executable, "-I", str(BUNDLE / "tools" / "pre2b-decode.py"),
                          "--bundle", str(b), "--out", str(out)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    check("解码器 CLI 退出码 0", rc == 0, "rc=%d" % rc)
    check("model.json 已生成", out.is_file())
    if out.is_file():
        data = json.loads(out.read_text(encoding="utf-8"))
        check("model.json 有 schema_version", data.get("schema_version") == 1)

print("===== PASS=%d  FAIL=%d =====" % (PASS, FAIL))
sys.exit(0 if FAIL == 0 else 1)