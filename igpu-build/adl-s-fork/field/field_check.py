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


def cmd_gfx_path(args):
    """Rebuild GFX0's IOService path from `ioreg -p IOService -w0` text.

    IORegistryEntry::getPath joins the same name@location components ioreg
    prints and omits Root and the platform node, so the result compares directly
    with the gate's kPCIPath.
    """
    stack = []
    found = []
    for line in pathlib.Path(args.tree).read_text(errors="replace").splitlines():
        match = re.match(r"^(.*?)\+-o (.+?)  <class ", line)
        if not match:
            continue
        depth = len(match.group(1)) // 2
        del stack[depth:]
        stack.append(match.group(2))
        if re.fullmatch(r"GFX0(@.*)?", match.group(2)):
            found.append("IOService:/" + "/".join(stack[2:]))
    print(f"gfx_path_count={len(found)}")
    print(f"gfx_path={found[0] if found else 'missing'}")
    print("gfx_path_ok=" + ("yes" if found == [args.expected] else "no"))


# Every [IGPU] line is classified; tags overlap (a GuC load failure counts under both).
# Only `fail` decides P2. `warn` words ("disabled", "invalid", ...) also appear in benign
# TGL messages, so they are counted for the reader but never fail the run.
IGPU_TAGS = (
    ("guc", re.compile(r"guc", re.I)),
    ("firmware", re.compile(r"(?i:firmware|wopcm|springboard)|\bME\b")),
    ("fail", re.compile(
        r"(?i:fail|error|panic|timeout|timed out|fatal|unrecoverable|exception|compromised"
        r"|never returned|cannot|unable|mismatch|halted|\bhang\b|\bhung\b)")),
    ("warn", re.compile(r"(?i:invalid|disabled|not enabled|did not|disallowing|not active|\bbad\b)")),
)
FOUND_DEVICE = re.compile(r"Found device with ID (0x[0-9a-fA-F]+), revision (0x[0-9a-fA-F]+)")
PROBE_REJECTED = re.compile(r"\[IGPU\][^\n]*(?:Failing probe|Failed to map Device ID)")


def read_log(path):
    log = pathlib.Path(path)
    return log.read_text(errors="replace") if log.is_file() else ""


def cmd_hwcaps(args):
    """P2 log criteria.

    SKU and L3BankCount come out of P-0002/P-0003, so they only show the patches
    took effect. EU/slice/subslice come from fuses and describe the hardware.
    None of this shows the GPU works: GuC and firmware lines are evidence to read.
    """
    text = read_log(args.log)
    found = FOUND_DEVICE.search(text)
    found_id = found.group(1) if found else "missing"
    found_rev = found.group(2) if found else "missing"
    print(f"found_device_id={found_id}")
    print(f"found_revision={found_rev}")
    found_ok = bool(found) and int(found_id, 16) == 0x46808086 and int(found_rev, 16) == 0x0c

    patch_checks = {"sku": r"HWCAPS - GPU Sku: 2\b", "l3": r"HWCAPS - L3BankCount:\s*4\b"}
    hw_checks = {
        "eu": r"ExecutionUnitCount:\s*32\b",
        "slices": r"NumSlices:\s*1\b",
        "subslices": r"NumSubSlices:\s*4\b",
    }
    missing_patch = [name for name, pattern in patch_checks.items() if not re.search(pattern, text)]
    missing_hw = [name for name, pattern in hw_checks.items() if not re.search(pattern, text)]
    missing = (["found"] if not found_ok else []) + missing_patch + missing_hw
    print(f"hwcaps_missing={','.join(missing)}")
    print("patch_effective=" + ("yes" if not missing_patch else "no"))
    print("hw_topology=" + ("ok" if not missing_hw else "mismatch"))

    lines = re.findall(r"\[IGPU\][^\n]*", text)
    counts = {name: 0 for name, _ in IGPU_TAGS}
    classified = []
    failures = []
    for line in lines:
        tags = [name for name, pattern in IGPU_TAGS if pattern.search(line)]
        for tag in tags:
            counts[tag] += 1
        if "fail" in tags:
            failures.append(line)
        classified.append(f"{','.join(tags) or 'other'}\t{line.rstrip()}")
    if args.out:
        pathlib.Path(args.out).write_text("".join(entry + "\n" for entry in classified), encoding="utf-8")
    print(f"igpu_lines={len(lines)}")
    print(f"igpu_guc={counts['guc']}")
    print(f"igpu_firmware={counts['firmware']}")
    print(f"igpu_fail={counts['fail']}")
    print(f"igpu_warn={counts['warn']}")
    version = re.search(r"Graphics Firmware Version: ([0-9.]+)", text)
    print(f"firmware_version={version.group(1) if version else 'not-seen'}")
    for line in failures[:20]:
        print(f"igpu_fail_line={line.strip()}")
    print("hwcaps=" + ("ok" if not missing and not failures else "mismatch"))


def collect_class(node, name):
    found = [node] if node.get("IOObjectClass") == name else []
    for child in node.get("IORegistryEntryChildren", []):
        found.extend(collect_class(child, name))
    return found


def cmd_p2_outcome(args):
    """Where the accelerator stopped: session failure record first, then registry state."""
    text = read_log(args.log)
    print("p2_probe_entered=" + ("yes" if FOUND_DEVICE.search(text) else "no"))
    failure = pathlib.Path(args.log).with_name("failure.json")
    if failure.is_file():
        try:
            record = json.loads(failure.read_text())
        except ValueError:
            record = {}
        if record.get("stage") == "preflight":
            print("p2_outcome=preflight-failed")
            return
        if record.get("outcome"):
            print(f"p2_outcome={record['outcome']}")
            return
    try:
        value = plistlib.loads(pathlib.Path(args.plist).read_bytes())
        root = value[0] if isinstance(value, list) else value
        accelerators = collect_class(root, "IntelAccelerator")
    except Exception:
        print("p2_outcome=unknown")
        return
    if not accelerators:
        # Attach precedes start, so an instance that is gone was rejected or returned false.
        late = FOUND_DEVICE.search(text) and not PROBE_REJECTED.search(text)
        print("p2_outcome=" + ("start-failed" if late else "probe-failed"))
    elif any(entry.get("IOServiceState", 0) & 2 for entry in accelerators):
        print("p2_outcome=published")
    elif len(accelerators) == 1 and not accelerators[0].get("IOServiceState", 0) & 1 \
            and root.get("IOServiceBusyState") == 0:
        print("p2_outcome=start-returned")
    else:
        print("p2_outcome=start-stuck")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("gfx"); p.add_argument("plist"); p.set_defaults(run=cmd_gfx)
    p = sub.add_parser("nvdata"); p.add_argument("plist"); p.add_argument("key"); p.set_defaults(run=cmd_nvdata)
    p = sub.add_parser("tgl-input"); p.add_argument("bundle"); p.set_defaults(run=cmd_tgl_input)
    p = sub.add_parser("receipt"); p.add_argument("bundle"); p.add_argument("receipt"); p.set_defaults(run=cmd_receipt)
    p = sub.add_parser("loaded"); p.add_argument("showloaded"); p.add_argument("identifier"); p.add_argument("uuid"); p.set_defaults(run=cmd_loaded)
    p = sub.add_parser("json-field"); p.add_argument("json"); p.add_argument("field"); p.set_defaults(run=cmd_json_field)
    p = sub.add_parser("gfx-path"); p.add_argument("tree"); p.add_argument("expected"); p.set_defaults(run=cmd_gfx_path)
    p = sub.add_parser("hwcaps"); p.add_argument("log"); p.add_argument("--out"); p.set_defaults(run=cmd_hwcaps)
    p = sub.add_parser("p2-outcome"); p.add_argument("plist"); p.add_argument("log"); p.set_defaults(run=cmd_p2_outcome)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
