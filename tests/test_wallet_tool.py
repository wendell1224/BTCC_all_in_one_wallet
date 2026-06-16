#!/usr/bin/env python3
"""Wallet CLI helper tests."""

import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "src"))

import wallet_tool


class WalletToolTest(unittest.TestCase):
    def test_amount_to_sats_is_exact(self):
        self.assertEqual(wallet_tool._amount_to_sats("0.00000001"), 1)
        self.assertEqual(wallet_tool._amount_to_sats("1,23456789"), 123_456_789)

    def test_amount_to_sats_rejects_lossy_values(self):
        with self.assertRaisesRegex(ValueError, "8 decimal"):
            wallet_tool._amount_to_sats("0.000000001")
        with self.assertRaisesRegex(ValueError, "positive"):
            wallet_tool._amount_to_sats("0")
        with self.assertRaisesRegex(ValueError, "format"):
            wallet_tool._amount_to_sats("nan")

    def test_normalize_recipient_address_accepts_supported_types(self):
        addr = "cc1qul8xq8urtf8rgg4px6xvdz4hf5fufks7grjwvx"
        self.assertEqual(wallet_tool._normalize_recipient_address(addr), addr)
        self.assertEqual(
            wallet_tool._normalize_recipient_address("1BoatSLRHtKNngkdXEeobR76b53LETtpyT"),
            "1BoatSLRHtKNngkdXEeobR76b53LETtpyT",
        )
        with self.assertRaisesRegex(ValueError, "unsupported recipient"):
            wallet_tool._normalize_recipient_address(addr[:-1] + "y")

    def test_classify_history_receive(self):
        parsed = {
            "inputs": [{"txid": "00" * 32, "vout": 0}],
            "outputs": [{"index": 0, "value": 12_345, "script": "0014aa"}],
        }
        self.assertEqual(
            wallet_tool._classify_tx_action("txid", parsed, "0014aa", {}),
            ("收到", 12_345),
        )

    def test_classify_history_send_uses_net_wallet_change(self):
        prev_txid = "11" * 32
        parsed = {
            "inputs": [{"txid": prev_txid, "vout": 0}],
            "outputs": [
                {"index": 0, "value": 30_000, "script": "0014bb"},
                {"index": 1, "value": 69_000, "script": "0014aa"},
            ],
        }
        cache = {prev_txid: {"outputs": [{"index": 0, "value": 100_000, "script": "0014aa"}]}}
        self.assertEqual(
            wallet_tool._classify_tx_action("txid", parsed, "0014aa", cache),
            ("转账", -31_000),
        )

    def test_classify_history_unknown_when_inputs_cannot_be_resolved(self):
        parsed = {
            "inputs": [{"txid": "22" * 32, "vout": 0}],
            "outputs": [{"index": 0, "value": 50_000, "script": "0014aa"}],
        }
        original = wallet_tool._tx_detail
        wallet_tool._tx_detail = lambda _txid, _cache: (_ for _ in ()).throw(RuntimeError("offline"))
        try:
            self.assertEqual(
                wallet_tool._classify_tx_action("txid", parsed, "0014aa", {}),
                ("未知", 0),
            )
        finally:
            wallet_tool._tx_detail = original

    def test_classify_history_self_transfer(self):
        prev_txid = "33" * 32
        parsed = {
            "inputs": [{"txid": prev_txid, "vout": 0}],
            "outputs": [{"index": 0, "value": 100_000, "script": "0014aa"}],
        }
        cache = {prev_txid: {"outputs": [{"index": 0, "value": 100_000, "script": "0014aa"}]}}
        self.assertEqual(
            wallet_tool._classify_tx_action("txid", parsed, "0014aa", cache),
            ("自转账", 0),
        )


if __name__ == "__main__":
    unittest.main()
