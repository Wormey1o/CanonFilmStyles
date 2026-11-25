"""Construct only private modeled updater images at the reviewed exact placement."""
import hashlib
import json
import shutil
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = Path(__file__).resolve().parent
out = Path(sys.argv[1]).resolve()
assert out.is_relative_to(ROOT / 'experiments/rom-search/sdboot-installer-v1') and not out.exists()
out.mkdir(mode=0o700)
original = (ROOT / 'experiments/rom-search/updater1.bin').read_bytes()
assert hashlib.sha256(original).hexdigest() == 'db1db77ede14cdd860a16a774a29925502a5fa6de7010430a6b4c49c4f5d1b09'
BASE = 0x800120
exclusions = [(0x807b38, 0x80844c), (0x8092a8, 0x8092cb), (0x80930c, 0x809338), (0x902f28, 0x902f40)]
critical = json.loads((ROOT / 'experiments/rom-search/sdboot-installer-v1/judge-fingerprint-proposal-v1.json').read_text())['words']
ranges = []
start = BASE
for low, high in exclusions + [(0x99de30, 0x99de30)]:
    if start < low:
        h = 2166136261
        for byte in original[start - BASE:low - BASE]:
            h = ((h ^ byte) * 16777619) & 0xffffffff
        ranges.append((start, low, h))
    start = high
for a, value in critical.items():
    assert struct.unpack_from('<I', original, int(a, 16) - BASE)[0] == int(value, 16)
target_path = ROOT / 'experiments/rom-search/sdboot-installer-v1/judge-installed-target-binding-v1.json'
assert hashlib.sha256(target_path.read_bytes()).hexdigest() == 'e1b9aa10f570fcb58c26c15406f13818c2a2479f8f55e62aeb3156b43b46db8d'
target = json.loads(target_path.read_text())
rom = (ROOT / 'experiments/rom-search/rom-extraction-readback-v1/ROM01.BIN').read_bytes()
assert hashlib.sha256(rom).hexdigest() == target['captured_rom_sha256']
for a, value in target['words'].items():
    assert struct.unpack_from('<I', rom, int(a, 16) - 0xf8000000)[0] == int(value, 16)
    critical[a] = value
critical['f8000008'] = 'ffffffff'
header = '/* Generated original-updater diagnostic fingerprints and exact critical words. */\nstatic const uint32_t fingerprints[][3]={\n'
header += ''.join('{{0x{:x}u,0x{:x}u,0x{:x}u}},\n'.format(*row) for row in ranges) + '};\nstatic const uint32_t signatures[][2]={\n'
header += ''.join(f'{{0x{a}u,0x{v}u}},\n' for a, v in critical.items()) + '};\n'
(out / 'signatures.h').write_text(header)
for name in ('body.c', 'wrapper.S'):
    shutil.copyfile(SRC / name, out / name)
linker = '''ENTRY(installer_callsite)
canon_sprintf = 0x98e4e8;
canon_constructor = 0x81e900;
SECTIONS {
 .body 0x807b38 : { *(.text*) *(.rodata*) }
 ASSERT(SIZEOF(.body) <= 2056, "body overflow")
 .guard 0x808340 : { *(.guard) }
 ASSERT(SIZEOF(.guard) <= 128, "guard overflow")
 .args 0x8092a8 : { *(.args) }
 ASSERT(SIZEOF(.args) == 32, "args extent before three padding bytes")
 .callsite 0x80930c : { *(.callsite) }
 ASSERT(SIZEOF(.callsite) == 44, "callsite extent")
 /DISCARD/ : { *(.comment) *(.ARM.attributes) }
}
'''
(out / 'placement.ld').write_text(linker)
commands: list[dict] = []


def run(args):
    p = subprocess.run(args, cwd=out, capture_output=True, text=True, check=False, timeout=60)
    commands.append({'argv': args, 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr})
    (out / 'commands.json').write_text(json.dumps(commands, indent=2))
    assert p.returncode == 0, p.stderr
    return p.stdout


flags = ['-std=c99', '-Os', '-mcpu=arm946e-s', '-marm', '-ffreestanding', '-fno-builtin', '-Wall', '-Wextra', '-Werror', '-fstack-usage']
allowed = {a - BASE for lo, hi in exclusions for a in range(lo, hi)}
allowed |= {0x99e2cc - BASE + 8 * i + j for i in range(17) for j in range(4)}
artifacts = {}
for mode in ('enable', 'disable'):
    run(['/opt/homebrew/bin/arm-none-eabi-gcc', *flags, '-DDISABLE=' + str(int(mode == 'disable')), '-c', 'body.c', '-o', mode + '.o'])
    run(['/opt/homebrew/bin/arm-none-eabi-gcc', '-mcpu=arm946e-s', '-marm', '-Werror', '-Wa,--fatal-warnings', '-c', 'wrapper.S', '-o', mode + '-wrapper.o'])
    run(['/opt/homebrew/bin/arm-none-eabi-gcc', '-mcpu=arm946e-s', '-marm', '-nostdlib', '-T', 'placement.ld', mode + '.o', mode + '-wrapper.o', '-o', mode + '.elf'])
    assert not run(['/opt/homebrew/bin/arm-none-eabi-nm', '-u', mode + '.elf']).strip()
    (out / (mode + '-symbols.txt')).write_text(run(['/opt/homebrew/bin/arm-none-eabi-nm', '-n', mode + '.elf']))
    (out / (mode + '-disassembly.txt')).write_text(run(['/opt/homebrew/bin/arm-none-eabi-objdump', '-d', mode + '.elf']))
    model = bytearray(original)
    model[0x807b38 - BASE:0x80844c - BASE] = bytes(2324)
    model[0x8092a8 - BASE:0x8092cb - BASE] = bytes(35)
    sizes = {}
    for section, address in (('body', 0x807b38), ('guard', 0x808340), ('args', 0x8092a8), ('callsite', 0x80930c)):
        name = mode + '-' + section + '.bin'
        run(['/opt/homebrew/bin/arm-none-eabi-objcopy', '-O', 'binary', '-j', '.' + section, mode + '.elf', name])
        raw = (out / name).read_bytes()
        sizes[section] = len(raw)
        model[address - BASE:address - BASE + len(raw)] = raw
    title = (b'BOOTSOFF' if mode == 'disable' else b'BOOTSDON') + b' 0x????????    \0'
    assert len(title) == 24
    model[0x902f28 - BASE:0x902f40 - BASE] = title
    for i in range(17):
        struct.pack_into('<I', model, 0x99e2cc - BASE + i * 8, 0x8092a8)
    assert model[0x809324 - BASE:0x809338 - BASE] == original[0x809324 - BASE:0x809338 - BASE]
    assert model[0x902f25 - BASE:0x902f28 - BASE] == b'\x05\x02\x18'
    changed = [i for i, (a, b) in enumerate(zip(original, model, strict=True)) if a != b]
    assert set(changed) <= allowed
    (out / (mode + '-updater.bin')).write_bytes(model)
    artifacts[mode] = {'sizes': sizes, 'sha256': hashlib.sha256(model).hexdigest(), 'changed_offsets': changed}
(out / 'manifest.json').write_text(json.dumps({'original_sha256': hashlib.sha256(original).hexdigest(), 'exclusions': exclusions, 'fingerprints': ranges, 'artifacts': artifacts, 'source': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in SRC.iterdir() if p.is_file()}, 'status': 'UNACCEPTED_MODELED_UPDATERS_NO_FIR'}, indent=2))
print({m: a['sizes'] for m, a in artifacts.items()})
