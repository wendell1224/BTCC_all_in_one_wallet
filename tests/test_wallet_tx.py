#!/usr/bin/env python3
"""Transaction build smoke tests."""

import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "src"))

from wallet.bip32 import HDKey
from wallet.bip39 import mnemonic_to_seed
from wallet.bech32 import p2wpkh_address
from wallet.tx_builder import address_to_script_pubkey, build_signed_tx
from wallet.secp256k1_min import sign


class TxBuilderTest(unittest.TestCase):
    def test_sign_does_not_require_openssl_rawin(self):
        mnemonic = "abandon " * 11 + "about"
        hd = HDKey.from_seed(mnemonic_to_seed(mnemonic)).derive("m/84'/0'/0'/0/0")
        sig = sign(hd.priv, bytes.fromhex("11" * 32))
        self.assertEqual(sig[0], 0x30)
        self.assertGreater(len(sig), 60)

    def test_segwit_input_has_empty_scriptsig(self):
        mnemonic = "abandon " * 11 + "about"
        hd = HDKey.from_seed(mnemonic_to_seed(mnemonic)).derive("m/84'/0'/0'/0/0")
        addr = p2wpkh_address(hd.pubkey_compressed(), "cc")
        raw = build_signed_tx(
            [{"tx_hash": "ab" * 32, "tx_pos": 0, "value": 100_000_000}],
            addr,
            50_000_000,
            addr,
            hd.priv,
            hd.pubkey_compressed(),
            10,
        )
        rawb = bytes.fromhex(raw)
        # version(4) + marker(2) + vin_count(1) + outpoint(36)
        idx = 4 + 2 + 1 + 36
        self.assertEqual(rawb[idx], 0, "scriptSig must be empty varint 0x00")

    def test_address_to_script_pubkey_supports_witness_and_legacy(self):
        self.assertEqual(
            address_to_script_pubkey("cc1qul8xq8urtf8rgg4px6xvdz4hf5fufks7grjwvx")[:2],
            b"\x00\x14",
        )
        self.assertEqual(
            address_to_script_pubkey("1BoatSLRHtKNngkdXEeobR76b53LETtpyT")[:3],
            b"\x76\xa9\x14",
        )

    def test_memo_adds_op_return_output(self):
        mnemonic = "abandon " * 11 + "about"
        hd = HDKey.from_seed(mnemonic_to_seed(mnemonic)).derive("m/84'/0'/0'/0/0")
        addr = p2wpkh_address(hd.pubkey_compressed(), "cc")
        raw = build_signed_tx(
            [{"tx_hash": "ab" * 32, "tx_pos": 0, "value": 100_000_000}],
            addr,
            50_000_000,
            addr,
            hd.priv,
            hd.pubkey_compressed(),
            10,
            memo="hello",
        )
        self.assertIn("6a0568656c6c6f", raw)

    def test_memo_rejects_over_80_bytes(self):
        mnemonic = "abandon " * 11 + "about"
        hd = HDKey.from_seed(mnemonic_to_seed(mnemonic)).derive("m/84'/0'/0'/0/0")
        addr = p2wpkh_address(hd.pubkey_compressed(), "cc")
        with self.assertRaisesRegex(ValueError, "80 bytes"):
            build_signed_tx(
                [{"tx_hash": "ab" * 32, "tx_pos": 0, "value": 100_000_000}],
                addr,
                50_000_000,
                addr,
                hd.priv,
                hd.pubkey_compressed(),
                10,
                memo="x" * 81,
            )


if __name__ == "__main__":
    unittest.main()
