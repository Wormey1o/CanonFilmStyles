"""Pure FAT16 boot-marker transformation; no filesystem or device interface."""
import struct


def prepare(mbr: bytes, sector: bytes, device_bytes: int) -> tuple[int, bytes]:
    if len(mbr) != 512 or len(sector) != 512 or mbr[510:] != b'\x55\xaa' or sector[510:] != b'\x55\xaa':
        raise ValueError('sector signature/length')
    entries = [mbr[446 + i * 16:462 + i * 16] for i in range(4)]
    used = [e for e in entries if e[4] != 0]
    if len(used) != 1 or used[0][4] not in (4, 6, 14):
        raise ValueError('one FAT16 partition required')
    if used[0][0] not in (0, 0x80) or any(e != bytes(16) for e in entries if e[4] == 0):
        raise ValueError('unsupported partition status or nonempty unused entry')
    lba, count = struct.unpack_from('<II', used[0], 8)
    if not lba or not count or (lba + count) * 512 > device_bytes:
        raise ValueError('partition bounds')
    bps = struct.unpack_from('<H', sector, 11)[0]
    spc, nf = sector[13], sector[16]
    reserved, root_entries = struct.unpack_from('<H', sector, 14)[0], struct.unpack_from('<H', sector, 17)[0]
    fat_sectors = struct.unpack_from('<H', sector, 22)[0]
    short_total = struct.unpack_from('<H', sector, 19)[0]
    long_total = struct.unpack_from('<I', sector, 32)[0]
    if short_total and long_total or struct.unpack_from('<I', sector, 28)[0] != lba:
        raise ValueError('contradictory total sectors or hidden-sector LBA')
    total = short_total or long_total
    if bps != 512 or spc not in (1, 2, 4, 8, 16, 32, 64, 128) or nf != 2 or not reserved or not root_entries or root_entries % 16 or not fat_sectors or not 0 < total <= count:
        raise ValueError('unsupported FAT16 geometry')
    overhead = reserved + nf * fat_sectors + (root_entries * 32 + 511) // 512
    clusters = (total - overhead) // spc
    if not 4085 <= clusters <= 65524 or (clusters + 2) * 2 > fat_sectors * 512:
        raise ValueError('FAT16 cluster bounds')
    if sector[64:72] == b'BOOTDISK':
        raise ValueError('already bootable; original backup required')
    output = bytearray(sector)
    output[43:54] = b'EOS_DEVELOP'
    output[64:72] = b'BOOTDISK'
    return lba, bytes(output)


def restore(current: bytes, original: bytes) -> bytes:
    if len(current) != 512 or len(original) != 512 or original[64:72] == b'BOOTDISK':
        raise ValueError('invalid saved original')
    expected = bytearray(original)
    expected[43:54], expected[64:72] = b'EOS_DEVELOP', b'BOOTDISK'
    if current != expected:
        raise ValueError('boot sector drift; no automatic overwrite')
    return original
