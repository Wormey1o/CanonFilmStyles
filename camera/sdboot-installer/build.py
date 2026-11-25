"""Compile a synthetic-address body; this tool never creates an updater/FIR."""
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = Path(__file__).resolve().parent
out = Path(sys.argv[1]).resolve()
assert out.is_relative_to(ROOT / 'experiments/rom-search/sdboot-installer-v1')
assert not out.exists()
out.mkdir()
commands: list[dict] = []


def run(args):
    p = subprocess.run(args, check=False, capture_output=True, text=True, timeout=60)
    commands.append({'argv': args, 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr})
    (out / 'commands.json').write_text(json.dumps(commands, indent=2))
    assert p.returncode == 0, p.stderr
    return p.stdout


linker = out / 'synthetic.ld'
linker.write_text('ENTRY(installer_body)\nSECTIONS { . = 0x500000; .text : { *(.text*) *(.rodata*) } /DISCARD/ : { *(.comment) *(.ARM.attributes) } }\n')
flags = ['-std=c99', '-Os', '-mcpu=arm946e-s', '-marm', '-ffreestanding', '-fno-builtin', '-Wall', '-Wextra', '-Werror', '-fstack-usage']
for mode in ('enable', 'disable'):
    obj, elf, binary = [out / (mode + suffix) for suffix in ('.o', '.elf', '.bin')]
    run(['/opt/homebrew/bin/arm-none-eabi-gcc', *flags, '-DDISABLE=' + str(int(mode == 'disable')), '-c', str(SRC / 'body.c'), '-o', str(obj)])
    run(['/opt/homebrew/bin/arm-none-eabi-gcc', '-mcpu=arm946e-s', '-marm', '-nostdlib', '-T', str(linker), str(obj), '-o', str(elf)])
    assert not run(['/opt/homebrew/bin/arm-none-eabi-nm', '-u', str(elf)]).strip()
    run(['/opt/homebrew/bin/arm-none-eabi-objcopy', '-O', 'binary', str(elf), str(binary)])
    symbols = run(['/opt/homebrew/bin/arm-none-eabi-nm', '-n', str(elf)])
    (out / (mode + '-symbols.txt')).write_text(symbols)
    (out / (mode + '-disassembly.txt')).write_text(run(['/opt/homebrew/bin/arm-none-eabi-objdump', '-d', str(elf)]))
    print(mode, len(binary.read_bytes()), 'bytes; synthetic only')
binding = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in SRC.iterdir() if p.is_file()}
(out / 'manifest.json').write_text(json.dumps({'source': binding, 'output': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.is_file()}, 'placement': 'synthetic 0x500000; no updater patch'}, indent=2))
