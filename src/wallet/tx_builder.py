"""Build and sign BTCC P2WPKH transactions with standard outputs."""

from __future__ import annotations

import hashlib
import struct
from typing import Any

from .bech32 import decode
from .secp256k1_min import hash160, sign

SIGHASH_ALL = 1
MIN_CHANGE = 546
MIN_RELAY_FEE = 546
BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


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


def _script_pubkey_p2tr(xonly_pubkey: bytes) -> bytes:
    return bytes([0x51, 0x20]) + xonly_pubkey


def _script_pubkey_p2pkh(pubkey_hash: bytes) -> bytes:
    return bytes([0x76, 0xA9, 0x14]) + pubkey_hash + bytes([0x88, 0xAC])


def _script_pubkey_p2sh(script_hash: bytes) -> bytes:
    return bytes([0xA9, 0x14]) + script_hash + bytes([0x87])


def _outpoint(txid_hex: str, vout: int) -> bytes:
    txid = bytes.fromhex(txid_hex)
    return _reverse32(txid) + struct.pack("<I", vout)


def _tx_output(value: int, script_pubkey: bytes) -> bytes:
    return struct.pack("<q", value) + _varint(len(script_pubkey)) + script_pubkey


def _varint_size(n: int) -> int:
    if n < 0xFD:
        return 1
    if n <= 0xFFFF:
        return 3
    if n <= 0xFFFFFFFF:
        return 5
    return 9


def _script_pubkey_op_return(data: bytes) -> bytes:
    if len(data) > 80:
        raise ValueError("memo must be at most 80 bytes")
    if len(data) <= 75:
        return bytes([0x6A, len(data)]) + data
    return bytes([0x6A, 0x4C, len(data)]) + data


def _base58check_decode(address: str) -> bytes:
    n = 0
    for ch in address:
        idx = BASE58_ALPHABET.find(ch)
        if idx < 0:
            raise ValueError("invalid base58 character")
        n = n * 58 + idx
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    pad = len(address) - len(address.lstrip("1"))
    raw = b"\x00" * pad + raw
    if len(raw) < 5:
        raise ValueError("invalid base58 address")
    payload, checksum = raw[:-4], raw[-4:]
    check = hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
    if checksum != check:
        raise ValueError("checksum failed")
    return payload


def _estimate_vsize(n_in: int, outputs: list[bytes]) -> int:
    # P2WPKH: rough input weight + exact serialized output sizes.
    return 10 + n_in * 68 + sum(len(output) for output in outputs)


def _memo_output(memo: str) -> bytes | None:
    text = memo.strip()
    if not text:
        return None
    script = _script_pubkey_op_return(text.encode("utf-8"))
    return _tx_output(0, script)


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
    addr = address.strip()
    if addr.lower().startswith("cc1"):
        hrp, witver, prog = decode(addr)
        if hrp != "cc":
            raise ValueError("unsupported witness address hrp")
        if witver == 0 and len(prog) == 20:
            return _script_pubkey_p2wpkh(prog)
        if witver == 1 and len(prog) == 32:
            return _script_pubkey_p2tr(prog)
        raise ValueError("unsupported witness address type")

    payload = _base58check_decode(addr)
    if len(payload) != 21:
        raise ValueError("invalid legacy address length")
    version, h = payload[0], payload[1:]
    if version == 0x00:
        return _script_pubkey_p2pkh(h)
    if version == 0x05:
        return _script_pubkey_p2sh(h)
    raise ValueError("unsupported legacy address version")


def _select_utxos(
    utxos: list[dict[str, Any]],
    amount_sats: int,
    fee_rate: int,
    outputs: list[bytes],
) -> list[dict[str, Any]]:
    ordered = sorted(utxos, key=lambda u: int(u["value"]), reverse=True)
    selected: list[dict[str, Any]] = []
    total = 0
    for u in ordered:
        selected.append(u)
        total += int(u["value"])
        fee = max(fee_rate * _estimate_vsize(len(selected), outputs), MIN_RELAY_FEE)
        if total >= amount_sats + fee:
            return selected
    raise ValueError("insufficient funds")


def build_signed_tx(
    utxos: list[dict[str, Any]],
    recipient: str,
    amount_sats: int,
    change_address: str,
    privkey: bytes,
    pubkey: bytes,
    fee_rate_sat_vb: int,
    locktime: int = 0,
    memo: str = "",
) -> str:
    if amount_sats <= 0:
        raise ValueError("amount must be positive")
    if not utxos:
        raise ValueError("no UTXOs")

    recipient_output = _tx_output(amount_sats, address_to_script_pubkey(recipient))
    outputs = [recipient_output]
    memo_out = _memo_output(memo)
    if memo_out is not None:
        outputs.append(memo_out)

    selected = _select_utxos(utxos, amount_sats, fee_rate_sat_vb, outputs)
    pubkey_hash = hash160(pubkey)
    script_code = bytes([0x76, 0xA9, 0x14]) + pubkey_hash + bytes([0x88, 0xAC])

    inputs = []
    total_in = 0
    for u in selected:
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

    fee = max(fee_rate_sat_vb * _estimate_vsize(len(inputs), outputs), MIN_RELAY_FEE)
    change = total_in - amount_sats - fee
    if change >= MIN_CHANGE:
        change_script = address_to_script_pubkey(change_address)
        no_change_leftover = change
        fee_with_change = max(
            fee_rate_sat_vb * _estimate_vsize(len(inputs), outputs + [_tx_output(change, change_script)]),
            MIN_RELAY_FEE,
        )
        change_with_output = total_in - amount_sats - fee_with_change
        if change_with_output >= MIN_CHANGE:
            fee = fee_with_change
            change = change_with_output
            outputs.append(_tx_output(change, change_script))
        else:
            change = no_change_leftover
    if change < 0:
        raise ValueError("insufficient funds")

    version = 2
    vin = b""
    for inp in inputs:
        vin += _outpoint(inp["txid"], inp["vout"])
        vin += b"\x00"  # empty scriptSig (witness lives in witness stack)
        vin += struct.pack("<I", inp["sequence"])
    vout = b"".join(outputs)

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
            SIGHASH_ALL,
        )
        digest = hashlib.sha256(hashlib.sha256(preimage).digest()).digest()
        sig_der = sign(privkey, digest)
        witnesses.append([sig_der + bytes([SIGHASH_ALL]), pubkey])

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
