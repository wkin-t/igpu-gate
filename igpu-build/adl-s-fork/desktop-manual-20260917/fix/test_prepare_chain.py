#!/usr/bin/env python3
"""Control-flow assertions for P-0002 without any Apple binary.

The fragment below is the probe device-id compare chain only (a few dozen
instruction bytes), placed at its real offset, so CI proves reachability:
comparing bytes alone once approved a patch on a branch 0x46808086 never takes.
"""
import importlib.util
import pathlib
import unittest

BASE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("prepare_runtime", BASE / "prepare-deferred-runtime.py")
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)

CHAIN_AT = 0x23c1f
CHAIN = bytes.fromhex(
    "81ffeebeafde7f15"            # cmp edi,0xdeafbeee; jg second branch (signed)
    "81ff8680409a742d"            # cmp edi,0x9a408086; je SKU 2
    "81ff8680489a7425"            # cmp edi,0x9a488086; je SKU 2
    "e8cecb0600"                  # call probe.cold.1 (panic)
    "81ffefbeafde7510"            # cmp edi,0xdeafbeef; jne next
    "41c7862011000001000000"      # mov [r14+0x1120],1
    "e9f2fcffff"                  # jmp out
    "81ff868020ff75db"            # cmp edi,0xff208086; jne panic
    "41c7862011000002000000"      # mov [r14+0x1120],2
    "e9dafcffff"                  # jmp out
)
P_0002 = next(patch for patch in PREPARE.PATCHES if patch[0] == "P-0002")


def image(apply_patch):
    data = bytearray(CHAIN_AT + len(CHAIN))
    data[CHAIN_AT:] = CHAIN
    if apply_patch:
        _, site, original, replacement = P_0002
        assert data[site:site + len(original)] == original
        data[site:site + len(replacement)] = replacement
    return bytes(data)


class ProbeChain(unittest.TestCase):
    def test_context_pins_this_chain(self):
        at, context = PREPARE.CONTEXT["P-0002"]
        self.assertEqual(image(False)[at:at + len(context)], context)

    def test_unpatched_chain_panics_on_adl_s(self):
        self.assertEqual(PREPARE.probe_sku(image(False), 0x46808086), "panic")

    def test_patched_chain_maps_adl_s_to_sku_2(self):
        self.assertEqual(PREPARE.probe_sku(image(True), 0x46808086), 2)

    def test_patched_chain_keeps_other_devices(self):
        patched = image(True)
        self.assertEqual(PREPARE.probe_sku(patched, 0x9a408086), 2)
        self.assertEqual(PREPARE.probe_sku(patched, 0x9a488086), 2)
        self.assertEqual(PREPARE.probe_sku(patched, 0xdeafbeef), 1)
        self.assertEqual(PREPARE.probe_sku(patched, 0xff208086), "panic")

    def test_old_offset_would_be_unreachable(self):
        # Regression: the first P-0002 patched the 0x9a48 slot on the negative branch.
        data = bytearray(image(False))
        data[0x23c2f + 2:0x23c2f + 6] = bytes.fromhex("86808046")
        self.assertEqual(PREPARE.probe_sku(bytes(data), 0x46808086), "panic")


if __name__ == "__main__":
    unittest.main()
