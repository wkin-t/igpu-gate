#!/usr/bin/env python3
"""Read-only checks used by adl-s-field.sh. Each subcommand prints key=value lines."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import sys


def fail(message, code=1):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(code)


def registry_root(path):
    value = plistlib.loads(pathlib.Path(path).read_bytes())
    if isinstance(value, list):
        if len(value) != 1:
            fail(f"expected one GFX0 registry root, found {len(value)}")
        value = value[0]
    if not isinstance(value, dict):
        fail("registry root is not a dict")
    return value


def count_class(node, name):
    total = 1 if node.get("IOObjectClass") == name else 0
    for child in node.get("IORegistryEntryChildren", []):
        total += count_class(child, name)
    return total


def cmd_gfx(args):
    root = registry_root(args.plist)
    print(f"device_id={bytes(root.get('device-id', b'')).hex()}")
    print(f"revision_id={bytes(root.get('revision-id', b'')).hex()}")
    print(f"vendor_id={bytes(root.get('vendor-id', b'')).hex()}")
    for label, name in (
        ("firmware_fb", "IONDRVFramebuffer"),
        ("accelerator", "IntelAccelerator"),
        ("desktop_link", "ReimsADLDesktopLink"),
        ("native_fb", "ReimsIntelADLFramebuffer"),
    ):
        print(f"{label}={count_class(root, name)}")


def cmd_nvdata(args):
    value = plistlib.loads(pathlib.Path(args.plist).read_bytes()).get(args.key)
    print(f"{args.key}={bytes(value).hex() if isinstance(value, (bytes, bytearray)) else 'missing'}")


def cmd_tgl_input(args):
    bundle = pathlib.Path(args.bundle)
    binary = bundle / "Contents/MacOS/AppleIntelTGLGraphics"
    info_path = bundle / "Contents/Info.plist"
    if not binary.is_file() or not info_path.is_file():
        fail(f"{bundle} lacks the executable or Info.plist")
    info = plistlib.loads(info_path.read_bytes())
    identifier = info.get("CFBundleIdentifier")
    if identifier != "com.apple.driver.AppleIntelTGLGraphics":
        fail(f"unexpected CFBundleIdentifier {identifier!r}")
    if info.get("CFBundleVersion") != "16.0.0":
        fail(f"unexpected CFBundleVersion {info.get('CFBundleVersion')!r}")
    print("tgl_input=ok")


def cmd_receipt(args):
    bundle = pathlib.Path(args.bundle)
    receipt = json.loads(pathlib.Path(args.receipt).read_text())
    for relative, expected in receipt["hashes"].items():
        actual = hashlib.sha256((bundle / relative).read_bytes()).hexdigest()
        if actual != expected:
            fail(f"{relative} differs from its receipt")
    print(f"receipt=ok uuid={receipt['uuid']}")


def cmd_loaded(args):
    text = pathlib.Path(args.showloaded).read_text(errors="replace")
    expected = args.uuid.upper().replace("-", "")
    lines = [line for line in text.splitlines() if args.identifier in line]
    if not lines:
        print("loaded=no")
    elif len(lines) > 1:
        print("loaded=duplicate")
    elif expected in lines[0].upper().replace("-", ""):
        print("loaded=yes")
    else:
        print("loaded=wrong-uuid")


def cmd_json_field(args):
    print(json.loads(pathlib.Path(args.json).read_text())[args.field])


def cmd_hwcaps(args):
    text = pathlib.Path(args.log).read_text(errors="replace")
    checks = {
        "sku": r"HWCAPS - GPU Sku: 2\b",
        "eu": r"ExecutionUnitCount:\s*32\b",
        "slices": r"NumSlices:\s*1\b",
        "subslices": r"NumSubSlices:\s*4\b",
        "l3": r"HWCAPS - L3BankCount:\s*4\b",
    }
    bad = re.findall(r"\[IGPU\][^\n]*(?:ERROR|Failed to map|invalid Gfx SKU|initHardwareCapsFailed)[^\n]*", text)
    missing = [name for name, pattern in checks.items() if not re.search(pattern, text)]
    print(f"hwcaps_missing={','.join(missing)}")
    print(f"hwcaps_errors={len(bad)}")
    for line in bad[:10]:
        print(f"hwcaps_error_line={line.strip()}")
    print("hwcaps=" + ("ok" if not missing and not bad else "mismatch"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("gfx"); p.add_argument("plist"); p.set_defaults(run=cmd_gfx)
    p = sub.add_parser("nvdata"); p.add_argument("plist"); p.add_argument("key"); p.set_defaults(run=cmd_nvdata)
    p = sub.add_parser("tgl-input"); p.add_argument("bundle"); p.set_defaults(run=cmd_tgl_input)
    p = sub.add_parser("receipt"); p.add_argument("bundle"); p.add_argument("receipt"); p.set_defaults(run=cmd_receipt)
    p = sub.add_parser("loaded"); p.add_argument("showloaded"); p.add_argument("identifier"); p.add_argument("uuid"); p.set_defaults(run=cmd_loaded)
    p = sub.add_parser("json-field"); p.add_argument("json"); p.add_argument("field"); p.set_defaults(run=cmd_json_field)
    p = sub.add_parser("hwcaps"); p.add_argument("log"); p.set_defaults(run=cmd_hwcaps)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
