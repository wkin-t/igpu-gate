#!/usr/bin/env python3
"""公开 CLI 的离线契约测试；字面文本夹具不是 25G83 真机采样。"""
import contextlib
import importlib.util
import io
import json
import pathlib
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "field_check.py"
SPEC = importlib.util.spec_from_file_location("field_check_test_target", SCRIPT)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)

TGL_ID = "com.apple.driver.AppleIntelTGLGraphics"
GATE_ID = "lab.reims.ReimsADLManualActivation"
UUID = "BBBB0000-0000-0000-0000-000000000002"
NEAR_ID_LINE = (
    "  1 0 0 0 0 com.apple.driver.AppleIntelTGLGraphics.Helper (16.0.3) "
    "BBBB0000-0000-0000-0000-000000000002 <1>\n"
)
LOADED_HEADER = "Index Refs Address Size Wired Name (Version) UUID <Linked Against>\n"
TARGET_LINE = (
    "  1 0 0x1000 0x2000 0x2000 com.apple.driver.AppleIntelTGLGraphics (16.0.3) "
    "BBBB0000-0000-0000-0000-000000000002 <1>\n"
)
OTHER_LINE = (
    "  2 1 0x3000 0x1000 0x1000 com.apple.driver.Other (1.0) "
    "CCCC0000-0000-0000-0000-000000000009 <1 2>\n"
)


def invoke(*arguments, text="", data=b"", read_error=None):
    output = io.StringIO()
    errors = io.StringIO()
    status = 0
    with patch.object(sys, "argv", [str(SCRIPT), *arguments]), \
            patch("pathlib.Path.read_text", return_value=text, side_effect=read_error), \
            patch("pathlib.Path.read_bytes", return_value=data, side_effect=read_error), \
            contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
        try:
            CHECK.main()
        except SystemExit as exc:
            status = exc.code or 0
    return status, output.getvalue().strip(), errors.getvalue().strip()


class LoadedTests(unittest.TestCase):
    def assert_unknown(self, **fixture):
        status, output, _ = invoke("loaded", "fixture.txt", TGL_ID, UUID, **fixture)
        self.assertNotEqual(status, 0)
        self.assertEqual(output, "loaded=unknown")

    def test_near_identifier_cannot_load_target(self):
        status, output, _ = invoke("loaded", "fixture.txt", TGL_ID, UUID, text=NEAR_ID_LINE)
        self.assertEqual((status, output), (0, "loaded=no"))

    def test_exact_identity_is_loaded(self):
        status, output, _ = invoke("loaded", "fixture.txt", TGL_ID, UUID, text=TARGET_LINE)
        self.assertEqual((status, output), (0, "loaded=yes"))

    def test_standard_uuid_forms_and_case_are_accepted(self):
        for expected in ("bbbb0000000000000000000000000002", UUID.lower()):
            with self.subTest(uuid=expected):
                status, output, _ = invoke("loaded", "fixture.txt", TGL_ID, expected, text=TARGET_LINE)
                self.assertEqual((status, output), (0, "loaded=yes"))

    def test_wrong_uuid_is_not_loaded(self):
        status, output, _ = invoke("loaded", "fixture.txt", TGL_ID,
                                   "AAAA0000-0000-0000-0000-000000000001", text=TARGET_LINE)
        self.assertEqual((status, output), (0, "loaded=wrong-uuid"))

    def test_duplicate_identity_is_not_loaded(self):
        second = TARGET_LINE.replace("  1 0 ", "  2 0 ")
        status, output, _ = invoke("loaded", "fixture.txt", TGL_ID, UUID, text=TARGET_LINE + second)
        self.assertEqual((status, output), (0, "loaded=duplicate"))

    def test_invalid_expected_uuid_is_unknown(self):
        for expected in ("", "BBBB", "G" * 32, "B" * 33,
                         "BBBB-0000000000000000000000000002", "{" + UUID + "}"):
            with self.subTest(uuid=expected):
                status, output, _ = invoke("loaded", "fixture.txt", TGL_ID, expected, text=TARGET_LINE)
                self.assertNotEqual(status, 0)
                self.assertEqual(output, "loaded=unknown")

    def test_bad_record_uuid_is_unknown(self):
        self.assert_unknown(text=TARGET_LINE.replace(UUID, "not-a-uuid"))

    def test_empty_output_is_unknown(self):
        self.assert_unknown(text=" \r\n")

    def test_explicit_empty_header_is_not_loaded(self):
        status, output, _ = invoke("loaded", "fixture.txt", TGL_ID, UUID, text=LOADED_HEADER)
        self.assertEqual((status, output), (0, "loaded=no"))

    def test_unknown_option_is_unknown(self):
        self.assert_unknown(text="Unknown option '--show-aux'\n")

    def test_truncated_or_extra_record_is_unknown(self):
        self.assert_unknown(text=TARGET_LINE + "3 0 0 incomplete\n")

    def test_uuid_in_unparsed_suffix_cannot_pass(self):
        self.assert_unknown(text=TARGET_LINE.rstrip() + " " + UUID + "\n")

    def test_read_failure_is_unknown(self):
        self.assert_unknown(read_error=OSError("fixture unreadable"))


class AbsentLoadedTests(unittest.TestCase):
    def assert_result(self, text, result, status=0, **fixture):
        actual_status, output, _ = invoke("absent", "fixture.txt", "loaded", TGL_ID, GATE_ID,
                                          text=text, **fixture)
        self.assertEqual((actual_status, output), (status, "identifiers_absent=" + result))

    def test_unrelated_and_near_identifiers_are_absent(self):
        self.assert_result(OTHER_LINE + NEAR_ID_LINE, "yes")

    def test_any_target_uuid_is_present(self):
        for line in (TARGET_LINE,
                     TARGET_LINE.replace(UUID, "AAAA0000-0000-0000-0000-000000000001"),
                     TARGET_LINE.replace(TGL_ID, GATE_ID)):
            with self.subTest(line=line):
                self.assert_result(line, "no")

    def test_explicit_empty_table_is_absent(self):
        self.assert_result(LOADED_HEADER, "yes")

    def test_empty_error_and_truncated_output_are_unknown(self):
        for text in ("", " \r\n", "Unknown option '--show-aux'\n",
                     "Auxiliary collection metadata\n", OTHER_LINE + "3 0 incomplete\n"):
            with self.subTest(text=text):
                self.assert_result(text, "unknown", status=1)

    def test_invalid_query_identity_is_unknown(self):
        for ids in (("", GATE_ID), (TGL_ID, TGL_ID), (TGL_ID + " ", GATE_ID)):
            with self.subTest(ids=ids):
                status, output, _ = invoke("absent", "fixture.txt", "loaded", *ids, text=OTHER_LINE)
                self.assertEqual((status, output), (1, "identifiers_absent=unknown"))

    def test_read_failure_is_unknown(self):
        self.assert_result("", "unknown", status=1, read_error=OSError("fixture unreadable"))


# 人工 Mach-O fileset 字面夹具；命令数、总尺寸和每个 entry 的边界明确，非 kmutil 真机输出。
INSPECT_OTHER = """Mach header
magic cputype cpusubtype caps filetype ncmds sizeofcmds flags
MH_MAGIC_64 X86_64 ALL 0x00 FILESET 2 80 0x00000000
Load command 0
cmd LC_UUID
cmdsize 24
uuid BBBB0000-0000-0000-0000-000000000002
Load command 1
cmd LC_FILESET_ENTRY
cmdsize 56
vmaddr 0xffffff8000100000
fileoff 0x1000
entry_id com.apple.driver.Other (offset 32)
reserved 0
"""
INSPECT_EMPTY = """Mach header
magic cputype cpusubtype caps filetype ncmds sizeofcmds flags
MH_MAGIC_64 X86_64 ALL 0x00 FILESET 0 0 0x00000000
"""


class AbsentInspectTests(unittest.TestCase):
    def assert_result(self, text, result, status=0):
        actual_status, output, _ = invoke("absent", "fixture.txt", "inspect", TGL_ID, GATE_ID, text=text)
        self.assertEqual((actual_status, output), (status, "identifiers_absent=" + result))

    def test_complete_fileset_without_targets_is_absent(self):
        self.assert_result(INSPECT_OTHER, "yes")

    def test_any_target_identifier_is_present(self):
        for identifier in (TGL_ID, GATE_ID):
            with self.subTest(identifier=identifier):
                text = INSPECT_OTHER.replace("FILESET 2 80", "FILESET 2 96")
                text = text.replace("cmdsize 56", "cmdsize 72").replace("com.apple.driver.Other", identifier)
                self.assert_result(text, "no")

    def test_explicit_empty_fileset_is_absent(self):
        self.assert_result(INSPECT_EMPTY, "yes")

    def test_markers_and_loaded_rows_are_not_collection_proof(self):
        for text in ("", "Mach header\n", "LC_FILESET_ENTRY\n",
                     "Auxiliary collection metadata\n", LOADED_HEADER + OTHER_LINE):
            with self.subTest(text=text):
                self.assert_result(text, "unknown", status=1)

    def test_truncated_command_or_count_mismatch_is_unknown(self):
        for text in (INSPECT_OTHER.replace("reserved 0\n", ""),
                     INSPECT_OTHER.replace("FILESET 2 80", "FILESET 3 80"),
                     INSPECT_OTHER.replace("Load command 1", "Load command 2")):
            with self.subTest(text=text):
                self.assert_result(text, "unknown", status=1)

    def test_size_and_identifier_boundaries_are_required(self):
        for text in (INSPECT_OTHER.replace("cmdsize 56", "cmdsize 48"),
                     INSPECT_OTHER.replace("FILESET 2 80", "FILESET 2 88"),
                     INSPECT_OTHER.replace("(offset 32)", "(offset 64)"),
                     INSPECT_OTHER.replace("entry_id com.apple.driver.Other", "entry_id")):
            with self.subTest(text=text):
                self.assert_result(text, "unknown", status=1)

    def test_unknown_command_or_trailing_error_is_unknown(self):
        for text in (INSPECT_OTHER.replace("LC_UUID", "LC_UNKNOWN"),
                     INSPECT_OTHER + "Unknown option '--show-aux'\n",
                     INSPECT_OTHER + INSPECT_EMPTY):
            with self.subTest(text=text):
                self.assert_result(text, "unknown", status=1)


# 字段顺序和前导提示取自 macOS CI 43634707261 的真实输出；只替换集合路径。
# CI 为 ARM，以下是格式回归，不宣称 Intel 25G83 的 AuxKC 已被验证。
NATIVE_INSPECT = """No variant specified, falling back to release
boot kernel collection at /fixtures/kernelcache (B0FC4415-99A9-D729-15CB-B6F66E8A2E26):
Extension Information:
com.apple.iokit.IOBufferCopyEngineFamily\t1\t/System/Library/Extensions/IOBufferCopyEngineFamily.kext\t(FB4D2E02-BC9F-39FE-B73F-61EDB9363D5B)
com.apple.driver.usb.IOUSBHostHIDDeviceSafeBoot\t1.2\t/System/Library/Extensions/IOUSBHostFamily.kext/Contents/PlugIns/IOUSBHostHIDDeviceSafeBoot.kext\t
"""


class NativeInspectTests(unittest.TestCase):
    def result(self, text, expected, status=0, path="/fixtures/kernelcache"):
        actual, output, _ = invoke("absent", "fixture.txt", "inspect", TGL_ID, GATE_ID,
                                   "--collection-path", path, text=text)
        self.assertEqual((actual, output), (status, "identifiers_absent=" + expected))

    def test_native_extension_information_can_prove_absence(self):
        self.result(NATIVE_INSPECT, "yes")

    def test_target_in_native_information_is_not_absent(self):
        self.result(NATIVE_INSPECT.replace("com.apple.iokit.IOBufferCopyEngineFamily", TGL_ID), "no")

    def test_wrong_collection_path_is_unknown(self):
        self.result(NATIVE_INSPECT, "unknown", 1, "/not/the/collection")

    def test_missing_information_header_or_bad_row_is_unknown(self):
        for text in (NATIVE_INSPECT.replace("Extension Information:\n", ""),
                     NATIVE_INSPECT + "partial row\n",
                     NATIVE_INSPECT.replace("(FB4D2E02-BC9F-39FE-B73F-61EDB9363D5B)", "(bad-uuid)")):
            with self.subTest(text=text):
                self.result(text, "unknown", 1)

    def test_missing_target_uuid_still_reports_present(self):
        self.result(NATIVE_INSPECT.replace("com.apple.driver.usb.IOUSBHostHIDDeviceSafeBoot", GATE_ID), "no")

    def test_multiple_collections_selects_only_exact_path(self):
        other = NATIVE_INSPECT.replace("/fixtures/kernelcache", "/fixtures/other")
        other = other.replace("com.apple.iokit.IOBufferCopyEngineFamily", TGL_ID)
        self.result(other + NATIVE_INSPECT.removeprefix("No variant specified, falling back to release\n"), "yes")


def gate_node(**overrides):
    node = {"IOObjectClass": "ReimsADLManualActivation",
            "ActivationPolicy": "explicit-root-current-boot-only", "RuntimeRequested": False}
    node.update(overrides)
    return node


class ControllerTests(unittest.TestCase):
    def assert_ready(self, value, ready):
        status, output, _ = invoke("controller", "fixture.plist", data=plistlib.dumps(value))
        self.assertEqual((status, output), (0 if ready else 1,
                                          "controller_ready=" + ("yes" if ready else "no")))

    def test_single_controller_in_list_is_ready(self):
        self.assert_ready([gate_node()], True)

    def test_single_nested_controller_in_dict_is_ready(self):
        self.assert_ready({"IOObjectClass": "IOService", "IORegistryEntryChildren": [gate_node()]}, True)

    def test_missing_controller_is_not_ready(self):
        for value in ([], {"IOObjectClass": "IOService"},
                      [gate_node(IOObjectClass="ReimsADLManualActivation.Helper")]):
            with self.subTest(value=value):
                self.assert_ready(value, False)

    def test_duplicate_controller_across_roots_is_not_ready(self):
        self.assert_ready([gate_node(), {"IOObjectClass": "IOService",
                                        "IORegistryEntryChildren": [gate_node()]}], False)

    def test_policy_must_match_exactly(self):
        for policy in ("", "explicit-root-current-boot-only ", "other-policy", b"explicit-root-current-boot-only"):
            with self.subTest(policy=policy):
                self.assert_ready(gate_node(ActivationPolicy=policy), False)

    def test_runtime_requested_must_be_boolean_false(self):
        for requested in (True, 0, "false", b"\x00"):
            with self.subTest(requested=requested):
                self.assert_ready(gate_node(RuntimeRequested=requested), False)

    def test_missing_required_property_is_not_ready(self):
        for key in ("ActivationPolicy", "RuntimeRequested"):
            with self.subTest(key=key):
                node = gate_node()
                node.pop(key)
                self.assert_ready(node, False)

    def test_malformed_registry_anywhere_is_not_ready(self):
        for value in ("not-a-registry", [gate_node(), "bad-node"],
                      gate_node(IORegistryEntryChildren={}),
                      [gate_node(), {"IOObjectClass": 0}]):
            with self.subTest(value=value):
                self.assert_ready(value, False)

    def test_bad_plist_or_read_failure_is_not_ready(self):
        for data in (b"not a plist", b"<plist><dict>"):
            with self.subTest(data=data):
                status, output, _ = invoke("controller", "fixture.plist", data=data)
                self.assertEqual((status, output), (1, "controller_ready=no"))
        status, output, _ = invoke("controller", "fixture.plist", read_error=OSError("unreadable"))
        self.assertEqual((status, output), (1, "controller_ready=no"))


class BundleReceiptTests(unittest.TestCase):
    def _run_real(self, *arguments):
        output, errors = io.StringIO(), io.StringIO()
        status = 0
        with patch.object(sys, "argv", [str(SCRIPT), *arguments]), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            try:
                CHECK.main()
            except SystemExit as exc:
                status = exc.code or 0
        return status, output.getvalue().strip(), errors.getvalue().strip()

    def test_strict_runtime_receipt_catches_info_plist_tampering_and_extra_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            bundle = root / "ReimsTGLBoot.kext"
            (bundle / "Contents/MacOS").mkdir(parents=True)
            (bundle / "Contents/MacOS/AppleIntelTGLGraphics").write_bytes(b"patched-runtime")
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": TGL_ID,
                "CFBundleVersion": "16.0.3",
                "IOKitPersonalities": {},
            }))
            receipt_file = root / "runtime-receipt.json"
            rc, out, err = self._run_real(
                "write-receipt", str(bundle), "bbbb0000000000000000000000000002",
                str(receipt_file), "--empty-personalities"
            )
            self.assertEqual((rc, err), (0, ""))
            self.assertEqual(out, f"receipt_written=ok uuid={UUID}")

            rc, out, _ = self._run_real("receipt", str(bundle), str(receipt_file))
            self.assertEqual((rc, out), (0, f"receipt=ok uuid={UUID}"))

            # Tampering Info.plist while keeping executable identical must fail
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.example.Foreign",
                "CFBundleVersion": "16.0.3",
                "IOKitPersonalities": {"Auto": {}},
            }))
            rc, _, _ = self._run_real("receipt", str(bundle), str(receipt_file))
            self.assertNotEqual(rc, 0)

            # Restoring Info.plist then adding an unexpected extra file must also fail
            data = json.loads(receipt_file.read_text(encoding="utf-8"))
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": TGL_ID,
                "CFBundleVersion": "16.0.3",
                "IOKitPersonalities": {},
            }))
            rc, _, _ = self._run_real("receipt", str(bundle), str(receipt_file))
            self.assertEqual(rc, 0, data)
            (bundle / "Contents/Extra.plist").write_bytes(b"unexpected")
            rc, _, _ = self._run_real("receipt", str(bundle), str(receipt_file))
            self.assertNotEqual(rc, 0)
            rc, _, _ = self._run_real("receipt", str(bundle), str(receipt_file), "--allow-partial")
            self.assertNotEqual(rc, 0)
            (bundle / "Contents/Extra.plist").unlink()

            # Partial truncated binary without Info.plist passes --allow-partial only
            (bundle / "Contents/Info.plist").unlink()
            (bundle / "Contents/MacOS/AppleIntelTGLGraphics").write_bytes(b"pat")
            rc, _, _ = self._run_real("receipt", str(bundle), str(receipt_file))
            self.assertNotEqual(rc, 0)
            rc, out, _ = self._run_real("receipt", str(bundle), str(receipt_file), "--allow-partial")
            self.assertEqual((rc, out), (0, f"receipt=partial-ok uuid={UUID}"))


class NvdataTests(unittest.TestCase):
    def test_valid_missing_and_corrupt_nvram_plist(self):
        status, out, _ = invoke("nvdata", "f.plist", "csr-active-config",
                                data=plistlib.dumps({"csr-active-config": bytes.fromhex("03000000")}))
        self.assertEqual((status, out), (0, "csr-active-config=03000000"))

        status, out, _ = invoke("nvdata", "f.plist", "csr-active-config", data=plistlib.dumps({}))
        self.assertEqual((status, out), (0, "csr-active-config=missing"))

        status, out, _ = invoke("nvdata", "f.plist", "csr-active-config", data=b"<corrupt")
        self.assertEqual((status, out), (1, "csr-active-config=invalid"))


if __name__ == "__main__":
    unittest.main()
