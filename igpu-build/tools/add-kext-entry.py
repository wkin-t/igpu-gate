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
import datetime
import os
import pathlib
import plistlib
import shutil
import sys


def entry_for(name, comment):
    return {
        "Arch": "x86_64",
        "BundlePath": "%s.kext" % name,   # 裸名字：相对 EFI/OC/Kexts/（与真机 config 一致）
        "Comment": comment,
        "Enabled": True,
        "ExecutablePath": "Contents/MacOS/%s" % name,
        "MaxKernel": "",
        "MinKernel": "",
        "PlistPath": "Contents/Info.plist",
    }



def write_config(cfg_path, doc, tag):
    """备份 + 同目录暂存 + 回读校验 + 原子 rename。

    为什么不能直接 open(path,"wb")：那是先截断活动 config 再写，写到一半断电/
    Ctrl-C/磁盘满，OpenCore 就会因为 plist 截断而停在引导 —— 现场无法恢复。
    本 kit 其他写 config 的地方（01-deploy / 04-state / inject-probe）都是这个套路。
    """
    p = pathlib.Path(cfg_path)
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = p.with_name("config-before-%s-%s.plist" % (tag, ts))
    if not backup.exists():
        shutil.copy2(p, backup)
    tmp = p.with_name(".%s.%s.tmp" % (p.name, tag))
    with open(tmp, "wb") as f:
        plistlib.dump(doc, f, fmt=plistlib.FMT_XML, sort_keys=False)
        f.flush()
        os.fsync(f.fileno())
    if plistlib.loads(tmp.read_bytes()) != doc:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise RuntimeError("回读校验失败：%s" % tmp)
    os.replace(tmp, p)
    os.sync()
    print("backup=%s" % backup)

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

    # 兼容两种历史写法：裸名字（正确）与被旧版本写坏的 Kexts/xxx.kext
    bundle = "%s.kext" % a.name
    legacy = "Kexts/%s" % bundle
    hits = [i for i, e in enumerate(adds)
            if isinstance(e, dict) and e.get("BundlePath") in (bundle, legacy)]

    if a.check:
        print("present=%s count=%d" % ("yes" if hits else "no", len(hits)))
        return 0 if hits else 1

    if a.remove:
        if not hits:
            print("nothing-to-remove")
            return 0
        for i in reversed(hits):
            del adds[i]
        write_config(a.config, doc, "loadprobe-remove")
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

    write_config(a.config, doc, "loadprobe")
    return 0



if __name__ == "__main__":
    sys.exit(main())