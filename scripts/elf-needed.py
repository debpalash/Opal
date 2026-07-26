#!/usr/bin/env python3
"""Print an ELF binary's DT_NEEDED entries, one per line.

Used by the Docker CI smoke test to enforce the Phase S1 acceptance criterion:
the headless server binary declares no GUI dependency.

Why not `ldd`: ldd resolves the whole TRANSITIVE closure, and libmpv legitimately
pulls in SDL2, X11, GL and friends. An `ldd | grep -q sdl` gate can therefore
never come back clean, and it failed the moment the image actually built. What
S1 claims is narrower and checkable — what *opal itself* links against.

Expected output for the headless build:
    libmpv.so.2, libsqlite3.so.0, libtorrent_wrapper.so, libm.so.6, libc.so.6

Exits non-zero (with nothing on stdout) if the file is not an ELF64 object, so a
broken probe fails the gate loudly instead of passing it vacuously.
"""
import struct
import sys

# Elf64_Shdr field offsets: name(0) type(4) flags(8) addr(16) offset(24)
# size(32) link(40) info(44) addralign(48) entsize(56)
_SHDR = "4xI16xQQI"  # -> (sh_type, sh_offset, sh_size, sh_link)
_SHT_DYNAMIC = 6
_DT_NULL, _DT_NEEDED = 0, 1


def needed(path):
    with open(path, "rb") as fh:
        d = fh.read()
    if d[:4] != b"\x7fELF":
        raise SystemExit(f"{path}: not an ELF file")
    if d[4] != 2:
        raise SystemExit(f"{path}: not ELF64")
    endian = "<" if d[5] == 1 else ">"

    (shoff,) = struct.unpack_from(endian + "Q", d, 0x28)
    shentsize, shnum = struct.unpack_from(endian + "HH", d, 0x3A)
    secs = [
        dict(zip(("type", "off", "size", "link"),
                 struct.unpack_from(endian + _SHDR, d, shoff + i * shentsize)))
        for i in range(shnum)
    ]

    out = []
    for sec in (s for s in secs if s["type"] == _SHT_DYNAMIC):
        strtab = secs[sec["link"]]
        for i in range(sec["size"] // 16):
            tag, val = struct.unpack_from(endian + "QQ", d, sec["off"] + i * 16)
            if tag == _DT_NULL:
                break
            if tag == _DT_NEEDED:
                start = strtab["off"] + val
                out.append(d[start:d.index(b"\0", start)].decode())
    return out


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <elf-binary>")
    libs = needed(sys.argv[1])
    if not libs:
        raise SystemExit(f"{sys.argv[1]}: no DT_NEEDED entries found — probe failed")
    print("\n".join(libs))
