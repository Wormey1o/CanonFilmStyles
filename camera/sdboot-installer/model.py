"""Actual synthetic ARM body/native writer with named host peripheral boundaries."""
import hashlib
import json
import struct
import sys
import time
from pathlib import Path
from typing import Any

from unicorn import UC_ARCH_ARM, UC_HOOK_CODE, UC_MODE_ARM, Uc
from unicorn.arm_const import (
    UC_ARM_REG_CPSR,
    UC_ARM_REG_LR,
    UC_ARM_REG_PC,
    UC_ARM_REG_R0,
    UC_ARM_REG_R1,
    UC_ARM_REG_R2,
    UC_ARM_REG_R3,
    UC_ARM_REG_R4,
    UC_ARM_REG_R5,
    UC_ARM_REG_R6,
    UC_ARM_REG_R7,
    UC_ARM_REG_R8,
    UC_ARM_REG_R9,
    UC_ARM_REG_R10,
    UC_ARM_REG_R11,
    UC_ARM_REG_R12,
    UC_ARM_REG_SP,
)

ROOT = Path(__file__).resolve().parents[2]
build, out = (Path(p).resolve() for p in sys.argv[1:3])
assert out.is_relative_to(ROOT / 'experiments/rom-search/sdboot-installer-v1') and not out.exists()
out.mkdir()
(out / 'executed-model.py').write_bytes(Path(__file__).read_bytes())
blob = (ROOT / 'experiments/rom-search/updater1.bin').read_bytes()
assert hashlib.sha256(blob).hexdigest() == 'db1db77ede14cdd860a16a774a29925502a5fa6de7010430a6b4c49c4f5d1b09'
rom = (ROOT / 'experiments/rom-search/rom-extraction-readback-v1/ROM01.BIN').read_bytes()
assert hashlib.sha256(rom).hexdigest() == 'c550ea570403b04c536f4b5f401df1452936dc15081b935ace3d755286c51912'
REGS = [UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
        UC_ARM_REG_R4, UC_ARM_REG_R5, UC_ARM_REG_R6, UC_ARM_REG_R7,
        UC_ARM_REG_R8, UC_ARM_REG_R9, UC_ARM_REG_R10, UC_ARM_REG_R11,
        UC_ARM_REG_R12, UC_ARM_REG_SP, UC_ARM_REG_LR, UC_ARM_REG_PC]


def word(u, a, value=None):
    if value is not None:
        u.mem_write(a, struct.pack('<I', value))
    return struct.unpack('<I', u.mem_read(a, 4))[0]


def run(mode, case, full=False):
    started = time.monotonic()
    placed = (build / (mode + '-updater.bin')).exists()
    binary = (build / (mode + '-updater.bin' if placed else mode + '.bin')).read_bytes()
    loaded = binary if placed else blob
    symbols = {line.split()[2]: int(line.split()[0], 16) for line in (build / (mode + '-symbols.txt')).read_text().splitlines() if len(line.split()) == 3}
    u = Uc(UC_ARCH_ARM, UC_MODE_ARM)
    for a, n in [(0, 0xb00000), (0x10000000, 0xb00000), (0xf8000000, 0x800000)]:
        u.mem_map(a, n)
    u.mem_write(0xf8000000, rom)
    u.mem_write(0x800120, loaded)
    u.mem_write(0x1900, loaded[0x99de30 - 0x800120:0x99de30 - 0x800120 + 0x15470 - 0x1900])
    if not placed:
        u.mem_write(0x500000, binary)
    u.reg_write(UC_ARM_REG_CPSR, 0x13)
    state: dict[str, Any] = {'control': 0x1005, 'heap': 0x200000, 'alloc': [], 'free': [], 'erase': [], 'program': [], 'cp15_events': 0, 'body': False, 'checks': 0}

    def ret(value):
        u.reg_write(UC_ARM_REG_R0, value)
        u.reg_write(UC_ARM_REG_PC, u.reg_read(UC_ARM_REG_LR))

    def hook(uc, address, size, data):
        args = [uc.reg_read(r) for r in REGS[:4]]
        if address == 0x9716b8:
            if state['body'] and case == 'allocation-fail':
                ret(0)
                return
            pointer = state['heap']
            state['heap'] += (args[0] + 15) & ~15
            state['alloc'].append([pointer, args[0]])
            ret(pointer)
        elif address == 0x9716f8:
            state['free'].append(args[0])
            ret(0)
        elif address == 0x9741e4:
            assert args[:3] == [0xf8000000, 0, 8192]
            state['erase'].append(args[:3])
            if case != 'erase-odd':
                uc.mem_write(0xf8000000, b'\xff' * 8192)
            ret(1 if case == 'erase-odd' else 2 if case == 'erase-even' else 0)
        elif address == 0x973da0:
            assert args[0:2] == [0xf8000000, 0] and args[3] == 8192
            state['program'].append(args)
            data = bytearray(uc.mem_read(args[2], args[3]))
            if case in ('wrong-flag', 'both-mismatch'):
                data[4:8] = b'\x12' * 4
            if case in ('collateral', 'both-mismatch'):
                data[100] ^= 1
            if case == 'partial-program':
                data = data[:1]
            if case == 'equivalent-tail':
                data = data[:4096]
            uc.mem_write(0xf8000000, bytes(data))
            ret(7 if case == 'program-error' else 0)
        elif address == symbols['code_ok']:
            state['checks'] += 1
            if (case == 'pre-state-change' and state['checks'] == 2) or (case == 'post-state-change' and state['checks'] == 3):
                word(uc, 0x3f34, 0x1008)
            if case == 'pre-flag-change' and state['checks'] == 2:
                word(uc, 0xf8000004, 0x12345678)
            if not full:
                ret(1)
        elif address == 0x96d7bc:
            ret(0xe0000000)
        elif address == 0x96d75c:
            word(uc, 0xf8000008, 0)
        else:
            ins = word(uc, address)
            assert ins & 0x0f000010 == 0x0e000010 and (ins >> 8) & 15 == 15
            rd, crn = (ins >> 12) & 15, (ins >> 16) & 15
            if ins & (1 << 20):
                assert crn in (0, 1), hex(ins)
                uc.reg_write(REGS[rd], 0x0f112112 if crn == 0 else state['control'])
            elif crn == 1:
                state['control'] = uc.reg_read(REGS[rd])
            state['cp15_events'] += 1
            uc.reg_write(UC_ARM_REG_PC, address + 4)

    addresses = {0x9716b8, 0x9716f8, 0x9741e4, 0x973da0, symbols['code_ok']}
    if case == 'invalid-allocation':
        addresses.add(0x96d7bc)
    if case in ('fresh-word8', 'fresh-word8-already'):
        addresses.add(0x96d75c)
    for start, data in ([(0x800120, loaded)] if placed else [(0x800120, blob), (0x500000, binary)]):
        for off in range(0, len(data) - 3, 4):
            ins = struct.unpack_from('<I', data, off)[0]
            if ins & 0x0f000010 == 0x0e000010 and (ins >> 8) & 15 == 15:
                addresses.add(start + off)
    for a in addresses:
        u.hook_add(UC_HOOK_CODE, hook, begin=a, end=a)

    def call(address, *args):
        for reg, value in zip(REGS, args):
            u.reg_write(reg, value)
        u.reg_write(UC_ARM_REG_SP, 0xa00000)
        u.reg_write(UC_ARM_REG_LR, 0xa10000)
        u.emu_start(address, 0xa10000, timeout=120000000, count=100000000)
        assert u.reg_read(UC_ARM_REG_PC) == 0xa10000, hex(u.reg_read(UC_ARM_REG_PC))
        return u.reg_read(UC_ARM_REG_R0)

    assert call(0x96d630, 0xf8000000) == 0
    assert call(0x99cf68, 0, 0) == 0
    if placed:
        for i in range(17):
            assert word(u, 0x1d9c + 8 * i) == 0x8092a8
            assert call(word(u, 0x1d9c + 8 * i)) == 1
        assert not state['erase'] and not state['program']
    desired = 0 if mode == 'disable' else 0xffffffff
    original = bytearray(rom[:8192])
    struct.pack_into('<I', original, 4, desired if case in ('already', 'fresh-word8-already') else 0x12345678 if case == 'unexpected' else desired ^ 0xffffffff)
    u.mem_write(0xf8000000, bytes(original))
    if case == 'missing-registry':
        word(u, 0x31c4, 0)
    if case == 'stale-shadow':
        word(u, 0x3f34, 0x1008)
    if case == 'bad-callback':
        word(u, 0x3a74, 0)
    if case == 'bad-code':
        word(u, 0x9725d8, 0)
    if case.startswith('target-'):
        word(u, int(case.split('-')[1], 16), 0)
    if case.startswith('cache-'):
        word(u, int(case.split('-')[1], 16), 0xdeadbeef)
    sentinel = word(u, 0x31c8)
    node = word(u, sentinel) - 0x24
    if case == 'bad-sentinel':
        word(u, 0x31c8, 0x17ffff)
    if case == 'bad-links':
        word(u, sentinel + 4, 0)
    if case == 'bad-node-count':
        word(u, node + 8, 141)
    if case == 'bad-table':
        word(u, node + 4, 0x6ffffc)
    if case == 'bad-sector':
        word(u, word(u, node + 4) + 4, 65536)
    state['alloc'] = []
    state['body'] = True
    result_address = 0x8092b8 if case in ('guard', 'guard-contended') else 0x18000
    if case == 'guard-contended':
        word(u, 0x902f3c, 0x004e5552)
    if case in ('guard', 'guard-contended'):
        call(symbols['installer_guard'])
        title = bytes(u.mem_read(0x902f33, 9))
        status = int(title[:8], 16) if case == 'guard' else 0
        counts = (len(state['erase']), len(state['program']), len(state['free']))
        call(symbols['installer_guard'])
        assert counts == (len(state['erase']), len(state['program']), len(state['free']))
        assert bytes(u.mem_read(0x902f33, 9)) == title
        assert word(u, 0x902f3c) == 0x004e5552
    else:
        status = call(symbols['installer_body'], result_address)
    result = [word(u, result_address + 4 * i) for i in range(4)]
    final = bytes(u.mem_read(0xf8000000, 8192))
    expected = {'success': 0, 'erase-even': 0, 'already': 1, 'bad-code': 2,
                'missing-registry': 3, 'stale-shadow': 4, 'bad-callback': 4,
                'unexpected': 5, 'allocation-fail': 6, 'erase-odd': 10,
                'program-error': 10, 'wrong-flag': 11, 'collateral': 12,
                'both-mismatch': 12, 'partial-program': 12, 'equivalent-tail': 0,
                'invalid-allocation': 7, 'pre-state-change': 8,
                'pre-flag-change': 8, 'post-state-change': 9,
                'bad-sentinel': 3, 'bad-links': 3, 'bad-node-count': 3,
                'bad-table': 3, 'bad-sector': 3, 'guard': 0, 'guard-contended': 0,
                'fresh-word8': 4, 'fresh-word8-already': 4}.get(case, 4 if case.startswith('cache-') else 2 if case.startswith('target-') else -1)
    assert status == expected, (mode, case, status, result, state)
    if case in ('success', 'erase-even', 'guard', 'equivalent-tail'):
        target = bytearray(original)
        struct.pack_into('<I', target, 4, desired)
        assert final == target and result[:2] == [0, 0] and result[3] == 1
    if case in ('already', 'unexpected', 'missing-registry', 'stale-shadow', 'bad-callback', 'bad-code', 'allocation-fail'):
        assert final == original and not state['erase'] and not state['program']
    if case in ('pre-state-change', 'post-state-change'):
        assert result[3] == 0 and result[2] and len(state['alloc']) == len(state['free']) + 1
    else:
        assert sorted(state['free']) == sorted(a[0] for a in state['alloc'])
    if case == 'both-mismatch':
        assert result[1] == 3
    if case == 'invalid-allocation' or case.startswith('bad-') and case != 'bad-code' or case.startswith('cache-'):
        assert not state['erase'] and not state['program']
    if case.startswith(('target-', 'fresh-word8')):
        assert not state['erase'] and not state['program'] and not state['alloc']
    receipt = {'mode': mode, 'case': case, 'full_fingerprints': full, 'status': status, 'result': result,
               'seconds': time.monotonic() - started, 'state': state,
               'before_sha256': hashlib.sha256(original).hexdigest(), 'after_sha256': hashlib.sha256(final).hexdigest(),
               'limits': 'Synthetic allocator/free and flash callbacks; modeled CP15; original copy/writer/cache/geometry instructions. No physical qualification.'}
    (out / (mode + '-' + case + '.json')).write_text(json.dumps(receipt, indent=2))
    print(mode, case, 'PASS', round(receipt['seconds'], 3), flush=True)


cases: tuple[str, ...] = ('success', 'already', 'unexpected', 'missing-registry', 'stale-shadow', 'bad-callback', 'allocation-fail', 'erase-odd', 'erase-even', 'program-error', 'wrong-flag', 'collateral', 'both-mismatch', 'partial-program', 'equivalent-tail', 'bad-code', 'invalid-allocation', 'pre-state-change', 'post-state-change', 'pre-flag-change', 'bad-sentinel', 'bad-links', 'bad-node-count', 'bad-table', 'bad-sector')
cases += tuple('cache-' + hex(a)[2:] for a in (0x3a70, 0x3a74, 0x3a80, 0x3328, 0x332c, 0x3f40, 0x3f54, 0x3f30, 0x3d34, 0x3f34))
if len(sys.argv) > 3:
    cases = tuple(sys.argv[3].split(','))
for mode in ('enable', 'disable'):
    for case in cases:
        try:
            run(mode, case, case in ('success', 'bad-code') or case.startswith(('target-', 'fresh-word8')))
        except Exception as exc:
            (out / 'failure.json').write_text(json.dumps({'status': 'FAIL', 'mode': mode, 'case': case, 'error': repr(exc)}, indent=2))
            raise
(out / 'summary.json').write_text(json.dumps({'status': 'PASS_MODELED_ONLY', 'cases': len(cases) * 2, 'build': str(build)}, indent=2))
