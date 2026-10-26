"""把 Phase 2a/2b 的现场证据解码成结构化模型（model.json）。

输入（全部只读）：
  <bundle>/results-collect-*/ioreg-probe.plist    探针 190 个寄存器（权威：plist 不是文本）
  <bundle>/results-collect-*/summary.txt          每轮判物结论（mode/probe_loaded/material_*）
  <bundle>/results-pre2b-*/{02-kc.txt,03-auxkc.txt,01-env.txt,10-ioreg-IODisplayConnect.plist}
  <bundle>/results-fbdescribe-*/summary.txt       扫描面基线
  <bundle>/../results-a0-gate.txt 或 ~/results-a0-gate.txt   A0 离线判定

输出：JSON（schema_version=1），分 device / display / scanout / container / gates / unknowns。
原则：**缺项写 null 并进 unknowns，不用默认值填充**——下游据此决定"能不能进 A2"。
"""

import argparse
import json
import os
import pathlib
import plistlib
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fbmodel  # noqa: E402

SCHEMA_VERSION = 1
REG_LINE = re.compile(r"^\s*([A-Z][A-Z0-9_]*)\s+(0x[0-9A-Fa-f]+)\s*$")


def say(msg):
    print(msg)


# ---------------------------------------------------------------- 证据定位
def newest(base, pattern):
    cands = sorted(base.glob(pattern), key=lambda p: p.name)
    return cands[-1] if cands else None


def load_regs_map(bundle):
    """regs.txt：NAME 0xOFFSET —— 用于在探针键是纯数字时反查名字。"""
    out = {}
    p = bundle / "regs.txt"
    if not p.is_file():
        return out
    for line in p.read_text("utf-8", "ignore").splitlines():
        m = REG_LINE.match(line)
        if m:
            out[m.group(1)] = int(m.group(2), 16)
    return out


def probe_registers(collect_dir):
    """从 ioreg-probe.plist 里取出 190 个寄存器 → {name: value}。

    为什么不用 ioreg-instances.txt：文本打印器会把 OSData 改写（本项目踩过）。
    """
    p = collect_dir / "ioreg-probe.plist"
    if not p.is_file():
        return {}, "ioreg-probe.plist 不存在"
    try:
        doc = plistlib.loads(p.read_bytes())
    except Exception as exc:  # noqa: BLE001
        return {}, "plist 解析失败：%s" % exc

    found = {}

    def walk(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if k == "IGPUProbeState" and isinstance(v, dict):
                    for rk, rv in v.items():
                        if isinstance(rv, (bytes, bytearray)) and len(rv) == 4:
                            found[rk] = int.from_bytes(bytes(rv), "little")
                        elif isinstance(rv, int):
                            found[rk] = rv
                walk(v)
        elif isinstance(node, list):
            for e in node:
                walk(e)

    walk(doc)
    if not found:
        return {}, "plist 里没有 IGPUProbeState"
    return found, None


def register_value(regs, name, name_to_offset=None):
    """按名字取寄存器值；允许探针键是数字（用 regs.txt 的偏移反查）。"""
    if name in regs:
        return regs[name]
    if name_to_offset and name in name_to_offset:
        off = "%d" % name_to_offset[name]
        for k, v in regs.items():
            if str(k) == off:
                return v
    return None


def parse_kv_file(path, sep="="):
    out = {}
    if not path.is_file():
        return out
    for line in path.read_text("utf-8", "ignore").splitlines():
        if sep in line:
            k, _, v = line.partition(sep)
            out[k.strip()] = v.strip()
    return out


def parse_kc_map(pre2b):
    """02-kc.txt 里每个模块后面跟着它的 collection（boot/system/aux）。"""
    p = pre2b / "02-kc.txt"
    out = {}
    if not p.is_file():
        return out
    for line in p.read_text("utf-8", "ignore").splitlines():
        m = re.match(r"^\s*(com\.apple\.[A-Za-z0-9_.]+|dev\.igpu\.probe)\s+(boot|system|aux)", line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def parse_aux(pre2b):
    p = pre2b / "03-auxkc.txt"
    txt = p.read_text("utf-8", "ignore") if p.is_file() else ""
    return {
        "aux_kc_present": ("AuxiliaryKernelExtensions.kc" in txt),
        "library_extensions_present": ("/Library/Extensions" in txt),
        "kernelmanagerd_running": ("kernelmanagerd" in txt and "(未运行)" not in txt),
        "text_len": len(txt),
    }


def parse_edid(pre2b):
    """优先从 IODisplayConnect 的 plist 取 EDID 原始字节。"""
    if pre2b is None:
        return None, "没有 pre2b 目录"
    p = pre2b / "10-ioreg-IODisplayConnect.plist"
    if not p.is_file():
        return None, "没有 10-ioreg-IODisplayConnect.plist"
    try:
        doc = plistlib.loads(p.read_bytes())
    except Exception as exc:  # noqa: BLE001
        return None, "plist 解析失败：%s" % exc
    roots = doc if isinstance(doc, list) else [doc.get("IORegistry", doc)]
    found = []

    def walk(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if "EDID" in str(k).upper() and isinstance(v, (bytes, bytearray)):
                    found.append(bytes(v))
                walk(v)
        elif isinstance(node, list):
            for e in node:
                walk(e)

    for r in roots:
        walk(r)
    if not found:
        return None, "plist 里没有 EDID 数据"
    return max(found, key=len), None


def parse_a0(bundle):
    for p in (bundle.parent / "results-a0-gate.txt",
              pathlib.Path.home() / "results-a0-gate.txt"):
        if p.is_file():
            for line in p.read_text("utf-8", "ignore").splitlines():
                if line.startswith("RESULT: "):
                    return line[len("RESULT: "):].strip(), str(p)
    return None, None


# ---------------------------------------------------------------- 组装
def build_model(bundle):
    bundle = pathlib.Path(bundle)
    unknowns = []
    name_to_off = load_regs_map(bundle)

    rounds = sorted(bundle.glob("results-collect-*"), key=lambda p: p.name)
    pre2b = newest(bundle, "results-pre2b-*")
    fbdesc = newest(bundle, "results-fbdescribe-*")

    if not rounds:
        unknowns.append("没有任何 results-collect-*（三轮判物未采）")
    elif len(rounds) < 3:
        unknowns.append("只有 %d 轮采集（三轮判物需要 3 轮：normal/off/normal）" % len(rounds))
    if pre2b is None:
        unknowns.append("没有 results-pre2b-*（容器/EDID/设备树证据缺）")
    if fbdesc is None:
        unknowns.append("没有 results-fbdescribe-*（扫描面基线缺）")

    # --- 每轮摘要
    round_info = []
    for d in rounds:
        s = parse_kv_file(d / "summary.txt")
        round_info.append({"dir": d.name, **{k: s.get(k) for k in
                                            ("mode", "probe_loaded", "instances",
                                             "material_complete", "functional_ok",
                                             "oc_log", "shutdown_cause")}})

    # --- 探针寄存器：取"最后一个 normal 轮"
    regs, reg_err = {}, "没有采集轮"
    for info, d in reversed(list(zip(round_info, rounds))):
        if info.get("mode") == "normal":
            regs, reg_err = probe_registers(d)
            if regs:
                break
    if not regs:
        unknowns.append("探针寄存器不可用：%s" % reg_err)

    measured = fbmodel.Measured(
        pipesrc=register_value(regs, "PIPESRC_A", name_to_off),
        plane_size=register_value(regs, "PLANE_SIZE_1_A", name_to_off),
        plane_stride=register_value(regs, "PLANE_STRIDE_1_A", name_to_off),
        plane_surf=register_value(regs, "PLANE_SURF_1_A", name_to_off),
    )

    # --- EDID / 时序 / 计划
    edid, edid_err = parse_edid(pre2b)
    preferred = fbmodel.edid_preferred_timing(edid) if edid else None
    if edid is None:
        unknowns.append("EDID 不可用：%s" % edid_err)
    elif preferred is None:
        unknowns.append("EDID 里解不出首选时序")

    plan, diffs = None, []
    if preferred is not None:
        plan = fbmodel.plan_for(preferred, "XRGB8888")
        diffs = fbmodel.compare(plan, measured)
    if measured.pipesrc is not None and preferred is None:
        w, h = fbmodel.decode_pipesrc(measured.pipesrc)
        unknowns.append("实测模式 %dx%d 但没有 EDID 首选时序可比对" % (w, h))

    # --- 容器
    a0, a0_src = parse_a0(bundle)
    kc_map = parse_kc_map(pre2b) if pre2b else {}
    aux = parse_aux(pre2b) if pre2b else {}
    if a0 is None:
        container = {"route": None, "reason": "没有 A0 判定"}
    elif a0 == "A0-SYMBOLS-PRESENT":
        container = {"route": "oc-injection",
                     "reason": "Boot KC 能解析 IOFramebuffer 符号（与预期不符，需复核）"}
    elif a0 == "A0-CROSS-KC-IMPOSSIBLE":
        if aux.get("aux_kc_present") and aux.get("library_extensions_present"):
            container = {"route": "aux-kc",
                         "reason": "Boot KC 跨集合不可行；aux KC 与 /Library/Extensions 均存在"}
        else:
            container = {"route": None,
                         "reason": "Boot KC 跨集合不可行，且 aux 路径证据不足"}
    else:
        container = {"route": None, "reason": "A0 判定无效：%s" % a0}

    # --- 门（与 onsite/16-coding-readiness.sh 同口径）
    g1 = "FAIL"
    if len(rounds) >= 3:
        m = [i.get("mode") for i in round_info[-3:]]
        l = [i.get("probe_loaded") for i in round_info[-3:]]
        mat = [i.get("material_complete") for i in round_info[-3:]]
        if m == ["normal", "off", "normal"] and l == ["yes", "no", "yes"] and all(x != "no" for x in mat):
            g1 = "PASS"
    g2 = "PASS" if container.get("route") else "FAIL"
    g3 = "PASS" if (plan is not None and measured.pipesrc is not None) else "FAIL"
    g4 = "PASS" if ((bundle.parent / "RECOVERY-EFI-VERIFIED.txt").is_file()
                    or (pathlib.Path.home() / "RECOVERY-EFI-VERIFIED.txt").is_file()) else "FAIL"

    model = {
        "schema_version": SCHEMA_VERSION,
        "bundle": str(bundle),
        "sources": {
            "rounds": [d.name for d in rounds],
            "pre2b": pre2b.name if pre2b else None,
            "fbdescribe": fbdesc.name if fbdesc else None,
            "a0_gate": a0_src,
        },
        "rounds": round_info,
        "display": {
            "edid_hex": edid.hex() if edid else None,
            "edid_len": len(edid) if edid else 0,
            "preferred": preferred.__dict__ if preferred else None,
            "all_timings": [t.__dict__ for t in (fbmodel.edid_all_dtds(edid) if edid else [])],
        },
        "scanout": {
            "measured": measured.to_dict(),
            "measured_decoded": {
                "pipesrc_wh": list(fbmodel.decode_pipesrc(measured.pipesrc)) if measured.pipesrc is not None else None,
                "plane_size_wh": list(fbmodel.decode_plane_size(measured.plane_size)) if measured.plane_size is not None else None,
                "stride_bytes": fbmodel.decode_stride(measured.plane_stride) if measured.plane_stride is not None else None,
                "surf_addr": (measured.plane_surf & ~(fbmodel.SURFACE_ALIGN - 1)) if measured.plane_surf is not None else None,
            },
            "plan": plan.to_dict() if plan else None,
            "diffs": diffs,
            "registers_read": len(regs),
        },
        "container": {
            **container,
            "a0_result": a0,
            "kc_placement": kc_map,
            "aux": aux,
        },
        "gates": {"G1_2a": g1, "G2_container": g2, "G3_a1_baseline": g3, "G4_rollback": g4},
        "unknowns": unknowns,
    }
    return model


def main():
    ap = argparse.ArgumentParser(description="把现场证据解码成 model.json")
    ap.add_argument("--bundle", default=str(pathlib.Path(__file__).resolve().parent.parent),
                    help="igpu-build 目录（默认取脚本的上两级）")
    ap.add_argument("--out", default=None, help="输出路径（默认 <bundle>/model.json）")
    ap.add_argument("--stdout", action="store_true", help="同时打印 JSON")
    a = ap.parse_args()

    model = build_model(a.bundle)
    out = pathlib.Path(a.out) if a.out else pathlib.Path(a.bundle) / "model.json"
    text = json.dumps(model, ensure_ascii=False, indent=2)
    out.write_text(text + "\n", encoding="utf-8")

    say("== 证据解码完成 ==")
    say("  输出：%s（%d B）" % (out, len(text)))
    say("  轮次：%d 轮 %s" % (len(model["rounds"]), [r.get("mode") for r in model["rounds"]]))
    say("  容器：%s（%s）" % (model["container"]["route"], model["container"]["reason"]))
    g = model["gates"]
    say("  门：G1=%s G2=%s G3=%s G4=%s" % (g["G1_2a"], g["G2_container"], g["G3_a1_baseline"], g["G4_rollback"]))
    if model["unknowns"]:
        say("  未知项 %d：" % len(model["unknowns"]))
        for u in model["unknowns"]:
            say("    - %s" % u)
    if model["scanout"]["diffs"]:
        say("  扫描面差异：")
        for d in model["scanout"]["diffs"]:
            say("    - %s" % d)
    if a.stdout:
        say(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())