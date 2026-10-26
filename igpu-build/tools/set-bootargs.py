#!/usr/bin/env python3
"""切换/校验 OpenCore config.plist 的 igpu-driver 状态（normal / off / verbose）。

第三版（2026-10-20 第三轮 codex 评审后）关键约束：
  · 归本工具管的 token 不只是 `igpu-driver=…`：裸 `igpu-driver`、`-igpu-driver`、
    `igpu_driver=off`（拼写错误）等"相关 token"一律清除，避免留下 XNU 仍会解析的同名参数；
  · 是否幂等只看 `原文 == 规范串`，并显式输出 `canonical=yes/no`；shell 与严格检查都用它，
    不再依赖宽松判态；
  · 严格校验 XML：根下恰好一个容器、容器内不允许非空白文本、标量结构合法、
    `<data>` 严格 Base64、重复 key / 未知元素 / 嵌套 plist 全部拒绝 —— 不替用户静默"修好"；
  · 只认 Apple boot GUID；写前必须确认 NVRAM/Delete 含 boot-args（否则 OC 的 Add 不生效）；
  · 分词按空格与 TAB；拒绝 C0（除 TAB）、DEL、C1 控制字符。

退出码：0 成功；2 用法；3 probe 条目缺失/不合法；4 boot-args 类型异常；
        5 GUID 定位异常；6 除 boot-args 外出现其它差异；7 写入后 probe 丢失；
        8 写入后 boot-args 复核失败；9 XML 不合法；10 缺 NVRAM/Delete；11 状态非规范。
"""
import argparse
import base64
import binascii
import datetime
import os
import pathlib
import plistlib
import re
import sys
import xml.etree.ElementTree as ET

APPLE_GUID = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
MODES = ("normal", "off", "verbose", "prep")
RELATED_RE = re.compile(r"^-?igpu[_-]driver(=.*)?$", re.IGNORECASE)
SAFE_RE = re.compile(r"^-x(=.*)?$", re.IGNORECASE)
PROBE_EXPECT = {
    "BundlePath": "IGPUProbe.kext",
    "ExecutablePath": "Contents/MacOS/IGPUProbe",
    "PlistPath": "Contents/Info.plist",
    "Arch": "x86_64",
    "MinKernel": "25.0.0",
    "MaxKernel": "",
}
KNOWN_TAGS = {"plist", "dict", "key", "string", "integer", "real", "true", "false", "date", "data", "array"}
CONTAINERS = {"dict", "array"}


def fail(msg, code):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def _is_bad_control(ch):
    code = ord(ch)
    if ch == "\t":
        return False
    return code < 0x20 or code == 0x7F or 0x80 <= code <= 0x9F


def strict_xml(path):
    try:
        root = ET.fromstring(pathlib.Path(path).read_bytes())
    except ET.ParseError as exc:
        fail(f"XML 解析失败：{exc}", 9)
    if root.tag != "plist":
        fail(f"根元素不是 <plist> 而是 <{root.tag}>", 9)
    if root.attrib and set(root.attrib) - {"version"}:
        fail(f"<plist> 上出现非标准属性 {dict(root.attrib)}", 9)
    if len(root) != 1 or root[0].tag not in CONTAINERS:
        fail(f"<plist> 下应恰好一个 <dict> 或 <array>，实际 {[c.tag for c in root]}", 9)

    def walk(el):
        if el.tag == "plist":
            fail("检测到嵌套的 <plist>", 9)
        if el.tag in CONTAINERS:
            if (el.text or "").strip():
                fail(f"<{el.tag}> 内出现非空白文本 {(el.text or '')[:30]!r}（plistlib 会丢弃）", 9)
            for child in el:
                if (child.tail or "").strip():
                    fail(f"<{child.tag}> 后出现非空白文本 {(child.tail or '')[:30]!r}", 9)
                walk(child)
            if el.tag == "dict":
                kids = list(el)
                if len(kids) % 2:
                    fail("<dict> 子元素数不是偶数（key/value 不成对）", 9)
                seen = set()
                for i in range(0, len(kids), 2):
                    k, v = kids[i], kids[i + 1]
                    if k.tag != "key":
                        fail(f"<dict> 第 {i + 1} 个子元素是 <{k.tag}>，应为 <key>", 9)
                    name = k.text or ""
                    if name in seen:
                        fail(f"<dict> 出现重复 key：{name!r}（plistlib 会合并）", 9)
                    seen.add(name)
                    if k.attrib:
                        fail("<key> 上不允许属性", 9)
                    if v.tag == "key":
                        fail(f"key {name!r} 后直接跟 <key>，value 缺失", 9)
            return
        # 标量
        if el.attrib:
            fail(f"<{el.tag}> 上不允许属性 {dict(el.attrib)}", 9)
        if len(el):
            fail(f"<{el.tag}> 不应有子元素", 9)
        text = (el.text or "").strip()
        if el.tag in {"true", "false"}:
            if text:
                fail(f"<{el.tag}> 不应带文本 {text!r}", 9)
        elif el.tag == "integer":
            try:
                int(text)
            except ValueError:
                fail(f"<integer> 内容不是整数：{text!r}", 9)
        elif el.tag == "real":
            try:
                float(text)
            except ValueError:
                fail(f"<real> 内容不是实数：{text!r}", 9)
        elif el.tag == "date":
            try:
                datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
            except ValueError:
                fail(f"<date> 不是 ISO8601 时间：{text!r}", 9)
        elif el.tag == "data":
            compact = "".join(text.split())
            try:
                base64.b64decode(compact, validate=True)
            except (binascii.Error, ValueError):
                fail("<data> 不是合法 Base64（plistlib 会解成空串）", 9)
        elif el.tag == "string":
            if (el.text or "").strip() and any(_is_bad_control(c) for c in el.text):
                fail("<string> 含控制字符", 9)
        elif el.tag == "key":
            if not text:
                fail("出现空 <key>", 9)

    walk(root[0])


def load_cfg(path):
    strict_xml(path)
    try:
        return plistlib.loads(pathlib.Path(path).read_bytes())
    except Exception as exc:  # noqa: BLE001 - 原样转述
        fail(f"plist 解析失败：{exc}", 9)


def probe_entries(cfg):
    return [
        e for e in cfg.get("Kernel", {}).get("Add", [])
        if isinstance(e, dict) and str(e.get("BundlePath", "")).startswith("IGPUProbe.kext")
    ]


def bootargs_slot(cfg):
    add = cfg.get("NVRAM", {}).get("Add", {})
    if APPLE_GUID not in add or not isinstance(add[APPLE_GUID], dict) or "boot-args" not in add[APPLE_GUID]:
        fail(f"NVRAM/Add/{APPLE_GUID} 里没有 boot-args", 5)
    others = [
        g for g, kv in add.items()
        if g != APPLE_GUID and isinstance(kv, dict) and "boot-args" in kv
    ]
    if others:
        fail(f"boot-args 还出现在别的 GUID：{', '.join(others)}（拒绝猜测取哪个）", 5)
    return add[APPLE_GUID]["boot-args"]


def nvram_delete_has_bootargs(cfg):
    seq = cfg.get("NVRAM", {}).get("Delete", {}).get(APPLE_GUID)
    return isinstance(seq, list) and any(str(x) == "boot-args" for x in seq)


def tokenize(text):
    for ch in text:
        if _is_bad_control(ch):
            fail(f"boot-args 含控制字符 U+{ord(ch):04X}，拒绝处理", 4)
    trailing = bool(text) and text[-1] in " \t"
    return [t for t in text.replace("\t", " ").split(" ") if t], trailing


def is_related(token):
    return bool(RELATED_RE.match(token))


def is_safe_token(token):
    return bool(SAFE_RE.match(token))


def safe_state(tokens):
    hits = [t for t in tokens if is_safe_token(t)]
    if not hits:
        return "off"
    if len(hits) > 1:
        return "dirty:multiple"
    return "on" if hits[0] == "-x" else f"dirty:{hits[0]}"


def state_report(tokens):
    hits = [t for t in tokens if is_related(t)]
    if not hits:
        return "normal"
    if len(hits) > 1:
        return "dirty:multiple"
    token = hits[0]
    for mode in MODES:
        if token == f"igpu-driver={mode}":
            return mode
    return f"dirty:{token}"


def canonical_args(tokens, trailing, mode, safe):
    kept = [t for t in tokens if not is_related(t) and not is_safe_token(t)]
    if mode != "normal":
        kept.append(f"igpu-driver={mode}")
    if safe == "on":
        kept.append("-x")
    joined = " ".join(kept)
    if trailing and joined:
        joined += " "
    return joined


def is_canonical(original, tokens, trailing, state, safe):
    if state not in MODES or safe not in ("on", "off"):
        return False
    return canonical_args(tokens, trailing, state, safe) == original


def normalized(cfg):
    clone = plistlib.loads(plistlib.dumps(cfg))
    slot = clone.get("NVRAM", {}).get("Add", {}).get(APPLE_GUID)
    if isinstance(slot, dict) and "boot-args" in slot:
        slot["boot-args"] = "<normalized>"
    return clone


def check_probe(cfg):
    probes = probe_entries(cfg)
    if len(probes) != 1:
        fail(f"Kernel/Add 里 IGPUProbe 条目有 {len(probes)} 条，要求恰好 1 条", 3)
    entry = probes[0]
    for key, want in PROBE_EXPECT.items():
        got = entry.get(key)
        if got != want:
            fail(f"probe 条目字段 {key}={got!r}，要求 {want!r}", 3)
    if entry.get("Enabled") is not True:
        fail(f"probe 条目 Enabled={entry.get('Enabled')!r}，必须为 True", 3)
    if not str(entry.get("Comment", "")).strip():
        fail("probe 条目缺 Comment（OpenCore 要求非空）", 3)


def check_deployable(cfg):
    check_probe(cfg)
    original = bootargs_slot(cfg)
    if not isinstance(original, str):
        fail(f"boot-args 不是字符串而是 {type(original).__name__}", 4)
    tokens, trailing = tokenize(original)
    state = state_report(tokens)
    safe = safe_state(tokens)
    if state not in MODES:
        fail(f"boot-args 状态不合法：{state}", 11)
    if safe not in ("on", "off"):
        fail(f"-x（安全模式）状态不合法：{safe}", 11)
    if not is_canonical(original, tokens, trailing, state, safe):
        fail(
            f"boot-args 不是规范串：{original!r}"
            f"（应为 {canonical_args(tokens, trailing, state, safe)!r}）",
            11,
        )
    # N7：OpenCore 的 NVRAM/Add 只在变量不存在时写入；Delete 里没有 boot-args
    # 时，改 boot-args 不会生效。把这一条纳入"可部署"判据，避免 accepted 后
    # 到第二轮 04-state off 才炸。
    if not nvram_delete_has_bootargs(cfg):
        print("deployable=no")
        print("reason=nvram_delete_bootargs")
        fail(
            "NVRAM/Delete 里没有 boot-args —— OpenCore 的 Add 只在变量不存在时写入，"
            "改了也不会生效；请先补 NVRAM/Delete/<GUID>/boot-args",
            12,
        )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--mode", choices=MODES)
    ap.add_argument("--set-x", choices=("on", "off"), help="安全模式：加/去 -x")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--out")
    ap.add_argument("--require-probe", action="store_true")
    ap.add_argument("--require-deployable", action="store_true")
    args = ap.parse_args()

    cfg = load_cfg(args.config)
    if not probe_entries(cfg):
        fail("Kernel/Add 里没有 IGPUProbe.kext 条目 —— 还没部署探针，拒绝改 boot-args", 3)
    wants_write = args.mode is not None or args.set_x is not None
    if args.require_deployable:
        if wants_write:
            # F4：带修改参数时，"先校验"只校验结构（探针条目/字段），
            # boot-args 的规范化说明写路径本来就要修的东西；严格判据放在写入后的回读。
            check_probe(cfg)
        else:
            check_deployable(cfg)
    elif args.require_probe:
        check_probe(cfg)

    original = bootargs_slot(cfg)
    if not isinstance(original, str):
        fail(f"boot-args 不是字符串而是 {type(original).__name__}", 4)
    tokens, trailing = tokenize(original)
    state = state_report(tokens)
    safe = safe_state(tokens)
    canonical = is_canonical(original, tokens, trailing, state, safe)
    probes = probe_entries(cfg)
    print(f"guid={APPLE_GUID}")
    print(f"boot-args={original!r}")
    print(f"state={state}")
    print(f"canonical={'yes' if canonical else 'no'}")
    print(f"safe={safe}")
    print(f"probe_count={len(probes)}")
    print(f"probe_enabled={probes[0].get('Enabled') if len(probes) == 1 else 'n/a'}")
    print(f"nvram_delete_bootargs={'yes' if nvram_delete_has_bootargs(cfg) else 'no'}")

    if not wants_write:
        if args.require_deployable:
            print("deployable=yes")
            return 0
        if args.require_probe:
            print("probe_ok=yes")
            return 0
        if args.check:
            return 0
        fail("要么给 --mode，要么给 --set-x", 2)
    if not nvram_delete_has_bootargs(cfg):
        fail(
            "NVRAM/Delete 里没有 boot-args —— OpenCore 的 Add 只在变量不存在时写入，"
            "改了也不会生效。请先在 config.plist 的 NVRAM/Delete/7C436110-… 里加上 boot-args",
            10,
        )

    target_mode = args.mode if args.mode is not None else state
    if target_mode not in MODES:
        fail(f"当前 igpu-driver 状态不干净（{target_mode}），请先用 --mode 归一化", 11)
    target_safe = args.set_x if args.set_x is not None else safe
    if target_safe not in ("on", "off"):
        fail(f"当前 -x 状态不干净（{target_safe}），请先用 --set-x 归一化", 11)

    new_args = canonical_args(tokens, trailing, target_mode, target_safe)
    if new_args == original:
        print("unchanged=1")
        print(f"state={target_mode}")
        print(f"safe={target_safe}")
        print(f"boot-args={new_args!r}")
        if args.require_deployable:
            check_deployable(cfg)
            print("deployable=yes")
        return 0

    updated = plistlib.loads(plistlib.dumps(cfg))
    updated["NVRAM"]["Add"][APPLE_GUID]["boot-args"] = new_args
    if normalized(cfg) != normalized(updated):
        fail("除 boot-args 外出现其它差异，拒绝写入", 6)

    out = pathlib.Path(args.out or args.config)
    tmp = out.with_suffix(out.suffix + f".new-{os.getpid()}")
    tmp.write_bytes(plistlib.dumps(updated))
    strict_xml(tmp)
    check = plistlib.loads(tmp.read_bytes())
    if len(probe_entries(check)) != len(probes):
        fail("写入后 probe 条目数量变化", 7)
    got = check.get("NVRAM", {}).get("Add", {}).get(APPLE_GUID, {}).get("boot-args")
    if got != new_args:
        fail(f"写入后 boot-args 复核失败：{got!r}", 8)
    tmp.replace(out)

    print(f"new_state={target_mode}")
    print(f"new_safe={target_safe}")
    print(f"new_boot-args={new_args!r}")
    print(f"out={out}")

    # F4：写完必须从磁盘回读，不能只信内存对象；回读状态不符即失败。
    final = load_cfg(out)
    f_tokens, f_trailing = tokenize(bootargs_slot(final))
    f_state = state_report(f_tokens)
    f_safe = safe_state(f_tokens)
    print(f"state={f_state}")
    print(f"safe={f_safe}")
    print(f"boot-args={bootargs_slot(final)!r}")
    if f_state != target_mode:
        fail(f"写入后回读状态是 {f_state}，不是 {target_mode}（磁盘内容可能被外部改动）", 8)
    if target_safe is not None and f_safe != target_safe:
        fail(f"写入后回读 -x 状态是 {f_safe}，不是 {target_safe}", 8)
    if args.require_deployable:
        check_deployable(final)
        print("deployable=yes")
    return 0


if __name__ == "__main__":
    sys.exit(main())