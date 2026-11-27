#!/usr/bin/env python3
"""boot-path 公开 CLI 的离线契约；合成 UEFI 夹具不是目标机采样。"""
import contextlib
import importlib.util
import io
import pathlib
import plistlib
import struct
import sys
import unittest
import uuid
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "field_check.py"
SPEC = importlib.util.spec_from_file_location("boot_path_test_target", SCRIPT)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)

KEY = "4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path"
ESP_UUID = "00112233-4455-6677-8899-AABBCCDDEEFF"
HD_NODE = "HD(1,GPT,00112233-4455-6677-8899-aabbccddeeff,0x800,0x32000)"
FULL_OC_PATH = (
    "PciRoot(0x0)/Pci(0x14,0x0)/USB(0x1,0x0)/"
    + HD_NODE
    + r"/\EFI\BOOT\BOOTx64.EFI"
)


def make_binary_gpt_hd(part_uuid=ESP_UUID, part_num=1, start=0x800, size=0x32000,
                       mbr_type=0x02, sig_type=0x02):
    sig = uuid.UUID(part_uuid).bytes_le
    return struct.pack("<BBHIQQ16sBB", 0x04, 0x01, 42, part_num, start, size, sig, mbr_type, sig_type)


def make_binary_end(subtype=0xFF):
    return struct.pack("<BBH", 0x7F, subtype, 4)


def make_binary_pci_usb_prefix():
    acpi = struct.pack("<BBHII", 0x02, 0x01, 12, 0x0A0341D0, 0)
    pci = struct.pack("<BBHBB", 0x01, 0x01, 6, 0, 0x14)
    return acpi + pci


def invoke(value=None, *, document=None, raw=None, key=KEY, read_error=None, fmt=plistlib.FMT_XML):
    if raw is None:
        if read_error is not None:
            raw = b""
        else:
            raw = plistlib.dumps(document if document is not None else {KEY: value}, fmt=fmt)
    output, errors = io.StringIO(), io.StringIO()
    status = 0
    with patch.object(sys, "argv", [str(SCRIPT), "boot-path", "fixture.plist", key]), \
            patch("pathlib.Path.read_bytes", return_value=raw, side_effect=read_error), \
            contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
        try:
            CHECK.main()
        except SystemExit as exc:
            status = exc.code or 0
    return status, output.getvalue().strip(), errors.getvalue().strip()


class BootPathTests(unittest.TestCase):
    def assert_uuid(self, value, **fixture):
        status, output, errors = invoke(value, **fixture)
        self.assertEqual((status, output, errors), (0, "boot_esp_uuid=" + ESP_UUID, ""))

    def assert_missing(self, value=None, **fixture):
        status, output, errors = invoke(value, **fixture)
        self.assertEqual((status, output), (1, "boot_esp_uuid=missing"))
        self.assertTrue(errors.startswith("FAIL:"))
        self.assertNotIn("Traceback", errors)

    def test_single_gpt_text_and_full_oc_path_return_uppercase_uuid(self):
        self.assert_uuid(HD_NODE)
        self.assert_uuid(FULL_OC_PATH)

    def test_utf8_data_with_optional_bom_and_nul_is_decoded(self):
        for text in (HD_NODE, FULL_OC_PATH):
            data = text.encode("utf-8")
            for value in (data, data + b"\x00", b"\xef\xbb\xbf" + data + b"\x00"):
                with self.subTest(value=value):
                    self.assert_uuid(value)

    def test_utf16le_data_with_optional_bom_and_nul_is_decoded(self):
        for text in (HD_NODE, FULL_OC_PATH):
            data = text.encode("utf-16-le")
            for value in (data, data + b"\x00\x00", b"\xff\xfe" + data + b"\x00\x00"):
                with self.subTest(len=len(value)):
                    self.assert_uuid(value)

    def test_binary_efi_device_path_extracts_mixed_endian_gpt_uuid(self):
        filepath = r"\EFI\OC\OpenCore.efi".encode("utf-16-le") + b"\x00\x00"
        fp_node = struct.pack("<BBH", 0x04, 0x04, 4 + len(filepath)) + filepath
        binary = make_binary_pci_usb_prefix() + make_binary_gpt_hd() + fp_node + make_binary_end()
        self.assert_uuid(binary)

    def test_missing_key_bad_plist_or_read_error_fails_closed(self):
        self.assert_missing(document={})
        self.assert_missing(document={"other": HD_NODE})
        self.assert_missing(raw=b"not xml")
        self.assert_missing(read_error=OSError("cannot read"))

    def test_ambiguous_or_malformed_text_and_bytes_fail_closed(self):
        other_hd = "HD(2,GPT,11111111-2222-3333-4444-555555555555,0x40000,0x10000)"
        for bad in (
            "",
            "PciRoot(0x0)/Pci(0x14,0x0)",
            f"{HD_NODE}/{other_hd}",
            "HD(1,MBR,0x12345678,0x800,0x32000)",
            "HD(0,GPT,00112233-4455-6677-8899-aabbccddeeff,0x800,0x32000)",
            "HD(1,GPT,00000000-0000-0000-0000-000000000000,0x800,0x32000)",
            b"",
            (HD_NODE + "\x00extra").encode("utf-8"),
            HD_NODE.encode("utf-8") + b"\x00\x00",
            HD_NODE.encode("utf-16-le") + b"\x00",
        ):
            with self.subTest(bad=bad):
                self.assert_missing(bad)
        self.assert_missing(HD_NODE + "\x00extra", fmt=plistlib.FMT_BINARY)

    def test_binary_efi_device_path_rejects_multi_hd_mbr_nil_or_truncated(self):
        hd1 = make_binary_gpt_hd()
        hd2 = make_binary_gpt_hd("11111111-2222-3333-4444-555555555555")
        for bad in (
            hd1,  # missing end node
            hd1 + make_binary_end() + b"\x00",  # trailing byte
            hd1 + make_binary_end(subtype=0x01) + hd1 + make_binary_end(),  # multi-instance
            hd1 + hd2 + make_binary_end(),  # two GPT nodes
            make_binary_gpt_hd(mbr_type=0x01) + make_binary_end(),  # MBR
            make_binary_gpt_hd(sig_type=0x01) + make_binary_end(),  # non-GUID sig
            make_binary_gpt_hd("00000000-0000-0000-0000-000000000000") + make_binary_end(),  # nil UUID
            make_binary_pci_usb_prefix() + make_binary_end(),  # zero GPT nodes
        ):
            with self.subTest(len=len(bad)):
                self.assert_missing(bad)


if __name__ == "__main__":
    unittest.main()
