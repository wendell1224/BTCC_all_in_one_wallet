"""BIP32 HD key derivation (secp256k1)."""

from __future__ import annotations

import hashlib
import hmac
import struct

from .secp256k1_min import N, point_mul, privkey_to_pubkey

HARDENED = 0x80000000


class HDKey:
  def __init__(self, priv: bytes, chain: bytes, depth: int = 0, parent_fp: bytes = b"\x00\x00\x00\x00", index: int = 0):
    if len(priv) != 32 or len(chain) != 32:
      raise ValueError("invalid key material")
    self.priv = priv
    self.chain = chain
    self.depth = depth
    self.parent_fp = parent_fp
    self.index = index

  @classmethod
  def from_seed(cls, seed: bytes) -> "HDKey":
    i = hmac.new(b"Bitcoin seed", seed, hashlib.sha512).digest()
    return cls(i[:32], i[32:])

  def fingerprint(self) -> bytes:
    from .secp256k1_min import hash160

    pub = privkey_to_pubkey(self.priv, compressed=True)
    return hash160(pub)[:4]

  def derive(self, path: str) -> "HDKey":
    if not path.startswith("m/"):
      raise ValueError("path must start with m/")
    key = self
    for part in path[2:].split("/"):
      if not part:
        continue
      hardened = part.endswith("'")
      idx = int(part[:-1] if hardened else part)
      if hardened:
        idx |= HARDENED
      key = key._derive_child(idx)
    return key

  def _derive_child(self, index: int) -> "HDKey":
    if index & HARDENED:
      data = b"\x00" + self.priv + struct.pack(">I", index)
    else:
      data = privkey_to_pubkey(self.priv, compressed=True) + struct.pack(">I", index)
    i = hmac.new(self.chain, data, hashlib.sha512).digest()
    il, ir = i[:32], i[32:]
    ki = (int.from_bytes(il, "big") + int.from_bytes(self.priv, "big")) % N
    if ki == 0:
      raise ValueError("invalid child key")
    parent_fp = self.fingerprint()
    return HDKey(
      ki.to_bytes(32, "big"),
      ir,
      depth=self.depth + 1,
      parent_fp=parent_fp,
      index=index,
    )

  def pubkey_compressed(self) -> bytes:
    return privkey_to_pubkey(self.priv, compressed=True)
