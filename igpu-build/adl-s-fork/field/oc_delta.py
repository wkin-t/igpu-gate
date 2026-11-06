#!/usr/bin/env python3
"""Apply, verify, or inspect the OpenCore config delta required by the ADL-S field package.

Delta (nothing else may change):
  DeviceProperties/Add/PciRoot(0x0)/Pci(0x2,0x0)  device-id = FFFF0000 (boot isolation)
  Kernel/Block  com.apple.driver.AppleIntelTGLGraphics, lab.reims.ReimsADLDesktopLink (Exclude, Darwin 25)
  NVRAM/Add/<Apple GUID>/csr-active-config = 430A0000 (AuxKC needs unsigned kexts; machine-wide)
  NVRAM/Add/<Apple GUID>/boot-args gains -allow3d (TGL probe rejects real device ids without it)

Exit codes: 0 ok; 2 usage; 3 config cannot accept the delta; 4 verification failed.
Output never includes PlatformInfo.
"""
import argparse
import copy
import os
import pathlib
import plistlib
import sys

APPLE_GUID = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
GFX_PATH = "PciRoot(0x0)/Pci(0x2,0x0)"
ISOLATED_ID = bytes.fromhex("ffff0000")
CSR_RELAXED = bytes.fromhex("430a0000")
CSR_DEFAULT = bytes.fromhex("00000000")
ALLOW3D = "-allow3d"
BLOCK_IDS = ("com.apple.driver.AppleIntelTGLGraphics", "lab.reims.ReimsADLDesktopLink")
# Tokens that set-bootargs.py keeps at the end of its canonical string; -allow3d
# goes before them so the existing state tool still reports canonical=yes.
TRAILING_PREFIXES = ("igpu-driver", "-igpu-driver", "igpu_driver", "-igpu_driver", "-x")


def refuse(message, code=3):
    print(f"REFUSED: {message}", file=sys.stderr)
    sys.exit(code)


def block_entry(identifier):
    return {
        "Arch": "x86_64",
        "Comment": "ADL-S field package: keep TGL runtime out of automatic matching",
        "Enabled": True,
        "Identifier": identifier,
        "MaxKernel": "25.99.99",
        "MinKernel": "25.0.0",
        "Strategy": "Exclude",
    }


def load(path):
    return plistlib.loads(pathlib.Path(path).read_bytes())


def nvram_slot(cfg):
    slot = cfg.get("NVRAM", {}).get("Add", {}).get(APPLE_GUID)
    if not isinstance(slot, dict):
        refuse(f"NVRAM/Add/{APPLE_GUID} is missing")
    return slot


def insert_allow3d(args):
    tokens = args.split()
    if ALLOW3D in tokens:
        return args
    for index, token in enumerate(tokens):
        if token.lower().startswith(TRAILING_PREFIXES):
            tokens.insert(index, ALLOW3D)
            break
    else:
        tokens.append(ALLOW3D)
    return " ".join(tokens)


def strip_allow3d(args):
    return " ".join(token for token in args.split() if token != ALLOW3D)


def status(cfg):
    slot = nvram_slot(cfg)
    present = {
        "device-id": cfg.get("DeviceProperties", {}).get("Add", {}).get(GFX_PATH, {}).get("device-id") == ISOLATED_ID,
        "csr": slot.get("csr-active-config") == CSR_RELAXED,
        "allow3d": ALLOW3D in str(slot.get("boot-args", "")).split(),
    }
    blocks = cfg.get("Kernel", {}).get("Block", [])
    for identifier in BLOCK_IDS:
        present[identifier] = block_entry(identifier) in blocks
    if all(present.values()):
        return "applied"
    return "partial" if any(present.values()) else "absent"


def check_can_apply(cfg):
    security = cfg.get("Misc", {}).get("Security", {})
    if security.get("SecureBootModel") != "Disabled":
        refuse(f"Misc/Security/SecureBootModel={security.get('SecureBootModel')!r}, must be Disabled")
    props = cfg.get("DeviceProperties", {}).get("Add", {})
    if not isinstance(props, dict):
        refuse("DeviceProperties/Add is not a dict")
    if props.get(GFX_PATH):
        refuse(f"{GFX_PATH} already has device properties: {sorted(props[GFX_PATH])}")
    blocks = cfg.get("Kernel", {}).get("Block")
    if not isinstance(blocks, list):
        refuse("Kernel/Block is not a list")
    for entry in blocks:
        if isinstance(entry, dict) and entry.get("Identifier") in BLOCK_IDS:
            refuse(f"Kernel/Block already mentions {entry.get('Identifier')}")
    for entry in cfg.get("Kernel", {}).get("Add", []):
        if isinstance(entry, dict) and entry.get("Enabled") and str(entry.get("BundlePath", "")).startswith("WhateverGreen"):
            refuse("WhateverGreen is enabled; it would act on the isolated GPU")
    slot = nvram_slot(cfg)
    if slot.get("csr-active-config") != CSR_DEFAULT:
        refuse("csr-active-config is not 00000000; refusing to guess what changed it")
    if not isinstance(slot.get("boot-args"), str):
        refuse("boot-args is not a string")
    if ALLOW3D in slot["boot-args"].split():
        refuse("boot-args already has -allow3d")
    delete = cfg.get("NVRAM", {}).get("Delete", {}).get(APPLE_GUID)
    if not isinstance(delete, list) or "boot-args" not in delete or "csr-active-config" not in delete:
        refuse("NVRAM/Delete must list boot-args and csr-active-config, or OpenCore will not rewrite them")


def apply_delta(cfg):
    updated = copy.deepcopy(cfg)
    updated.setdefault("DeviceProperties", {}).setdefault("Add", {})[GFX_PATH] = {"device-id": ISOLATED_ID}
    updated["Kernel"]["Block"].extend(block_entry(identifier) for identifier in BLOCK_IDS)
    slot = updated["NVRAM"]["Add"][APPLE_GUID]
    slot["csr-active-config"] = CSR_RELAXED
    slot["boot-args"] = insert_allow3d(slot["boot-args"])
    return updated


def without_delta(cfg):
    clone = copy.deepcopy(cfg)
    clone.get("DeviceProperties", {}).get("Add", {}).pop(GFX_PATH, None)
    clone["Kernel"]["Block"] = [
        entry for entry in clone["Kernel"]["Block"]
        if not (isinstance(entry, dict) and entry.get("Identifier") in BLOCK_IDS)
    ]
    slot = clone["NVRAM"]["Add"][APPLE_GUID]
    slot["csr-active-config"] = CSR_DEFAULT
    slot["boot-args"] = strip_allow3d(slot["boot-args"])
    return clone


def verify_pair(original, updated):
    if status(updated) != "applied":
        refuse("delta is not fully present after writing", 4)
    baseline = copy.deepcopy(original)
    baseline.get("DeviceProperties", {}).get("Add", {}).pop(GFX_PATH, None)
    baseline_slot = baseline["NVRAM"]["Add"][APPLE_GUID]
    baseline_slot["boot-args"] = " ".join(baseline_slot["boot-args"].split())
    if without_delta(updated) != baseline:
        refuse("config differs from the original by more than the delta", 4)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=("status", "check", "apply", "verify"))
    parser.add_argument("--config", required=True)
    parser.add_argument("--out", help="apply: destination for the updated config")
    parser.add_argument("--orig", help="verify: the config as it was before apply")
    args = parser.parse_args()
    cfg = load(args.config)
    if args.action == "status":
        print(f"delta={status(cfg)}")
    elif args.action == "check":
        check_can_apply(cfg)
        print("delta=can-apply")
    elif args.action == "apply":
        if not args.out:
            parser.error("apply requires --out")
        check_can_apply(cfg)
        updated = apply_delta(cfg)
        verify_pair(cfg, updated)
        out = pathlib.Path(args.out)
        temporary = out.with_name(out.name + f".tmp-{os.getpid()}")
        temporary.write_bytes(plistlib.dumps(updated))
        verify_pair(cfg, load(temporary))
        temporary.replace(out)
        print(f"delta=applied out={out}")
    else:
        if not args.orig:
            parser.error("verify requires --orig")
        verify_pair(load(args.orig), cfg)
        print("delta=verified")


if __name__ == "__main__":
    main()
