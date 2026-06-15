"""BIP39 mnemonic generation and seed derivation."""

from __future__ import annotations

import hashlib
import secrets

from .bip39_words import WORDS


def generate_mnemonic(strength: int = 128) -> str:
    if strength not in (128, 160, 192, 224, 256):
        raise ValueError("invalid strength")
    entropy = secrets.token_bytes(strength // 8)
    return entropy_to_mnemonic(entropy)


def entropy_to_mnemonic(entropy: bytes) -> str:
    if len(entropy) not in (16, 20, 24, 28, 32):
        raise ValueError("invalid entropy length")
    h = hashlib.sha256(entropy).digest()
    bits = "".join(f"{b:08b}" for b in entropy)
    cs = len(entropy) // 4
    bits += f"{h[0]:08b}"[:cs]
    chunks = [bits[i : i + 11] for i in range(0, len(bits), 11)]
    words = [WORDS[int(c, 2)] for c in chunks]
    return " ".join(words)


def mnemonic_to_seed(mnemonic: str, passphrase: str = "") -> bytes:
    words = mnemonic.strip().lower().split()
    if len(words) not in (12, 15, 18, 21, 24):
        raise ValueError("mnemonic must be 12/15/18/21/24 words")
    for w in words:
        if w not in WORDS:
            raise ValueError(f"unknown word: {w}")
    salt = ("mnemonic" + passphrase).encode("utf-8")
    return hashlib.pbkdf2_hmac("sha512", " ".join(words).encode("utf-8"), salt, 2048, dklen=64)


def validate_mnemonic(mnemonic: str) -> bool:
    try:
        mnemonic_to_seed(mnemonic)
        return True
    except ValueError:
        return False
