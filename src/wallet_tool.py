#!/usr/bin/env python3
"""BTCC wallet CLI — JSON lines on stdout for GUI integration."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

# Allow `python3 src/wallet_tool.py` without installing package.
_ROOT = os.path.dirname(os.path.abspath(__file__))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from wallet.bech32 import p2wpkh_address
from wallet.bip32 import HDKey
from wallet.bip39 import generate_mnemonic, mnemonic_to_seed
from wallet.tx_builder import build_signed_tx

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


def _keys_from_mnemonic(mnemonic: str) -> tuple[bytes, bytes, str]:
    seed = mnemonic_to_seed(mnemonic)
    hd = HDKey.from_seed(seed).derive(BIP84_PATH)
    priv = hd.priv
    pub = hd.pubkey_compressed()
    addr = p2wpkh_address(pub, hrp="cc")
    return priv, pub, addr


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
    to_addr = args.to.strip()
    if not to_addr.startswith("cc1"):
        raise SystemExit("recipient must be cc1... address")

    amount_sats = int(round(float(args.amount) * 1e8))
    utxo_data = _api_get(f"/api/v1/address/{from_addr}/utxos")
    utxos = list(utxo_data.get("utxos", []))
    if not utxos:
        raise SystemExit("no spendable UTXOs")

    utxos.sort(key=lambda u: int(u["value"]), reverse=True)
    selected = []
    total = 0
    for u in utxos:
        selected.append(u)
        total += int(u["value"])
        fee_est = _fee_rate_sat_vb() * (10 + len(selected) * 68 + 2 * 31)
        if total >= amount_sats + fee_est:
            break
    if total < amount_sats:
        raise SystemExit("insufficient balance")

    rawtx = build_signed_tx(
        selected,
        to_addr,
        amount_sats,
        from_addr,
        priv,
        pub,
        _fee_rate_sat_vb(),
    )
    result = _api_post("/api/v1/tx/broadcast", {"rawtx": rawtx})
    _out({"ok": True, "txid": result.get("txid"), "from": from_addr, "to": to_addr, "amount_sats": amount_sats})
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

    args = parser.parse_args()
    try:
        handlers = {
            "create": cmd_create,
            "import": cmd_import,
            "address": cmd_address,
            "balance": cmd_balance,
            "send": cmd_send,
        }
        return handlers[args.cmd](args)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        _out({"ok": False, "error": f"HTTP {e.code}: {body}"})
        return 1
    except Exception as e:
        _out({"ok": False, "error": str(e)})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
