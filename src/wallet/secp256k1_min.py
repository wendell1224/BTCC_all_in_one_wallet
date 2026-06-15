"""Minimal secp256k1 helpers for BIP32 + signing (pure Python, stdlib only)."""

from __future__ import annotations

import hashlib
import hmac
import struct

P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
A = 0
B = 7
Gx = 55066263022277343669578718895168534326250603453777594175500187360389150533434
Gy = 32670510020758816978083085130507043184471273380659243275938904345752686056
G = (Gx, Gy)


def _modinv(a: int, m: int) -> int:
    return pow(a, -1, m)


def _mod_sqrt(a: int) -> int:
    # p % 4 == 3 for secp256k1
    return pow(a, (P + 1) // 4, P)


def point_add(p1: tuple[int, int] | None, p2: tuple[int, int] | None) -> tuple[int, int] | None:
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2 and (y1 + y2) % P == 0:
        return None
    if p1 == p2:
        if y1 == 0:
            return None
        s = (3 * x1 * x1 + A) * _modinv(2 * y1, P) % P
    else:
        s = (y2 - y1) * _modinv(x2 - x1, P) % P
    x3 = (s * s - x1 - x2) % P
    y3 = (s * (x1 - x3) - y1) % P
    return x3, y3


def point_mul(k: int, point: tuple[int, int] = G) -> tuple[int, int] | None:
    k %= N
    if k == 0:
        return None
    result = None
    addend = point
    while k:
        if k & 1:
            result = point_add(result, addend)
        addend = point_add(addend, addend)
        k >>= 1
    return result


def privkey_to_pubkey(priv: bytes, compressed: bool = True) -> bytes:
    k = int.from_bytes(priv, "big")
    if k <= 0 or k >= N:
        raise ValueError("invalid private key")
    pt = point_mul(k)
    if pt is None:
        raise ValueError("invalid private key point")
    x, y = pt
    xb = x.to_bytes(32, "big")
    if compressed:
        return bytes([2 + (y & 1)]) + xb
    return b"\x04" + xb + y.to_bytes(32, "big")


def sign(priv: bytes, digest32: bytes, low_s: bool = True) -> bytes:
    if len(digest32) != 32:
        raise ValueError("digest must be 32 bytes")
    d = int.from_bytes(priv, "big")
    z = int.from_bytes(digest32, "big")
    for _ in range(64):
        k_bytes = hashlib.sha256(priv + digest32 + struct.pack("<I", _)).digest()
        k = int.from_bytes(k_bytes, "big") % N
        if k == 0:
            continue
        r_pt = point_mul(k)
        if r_pt is None:
            continue
        r = r_pt[0] % N
        if r == 0:
            continue
        s = (_modinv(k, N) * (z + r * d)) % N
        if s == 0:
            continue
        if low_s and s > N // 2:
            s = N - s

        def _enc_int(x: int) -> bytes:
            xb = x.to_bytes(32, "big")
            while len(xb) > 1 and xb[0] == 0 and (xb[1] & 0x80) == 0:
                xb = xb[1:]
            if xb[0] & 0x80:
                xb = b"\x00" + xb
            return b"\x02" + bytes([len(xb)]) + xb

        payload = _enc_int(r) + _enc_int(s)
        return b"\x30" + bytes([len(payload)]) + payload
    raise RuntimeError("signing failed")


def ripemd160(data: bytes) -> bytes:
    # OpenSSL is available on macOS; fallback keeps wallet usable without extra deps.
    import subprocess

    p = subprocess.run(
        ["openssl", "dgst", "-ripemd160", "-binary"],
        input=data,
        capture_output=True,
        check=False,
    )
    if p.returncode == 0 and len(p.stdout) == 20:
        return p.stdout
    raise RuntimeError("ripemd160 unavailable (need openssl)")


def hash160(data: bytes) -> bytes:
    return ripemd160(hashlib.sha256(data).digest())


def tagged_hash(tag: str, msg: bytes) -> bytes:
    tag_hash = hashlib.sha256(tag.encode()).digest()
    return hashlib.sha256(tag_hash + tag_hash + msg).digest()
