#!/usr/bin/env python3
"""向 OpenCore config.plist 注入 IGPUProbe 探针条目（最小编辑、可审计）。

设计要点：
  · 单一真源：严格 XML 校验、加载器、探针字段期望值全部从 tools/set-bootargs.py 按路径导入，
    不复制实现（importlib 按文件加载，因为文件名带连字符不能直接 import）；
  · 最小编辑：只做两件事 —— 向 Kernel/Add 追加恰好一条条目、确保 NVRAM/Delete/<GUID> 含 boot-args；
    不重建数组、不删除再插入、不改其它 key；
  · 幂等：已存在且逐字段相同 ⇒ 不写盘，打印 idempotent=1；
  · 拒绝覆盖：已存在但字段不同 / 多于一条 ⇒ 非零退出，交给人工判断（避免静默改坏配置）；
  · 原子写：写临时文件 → 严格复核 → rename 覆盖 → 回读复核；任一步失败原文件不变。

退出码：0 成功或幂等；2 用法；3 配置结构异常（Kernel/Add 缺失/非数组、Delete 非数组）；
        4 已存在多条探针条目；5 已存在但字段不同；6 写入或回读校验失败；7 出现预期外差异。
"""
import argparse
import copy
import importlib.util
import json
import os
import pathlib
import plistlib
import sys

def _load_setter():
    """按路径加载同目录的 set-bootargs.py（单一真源），返回模块对象。"""
    path = pathlib.Path(__file__).resolve().with_name("set-bootargs.py")
    spec = importlib.util.spec_from_file_location("igpu_set_bootargs", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"无法加载 {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


SB = _load_setter()

# 期望条目 = setter 的 PROBE_EXPECT（BundlePath/ExecutablePath/PlistPath/Arch/MinKernel/MaxKernel）
# + OpenCore 必需的 Enabled/Comment。**不加 Phase-1 现场没有的键**（否则幂等判定会把现网配置判成"不同"）。
EXPECT = dict(SB.PROBE_EXPECT)
EXPECT["Enabled"] = True
EXPECT["Comment"] = "IGPUProbe Phase-1 probe"


def fail(msg, code):
    print(f"ERROR: {msg}", file=sys.stderr)
    return code


def entry_matches(entry):
    """逐字段比较；键集合也必须一致（多键少键都算不同，避免静默接受未知改动）。"""
    if set(entry.keys()) != set(EXPECT.keys()):
        return False, f"键集合不同：现网={sorted(entry.keys())} 期望={sorted(EXPECT.keys())}"
    for key, want in EXPECT.items():
        got = entry.get(key)
        if got != want:
            return False, f"{key}={got!r}，期望 {want!r}"
    return True, ""


def strip_managed(cfg, ignore_bootargs=False):
    """复制一份，抹掉本工具负责的两处（探针条目、Delete 里的 boot-args），用于"其它内容未变"比较。

    ignore_bootargs=True 时额外把 boot-args 的**值**也抹掉：事务化重新注入会同时改
    探针条目与 boot-args（归一到 normal），比较"其它 key 未变"时必须忽略这两处。
    """
    clone = copy.deepcopy(cfg)
    kernel = clone.get("Kernel")
    if isinstance(kernel, dict):
        add = kernel.get("Add")
        if isinstance(add, list):
            kernel["Add"] = [
                e for e in add
                if not (isinstance(e, dict) and str(e.get("BundlePath", "")).startswith("IGPUProbe.kext"))
            ]
    nvram = clone.get("NVRAM")
    if isinstance(nvram, dict):
        delete = nvram.get("Delete")
        if isinstance(delete, dict):
            seq = delete.get(SB.APPLE_GUID)
            if isinstance(seq, list):
                left = [x for x in seq if str(x) != "boot-args"]
                if left:
                    delete[SB.APPLE_GUID] = left
                else:
                    delete.pop(SB.APPLE_GUID, None)
            if not delete:
                nvram.pop("Delete", None)
    if ignore_bootargs:
        slot = clone.get("NVRAM", {}).get("Add", {}).get(SB.APPLE_GUID)
        if isinstance(slot, dict) and "boot-args" in slot:
            slot["boot-args"] = "<ignored>"
    return clone


def ensure_delete(cfg):
    """确保 NVRAM/Delete/<GUID> 是数组且含 boot-args；返回是否发生了修改。"""
    nvram = cfg.get("NVRAM")
    if nvram is None:
        cfg["NVRAM"] = {}
        nvram = cfg["NVRAM"]
    if not isinstance(nvram, dict):
        raise ValueError("NVRAM 不是 dict")
    delete = nvram.get("Delete")
    if delete is None:
        nvram["Delete"] = {}
        delete = nvram["Delete"]
    if not isinstance(delete, dict):
        raise ValueError("NVRAM/Delete 不是 dict")
    seq = delete.get(SB.APPLE_GUID)
    if seq is None:
        delete[SB.APPLE_GUID] = ["boot-args"]
        return True
    if not isinstance(seq, list):
        raise ValueError("NVRAM/Delete/<GUID> 不是数组")
    if not any(str(x) == "boot-args" for x in seq):
        seq.append("boot-args")
        return True
    return False


def run(argv):
    ap = argparse.ArgumentParser(description="注入 IGPUProbe 探针条目（最小编辑）")
    ap.add_argument("--config")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--verify-staged", metavar="STAGED", help="只校验暂存副本，不写盘")
    ap.add_argument("--orig", metavar="ORIG", help="与 --verify-staged 配套的改前配置")
    ap.add_argument("--expect-state", choices=SB.MODES, help="与 --verify-staged 配套：要求 boot-args 状态")
    args = ap.parse_args(argv)

    if args.verify_staged:
        if not args.orig:
            return fail("--verify-staged 需要 --orig（改前配置路径）", 2)
        staged = SB.load_cfg(args.verify_staged)
        orig = SB.load_cfg(args.orig)
        probes = [e for e in staged.get("Kernel", {}).get("Add", [])
                  if isinstance(e, dict) and str(e.get("BundlePath", "")).startswith("IGPUProbe.kext")]
        if len(probes) != 1:
            return fail(f"staged 里探针条目={len(probes)}，要求恰好 1", 6)
        ok, why = entry_matches(probes[0])
        if not ok:
            return fail(f"staged 探针字段不符：{why}", 6)
        if not SB.nvram_delete_has_bootargs(staged):
            return fail("staged 的 NVRAM/Delete 不含 boot-args（OC 的 Add 不会生效）", 6)
        if strip_managed(staged, True) != strip_managed(orig, True):
            tmp1 = strip_managed(staged, True)
            tmp2 = strip_managed(orig, True)
            diff = [k for k in set(tmp1) | set(tmp2) if tmp1.get(k) != tmp2.get(k)]
            return fail(f"staged 除探针条目/boot-args 外还有改动：{sorted(diff)[:5]}", 7)
        if args.expect_state:
            raw = SB.bootargs_slot(staged)
            tokens, trailing = SB.tokenize(raw)
            state = SB.state_report(tokens)
            safe = SB.safe_state(tokens)
            if state != args.expect_state:
                return fail(f"staged state={state}，要求 {args.expect_state}", 8)
            if safe not in ("on", "off"):
                return fail(f"staged -x 状态不干净：{safe}", 8)
            if not SB.is_canonical(raw, tokens, trailing, state, safe):
                return fail(f"staged boot-args 不是规范串：{raw!r}", 8)
        print("verified=1")
        print("probe_count=1")
        if args.expect_state:
            print(f"state={args.expect_state}")
        return 0

    if not args.config:
        return fail("要么给 --config，要么给 --verify-staged", 2)
    cfg_path = pathlib.Path(args.config)
    cfg = SB.load_cfg(cfg_path)          # 内部已做严格 XML 校验；失败走 setter 的退出码 9

    kernel = cfg.get("Kernel")
    if not isinstance(kernel, dict):
        return fail("配置里没有 Kernel 字典", 3)
    add = kernel.get("Add")
    if not isinstance(add, list):
        return fail("Kernel/Add 不存在或不是数组", 3)

    probes = [e for e in add if isinstance(e, dict) and str(e.get("BundlePath", "")).startswith("IGPUProbe.kext")]
    if len(probes) > 1:
        return fail(f"Kernel/Add 里已有 {len(probes)} 条 IGPUProbe 条目，拒绝继续（请人工清理）", 4)

    changed = False
    if len(probes) == 1:
        ok, why = entry_matches(probes[0])
        if not ok:
            return fail(f"已存在探针条目但与期望不同：{why}（拒绝覆盖）", 5)
    else:
        add.append(dict(EXPECT))
        changed = True

    try:
        delete_changed = ensure_delete(cfg)
    except ValueError as exc:
        return fail(str(exc), 3)
    changed = changed or delete_changed

    if args.dry_run:
        print("dry_run=1")
        print("probe_entry=" + json.dumps(dict(EXPECT), ensure_ascii=False, sort_keys=True))
        print(f"delete_change={'yes' if delete_changed else 'no'}")
        print(f"would_write={'yes' if changed else 'no'}")
        return 0

    if not changed:
        print("idempotent=1")
        print("probe_count=1")
        print("delete_bootargs=yes")
        print(f"out={cfg_path}")
        return 0

    # 写入前快照（抹掉受管项），用于"其它内容未变"校验
    before = strip_managed(SB.load_cfg(cfg_path))

    tmp = cfg_path.with_suffix(cfg_path.suffix + f".inj-{os.getpid()}")
    try:
        tmp.write_bytes(plistlib.dumps(cfg))
        SB.strict_xml(tmp)
        reloaded = SB.load_cfg(tmp)
        if strip_managed(reloaded) != before:
            tmp.unlink(missing_ok=True)
            return fail("写入内容出现预期外差异（除探针条目/Delete 外有改动），已放弃", 7)
        got = [e for e in reloaded.get("Kernel", {}).get("Add", [])
               if isinstance(e, dict) and str(e.get("BundlePath", "")).startswith("IGPUProbe.kext")]
        if len(got) != 1:
            tmp.unlink(missing_ok=True)
            return fail(f"写入后探针条目数={len(got)}，期望 1", 6)
        ok, why = entry_matches(got[0])
        if not ok:
            tmp.unlink(missing_ok=True)
            return fail(f"写入后条目复核失败：{why}", 6)
        try:
            tmp.replace(cfg_path)
        except OSError as exc:
            tmp.unlink(missing_ok=True)
            return fail(f"rename 覆盖失败：{exc}（原文件未变）", 6)
    except OSError as exc:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        return fail(f"写入失败：{exc}（原文件未变）", 6)

    # 覆盖后再从磁盘回读一次（不信内存对象）
    final = SB.load_cfg(cfg_path)
    got = [e for e in final.get("Kernel", {}).get("Add", [])
           if isinstance(e, dict) and str(e.get("BundlePath", "")).startswith("IGPUProbe.kext")]
    if len(got) != 1 or not entry_matches(got[0])[0] or not SB.nvram_delete_has_bootargs(final):
        return fail("覆盖后回读复核失败（请检查 config.plist）", 6)

    print("injected=1")
    print("probe_count=1")
    print("delete_bootargs=yes")
    print(f"probe_entry={json.dumps(dict(EXPECT), ensure_ascii=False, sort_keys=True)}")
    print(f"out={cfg_path}")
    return 0


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))