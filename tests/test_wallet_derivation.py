#!/usr/bin/env python3
"""Wallet derivation smoke test against BIP84 reference vector."""

import os
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "src", "wallet_tool.py")
PY = sys.executable


class WalletDerivationTest(unittest.TestCase):
    def test_bip84_abandon_about_cc1(self):
        proc = subprocess.run(
            [PY, TOOL, "import", *("abandon " * 11 + "about").split()],
            capture_output=True,
            text=True,
            check=True,
        )
        line = proc.stdout.strip().splitlines()[-1]
        self.assertIn("cc1qcr8te4kr609gcawutmrza0j4xv80jy8zrw2myk", line)
        self.assertIn('"path": "m/84\'/0\'/0\'/0/0"', line)


if __name__ == "__main__":
    unittest.main()
