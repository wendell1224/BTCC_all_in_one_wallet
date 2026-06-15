"""Build and sign BTCC P2WPKH (BIP84) transactions."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from .bech32 import decode
from .secp256k1_min import hash160, sign


def _varint(n: int) -> bytes:
    if n < 0xFD:
        return bytes([n])
    if n <= 0xFFFF:
        return b"\xfd" + struct.pack("<H", n)
    if n <= 0xFFFFFFFF:
        return b"\xfe" + struct.pack("<I", n)
    return b"\xff" + struct.pack("<Q", n)


def _reverse32(b: bytes) -> bytes:
    return bytes(reversed(b))


def _script_pubkey_p2wpkh(pubkey_hash: bytes) -> bytes:
    return bytes([0x00, 0x14]) + pubkey_hash


def _outpoint(txid_hex: str, vout: int) -> bytes:
    txid = bytes.fromhex(txid_hex)
    return _reverse32(txid) + struct.pack("<I", vout)


def _tx_output(value: int, script_pubkey: bytes) -> bytes:
    return struct.pack("<q", value) + _varint(len(script_pubkey)) + script_pubkey


def _bip143_preimage(
    version: int,
    hash_prevouts: bytes,
    hash_sequence: bytes,
    outpoint: bytes,
    script_code: bytes,
    value: int,
    sequence: int,
    hash_outputs: bytes,
    locktime: int,
    sighash_type: int,
) -> bytes:
    return (
        struct.pack("<I", version)
        + hash_prevouts
        + hash_sequence
        + outpoint
        + _varint(len(script_code))
        + script_code
        + struct.pack("<q", value)
        + struct.pack("<I", sequence)
        + hash_outputs
        + struct.pack("<I", locktime)
        + struct.pack("<I", sighash_type)
    )


def address_to_script_pubkey(address: str) -> bytes:
    hrp, witver, prog = decode(address)
    if hrp != "cc" or witver != 0 or len(prog) != 20:
        raise ValueError("only cc1 P2WPKH supported")
    return _script_pubkey_p2wpkh(prog)


def build_signed_tx(
    utxos: list[dict[str, Any]],
    recipient: str,
    amount_sats: int,
    change_address: str,
    privkey: bytes,
    pubkey: bytes,
    fee_rate_sat_vb: int,
    locktime: int = 0,
) -> str:
    if amount_sats <= 0:
        raise ValueError("amount must be positive")
    pubkey_hash = hash160(pubkey)
    script_code = bytes([0x76, 0xA9, 0x14]) + pubkey_hash + bytes([0x88, 0xAC])

    inputs = []
    total_in = 0
    for u in utxos:
        val = int(u["value"])
        total_in += val
        inputs.append(
            {
                "txid": u["tx_hash"],
                "vout": int(u["tx_pos"]),
                "value": val,
                "sequence": 0xFFFFFFFD,
            }
        )

    out_recipient = _tx_output(amount_sats, address_to_script_pubkey(recipient))
    # vbytes estimate: base + inputs*68 + outputs*31
    est_vsize = 10 + len(inputs) * 68 + 2 * 31
    fee = max(fee_rate_sat_vb * est_vsize, 546)
    change = total_in - amount_sats - fee
    if change < 0:
        raise ValueError("insufficient funds")
    outputs = [out_recipient]
    if change >= 546:
        outputs.append(_tx_output(change, address_to_script_pubkey(change_address)))
    else:
        fee += change
        change = 0

    version = 2
    vin = b""
    for inp in inputs:
        vin += _outpoint(inp["txid"], inp["vout"])
        vin += struct.pack("<I", inp["sequence"])
    vout = b""
    for o in outputs:
        vout += o

    hash_prevouts = hashlib.sha256(
        hashlib.sha256(b"".join(_outpoint(i["txid"], i["vout"]) for i in inputs)).digest()
    ).digest()
    hash_sequence = hashlib.sha256(
        hashlib.sha256(b"".join(struct.pack("<I", i["sequence"]) for i in inputs)).digest()
    ).digest()
    hash_outputs = hashlib.sha256(hashlib.sha256(vout).digest()).digest()

    witnesses = []
    for inp in inputs:
        preimage = _bip143_preimage(
            version,
            hash_prevouts,
            hash_sequence,
            _outpoint(inp["txid"], inp["vout"]),
            script_code,
            inp["value"],
            inp["sequence"],
            hash_outputs,
            locktime,
            1,
        )
        digest = hashlib.sha256(hashlib.sha256(preimage).digest()).digest()
        sig_der = sign(privkey, digest)
        witnesses.append([sig_der + bytes([0x01]), pubkey])

    # serialize
    witness_part = b""
    for w in witnesses:
        witness_part += _varint(len(w))
        for item in w:
            witness_part += _varint(len(item)) + item

    body = (
        struct.pack("<I", version)
        + b"\x00\x01"
        + _varint(len(inputs))
        + vin
        + _varint(len(outputs))
        + vout
        + witness_part
        + struct.pack("<I", locktime)
    )
    return body.hex()
