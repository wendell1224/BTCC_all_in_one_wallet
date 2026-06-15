# BTCC All-in-One Wallet (macOS)

Bitcoin Classic (BTCC) **all-in-one macOS client**: mnemonic wallet + pool hashrate dashboard + Apple Silicon GPU mining in one SwiftUI app.

> Evolved from [BTCC_apple-gpu-miner](https://github.com/wendell1224/BTCC_apple-gpu-miner) GUI — **wallet-first** product positioning.

> 中文: [README.md](README.md)

![BTCC Wallet GUI](docs/GUI.png)

## Features

| Tab | What it does |
|-----|--------------|
| **Wallet** | BIP39 create/import, cc1 address, balance, send BTCC |
| **Pool stats** | Miner hashrate & pending payout from pool.btc-classic.org API |
| **Pool mining** | Stratum v1 GPU mining with optional proxy |
| **Solo** | Mine against your own node via RPC |
| **Tools** | Build Metal helper, smoke test, proxy test |

## Quick start

```bash
./scripts/build_metal.sh    # first time
./scripts/start_gui.sh      # dev launch

./scripts/build_dmg.sh      # → dist/BTCC Wallet.app + BTCC-Wallet-v*.dmg
```

Install: open DMG → drag **BTCC Wallet** to Applications → launch from Applications.

## Wallet

- Derivation: BIP84 `m/84'/0'/0'/0/0` → `cc1...` addresses
- Mnemonic stored in macOS Keychain (device-only)
- Balance / UTXO / broadcast via [api.btc-classic.org](https://api.btc-classic.org)
- **Use for mining** button fills your wallet address into the pool tab

## Pool stats API

`GET pool.btc-classic.org/api/pplns/pools/btcc-pplns/miners/{address}?perfMode=Day`

## vs BTCC_apple-gpu-miner

| | Miner repo | This repo |
|---|---|---|
| Focus | GPU miner + GUI | **All-in-one BTCC wallet** |
| App name | BTCC Apple GPU Miner | **BTCC Wallet** |
| Default tab | Pool mining | **Wallet** |
| Bundle ID | org.btc-classic.apple-gpu-miner | org.btc-classic.wallet |
| DMG | BTCC-Apple-GPU-Miner-v*.dmg | **BTCC-Wallet-v*.dmg** |

## License

MIT — see [LICENSE](LICENSE).
