#!/usr/bin/env python3
"""Generate the CBZ fixture archives used by src/services/cbz_pure.zig.

Deterministic: a hand-written zip writer (fixed DOS date, fixed attributes) and
a hand-written fixed-Huffman deflate encoder, so the output never depends on
the local zlib build. tests/features/test_reader_quality.py regenerates these
into a temp dir and asserts they are byte-identical to the committed copies.

    python3 tests/fixtures/gen_cbz_fixtures.py [OUT_DIR]   # default src/services/testdata
"""
import os
import struct
import sys
import zlib

LOCAL_SIG, CD_SIG, EOCD_SIG, ZIP64_LOCATOR_SIG = 0x04034B50, 0x02014B50, 0x06054B50, 0x07064B50
DOS_TIME = 0
DOS_DATE = ((2020 - 1980) << 9) | (1 << 5) | 1


# ── Minimal PNG (stored zlib IDAT, so no zlib-version dependence) ──
def png(w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    idat = b"\x78\x01\x01" + struct.pack("<HH", len(raw), len(raw) ^ 0xFFFF) + raw + struct.pack(">I", zlib.adler32(raw))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", idat) + chunk(b"IEND", b""))


# ── Fixed-Huffman deflate: literals + distance-1 run matches ──
class Bits:
    def __init__(self):
        self.out, self.acc, self.n = bytearray(), 0, 0

    def put(self, value, count):
        self.acc |= value << self.n
        self.n += count
        while self.n >= 8:
            self.out.append(self.acc & 0xFF)
            self.acc >>= 8
            self.n -= 8

    def code(self, code, length):
        self.put(int(format(code, "0%db" % length)[::-1], 2), length)

    def done(self):
        if self.n:
            self.out.append(self.acc & 0xFF)
        return bytes(self.out)


LEN_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
LEN_EXTRA = [0] * 8 + [1] * 4 + [2] * 4 + [3] * 4 + [4] * 4 + [5] * 4 + [0]


def _sym(b, v):
    if v < 144:
        b.code(0x30 + v, 8)
    elif v < 256:
        b.code(0x190 + v - 144, 9)
    elif v < 280:
        b.code(v - 256, 7)
    else:
        b.code(0xC0 + v - 280, 8)


def _match(b, length):
    for i in reversed(range(len(LEN_BASE))):
        if length >= LEN_BASE[i]:
            _sym(b, 257 + i)
            if LEN_EXTRA[i]:
                b.put(length - LEN_BASE[i], LEN_EXTRA[i])
            break
    b.code(0, 5)  # distance code 0 = distance 1


def deflate(data):
    b = Bits()
    b.put(1, 1)  # BFINAL
    b.put(1, 2)  # BTYPE = fixed Huffman
    i, n = 0, len(data)
    while i < n:
        v = data[i]
        _sym(b, v)
        i += 1
        j = i
        while j < n and data[j] == v:
            j += 1
        run = j - i
        while run >= 3:
            length = min(run, 258)
            _match(b, length)
            i += length
            run -= length
    _sym(b, 256)
    out = b.done()
    assert zlib.decompress(out, -15) == bytes(data), "fixture deflate encoder is broken"
    return out


# ── Zip writer with per-field overrides for hostile fixtures ──
def entry(name, data, method=0, **over):
    payload = deflate(data) if method == 8 else data
    if "payload" in over:
        payload = over["payload"]
    return dict(name=name.encode(), payload=payload, method=method, flags=over.get("flags", 0),
                crc=over.get("crc", zlib.crc32(data) & 0xFFFFFFFF), usize=over.get("usize", len(data)),
                cd_csize=over.get("cd_csize"))


def build(entries, total=None, zip64_locator=False):
    out, cd = bytearray(), bytearray()
    for e in entries:
        off = len(out)
        out += struct.pack("<IHHHHHIIIHH", LOCAL_SIG, 20, e["flags"], e["method"], DOS_TIME, DOS_DATE,
                           e["crc"], len(e["payload"]), e["usize"], len(e["name"]), 0)
        out += e["name"] + e["payload"]
        csize = e["cd_csize"] if e["cd_csize"] is not None else len(e["payload"])
        cd += struct.pack("<IHHHHHHIIIHHHHHII", CD_SIG, 20, 20, e["flags"], e["method"], DOS_TIME, DOS_DATE,
                          e["crc"], csize, e["usize"], len(e["name"]), 0, 0, 0, 0, 0, off)
        cd += e["name"]
    cd_off = len(out)
    out += cd
    if zip64_locator:
        out += struct.pack("<IIQI", ZIP64_LOCATOR_SIG, 0, len(out), 1)
    count = len(entries) if total is None else total
    out += struct.pack("<IHHHHIIH", EOCD_SIG, 0, 0, count, count, len(cd), cd_off, 0)
    return bytes(out)


def fixtures():
    page = lambda i: png(8, 12, ((i * 40) % 256, 80, 200 - i * 10))
    good = build([
        entry("Vol 1/p10.png", page(10), method=8),
        entry("Vol 1/p2.png", page(2)),
        entry("ComicInfo.xml", b"<ComicInfo><Title>Fixture</Title></ComicInfo>"),
        entry("__MACOSX/Vol 1/._p1.png", b"\x00\x05\x16\x07resource-fork"),
        entry("Vol 1/p1.png", page(1)),
        entry("Vol 1/", b""),
        entry("Vol 1/p3.png", page(3), method=8),
    ])
    traversal = build([
        entry("../evil.png", page(4)),
        entry("/abs.png", page(5)),
        entry("C:/drive.png", page(6)),
        entry("a\\..\\b.png", page(7)),
        entry("x/../../up.png", page(8)),
        entry("ok/page1.png", page(1)),
    ])
    corrupt = build([
        entry("fine.png", page(1)),
        entry("bad-deflate.png", page(2), method=8, payload=b"\xff" * 24),
        entry("bad-crc.png", page(3), crc=0xDEADBEEF),
        entry("liar.png", b"\x00" * 100000, method=8, usize=64),
        entry("huge.png", page(4), usize=1 << 30),
        entry("locked.png", page(5), flags=1),
        entry("past-end.png", page(6), cd_csize=0x7FFFFFF0),
    ])
    zip64 = build([entry("p1.png", page(1))], zip64_locator=True)
    many = build([entry("p1.png", page(1))], total=60000)
    return {
        "reader-good.cbz": good,
        "reader-traversal.cbz": traversal,
        "reader-corrupt.cbz": corrupt,
        "reader-zip64.cbz": zip64,
        "reader-many.cbz": many,
    }


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    out_dir = argv[1] if len(argv) > 1 else os.path.join(root, "src", "services", "testdata")
    os.makedirs(out_dir, exist_ok=True)
    for name, data in fixtures().items():
        with open(os.path.join(out_dir, name), "wb") as f:
            f.write(data)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
