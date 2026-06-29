# BTCC Wallet (Electron / macOS)

Bitcoin Classic (BTCC) **all-in-one desktop client**: mnemonic wallet, transfers, on-chain history, OTC market overview, pool hashrate dashboard, and Apple Silicon GPU mining. The main desktop app is now **Electron + Node.js** for a shared multi-client codebase; the previous SwiftUI app remains in `gui/native/` for reference.

> Evolved from [BTCC_apple-gpu-miner](https://github.com/wendell1224/BTCC_apple-gpu-miner) GUI — **wallet-first** product positioning.

> 中文: [README.md](README.md)

![BTCC Wallet GUI](docs/GUI.png)

## Features

| Tab | What it does |
|-----|--------------|
| **Wallet** | BIP39 create/import, cc1 address, balance, send BTCC; mnemonic encrypted with a user wallet password without touching the local Keychain |
| **Transfer** | Supports Native SegWit, Taproot, Legacy, and P2SH recipients; optional memo; TXID and explorer link after broadcast |
| **History** | Paginated wallet history from explorer API with action, amount, height, time, and explorer link |
| **OTC** | Latest OTC price, 24h change, volume, turnover, and total market stats |
| **Pool stats** | Miner hashrate, pending payout, worker samples, and current hashrate leaderboard from pool.btc-classic.org API |
| **Pool mining** | Stratum v1 GPU mining with optional proxy and low-power online mode |
| **Solo** | Mine against your own node via RPC, with low-power online mode |
| **Tools** | Build Metal helper, smoke test, proxy test |

## Quick start

```bash
npm install --cache .npm-cache
./scripts/start_electron.sh # Electron dev launch

./scripts/build_electron.sh --dir # → dist/electron/mac-arm64/BTCC Wallet.app
./scripts/build_electron.sh       # → Electron DMG/ZIP
```

Install: open DMG → drag **BTCC Wallet** to Applications → launch from Applications.

Build only the `.app` bundle:

```bash
./scripts/build_dmg.sh --app-only --skip-metal # legacy SwiftUI build
```

The local build uses ad-hoc signing by default. For smooth double-click distribution on modern macOS, sign with an Apple Developer ID certificate and notarize the app.

## Wallet

- Derivation: BIP84 `m/84'/0'/0'/0/0` → `cc1...` addresses
- Electron mnemonic store: `~/Library/Application Support/BTCCWallet/wallet.enc.json`, encrypted with the user wallet password using `scrypt` + `AES-256-GCM`. The app does not call macOS Keychain / local keychain storage. Existing plaintext `wallet.json` is migrated and removed after the user enters a wallet password.
- Balance / UTXO / broadcast via [api.btc-classic.org](https://api.btc-classic.org)
- Transaction history and explorer links via [explorer.btc-classic.org](https://explorer.btc-classic.org/)
- Recipient address support: `cc1q...`, `cc1p...`, `1...`, `3...`
- Optional memo is encoded as an OP_RETURN output

## OTC

The **OTC** tab displays current market stats from:

`GET https://otc.btc-classic.org/otc/api/stats/overview`

It shows latest price, 24h change, 24h trade count, total trade count, BTCC volume, and USDT turnover.

## Pool stats API

`GET pool.btc-classic.org/api/pplns/pools/btcc-pplns/miners/{address}?perfMode=Day`

Pool mining and Solo mining support **low-power online mode**. When enabled,
the app runs short GPU batches and idles between them to approximate the
selected 5%-100% average GPU duty cycle while keeping the miner connected.

The Pool Stats tab also shows the current Solo hashrate leaderboard with full address, worker count, 1h/1d/7d hashrate, and best share:

`GET pool.btc-classic.org/api/solo/top/hashrates`

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
