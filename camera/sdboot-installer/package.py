"""Private FIR construction/whole-image decode; no physical destination support."""
import hashlib
import json
import os
import runpy
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
build, out = (Path(p).resolve() for p in sys.argv[1:3])
assert build.is_relative_to(ROOT / 'experiments/rom-search/sdboot-installer-v1')
assert out.is_relative_to(ROOT / 'experiments/rom-search/sdboot-installer-v1') and not out.exists()
os.umask(0o077)
out.mkdir(mode=0o700)


def sha(data):
    return hashlib.sha256(data).hexdigest()


fir = (ROOT / 'experiments/rom-search/450D_110.FIR').read_bytes()
original = (ROOT / 'experiments/rom-search/updater1.bin').read_bytes()
assert sha(fir) == 'ec34d11815d85e013b0d73b5d754f27bd07b7812a9f3a960dae855eae686ddf4'
assert sha(original) == 'db1db77ede14cdd860a16a774a29925502a5fa6de7010430a6b4c49c4f5d1b09'
assert len(fir) == 7397084 and len(original) == 1704832
assert struct.unpack_from('<I', fir, 0x28)[0] == 0x120
assert struct.unpack_from('<I', fir, 0x30)[0] == 0x1a04a0
manifest = json.loads((build / 'manifest.json').read_text())
assert manifest['original_sha256'] == sha(original)
exclusions = [[0x807b38, 0x80844c], [0x8092a8, 0x8092cb], [0x80930c, 0x809338], [0x902f28, 0x902f40]]
assert manifest['exclusions'] == exclusions
inspector = ROOT / 'experiments/inspect_450d_update.py'
assert sha(inspector.read_bytes()) == 'd30a62e90d92902d5d73c421ec99b3bd1a05a0c661d33ed3da3163b49dac9a1f'
tool = ROOT / 'experiments/upstream/magiclantern/tools/indy/fir_tool2.py'
assert sha(tool.read_bytes()) == '41cf8211cdb59ec4747a03874cf39d992c126bf956fdddac068526c283ac6e63'
inspect = runpy.run_path(str(inspector))['inspect']


def checksum(data):
    return (~(sum(data[:0x20]) + sum(data[0x24:]))) & 0xffffffff


def verify(data, model, changes):
    assert len(data) == len(fir)
    assert struct.unpack_from('<I', data, 0x20)[0] == checksum(data)
    allowed = {0x120 + i for i in changes} | set(range(0x20, 0x24))
    assert all(a == b or i in allowed for i, (a, b) in enumerate(zip(data, fir, strict=True)))
    decoded = bytes(data[0x120 + i] ^ fir[0x120 + i] ^ original[i] for i in range(len(original)))
    assert decoded == model
    assert data[0x1a04a0:] == fir[0x1a04a0:]


results = {}
for mode in ('enable', 'disable'):
    model = (build / (mode + '-updater.bin')).read_bytes()
    assert sha(model) == manifest['artifacts'][mode]['sha256']
    changes = manifest['artifacts'][mode]['changed_offsets']
    assert changes == [i for i, (a, b) in enumerate(zip(model, original, strict=True)) if a != b]
    allowed_model = {a - 0x800120 for lo, hi in exclusions for a in range(lo, hi)}
    allowed_model |= {0x99e2cc - 0x800120 + 8 * i + j for i in range(17) for j in range(4)}
    assert set(changes) <= allowed_model
    data = bytearray(fir)
    for i in changes:
        data[0x120 + i] ^= original[i] ^ model[i]
    struct.pack_into('<I', data, 0x20, checksum(data))
    verify(data, model, changes)
    denials = []
    for offset in (0, 0x20, 0x28, 0x30, 0x120, 0x1a04a0, 0x120 + changes[0], 0x120 + changes[-1]):
        for corrected_checksum in (False, True):
            bad = bytearray(data)
            bad[offset] ^= 1
            if corrected_checksum:
                struct.pack_into('<I', bad, 0x20, checksum(bad))
            if bad == data:
                continue
            try:
                verify(bad, model, changes)
            except AssertionError:
                denials.append([offset, corrected_checksum])
            else:
                raise AssertionError('mutated package accepted')
    for bad in (data[:-1], data + b'X'):
        try:
            verify(bad, model, changes)
        except AssertionError:
            denials.append(['extent', len(bad)])
        else:
            raise AssertionError('wrong extent accepted')
    path = out / ('e5kr4110-sd-' + mode + '-v1.fir')
    with path.open('xb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    assert path.read_bytes() == data
    decoded_dir = out / (mode + '-decoded')
    inspect(path, decoded_dir)
    assert (decoded_dir / 'updater1.bin').read_bytes() == model
    results[mode] = {'artifact': path.name, 'sha256': sha(data), 'updater_sha256': sha(model),
                     'encrypted_main_sha256': sha(fir[0x1a04a0:]), 'denials': denials,
                     'whole_independent_decode': 'PASS', 'physical_use': 'NOT_AUTHORIZED'}
(out / 'packages.json').write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2))
