#!/usr/bin/env python3
"""Wallet manager UI helper tests."""

import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "src"))

from wallet_tool import _normalize_recipient_address


class WalletManagerTest(unittest.TestCase):
    def test_recipient_normalization_keeps_supported_addresses(self):
        self.assertEqual(
            _normalize_recipient_address("cc1qul8xq8urtf8rgg4px6xvdz4hf5fufks7grjwvx"),
            "cc1qul8xq8urtf8rgg4px6xvdz4hf5fufks7grjwvx",
        )
        self.assertEqual(
            _normalize_recipient_address("1BoatSLRHtKNngkdXEeobR76b53LETtpyT"),
            "1BoatSLRHtKNngkdXEeobR76b53LETtpyT",
        )


if __name__ == "__main__":
    unittest.main()
