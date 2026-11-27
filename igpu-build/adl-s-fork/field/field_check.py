#!/usr/bin/env python3
"""Read-only checks and bundle receipt helpers used by adl-s-field.sh."""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import re
import struct
import sys
import uuid
from xml.parsers.expat import ExpatError


def fail(message, code=1):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(code)


def registry_root(path):
    try:
        value = plistlib.loads(pathlib.Path(path).read_bytes())
    except (OSError, ExpatError, ValueError, TypeError) as exc:
        fail(f"unreadable registry plist: {exc}")
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
    try:
        doc = plistlib.loads(pathlib.Path(args.plist).read_bytes())
        if not isinstance(doc, dict):
            raise ValueError("NVRAM plist 根对象不是字典")
        if args.key not in doc:
            print(f"{args.key}=missing")
            return
        value = doc[args.key]
        if not isinstance(value, (bytes, bytearray)):
            raise ValueError("NVRAM 键值不是字节串")
    except (OSError, ExpatError, ValueError, TypeError) as exc:
        print(f"{args.key}=invalid")
        fail(f"NVRAM 数据无效：{exc}")
    print(f"{args.key}={bytes(value).hex()}")


BOOT_GUID_PATTERN = r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}"
BOOT_NUMBER_PATTERN = r"(?:0[xX][0-9A-Fa-f]+|[0-9]+)"
BOOT_HD_TEXT = re.compile(
    rf"HD\(({BOOT_NUMBER_PATTERN}),GPT,({BOOT_GUID_PATTERN}),"
    rf"({BOOT_NUMBER_PATTERN}),({BOOT_NUMBER_PATTERN})\)",
    re.IGNORECASE,
)


def boot_path_text_uuid(text):
    if not text or text != text.strip() or any(ord(ch) < 0x20 for ch in text):
        raise ValueError("启动路径文本为空或含控制字符")
    if text.startswith("/") or text.endswith("/"):
        raise ValueError("启动路径文本首尾分隔符无效")
    segments = text.split("/")
    if any(not seg for seg in segments):
        raise ValueError("启动路径含空路径段")
    found = []
    for segment in segments:
        if segment.upper().startswith("HD(") or "HD(" in segment.upper():
            match = BOOT_HD_TEXT.fullmatch(segment)
            if not match:
                raise ValueError("启动路径含非 GPT 或格式无效的 HD 节点")
            part_num = int(match[1], 0)
            start_lba = int(match[3], 0)
            size_lba = int(match[4], 0)
            parsed = uuid.UUID(match[2])
            if part_num < 1 or start_lba < 0 or size_lba < 1 or parsed.int == 0:
                raise ValueError("GPT HD 节点范围或 UUID 无效")
            found.append(str(parsed).upper())
    if len(found) != 1:
        raise ValueError(f"启动路径必须恰好含 1 个 GPT HD 节点，实际 {len(found)} 个")
    return found[0]


def _is_binary_efi_device_path(data):
    return len(data) >= 4 and data[-4:] == b"\x7f\xff\x04\x00"


def boot_path_binary_uuid(data):
    offset = 0
    total = len(data)
    found = []
    saw_end = False
    while offset < total:
        if offset + 4 > total:
            raise ValueError("二进制 UEFI 设备路径节点头截断")
        dtype, subtype, length = struct.unpack_from("<BBH", data, offset)
        if length < 4 or offset + length > total:
            raise ValueError("二进制 UEFI 设备路径节点长度越界")
        node = data[offset:offset + length]
        offset += length
        if dtype == 0x7F:
            if subtype != 0xFF or length != 4 or offset != total:
                raise ValueError("二进制 UEFI 设备路径结束节点不唯一或含尾部残留")
            saw_end = True
            break
        if dtype == 0x04 and subtype == 0x01:
            if length != 42:
                raise ValueError("Media HardDrive 节点长度不是 42 字节")
            part_num, _part_start, part_size = struct.unpack_from("<IQQ", node, 4)
            mbr_type, sig_type = node[40], node[41]
            parsed = uuid.UUID(bytes_le=node[24:40])
            if part_num < 1 or part_size < 1 or mbr_type != 0x02 or sig_type != 0x02 or parsed.int == 0:
                raise ValueError("Media HardDrive 节点不是有效的非空 GPT 分区")
            found.append(str(parsed).upper())
    if not saw_end or len(found) != 1:
        raise ValueError(f"二进制 UEFI 设备路径必须完整结束且恰好含 1 个 GPT 节点，实际 {len(found)} 个")
    return found[0]


def decode_boot_path_bytes(data):
    if not data:
        raise ValueError("启动路径字节串为空")
    if _is_binary_efi_device_path(data):
        return boot_path_binary_uuid(data)
    if data.startswith(b"\xff\xfe") or (len(data) >= 4 and len(data) % 2 == 0 and b"\x00" in data[:-1]):
        payload = data[2:] if data.startswith(b"\xff\xfe") else data
        if len(payload) % 2 != 0:
            raise ValueError("UTF-16LE 启动路径字节长度为奇数")
        if payload.endswith(b"\x00\x00"):
            payload = payload[:-2]
        if not payload:
            raise ValueError("UTF-16LE 启动路径内容为空")
        text = payload.decode("utf-16-le")
        if "\x00" in text:
            raise ValueError("UTF-16LE 启动路径含内部 NUL")
        return boot_path_text_uuid(text)
    if data.endswith(b"\x00"):
        data = data[:-1]
    if b"\x00" in data:
        raise ValueError("UTF-8 启动路径含内部 NUL")
    return boot_path_text_uuid(data.decode("utf-8-sig"))


def cmd_boot_path(args):
    try:
        value = plistlib.loads(pathlib.Path(args.plist).read_bytes())
        if not isinstance(value, dict) or args.key not in value:
            raise ValueError("NVRAM plist 没有指定的精确键")
        raw = value[args.key]
        if isinstance(raw, (bytes, bytearray)):
            result = decode_boot_path_bytes(bytes(raw))
        elif isinstance(raw, str):
            if "\x00" in raw:
                raise ValueError("启动路径字符串含内部 NUL")
            result = boot_path_text_uuid(raw)
        else:
            raise ValueError("启动路径值类型未知")
    except (OSError, ValueError, TypeError, UnicodeDecodeError, ExpatError) as exc:
        print("boot_esp_uuid=missing")
        fail(f"启动路径只读证据不足：{exc}")
    print(f"boot_esp_uuid={result}")


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


def _walk_bundle_regular_files(bundle):
    if bundle.is_symlink() or not bundle.is_dir():
        fail(f"{bundle} is not a real directory")
    files = {}
    for root, dirs, names in os.walk(bundle, followlinks=False):
        root_path = pathlib.Path(root)
        for dname in dirs:
            if (root_path / dname).is_symlink():
                fail(f"symlink directory inside bundle: {root_path / dname}")
        for fname in names:
            fpath = root_path / fname
            if fpath.is_symlink() or not fpath.is_file():
                fail(f"non-regular file inside bundle: {fpath}")
            rel = fpath.relative_to(bundle).as_posix()
            files[rel] = fpath
    return files


def _is_truncated_plist_prefix(raw):
    stripped = raw.lstrip(b" \t\r\n")
    for magic in (b"<?xml", b"<plist", b"bplist00"):
        candidate = raw if magic == b"bplist00" else stripped
        if candidate.startswith(magic) or magic.startswith(candidate):
            return True
    return False


def cmd_receipt(args):
    bundle = pathlib.Path(args.bundle)
    try:
        receipt = json.loads(pathlib.Path(args.receipt).read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError) as exc:
        fail(f"invalid receipt {args.receipt}: {exc}")
    if not isinstance(receipt, dict) or not isinstance(receipt.get("hashes"), dict) or not receipt["hashes"]:
        fail("receipt hashes missing or empty")
    actual_files = _walk_bundle_regular_files(bundle)
    hashes = receipt["hashes"]
    if args.allow_partial:
        unknown = sorted(set(actual_files.keys()) - set(hashes.keys()))
        if unknown:
            fail(f"partial bundle contains unexpected files: {unknown}")
        if "Contents/Info.plist" in actual_files:
            raw_info = actual_files["Contents/Info.plist"].read_bytes()
            if len(raw_info) > 65536:
                fail("partial Info.plist exceeds reasonable size")
            try:
                info = plistlib.loads(raw_info)
            except (ExpatError, ValueError, TypeError):
                if not _is_truncated_plist_prefix(raw_info):
                    fail("partial Info.plist is not a valid or truncated plist")
                info = None
            if info is not None:
                if not isinstance(info, dict):
                    fail("partial Info.plist root is not a dict")
                if info.get("CFBundleIdentifier") != receipt.get("identifier"):
                    fail("partial Info.plist CFBundleIdentifier differs from receipt")
                if info.get("CFBundleVersion") != receipt.get("version"):
                    fail("partial Info.plist CFBundleVersion differs from receipt")
                if receipt.get("empty_personalities") and info.get("IOKitPersonalities") != {}:
                    fail("partial runtime IOKitPersonalities is not empty")
        print(f"receipt=partial-ok uuid={receipt['uuid']}")
        return
    for relative, expected in hashes.items():
        if relative not in actual_files:
            fail(f"{relative} is missing from {bundle}")
        actual = hashlib.sha256(actual_files[relative].read_bytes()).hexdigest()
        if actual != expected:
            fail(f"{relative} differs from its receipt")
    if receipt.get("strict_files") and set(actual_files.keys()) != set(hashes.keys()):
        fail("bundle contains unexpected or missing files relative to strict receipt")
    if receipt.get("verify_info"):
        if "Contents/Info.plist" not in actual_files:
            fail("Contents/Info.plist missing from bundle")
        try:
            info = plistlib.loads(actual_files["Contents/Info.plist"].read_bytes())
        except (OSError, ExpatError, ValueError, TypeError) as exc:
            fail(f"unreadable Info.plist: {exc}")
        if not isinstance(info, dict):
            fail("Info.plist root is not a dict")
        if info.get("CFBundleIdentifier") != receipt.get("identifier"):
            fail("Info.plist CFBundleIdentifier differs from receipt")
        if info.get("CFBundleVersion") != receipt.get("version"):
            fail("Info.plist CFBundleVersion differs from receipt")
        if receipt.get("empty_personalities") and info.get("IOKitPersonalities") != {}:
            fail("runtime bundle IOKitPersonalities is not empty")
    print(f"receipt=ok uuid={receipt['uuid']}")


def cmd_write_receipt(args):
    bundle = pathlib.Path(args.bundle)
    actual_files = _walk_bundle_regular_files(bundle)
    if "Contents/Info.plist" not in actual_files:
        fail(f"{bundle} lacks Contents/Info.plist")
    if not any(rel.startswith("Contents/MacOS/") for rel in actual_files):
        fail(f"{bundle} lacks executable under Contents/MacOS/")
    try:
        norm_uuid = normalized_uuid(args.uuid)
        info = plistlib.loads(actual_files["Contents/Info.plist"].read_bytes())
    except (OSError, ExpatError, ValueError, TypeError) as exc:
        fail(f"invalid bundle metadata or uuid: {exc}")
    if not isinstance(info, dict):
        fail("Info.plist root is not a dict")
    identifier = info.get("CFBundleIdentifier")
    version = info.get("CFBundleVersion")
    if not isinstance(identifier, str) or not identifier or not isinstance(version, str) or not version:
        fail("Info.plist lacks string CFBundleIdentifier or CFBundleVersion")
    if args.empty_personalities:
        if identifier != "com.apple.driver.AppleIntelTGLGraphics" or version != "16.0.3":
            fail("unexpected runtime identifier or version")
        if info.get("IOKitPersonalities") != {}:
            fail("runtime IOKitPersonalities must be empty")
    hashes = {
        rel: hashlib.sha256(actual_files[rel].read_bytes()).hexdigest()
        for rel in sorted(actual_files)
    }
    record = {
        "bundle": bundle.name,
        "identifier": identifier,
        "version": version,
        "uuid": str(uuid.UUID(norm_uuid)).upper(),
        "strict_files": True,
        "verify_info": True,
        "empty_personalities": bool(args.empty_personalities),
        "hashes": hashes,
    }
    out = pathlib.Path(args.out)
    tmp = out.with_name(out.name + f".tmp-{os.getpid()}")
    tmp.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    tmp.replace(out)
    print(f"receipt_written=ok uuid={record['uuid']}")


IDENTIFIER_PATTERN = r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+"
UUID_PATTERN = r"(?:[0-9A-Fa-f]{32}|[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})"
NUMBER_PATTERN = r"(?:0[xX][0-9A-Fa-f]+|[0-9]+)"
LOADED_HEADER = re.compile(
    r"Index\s+Refs\s+Address\s+Size\s+Wired\s+Name\s+\(Version\)\s+UUID\s+<Linked Against>"
)
LOADED_ROW = re.compile(
    rf"(?P<index>[0-9]+)\s+[0-9]+\s+{NUMBER_PATTERN}\s+{NUMBER_PATTERN}\s+{NUMBER_PATTERN}"
    rf"\s+(?P<identifier>{IDENTIFIER_PATTERN})\s+\([^()\s]+\)\s+(?P<uuid>{UUID_PATTERN})"
    r"(?:\s+<(?:[0-9]+(?:\s+[0-9]+)*)?>)?"
)


def normalized_uuid(value):
    if not re.fullmatch(UUID_PATTERN, value):
        raise ValueError("UUID 必须是完整的 32hex 或标准连字符格式")
    return value.replace("-", "").upper()


def loaded_records(text):
    # 只接受完整数据行；明确表头才足以表达空表，任意空输出不作缺席证据。
    records = []
    indexes = set()
    header = False
    preamble = False
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line == "No variant specified, falling back to release":
            if header or records or preamble:
                raise ValueError("加载清单前缀位置或次数不符")
            preamble = True
            continue
        if LOADED_HEADER.fullmatch(line):
            if header or records:
                raise ValueError("加载清单表头重复或位置不符")
            header = True
            continue
        match = LOADED_ROW.fullmatch(line)
        if not match or int(match["index"]) in indexes:
            raise ValueError("加载清单含未知、截断或重复索引行")
        indexes.add(int(match["index"]))
        records.append((match["identifier"], normalized_uuid(match["uuid"])))
    if not records and not header:
        raise ValueError("加载清单没有完整数据或明确空表头")
    return records


def cmd_loaded(args):
    try:
        if not re.fullmatch(IDENTIFIER_PATTERN, args.identifier):
            raise ValueError("目标 identifier 格式无效")
        expected = normalized_uuid(args.uuid)
        text = pathlib.Path(args.showloaded).read_text(encoding="utf-8")
        records = loaded_records(text)
    except (OSError, ValueError) as exc:
        print("loaded=unknown")
        fail(f"无法确认加载身份：{exc}")
    matches = [item_uuid for identifier, item_uuid in records if identifier == args.identifier]
    if not matches:
        print("loaded=no")
    elif len(matches) > 1:
        print("loaded=duplicate")
    elif matches[0] == expected:
        print("loaded=yes")
    else:
        print("loaded=wrong-uuid")


def cmd_empty_loaded(args):
    try:
        text = pathlib.Path(args.showloaded).read_text(encoding="utf-8")
        records = loaded_records(text)
    except (OSError, ValueError) as exc:
        print("loaded_empty=unknown")
        fail(f"无法确认加载清单为空：{exc}")
    print("loaded_empty=" + ("yes" if not records else "no"))



def inspect_identifiers(text):
    # 仅解析有计数和尺寸边界的完整 fileset；这不是命令成功、批准或 KC 已采用的证明。
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    columns = "magic cputype cpusubtype caps filetype ncmds sizeofcmds flags".split()
    if len(lines) < 3 or lines[0] != "Mach header" or lines[1].split() != columns:
        raise ValueError("inspect 没有受支持的完整 Mach header")
    header = lines[2].split()
    if len(header) != 8 or header[0] not in ("MH_MAGIC_64", "0xfeedfacf") \
            or header[1] not in ("X86_64", "16777223", "0x01000007") \
            or header[4] not in ("FILESET", "12", "0xc"):
        raise ValueError("inspect 不是受支持的 x86_64 fileset")
    if header[2] != "ALL":
        int(header[2], 0)
    int(header[3], 0)
    int(header[7], 0)
    count, total_size = int(header[5]), int(header[6])
    commands = []
    for line in lines[3:]:
        marker = re.fullmatch(r"Load command\s+([0-9]+)", line)
        if marker:
            if int(marker[1]) != len(commands):
                raise ValueError("inspect 的 load command 索引不连续")
            commands.append([])
        elif commands:
            commands[-1].append(line)
        else:
            raise ValueError("inspect 有未归属的命令数据")
    if count < 0 or total_size < 0 or len(commands) != count:
        raise ValueError("inspect 的 load command 计数不完整")
    identifiers = []
    sizes = []
    for body in commands:
        cmd = re.fullmatch(r"cmd\s+(LC_[A-Z0-9_]+)", body[0]) if body else None
        size = re.fullmatch(r"cmdsize\s+([0-9]+)", body[1]) if len(body) > 1 else None
        if not cmd or not size:
            raise ValueError("inspect 的命令字段截断")
        size = int(size[1])
        if cmd[1] == "LC_UUID" and len(body) == 3 and size == 24:
            col_uuid = re.fullmatch(rf"uuid\s+({UUID_PATTERN})", body[2])
            if not col_uuid:
                raise ValueError("inspect 的 collection UUID 无效")
            normalized_uuid(col_uuid[1])
        elif cmd[1] == "LC_FILESET_ENTRY" and len(body) == 6:
            entry = re.fullmatch(rf"entry_id\s+({IDENTIFIER_PATTERN})\s+\(offset 32\)", body[4])
            if not re.fullmatch(rf"vmaddr\s+{NUMBER_PATTERN}", body[2]) \
                    or not re.fullmatch(rf"fileoff\s+{NUMBER_PATTERN}", body[3]) \
                    or not entry or not re.fullmatch(r"reserved\s+0", body[5]):
                raise ValueError("inspect 的 fileset entry 字段不完整")
            if size != ((32 + len(entry[1]) + 1 + 7) // 8) * 8:
                raise ValueError("inspect 的 fileset entry 尺寸不符")
            identifiers.append(entry[1])
        else:
            raise ValueError("inspect 含未知或不完整的 load command")
        sizes.append(size)
    if sum(sizes) != total_size:
        raise ValueError("inspect 的 load command 总尺寸不符")
    return identifiers


NATIVE_COLLECTION_HEADER = re.compile(
    rf"(?P<kind>boot|system|auxiliary) kernel collection at (?P<path>/.+) \((?P<uuid>{UUID_PATTERN})\):"
)


def native_inspect_identifiers(text, expected_path):
    # 使用真实 CI 的 Extension Information 表格格式；路径绑定由调用方显式提供。
    # 解析本身不证明批准或 KC 已采用；shell 必须另外校验命令退出码、系统卷和新 boot。
    collections = {}
    current = None
    information = False
    preamble = False
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line == "No variant specified, falling back to release":
            if current is not None or preamble:
                raise ValueError("inspect 前导提示重复或位置不符")
            preamble = True
            continue
        header = NATIVE_COLLECTION_HEADER.fullmatch(line)
        if header:
            if current is not None and not information:
                raise ValueError("inspect 缺完整的 Extension Information 表头")
            path = header["path"]
            if path in collections:
                raise ValueError("inspect 集合路径重复")
            normalized_uuid(header["uuid"])
            current = path
            collections[current] = []
            information = False
            continue
        if line == "Extension Information:":
            if current is None or information:
                raise ValueError("inspect 表头位置不符")
            information = True
            continue
        if current is None or not information:
            raise ValueError("inspect 没有完整集合边界")
        fields = raw_line.strip("\r\n").split("\t")
        if len(fields) not in (3, 4):
            raise ValueError("inspect 表格行截断或包含未知字段")
        identifier, version, path = (field.strip() for field in fields[:3])
        if not re.fullmatch(IDENTIFIER_PATTERN, identifier) or not version \
                or not path.startswith("/") or "\x00" in path:
            raise ValueError("inspect 组件身份/版本/路径不完整")
        if len(fields) == 4 and fields[3].strip():
            ext_uuid = re.fullmatch(rf"\(({UUID_PATTERN})\)", fields[3].strip())
            if not ext_uuid:
                raise ValueError("inspect 组件 UUID 无效")
            normalized_uuid(ext_uuid[1])
        collections[current].append(identifier)
    if current is None or not information or expected_path not in collections:
        raise ValueError("inspect 没有指定磁盘集合的完整信息")
    return collections[expected_path]


def cmd_absent(args):
    try:
        targets = set(args.identifiers)
        if len(targets) != 2 or any(not re.fullmatch(IDENTIFIER_PATTERN, item) for item in targets):
            raise ValueError("必须提供两个不同且完整的 identifier")
        text = pathlib.Path(args.file).read_text(encoding="utf-8")
        if args.kind == "loaded":
            identifiers = [identifier for identifier, _ in loaded_records(text)]
        elif args.collection_path:
            identifiers = native_inspect_identifiers(text, args.collection_path)
        else:
            identifiers = inspect_identifiers(text)
    except (OSError, ValueError) as exc:
        print("identifiers_absent=unknown")
        fail(f"无法确认组件缺席：{exc}")
    print("identifiers_absent=" + ("no" if targets.intersection(identifiers) else "yes"))


def cmd_controller(args):
    try:
        value = plistlib.loads(pathlib.Path(args.plist).read_bytes())
        pending = list(value) if isinstance(value, list) else [value]
        controllers = []
        while pending:
            node = pending.pop()
            if not isinstance(node, dict) or not isinstance(node.get("IOObjectClass"), str):
                raise ValueError("IORegistry 节点结构无效")
            children = node.get("IORegistryEntryChildren", [])
            if not isinstance(children, list):
                raise ValueError("IORegistry 子节点不是列表")
            pending.extend(children)
            if node["IOObjectClass"] == "ReimsADLManualActivation":
                controllers.append(node)
        if len(controllers) != 1:
            raise ValueError("必须恰好有一个手动控制器")
        node = controllers[0]
        if node.get("ActivationPolicy") != "explicit-root-current-boot-only" \
                or node.get("RuntimeRequested") is not False:
            raise ValueError("控制器策略不符或已请求 runtime")
    except (OSError, ValueError, TypeError, RecursionError, ExpatError) as exc:
        print("controller_ready=no")
        fail(f"控制器只读证据不足：{exc}")
    print("controller_ready=yes")


def cmd_json_field(args):
    try:
        data = json.loads(pathlib.Path(args.json).read_text(encoding="utf-8"))
        if not isinstance(data, dict) or args.field not in data:
            raise ValueError(f"missing field {args.field}")
    except (OSError, ValueError, TypeError) as exc:
        fail(f"cannot read json field {args.field}: {exc}")
    print(data[args.field])


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
            record = json.loads(failure.read_text(encoding="utf-8"))
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
    p = sub.add_parser("boot-path"); p.add_argument("plist"); p.add_argument("key"); p.set_defaults(run=cmd_boot_path)
    p = sub.add_parser("tgl-input"); p.add_argument("bundle"); p.set_defaults(run=cmd_tgl_input)
    p = sub.add_parser("receipt"); p.add_argument("bundle"); p.add_argument("receipt"); p.add_argument("--allow-partial", action="store_true"); p.set_defaults(run=cmd_receipt)
    p = sub.add_parser("write-receipt"); p.add_argument("bundle"); p.add_argument("uuid"); p.add_argument("out"); p.add_argument("--empty-personalities", action="store_true"); p.set_defaults(run=cmd_write_receipt)
    p = sub.add_parser("loaded"); p.add_argument("showloaded"); p.add_argument("identifier"); p.add_argument("uuid"); p.set_defaults(run=cmd_loaded)
    p = sub.add_parser("empty-loaded"); p.add_argument("showloaded"); p.set_defaults(run=cmd_empty_loaded)
    p = sub.add_parser("absent"); p.add_argument("file"); p.add_argument("kind", choices=("loaded", "inspect")); p.add_argument("identifiers", nargs=2); p.add_argument("--collection-path"); p.set_defaults(run=cmd_absent)
    p = sub.add_parser("controller"); p.add_argument("plist"); p.set_defaults(run=cmd_controller)
    p = sub.add_parser("json-field"); p.add_argument("json"); p.add_argument("field"); p.set_defaults(run=cmd_json_field)
    p = sub.add_parser("gfx-path"); p.add_argument("tree"); p.add_argument("expected"); p.set_defaults(run=cmd_gfx_path)
    p = sub.add_parser("hwcaps"); p.add_argument("log"); p.add_argument("--out"); p.set_defaults(run=cmd_hwcaps)
    p = sub.add_parser("p2-outcome"); p.add_argument("plist"); p.add_argument("log"); p.set_defaults(run=cmd_p2_outcome)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
