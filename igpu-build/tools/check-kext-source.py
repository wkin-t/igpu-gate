"""IGPUProbe 源码红线静态检查（Windows 侧可跑；不能替代编译）。

用法：
    python -I tools/check-kext-source.py --kext-dir kext/IGPUProbe

它守护的是 spec §1.1/§1.2 里那几条"评审会逐行查、写错了现场才炸"的约束：

  R1  Phase 1 **零 MMIO 写**：不得出现 OSWriteLittleInt32 / outl / *base = ... 等写路径；
  R2  **不读 EDID**：不得出现 GMBUS / AUX 事务（要写总线控制寄存器，属主动操作）；
  R3  `-igpu-driver=off` 分支存在，且 off 走"不匹配"（无实例/无属性）；
  R4  身份三元组校验**先于**任何 MMIO 映射（顺序错就等于先摸寄存器再验身份）；
  R5  发布 `PhysicalIdentityVerified` 与 `GPUAccess`（含失败路径）；
  R6  Info.plist：OSBundleRequired=Root、IOPCIPrimaryMatch=0x46808086、
      IOMatchCategory=dev.igpu.probe、IOProviderClass=IOPCIDevice、独立 CI；
  R7  读集头文件：`kIGPUProbeRegCount` 与实际条目数一致、偏移无重复；
  R8  不发布 IOFramebuffer（Phase 1 不接管显示）。

退出码：0 全过；3 有违例；2 用法/缺文件。
"""

import argparse
import re
import sys
from pathlib import Path

WRITE_APIS = [
    r"\bOSWriteLittleInt32\b", r"\bOSWriteLittleInt16\b", r"\bOSWriteLittleInt64\b",
    r"\bOSWriteBigInt32\b", r"\bOSWriteBigInt16\b",
    r"\boutb\s*\(", r"\boutw\s*\(", r"\boutl\s*\(",
    r"\bwriteReg\b", r"\biosf_mbi_write\b",
]
WRITE_DEREF = [r"\*\s*base\s*=", r"\bbase\s*\[[^\]]*\]\s*=", r"\bmmio\s*\[[^\]]*\]\s*="]
# 只锚词首不锚词尾：`GMBUS_READ` / `GMBUS_DATA` 这类带后缀的写法同样要抓（反例②暴露过漏判）
EDID_PAT = [r"\bEDID", r"\bGMBUS", r"\bgmbus", r"\bAUX_CH", r"\bDP_AUX", r"\baux_ch", r"\bEDID_"]


def strip_comments(text):
    """去掉 // 与 /* */ 注释（保留行号：把注释替换成等长空白 + 换行）。

    为什么必须剥：源码里"禁止写 MMIO"这条红线本身就要把函数名写进注释，
    不剥注释会让检查器把自己的说明判成违例（假阳性会训练人忽略告警）。
    """
    out = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            block = text[i:j]
            out.append("".join(ch if ch == "\n" else " " for ch in block))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


DECL_RE = re.compile(
    r"^\s*(volatile|const|void|static|UInt32|UInt64|UInt16|UInt8|char|int|unsigned|Boolean|bool|OSObject|OSData|IO[A-Za-z]+)\b[^;=]*?\*\s*\w+\s*="
)


def find_all(text, pats):
    """返回 [(行号, 命中文本)]；命中的若是变量声明（如 `*base =` 出现在
    `volatile const void *base = ...` 里），则跳过。"""
    hits = []
    for pat in pats:
        for m in re.finditer(pat, text):
            line_no = text.count("\n", 0, m.start()) + 1
            line_start = text.rfind("\n", 0, m.start()) + 1
            line_end = text.find("\n", m.start())
            line = text[line_start:(len(text) if line_end < 0 else line_end)]
            if DECL_RE.match(line):
                continue
            hits.append((line_no, m.group(0)))
    return sorted(hits)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kext-dir", default="kext/IGPUProbe")
    a = ap.parse_args()

    d = Path(a.kext_dir)
    cpp = d / "IGPUProbe.cpp"
    hdr = d / "IGPUProbeState.hpp"
    plist = d / "Info.plist"
    for f in (cpp, hdr, plist):
        if not f.is_file():
            print(f"用法错误：缺文件 {f}")
            return 2

    raw_src = cpp.read_text(encoding="utf-8", errors="replace")
    src = strip_comments(raw_src)
    h = strip_comments(hdr.read_text(encoding="utf-8", errors="replace"))
    fails = []
    warns = []

    # --- R1 零 MMIO 写 ---
    hits = find_all(src, WRITE_APIS + WRITE_DEREF)
    if hits:
        for line, tok in hits:
            fails.append(f"R1 出现 MMIO 写路径：{tok!r}（第 {line} 行）")
    else:
        print("[PASS] R1 无 MMIO 写（OSWrite*/outl/裸指针赋值 均未出现）")

    # --- R2 不读 EDID ---
    hits = find_all(src, EDID_PAT)
    if hits:
        for line, tok in hits:
            fails.append(f"R2 出现 EDID/GMBUS/AUX 痕迹：{tok!r}（第 {line} 行）")
    else:
        print("[PASS] R2 无 EDID/GMBUS/AUX 事务")

    # --- R3 off 分支 ---
    if "kModeOff" not in src:
        fails.append("R3 没有 off 模式（kModeOff 未出现）")
    else:
        probe_region = ""
        m = re.search(r"IOService \*IGPUProbe::probe\(.*?\n\}", src, re.S)
        if m:
            probe_region = m.group(0)
        if "kModeOff" in probe_region and "return 0" in probe_region:
            print("[PASS] R3 off 在 probe 阶段不匹配（无实例/无属性）")
        else:
            fails.append("R3 off 分支不在 probe()，或没有 return 0 ⇒ ioreg 仍会有实例，与验收 d 冲突")

    # --- R4 身份先于 MMIO ---
    start_m = re.search(r"bool IGPUProbe::start\(.*?\n\}", src, re.S)
    if not start_m:
        fails.append("R4 找不到 start() 函数体")
    else:
        body = start_m.group(0)
        i_verify = body.find("verifyIdentity()")
        i_open = body.find("openBar()")
        if i_verify < 0:
            fails.append("R4 start() 未调用 verifyIdentity()")
        elif i_open < 0:
            fails.append("R4 start() 未调用 openBar()")
        elif i_verify > i_open:
            fails.append("R4 openBar() 出现在 verifyIdentity() 之前 ⇒ 先摸寄存器再验身份")
        else:
            print("[PASS] R4 身份三元组校验先于 BAR0 映射")

    # --- R5 门控属性 ---
    for key in ("PhysicalIdentityVerified", "GPUAccess"):
        if f'setProperty("{key}"' not in src:
            fails.append(f"R5 没有发布 {key}")
    if not any(f.startswith("R5") for f in fails):
        if 'setProperty("GPUAccess", "none: MMIO reads only")' not in src:
            fails.append('R5 GPUAccess 的字面值必须是 "none: MMIO reads only"（需与 spec §1.2 一致）')
        else:
            print("[PASS] R5 PhysicalIdentityVerified + GPUAccess 均发布，含失败路径")

    # --- R6 Info.plist ---
    try:
        import plistlib
        pl = plistlib.loads(plist.read_bytes())
    except Exception as e:  # noqa: BLE001
        fails.append(f"R6 Info.plist 解析失败：{e}")
        pl = None
    if pl is not None:
        checks = [
            ("OSBundleRequired", pl.get("OSBundleRequired"), "Root"),
            ("CFBundleIdentifier", pl.get("CFBundleIdentifier"), "dev.igpu.probe"),
        ]
        for name, got, want in checks:
            if got != want:
                fails.append(f"R6 {name}={got!r}，应为 {want!r}")
        pers = pl.get("IOKitPersonalities", {})
        if len(pers) != 1:
            fails.append(f"R6 IOKitPersonalities 应恰好 1 个，实际 {len(pers)}")
        for pname, p in pers.items():
            want = {
                "IOClass": "IGPUProbe",
                "IOProviderClass": "IOPCIDevice",
                "IOPCIPrimaryMatch": "0x46808086",
                "IOMatchCategory": "dev.igpu.probe",
                "CFBundleIdentifier": "dev.igpu.probe",
            }
            for k, v in want.items():
                if p.get(k) != v:
                    fails.append(f"R6 personality[{pname}].{k}={p.get(k)!r}，应为 {v!r}")
            if "IOProbeScore" in p and p["IOProbeScore"] != 0:
                warns.append(f"R6 personality[{pname}].IOProbeScore={p['IOProbeScore']}（spec 要求不设/为 0）")
        if not any(f.startswith("R6") for f in fails):
            print("[PASS] R6 Info.plist 键值与 spec §1.1 一致")

    # --- R7 读集一致性 ---
    m = re.search(r"kIGPUProbeRegCount\s*=\s*(\d+)", h)
    entries = re.findall(r'\{\s*"([A-Za-z0-9_]+)"\s*,\s*(0x[0-9A-Fa-f]+)\s*(?:,[^{}]*)?\}', h)
    if not m:
        fails.append("R7 头文件缺 kIGPUProbeRegCount")
    elif int(m.group(1)) != len(entries):
        fails.append(f"R7 计数常量={m.group(1)} 与条目数={len(entries)} 不一致（头文件被手改过？）")
    else:
        offs = [int(o, 16) for _, o in entries]
        dup = {o for o in offs if offs.count(o) > 1}
        if dup:
            fails.append(f"R7 头文件里有重复偏移：{sorted(hex(x) for x in dup)}")
        else:
            print(f"[PASS] R7 读集 {len(entries)} 项、计数常量一致、无重复偏移")

    # --- R8 不发布 IOFramebuffer ---
    if re.search(r"class\s+\w+\s*:\s*public\s+IOFramebuffer", src) or 'setProperty("IOFramebuffer' in src:
        fails.append("R8 出现 IOFramebuffer 继承或发布 ⇒ 越过 Phase 1 边界")
    else:
        print("[PASS] R8 未接管显示（无 IOFramebuffer 继承/发布）")

    # --- 结构完整性（弱检查） ---
    for tok, why in [
        ("OSDeclareDefaultStructors", "缺 OSDeclareDefaultStructors"),
        ("OSDefineMetaClassAndStructors", "缺 OSDefineMetaClassAndStructors"),
        ("registerService()", "start() 未 registerService()"),
    ]:
        if tok not in raw_src:
            fails.append(f"{why}")

    print()
    for w in warns:
        print(f"[WARN] {w}")
    if fails:
        print(f"结论：{len(fails)} 项违例 ⇒ 这份源码不得进入构建/部署")
        for f in fails:
            print("  - " + f)
        return 3
    print("结论：红线静态检查全过。它**不证明**能编译、能加载、能读对值——"
          "那要等 macOS 构建 + kextutil + kc_gate + 上机采集。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
