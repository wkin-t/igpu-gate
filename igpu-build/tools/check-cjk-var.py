#!/usr/bin/env python3
"""扫描 shell 脚本里"未加花括号的变量紧邻非 ASCII 字符"的写法。

为什么需要：macOS 的 bash 3.2 在 C.UTF-8 下会把全角字符的字节并进变量名，
`$VAR（` 会变成变量 `VAR？`，`set -u` 下直接 "unbound variable" 退出。
这个坑在本项目已经踩过三次（onsite 脚本、trip 脚本、IGPUModel/build.sh），
`bash -n` 完全查不出来，所以必须有一道独立的静态门禁。

用法：check-cjk-var.py DIR [DIR...]     退出码 1 = 发现违规
"""

import pathlib
import re
import sys

# 未加花括号的 $VAR 后面紧跟非 ASCII 字符
PATTERN = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7F])")


def shell_files(roots):
    for root in roots:
        p = pathlib.Path(root)
        if p.is_file():
            yield p
            continue
        for f in p.rglob("*"):
            if not f.is_file():
                continue
            if f.suffix in (".sh", ".bash") or f.name in ("macmini-run.sh",):
                yield f


def main(argv):
    if not argv:
        print("用法：check-cjk-var.py DIR [DIR...]")
        return 2
    bad = []
    total = 0
    skipped_comments = 0
    for f in shell_files(argv):
        total += 1
        try:
            text = f.read_text("utf-8", "ignore")
        except OSError as exc:
            print("WARN 读不了 %s：%s" % (f, exc))
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            # 整行注释里的示例不算问题（注释不会被执行），避免门禁被文档噪音拖垮。
            if line.lstrip().startswith("#"):
                skipped_comments += 1
                continue
            for m in PATTERN.finditer(line):
                bad.append("%s:%d: $%s 后面紧跟非 ASCII 字符 —— 请写成 ${%s}"
                           % (f, lineno, m.group(1), m.group(1)))
    print("扫描 %d 个 shell 文件（跳过整行注释 %d 行）" % (total, skipped_comments))
    if bad:
        print("发现 %d 处未加花括号的 CJK 邻接变量：" % len(bad))
        for b in bad:
            print("  " + b)
        print("===== PASS=0  FAIL=%d =====" % len(bad))
        return 1
    print("没有发现 CJK 邻接问题 ✓")
    print("===== PASS=%d  FAIL=0 =====" % total)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))