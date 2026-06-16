"""Minimal secp256k1 helpers for BIP32 and transaction signing."""

from __future__ import annotations

import hashlib
import subprocess

P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
G = (GX, GY)


def privkey_to_pubkey(priv: bytes, compressed: bool = True) -> bytes:
    k = int.from_bytes(priv, "big")
    if k <= 0 or k >= N:
        raise ValueError("invalid private key")
    x, y = _point_mul(k, G)
    xb = x.to_bytes(32, "big")
    yb = y.to_bytes(32, "big")
    if compressed:
        return bytes([0x02 | (y & 1)]) + xb
    return b"\x04" + xb + yb


def sign(priv: bytes, digest32: bytes, low_s: bool = True) -> bytes:
    if len(digest32) != 32:
        raise ValueError("digest must be 32 bytes")
    d = int.from_bytes(priv, "big")
    if d <= 0 or d >= N:
        raise ValueError("invalid private key")
    z = int.from_bytes(digest32, "big")

    for k in _rfc6979_k(priv, digest32):
        x, _ = _point_mul(k, G)
        r = x % N
        if r == 0:
            continue
        s = (_modinv(k, N) * (z + r * d)) % N
        if s == 0:
            continue
        if low_s and s > N // 2:
            s = N - s
        return _encode_der(r, s)
    raise RuntimeError("failed to generate signature")


def _rfc6979_k(priv: bytes, digest32: bytes):
    x = priv
    h1 = digest32
    v = b"\x01" * 32
    k = b"\x00" * 32
    k = hmac_sha256(k, v + b"\x00" + x + h1)
    v = hmac_sha256(k, v)
    k = hmac_sha256(k, v + b"\x01" + x + h1)
    v = hmac_sha256(k, v)
    while True:
        v = hmac_sha256(k, v)
        candidate = int.from_bytes(v, "big")
        if 1 <= candidate < N:
            yield candidate
        k = hmac_sha256(k, v + b"\x00")
        v = hmac_sha256(k, v)


def hmac_sha256(key: bytes, data: bytes) -> bytes:
    import hmac

    return hmac.new(key, data, hashlib.sha256).digest()


def _modinv(a: int, n: int) -> int:
    return pow(a, -1, n)


def _point_add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2 and (y1 + y2) % P == 0:
        return None
    if p1 == p2:
        m = (3 * x1 * x1) * _modinv(2 * y1 % P, P) % P
    else:
        m = (y2 - y1) * _modinv((x2 - x1) % P, P) % P
    x3 = (m * m - x1 - x2) % P
    y3 = (m * (x1 - x3) - y1) % P
    return x3, y3


def _point_mul(k: int, point):
    result = None
    addend = point
    while k:
        if k & 1:
            result = _point_add(result, addend)
        addend = _point_add(addend, addend)
        k >>= 1
    if result is None:
        raise RuntimeError("invalid scalar multiplication")
    return result


def _encode_der(r: int, s: int) -> bytes:
    def enc_int(x: int) -> bytes:
        xb = x.to_bytes(32, "big")
        while len(xb) > 1 and xb[0] == 0 and (xb[1] & 0x80) == 0:
            xb = xb[1:]
        if xb[0] & 0x80:
            xb = b"\x00" + xb
        return b"\x02" + bytes([len(xb)]) + xb

    payload = enc_int(r) + enc_int(s)
    return b"\x30" + bytes([len(payload)]) + payload


def ripemd160(data: bytes) -> bytes:
    try:
        h = hashlib.new("ripemd160")
        h.update(data)
        return h.digest()
    except (ValueError, TypeError):
        pass

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
