"""Prepare only: defer TGL service publication until explicit display commit.

The input is identified structurally (LC_UUID + body hash + code assertions),
not by whole-file SHA-256: re-signing changes the signature blob but not the
code, and the same Apple build circulates with different signatures.

Patch set (each patch asserts the exact original bytes before writing):
  P-0001  IntelAccelerator::start: NOP the registerService() call (upstream).
  P-0002  IntelAccelerator::probe: map 0x4680 (ADL-S GT1) to GPU SKU 2 by
          replacing the 0x9a48 entry of the device-id table. Without it probe
          reaches "Failed to map Device ID ... to GPU SKU!" and panics.
  P-0003  IntelAccelerator::getGPUInfo: accept 1 slice x 4 subslices without
          the pre-silicon flag, so the GT1 topology gets L3BankCount=4 instead
          of falling through with L3BankCount unset.
"""
from pathlib import Path
import argparse, hashlib, json, plistlib, shutil, struct, subprocess, sys

ACCEPTED_LC_UUID = 'ba3aa1c0fe6b33b39d8573f848394e3d'
# body_sha256 = SHA-256(b[32+sizeofcmds : LC_CODE_SIGNATURE.dataoff])
ACCEPTED_BODY_SHA256 = {
    '1b2ef94a5dd9d921ee925bebf23e4f332319f3fc011a5ec692eaca4b6204212d',  # NootedGreen SLE (F01)
}
# Upstream's exact input, kept so an upstream-identical checkout still works.
ACCEPTED_FILE_SHA256 = {
    'ae99582bd5a945494ee684d339ac1abd0526828bcd3ea981239c0fd38f794d47',
}

PATCHES = [
    # (id, file offset, original bytes, replacement bytes)
    ('P-0001', 0x246b5, bytes.fromhex('ff90b0050000'), b'\x90' * 6),
    ('P-0002', 0x23c2f, bytes.fromhex('81ff8680489a'), bytes.fromhex('81ff86808046')),
    ('P-0003', 0x287ea, bytes.fromhex('7412'), b'\x90\x90'),
]
# Context that must surround each site, so a shifted build cannot be patched.
CONTEXT = {
    'P-0001': (0x246b5 - 12, bytes.fromhex('498b45004531ff4c89ef31f6')),
    'P-0002': (0x23c1f, bytes.fromhex('81ffeebeafde7f1581ff8680409a742d')),
    'P-0003': (0x287df, bytes.fromhex('83fe01751a83e0204885c0')),
}


def parse(b):
    assert len(b) >= 32 and struct.unpack_from('<II', b, 0) == (0xfeedfacf, 0x01000007), 'not thin x86_64 Mach-O'
    ncmds, sizeofcmds = struct.unpack_from('<II', b, 16)
    lc_end = 32 + sizeofcmds
    cursor = 32; info = {'lc_end': lc_end, 'codesig': None, 'uuid_offset': None}
    for _ in range(ncmds):
        command, size = struct.unpack_from('<II', b, cursor)
        assert size >= 8, 'malformed load command'
        if command == 2: info['symtab'] = struct.unpack_from('<IIII', b, cursor + 8)
        if command == 0xb: info['dysymtab'] = struct.unpack_from('<18I', b, cursor + 8)
        if command == 0x1b:
            assert info['uuid_offset'] is None, 'multiple LC_UUID'
            info['uuid_offset'] = cursor + 8
        if command == 0x1d:
            assert info['codesig'] is None, 'multiple LC_CODE_SIGNATURE'
            info['codesig'] = struct.unpack_from('<II', b, cursor + 8)
        cursor += size
    assert cursor == lc_end <= len(b), 'load commands do not match sizeofcmds'
    assert info['uuid_offset'] is not None, 'missing LC_UUID'
    end = info['codesig'][0] if info['codesig'] else len(b)
    assert lc_end < end <= len(b), 'bad body bounds'
    info['body_sha256'] = hashlib.sha256(b[lc_end:end]).hexdigest()
    info['uuid'] = b[info['uuid_offset']:info['uuid_offset'] + 16].hex()
    return info


def identify(b, info):
    file_sha = hashlib.sha256(b).hexdigest()
    if file_sha in ACCEPTED_FILE_SHA256:
        return 'upstream-file-sha256'
    assert info['uuid'] == ACCEPTED_LC_UUID, f"unexpected LC_UUID {info['uuid']}"
    assert info['body_sha256'] in ACCEPTED_BODY_SHA256, f"unexpected body hash {info['body_sha256']}"
    return 'lc-uuid+body-sha256'


def verify_code(b, info):
    sym, dyn = info['symtab'], info['dysymtab']
    names = []; values = {}
    for i in range(sym[1]):
        offset, kind, section, desc, value = struct.unpack_from('<IBBHQ', b, sym[0] + 16 * i)
        name = b[sym[2] + offset:b.index(b'\0', sym[2] + offset)].decode()
        names.append(name); values[name] = value
    relocs = {}
    for i in range(dyn[15]):
        address, rinfo = struct.unpack_from('<II', b, dyn[14] + 8 * i)
        if rinfo >> 27 & 1: relocs[address] = names[rinfo & 0xffffff]
    assert values['__ZN16IntelAccelerator5startEP9IOService'] == 0x23ecc
    assert values['__ZN16IntelAccelerator5probeEP9IOServicePi'] == 0x238e2
    assert values['__ZN16IntelAccelerator10getGPUInfoEv'] == 0x2847e
    assert relocs[values['__ZTV16IntelAccelerator']+16+0x5b0] == '__ZN9IOService15registerServiceEj'
    for pid, site, original, replacement in PATCHES:
        assert len(original) == len(replacement)
        assert not any(site <= a < site + len(original) for a in relocs), f'{pid} overlaps a relocation'
        context_at, context = CONTEXT[pid]
        assert b[context_at:context_at + len(context)] == context, f'{pid} context mismatch'
        assert b[site:site + len(original)] == original, f'{pid} original bytes mismatch'


def build_candidate(b):
    info = parse(b)
    identity = identify(b, info)
    verify_code(b, info)
    patched = bytearray(b)
    applied = []
    for pid, site, original, replacement in PATCHES:
        patched[site:site + len(original)] = replacement
        applied.append({'id': pid, 'file_offset': hex(site), 'from': original.hex(), 'to': replacement.hex()})
    changed = [i for i in range(len(b)) if b[i] != patched[i]]
    expected_changes = sum(sum(x != y for x, y in zip(p[2], p[3])) for p in PATCHES)
    assert len(changed) == expected_changes, 'unexpected number of changed bytes'
    deferred_uuid = hashlib.sha256(bytes(patched)).digest()[:16]
    patched[info['uuid_offset']:info['uuid_offset'] + 16] = deferred_uuid
    record = {
        'source_identity': identity,
        'source_lc_uuid': info['uuid'],
        'source_body_sha256': info['body_sha256'],
        'source_sha256': hashlib.sha256(b).hexdigest(),
        'patches': applied,
        'functional_text_change_bytes': len(changed),
        'candidate_uuid': deferred_uuid.hex(),
        'supported_device_ids': ['0x46a3 (upstream, requires its own patched input)', '0x4680'],
        'automatic_personalities': 0,
    }
    return bytes(patched), deferred_uuid, record


def main():
    base = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('source', type=Path, help='Locally obtained compatible TGL runtime bundle (not distributed)')
    parser.add_argument('--check-only', action='store_true', help='Validate and print the record; write nothing')
    args = parser.parse_args()
    source = args.source.resolve()
    binary = source / 'Contents/MacOS/AppleIntelTGLGraphics'
    patched, deferred_uuid, record = build_candidate(binary.read_bytes())
    candidate_sha = hashlib.sha256(patched).hexdigest()
    record['candidate_sha256'] = candidate_sha
    if args.check_only:
        print(json.dumps(record, indent=2)); return
    target = base / 'ReimsTGLManualRuntime.kext'
    if target.exists(): raise SystemExit('Candidate already exists; do not overwrite a reviewed release.')
    (base / 'manual-gate/deferred_uuid.hpp').write_text(
        'static const unsigned char deferredUUID[]={' + ','.join(hex(x) for x in deferred_uuid) + '};\n')
    shutil.copytree(source, target)
    (target / 'Contents/MacOS/AppleIntelTGLGraphics').write_bytes(patched)
    p = target / 'Contents/Info.plist'; info = plistlib.loads(p.read_bytes())
    # No GPU personalities in the installed candidate. Only the explicit controller
    # may add a current-session personality. Physical identity remains FFFF at boot.
    info['IOKitPersonalities'] = {}
    info['CFBundleVersion'] = info['CFBundleShortVersionString'] = '16.0.3'
    info['ReimsManualPublicationDeferred'] = True
    p.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(target)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(target)], check=True)
    # Signing changes the file again; record what is actually installed.
    record['candidate_sha256'] = hashlib.sha256((target / 'Contents/MacOS/AppleIntelTGLGraphics').read_bytes()).hexdigest()
    record['installed'] = False; record['hardware_tested'] = False
    (base / 'deferred-runtime.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()
