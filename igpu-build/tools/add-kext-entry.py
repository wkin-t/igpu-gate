#!/usr/bin/env python
"""在 OpenCore 的 config.plist 里加入/移除一个 kext 条目（幂等）。

为什么单独写一个：Phase 2b-A0 要往 OC 配置里加 IGPULoadProbe.kext，
手工编辑 XML 容易破坏其余键；本项目其他脚本也不该被改造成"通用配置编辑器"。

用法：
  add-kext-entry.py --config EFI/OC/config.plist --name IGPULoadProbe
  add-kext-entry.py --config ... --name X --check      # 只检查，0=存在 1=不存在
  add-kext-entry.py --config ... --name X --remove     # 移除
  add-kext-entry.py --config ... --name X --comment "自定义注释"

约定：条目 = Kernel/Add 中的一项，字段固定为我们用过的集合。
"""
import argparse
import plistlib
import sys


def entry_for(name, comment):
    return {
        "Arch": "x86_64",
        "BundlePath": "Kexts/%s.kext" % name,
        "Comment": comment,
        "Enabled": True,
        "ExecutablePath": "Contents/MacOS/%s" % name,
        "MaxKernel": "",
        "MinKernel": "",
        "PlistPath": "Contents/Info.plist",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--comment", default="Phase 2b-A0 load probe")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--remove", action="store_true")
    a = ap.parse_args()

    with open(a.config, "rb") as f:
        doc = plistlib.loads(f.read())

    kernel = doc.setdefault("Kernel", {})
    adds = kernel.setdefault("Add", [])
    if not isinstance(adds, list):
        print("ERROR: Kernel/Add 不是数组", file=sys.stderr)
        return 2

    bundle = "Kexts/%s.kext" % a.name
    hits = [i for i, e in enumerate(adds) if isinstance(e, dict) and e.get("BundlePath") == bundle]

    if a.check:
        print("present=%s count=%d" % ("yes" if hits else "no", len(hits)))
        return 0 if hits else 1

    if a.remove:
        if not hits:
            print("nothing-to-remove")
            return 0
        for i in reversed(hits):
            del adds[i]
        with open(a.config, "wb") as f:
            plistlib.dump(doc, f, fmt=plistlib.FMT_XML, sort_keys=False)
        print("removed %d entry(ies); Kernel/Add now %d" % (len(hits), len(adds)))
        return 0

    if len(hits) > 1:
        print("ERROR: 已有 %d 条重复条目，先移除再添加" % len(hits), file=sys.stderr)
        return 2

    if hits:
        adds[hits[0]] = entry_for(a.name, a.comment)
        print("updated existing entry; Kernel/Add 仍 %d 条" % len(adds))
    else:
        adds.append(entry_for(a.name, a.comment))
        print("appended entry; Kernel/Add 变为 %d 条" % len(adds))

    with open(a.config, "wb") as f:
        plistlib.dump(doc, f, fmt=plistlib.FMT_XML, sort_keys=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())