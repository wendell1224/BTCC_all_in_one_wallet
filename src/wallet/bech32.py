"""BIP173 bech32 encode/decode with configurable HRP (BTCC uses 'cc')."""

from __future__ import annotations

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def _polymod(values):
    generators = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
    chk = 1
    for v in values:
        top = chk >> 25
        chk = ((chk & 0x1FFFFFF) << 5) ^ v
        for i in range(5):
            if (top >> i) & 1:
                chk ^= generators[i]
    return chk


def _hrp_expand(hrp: str) -> list[int]:
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]


def _create_checksum(hrp: str, data: list[int]) -> list[int]:
    values = _hrp_expand(hrp) + data
    polymod = _polymod(values + [0, 0, 0, 0, 0, 0]) ^ 1
    return [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]


def _verify_checksum(hrp: str, data: list[int]) -> bool:
    return _polymod(_hrp_expand(hrp) + data) == 1


def _convertbits(data, frombits, tobits, pad=True):
    acc = 0
    bits = 0
    ret = []
    maxv = (1 << tobits) - 1
    for value in data:
        if value < 0 or (value >> frombits):
            raise ValueError("invalid value")
        acc = (acc << frombits) | value
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad and bits:
        ret.append((acc << (tobits - bits)) & maxv)
    elif bits >= frombits or ((acc << (tobits - bits)) & maxv):
        raise ValueError("invalid padding")
    return ret


def encode(hrp: str, witver: int, witprog: bytes) -> str:
    if witver < 0 or witver > 16:
        raise ValueError("invalid witness version")
    data = [witver] + _convertbits(list(witprog), 8, 5)
    combined = data + _create_checksum(hrp, data)
    return hrp + "1" + "".join(CHARSET[d] for d in combined)


def decode(addr: str) -> tuple[str, int, bytes]:
    if any(ord(x) < 33 or ord(x) > 126 for x in addr):
        raise ValueError("invalid character")
    addr = addr.lower()
    pos = addr.rfind("1")
    if pos < 1 or pos + 7 > len(addr) or len(addr) > 90:
        raise ValueError("invalid bech32")
    hrp = addr[:pos]
    data = [CHARSET.find(c) for c in addr[pos + 1 :]]
    if -1 in data or not _verify_checksum(hrp, data):
        raise ValueError("checksum failed")
    data = data[:-6]
    witver = data[0]
    prog = bytes(_convertbits(data[1:], 5, 8, False))
    if witver > 16 or len(prog) < 2 or len(prog) > 40:
        raise ValueError("invalid witness program")
    return hrp, witver, prog


def p2wpkh_address(pubkey: bytes, hrp: str = "cc") -> str:
    from .secp256k1_min import hash160

    if len(pubkey) == 33:
        prog = hash160(pubkey)
    else:
        raise ValueError("need compressed pubkey")
    return encode(hrp, 0, prog)
