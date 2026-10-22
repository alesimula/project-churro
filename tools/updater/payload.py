#!/usr/bin/env python3
"""Minimal reader for an A/B OTA zip's payload.bin (update_metadata.proto, no deps).
  payload.py offset <ota.zip>          byte offset of payload.bin inside the zip (stored entry)
  payload.py parts  <ota.zip>          "<name> <old_size> <new_size>" per partition (old_size 0 = full)
  payload.py target <ota.zip> <name>   "<new_size> <sha256 hex>" the partition must have after the update"""
import struct, sys, zipfile

def _v(b, i):
    n = s = 0
    while True:
        x = b[i]; i += 1; n |= (x & 127) << s; s += 7
        if x < 128: return n, i

def _f(b):
    i = 0
    while i < len(b):
        k, i = _v(b, i); f, w = k >> 3, k & 7
        if w == 0: v, i = _v(b, i)
        elif w == 2: l, i = _v(b, i); v = b[i:i + l]; i += l
        elif w == 1: v = b[i:i + 8]; i += 8
        elif w == 5: v = b[i:i + 4]; i += 4
        else: raise ValueError("wire type %d" % w)
        yield f, v

def partitions(zp):
    p = zipfile.ZipFile(zp).open("payload.bin").read(1 << 22)
    if p[:4] != b"CrAU": sys.exit("not a payload")
    m = p[24:24 + struct.unpack(">Q", p[12:20])[0]]
    for f, v in _f(m):
        if f == 13:  # PartitionUpdate
            d = dict(_f(v))
            old = dict(_f(d[6])) if 6 in d else {}
            new = dict(_f(d[7]))
            yield d[1].decode(), old.get(1, 0), new[1], new[2]

def offset(zp):
    z = zipfile.ZipFile(zp); i = z.getinfo("payload.bin")
    if i.compress_type != zipfile.ZIP_STORED: sys.exit("payload.bin is compressed")
    with open(zp, "rb") as f:
        f.seek(i.header_offset); h = f.read(30)
    return i.header_offset + 30 + struct.unpack_from("<H", h, 26)[0] + struct.unpack_from("<H", h, 28)[0]

if __name__ == "__main__":
    cmd, zp = sys.argv[1], sys.argv[2]
    if cmd == "offset": print(offset(zp))
    elif cmd == "parts":
        for n, o, s, _ in partitions(zp): print(n, o, s)
    elif cmd == "target":
        for n, _, s, h in partitions(zp):
            if n == sys.argv[3]: print(s, h.hex()); break
        else: sys.exit("no partition " + sys.argv[3])
