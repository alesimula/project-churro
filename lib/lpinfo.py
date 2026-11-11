#!/usr/bin/env python3
"""Minimal Android liblp (super partition) metadata tool.
  lpinfo.py <super>                     list "<name> <byte offset> <byte size>"
  lpinfo.py <super> <name>              print "<offset> <size>" of one (single-extent) partition
  lpinfo.py <super> grow <name> <bytes> grow that partition: in place if the next partition is
                                        far enough, else moved to the free space at the end of
                                        super; rewrites every metadata slot; prints "<offset> <size>"
Formats: system/core/fs_mgr/liblp/include/liblp/metadata_format.h"""
import hashlib, struct, sys

RESERVED, GEOM_SIZE = 4096, 4096
HDR_FMT_SIZE = 256

class Super:
    def __init__(self, path, write=False):
        self.f = open(path, "r+b" if write else "rb")
        self.f.seek(RESERVED)
        g = self.f.read(GEOM_SIZE)
        magic, _ = struct.unpack_from("<II", g, 0)
        if magic != 0x616C4467:
            sys.exit("no LP geometry")
        self.max_meta, self.slots, self.lbs = struct.unpack_from("<III", g, 40)
        self.base = RESERVED + GEOM_SIZE * 2
        self.load(self.base)

    def load(self, off):
        self.f.seek(off)
        self.hdr = bytearray(self.f.read(HDR_FMT_SIZE))
        self.hsize = struct.unpack_from("<I", self.hdr, 8)[0]
        self.hdr = self.hdr[:self.hsize]
        self.tsize = struct.unpack_from("<I", self.hdr, 44)[0]
        self.descs = [list(struct.unpack_from("<III", self.hdr, 80 + 12 * i)) for i in range(4)]
        self.f.seek(off + self.hsize)
        self.tables = bytearray(self.f.read(self.tsize))

    def rows(self, i):
        o, n, sz = self.descs[i]
        return [(o + k * sz) for k in range(n)]

    def parts(self):
        out = []
        ext_rows = self.rows(1)
        for r in self.rows(0):
            name = self.tables[r:r + 36].rstrip(b"\0").decode()
            _, fe, ne, gi = struct.unpack_from("<IIII", self.tables, r + 36)
            exts = [struct.unpack_from("<QIQI", self.tables, ext_rows[i]) + (ext_rows[i],) for i in range(fe, fe + ne)]
            out.append((name, exts, gi))
        return out

    def find(self, name):
        for n, exts, gi in self.parts():
            if n == name:
                return exts, gi
        sys.exit(f"no partition {name}")

    def write_all(self):
        struct.pack_into("<32s", self.hdr, 48, hashlib.sha256(self.tables).digest())
        struct.pack_into("<32s", self.hdr, 12, b"\0" * 32)
        struct.pack_into("<32s", self.hdr, 12, hashlib.sha256(self.hdr).digest())
        blob = bytes(self.hdr) + bytes(self.tables)
        for copy in range(2):  # primary slots, then backup slots
            for s in range(self.slots):
                self.f.seek(self.base + (copy * self.slots + s) * self.max_meta)
                self.f.write(blob)
        self.f.flush()

    def grow(self, name, newsize):
        exts, gi = self.find(name)
        if len(exts) != 1 or exts[0][1] != 0:
            sys.exit("only single linear extents supported")
        nsec, _, start, _, row = exts[0]
        need = (newsize + 511) // 512
        if need <= nsec:
            return start * 512, nsec * 512
        # group limit (0 = unlimited)
        g = self.rows(2)[gi]
        gmax = struct.unpack_from("<Q", self.tables, g + 40)[0]
        used = sum(e[0] for n, es, gg in self.parts() if gg == gi for e in es) * 512
        if gmax and used - nsec * 512 + need * 512 > gmax:
            sys.exit(f"group limit {gmax} exceeded")
        bd = self.rows(3)[0]
        first, align, _, bdsize = struct.unpack_from("<QIIQ", self.tables, bd)
        ext = [e for n, es, gg in self.parts() for e in es if e[1] == 0]
        if start + need <= min([e[2] for e in ext if e[2] > start] + [bdsize // 512]):
            new_start = start  # fits before the next partition (alignment gap): stays where it is
        else:
            al = max(align, 1 << 20) // 512
            new_start = (max(max(e[2] + e[0] for e in ext), first) + al - 1) // al * al
            if (new_start + need) * 512 > bdsize:
                sys.exit("not enough free space in super")
        struct.pack_into("<QIQI", self.tables, row, need, 0, new_start, 0)
        self.write_all()
        return new_start * 512, need * 512

if __name__ == "__main__":
    a = sys.argv
    if len(a) == 5 and a[2] == "grow":
        o, s = Super(a[1], write=True).grow(a[3], int(a[4]))
        print(o, s); sys.exit(0)
    sp = Super(a[1])
    if len(a) == 3:
        exts, _ = sp.find(a[2])
        if len(exts) == 1 and exts[0][1] == 0:
            print(exts[0][2] * 512, exts[0][0] * 512); sys.exit(0)
        sys.exit(1)
    for n, exts, _ in sp.parts():
        if len(exts) == 1 and exts[0][1] == 0:
            print(n, exts[0][2] * 512, exts[0][0] * 512)
        else:
            print(n, -1, sum(e[0] for e in exts) * 512)
