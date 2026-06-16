#!/usr/bin/env python3
"""BTCC wallet CLI — JSON lines on stdout for GUI integration."""

from __future__ import annotations

import argparse
import json
import os
import sys
import struct
import urllib.error
import urllib.request
from decimal import Decimal, InvalidOperation

# Allow `python3 src/wallet_tool.py` without installing package.
_ROOT = os.path.dirname(os.path.abspath(__file__))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from wallet.bech32 import p2wpkh_address
from wallet.bip32 import HDKey
from wallet.bip39 import generate_mnemonic, mnemonic_to_seed
from wallet.tx_builder import address_to_script_pubkey, build_signed_tx

API_BASE = os.environ.get("BTCC_API_BASE", "https://api.btc-classic.org")
BIP84_PATH = "m/84'/0'/0'/0/0"


def _out(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False))


def _api_get(path: str) -> dict:
    req = urllib.request.Request(
        f"{API_BASE}{path}",
        headers={"Accept": "application/json", "User-Agent": "BTCCWallet/1.0"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def _api_post(path: str, body: dict) -> dict:
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{API_BASE}{path}",
        data=data,
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "BTCCWallet/1.0",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def _read_varint(data: bytes, offset: int) -> tuple[int, int]:
    prefix = data[offset]
    if prefix < 0xFD:
        return prefix, offset + 1
    if prefix == 0xFD:
        return struct.unpack_from("<H", data, offset + 1)[0], offset + 3
    if prefix == 0xFE:
        return struct.unpack_from("<I", data, offset + 1)[0], offset + 5
    return struct.unpack_from("<Q", data, offset + 1)[0], offset + 9


def _parse_tx_hex(hex_tx: str) -> dict:
    data = bytes.fromhex(hex_tx)
    offset = 0
    version = struct.unpack_from("<I", data, offset)[0]
    offset += 4
    segwit = False
    if data[offset : offset + 2] == b"\x00\x01":
        segwit = True
        offset += 2
    vin_count, offset = _read_varint(data, offset)
    inputs = []
    for _ in range(vin_count):
        txid = data[offset : offset + 32][::-1].hex()
        offset += 32
        vout = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        script_len, offset = _read_varint(data, offset)
        script_sig = data[offset : offset + script_len]
        offset += script_len
        sequence = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        inputs.append({"txid": txid, "vout": vout, "script_sig": script_sig.hex(), "sequence": sequence})
    vout_count, offset = _read_varint(data, offset)
    outputs = []
    for idx in range(vout_count):
        value = struct.unpack_from("<q", data, offset)[0]
        offset += 8
        script_len, offset = _read_varint(data, offset)
        script = data[offset : offset + script_len]
        offset += script_len
        outputs.append({"index": idx, "value": value, "script": script.hex()})
    if segwit:
        for _ in range(vin_count):
            items, offset = _read_varint(data, offset)
            witness = []
            for _ in range(items):
                item_len, offset = _read_varint(data, offset)
                witness.append(data[offset : offset + item_len].hex())
                offset += item_len
    locktime = struct.unpack_from("<I", data, offset)[0]
    return {"version": version, "segwit": segwit, "inputs": inputs, "outputs": outputs, "locktime": locktime}


def _tx_detail(txid: str, cache: dict[str, dict]) -> dict:
    if txid not in cache:
        raw = _api_get(f"/api/v1/tx/{txid}")
        cache[txid] = _parse_tx_hex(raw.get("hex", ""))
    return cache[txid]


def _classify_tx_action(txid: str, parsed: dict, our_script_hex: str, cache: dict[str, dict]) -> tuple[str, int]:
    our_output_value = sum(
        out.get("value", 0) for out in parsed.get("outputs", []) if out.get("script") == our_script_hex
    )
    our_input_value = 0
    unresolved_inputs = 0
    for inp in parsed.get("inputs", []):
        prev_txid = inp.get("txid", "")
        if not prev_txid or prev_txid == "00" * 32:
            continue
        try:
            prev = _tx_detail(prev_txid, cache)
            prev_out = prev.get("outputs", [])[int(inp.get("vout", -1))]
        except Exception:
            unresolved_inputs += 1
            continue
        if prev_out.get("script") == our_script_hex:
            our_input_value += int(prev_out.get("value", 0))

    if unresolved_inputs > 0 and our_input_value == 0 and our_output_value > 0:
        return "未知", 0

    net = our_output_value - our_input_value
    if our_input_value > 0 and our_output_value > 0 and net == 0:
        return "自转账", 0
    if our_input_value > 0:
        return "转账", net
    if our_output_value > 0:
        return "收到", our_output_value
    return "未知", 0


def _keys_from_mnemonic(mnemonic: str) -> tuple[bytes, bytes, str]:
    seed = mnemonic_to_seed(mnemonic)
    hd = HDKey.from_seed(seed).derive(BIP84_PATH)
    priv = hd.priv
    pub = hd.pubkey_compressed()
    addr = p2wpkh_address(pub, hrp="cc")
    return priv, pub, addr


def _amount_to_sats(amount_text: str) -> int:
    cleaned = amount_text.strip().replace(",", ".")
    try:
        amount = Decimal(cleaned)
    except InvalidOperation as exc:
        raise ValueError("amount format invalid") from exc
    if not amount.is_finite():
        raise ValueError("amount format invalid")

    sats = amount * Decimal(100_000_000)
    if sats != sats.to_integral_value():
        raise ValueError("amount supports at most 8 decimal places")

    amount_sats = int(sats)
    if amount_sats <= 0:
        raise ValueError("amount must be positive")
    return amount_sats


def _normalize_recipient_address(address: str) -> str:
    addr = address.strip()
    if not addr:
        raise ValueError("recipient address is required")
    try:
        address_to_script_pubkey(addr)
    except ValueError as exc:
        raise ValueError(f"unsupported recipient address: {exc}") from exc
    return addr.lower() if addr.lower().startswith("cc1") else addr


def _memo_text(memo: str) -> str:
    text = memo.strip()
    if not text:
        return ""
    if len(text.encode("utf-8")) > 80:
        raise ValueError("memo must be at most 80 bytes")
    return text


def cmd_create(_args: argparse.Namespace) -> int:
    mnemonic = generate_mnemonic(128)
    _, _, addr = _keys_from_mnemonic(mnemonic)
    _out({"ok": True, "mnemonic": mnemonic, "address": addr, "path": BIP84_PATH})
    return 0


def cmd_import(args: argparse.Namespace) -> int:
    mnemonic = " ".join(args.mnemonic)
    _, _, addr = _keys_from_mnemonic(mnemonic)
    _out({"ok": True, "address": addr, "path": BIP84_PATH})
    return 0


def cmd_address(args: argparse.Namespace) -> int:
    _, _, addr = _keys_from_mnemonic(" ".join(args.mnemonic))
    _out({"ok": True, "address": addr})
    return 0


def cmd_balance(args: argparse.Namespace) -> int:
    data = _api_get(f"/api/v1/address/{args.address}/balance")
    _out(
        {
            "ok": True,
            "address": data.get("address"),
            "confirmed": data.get("confirmed", 0),
            "unconfirmed": data.get("unconfirmed", 0),
            "total": data.get("total", 0),
        }
    )
    return 0


def _fee_rate_sat_vb() -> int:
    try:
        est = _api_get("/api/v1/fees/estimate")
        rate = float(est.get("fee_rate_btcc_per_kvb", 0.00001))
        sat_vb = int(rate * 1e8 / 1000)
        return max(sat_vb, 2)
    except Exception:
        return 10


def cmd_send(args: argparse.Namespace) -> int:
    mnemonic = " ".join(args.mnemonic)
    priv, pub, from_addr = _keys_from_mnemonic(mnemonic)
    to_addr = _normalize_recipient_address(args.to)

    amount_sats = _amount_to_sats(args.amount)

    utxo_data = _api_get(f"/api/v1/address/{from_addr}/utxos")
    utxos = list(utxo_data.get("utxos", []))
    if not utxos:
        raise ValueError("no spendable UTXOs")

    rawtx = build_signed_tx(
        utxos,
        to_addr,
        amount_sats,
        from_addr,
        priv,
        pub,
        _fee_rate_sat_vb(),
        memo=_memo_text(getattr(args, "memo", "")),
    )
    result = _api_post("/api/v1/tx/broadcast", {"rawtx": rawtx})
    txid = result.get("txid") or result.get("hash") or result.get("id")
    _out({"ok": True, "txid": txid, "from": from_addr, "to": to_addr, "amount_sats": amount_sats})
    return 0


def cmd_history(args: argparse.Namespace) -> int:
    mnemonic = " ".join(args.mnemonic)
    _, _, address = _keys_from_mnemonic(mnemonic)
    our_script = address_to_script_pubkey(address).hex()
    page_size = max(1, int(args.page_size))
    offset = 0
    txs: list[dict] = []
    seen_txids: set[str] = set()
    while True:
        data = _api_get(f"/api/v1/address/{address}/txs?limit={page_size}&offset={offset}")
        page = list(data.get("transactions", []))
        if not page:
            break
        added = 0
        for item in page:
            txid = item.get("tx_hash") or item.get("txid") or ""
            if txid and txid not in seen_txids:
                txs.append(item)
                seen_txids.add(txid)
                added += 1
        if added == 0 or len(page) < page_size:
            break
        offset += page_size
    records = []
    cache: dict[str, dict] = {}
    for item in txs:
        txid = item.get("tx_hash") or item.get("txid") or ""
        if not txid:
            continue
        try:
            cache[txid] = _tx_detail(txid, cache)
        except Exception:
            cache.setdefault(txid, {})
    for item in txs:
        txid = item.get("tx_hash") or item.get("txid") or ""
        if not txid:
            continue
        try:
            parsed = cache.get(txid) or _tx_detail(txid, cache)
            action, amount_sats = _classify_tx_action(txid, parsed, our_script, cache)
        except Exception:
            action, amount_sats = "未知", 0
        records.append(
            {
                "txid": txid,
                "height": item.get("height"),
                "action": action,
                "amount_sats": amount_sats,
            }
        )
    _out(
        {
            "ok": True,
            "address": address,
            "page_size": page_size,
            "transactions": records,
        }
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="BTCC wallet tool")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("create", help="generate new mnemonic wallet")

    p_import = sub.add_parser("import", help="validate mnemonic and derive address")
    p_import.add_argument("mnemonic", nargs="+")

    p_addr = sub.add_parser("address", help="derive address from mnemonic")
    p_addr.add_argument("mnemonic", nargs="+")

    p_bal = sub.add_parser("balance", help="query balance via BTCC API")
    p_bal.add_argument("address")

    p_send = sub.add_parser("send", help="send BTCC to address")
    p_send.add_argument("mnemonic", nargs="+")
    p_send.add_argument("--to", required=True)
    p_send.add_argument("--amount", required=True, help="amount in BTCC (e.g. 0.001)")
    p_send.add_argument("--memo", default="", help="optional on-chain memo, max 80 UTF-8 bytes")

    p_hist = sub.add_parser("history", help="list wallet transaction history")
    p_hist.add_argument("mnemonic", nargs="+")
    p_hist.add_argument("--page-size", default="30")

    args = parser.parse_args()
    try:
        handlers = {
            "create": cmd_create,
            "import": cmd_import,
            "address": cmd_address,
            "balance": cmd_balance,
            "send": cmd_send,
            "history": cmd_history,
        }
        return handlers[args.cmd](args)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        try:
            detail = json.loads(body).get("detail", body)
        except json.JSONDecodeError:
            detail = body
        _out({"ok": False, "error": f"HTTP {e.code}: {detail}"})
        return 1
    except Exception as e:
        _out({"ok": False, "error": str(e)})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
