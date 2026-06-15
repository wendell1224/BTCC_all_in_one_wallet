# BTCC All-in-One Wallet (macOS)

Bitcoin Classic (BTCC) **一体化 macOS 客户端**：助记词钱包 + 矿池算力查询 + Apple Silicon GPU 挖矿，全部集成在一个 SwiftUI 应用里。

> 本项目由 [BTCC_apple-gpu-miner](https://github.com/wendell1224/BTCC_apple-gpu-miner) 的 GUI 整合而来，定位为 **钱包优先** 的 all-in-one 产品。

![BTCC Wallet 界面](docs/GUI.png)

## 功能一览

| 模块 | 说明 |
|------|------|
| **钱包** | BIP39 创建/导入助记词、cc1 地址、查余额、转账（api.btc-classic.org） |
| **矿池算力** | 查询 pool.btc-classic.org 矿工算力、待结算余额、Worker 24h 采样 |
| **矿池挖矿** | Stratum v1 GPU 挖矿，支持 SOCKS5/HTTP 代理 |
| **Solo** | 连本地 bitcoind/btccd 节点 Solo 挖 |
| **工具** | 编译 Metal Helper、GPU 冒烟测试、代理测试 |

## 系统要求

- macOS 12+，Apple Silicon (M1/M2/M3/M4)
- Xcode Command Line Tools：`xcode-select --install`
- Python 3.9+（标准库，钱包与挖矿子进程）

## 快速开始

### 用户：安装 DMG

```bash
./scripts/build_dmg.sh
# → dist/BTCC Wallet.app
# → dist/BTCC-Wallet-v1.0.0.dmg
```

打开 DMG → 拖到「应用程序」→ 从启动台打开（不要直接从 DMG 卷运行）。

### 开发者：本地运行

```bash
git clone <本仓库>
cd BTCC_all_in_one_wallet_mac

./scripts/build_metal.sh          # 首次编译 GPU helper
./scripts/start_gui.sh            # 启动 SwiftUI 应用
```

## 钱包

1. 打开 **「钱包」** 标签 → **创建新钱包** 或 **导入助记词**
2. 创建后请务必备份 12 词助记词（保存在 macOS Keychain，仅本机）
3. 地址路径：`m/84'/0'/0'/0/0`，生成 `cc1...` 收款地址
4. **转账**：填收款地址和 BTCC 金额 → 发送（自动选 UTXO、签名、广播）
5. 点 **「用于挖矿」** 可把钱包地址一键填入矿池挖矿页

数据接口：[api.btc-classic.org](https://api.btc-classic.org)（余额 / UTXO / 广播）

## 矿池算力

在 **「矿池算力」** 标签填入矿工地址（`cc1...`，不含 worker 后缀），点击 **查询矿池算力**。

接口：`pool.btc-classic.org/api/pplns/pools/btcc-pplns/miners/{地址}?perfMode=Day`

## GPU 挖矿

默认矿池：`stratum+tcp://pool.btc-classic.org:63101`，地址须 `cc1...` 前缀。

```bash
# 命令行（可选）
./scripts/start_stratum.sh cc1q....your_address
./scripts/start_stratum.sh cc1q.... --proxy http://127.0.0.1:7890
```

M 系列实测 ~180 MH/s，零调参。详见原矿工项目文档。

## 项目结构

```
BTCC_all_in_one_wallet_mac/
├── gui/native/              # SwiftUI 应用 (BTCCWalletApp)
├── src/
│   ├── wallet/              # BIP39/BIP32/bech32/交易签名
│   ├── wallet_tool.py       # 钱包 CLI（GUI 子进程调用）
│   ├── stratum_miner.py     # Stratum 矿池客户端
│   └── metal_nonce_finder   # Metal GPU helper（编译产物）
├── scripts/
│   ├── start_gui.sh         # 开发启动
│   ├── build_dmg.sh         # 打包 .app + DMG
│   └── release.sh           # 发布 GitHub Release
├── docs/GUI.png             # 界面截图
└── VERSION                  # 版本号
```

应用数据目录：`~/Library/Application Support/BTCCWallet/`

## 发布

```bash
# 改 VERSION + docs/releases/vX.Y.Z.md
./scripts/release.sh --build-only   # 本地试打包
git tag v1.0.0 && git push origin main --tags
./scripts/release.sh                # 或 push tag 触发 GitHub Actions
```

输出：`dist/BTCC-Wallet-v<版本>.dmg`

## 与 BTCC_apple-gpu-miner 的关系

| | BTCC_apple-gpu-miner | BTCC_all_in_one_wallet_mac |
|---|---|---|
| 定位 | GPU 挖矿工具 + GUI | **一体化 BTCC 钱包**（含挖矿） |
| 应用名 | BTCC Apple GPU Miner | **BTCC Wallet** |
| 默认 Tab | 矿池挖矿 | **钱包** |
| Bundle ID | org.btc-classic.apple-gpu-miner | org.btc-classic.wallet |

两个仓库可独立演进；新功能建议优先在本仓库开发。

## License

MIT — 见 [LICENSE](LICENSE)
