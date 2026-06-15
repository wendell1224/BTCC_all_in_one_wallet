import Foundation
import Security

@MainActor
final class WalletManager: ObservableObject {
    @Published var hasWallet = false
    @Published var address = ""
    @Published var mnemonicPreview = ""
    @Published var balanceConfirmed: Int64 = 0
    @Published var balanceUnconfirmed: Int64 = 0
    @Published var statusMessage = "未创建钱包"
    @Published var isBusy = false
    @Published var lastTxid = ""

    private let service = "org.btc-classic.BTCCWallet"

    init() {
        reloadFromKeychain()
    }

    func reloadFromKeychain() {
        if let mnemonic = loadMnemonic() {
            hasWallet = true
            mnemonicPreview = maskMnemonic(mnemonic)
            Task { await refreshAddress(mnemonic: mnemonic) }
        } else {
            hasWallet = false
            address = ""
            mnemonicPreview = ""
            statusMessage = "未创建钱包"
        }
    }

    func createWallet() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await runWalletTool(["create"])
            guard result.ok == true, let mnemonic = result.mnemonic, let addr = result.address else {
                statusMessage = result.error ?? "创建失败"
                return
            }
            try saveMnemonic(mnemonic)
            address = addr
            hasWallet = true
            mnemonicPreview = maskMnemonic(mnemonic)
            statusMessage = "钱包已创建"
            await refreshBalance()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func importWallet(mnemonic: String) async {
        let words = mnemonic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            statusMessage = "请输入助记词"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            var args = ["import"]
            args.append(contentsOf: words.split(separator: " ").map(String.init))
            let result = try await runWalletTool(args)
            guard result.ok == true, let addr = result.address else {
                statusMessage = result.error ?? "导入失败"
                return
            }
            try saveMnemonic(words)
            address = addr
            hasWallet = true
            mnemonicPreview = maskMnemonic(words)
            statusMessage = "钱包已导入"
            await refreshBalance()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refreshBalance() async {
        guard !address.isEmpty else { return }
        do {
            let bal = try await BTCCApiClient.fetchBalance(address: address)
            balanceConfirmed = bal.confirmed ?? 0
            balanceUnconfirmed = bal.unconfirmed ?? 0
        } catch {
            statusMessage = "余额查询失败: \(error.localizedDescription)"
        }
    }

    func send(to: String, amountBTCC: String) async {
        guard let mnemonic = loadMnemonic() else {
            statusMessage = "无钱包"
            return
        }
        let dest = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard dest.hasPrefix("cc1") else {
            statusMessage = "收款地址须为 cc1..."
            return
        }
        guard Double(amountBTCC) != nil else {
            statusMessage = "金额格式错误"
            return
        }
        isBusy = true
        statusMessage = "转账中…"
        defer { isBusy = false }
        do {
            var args = ["send"]
            args.append(contentsOf: mnemonic.split(separator: " ").map(String.init))
            args += ["--to", dest, "--amount", amountBTCC]
            let result = try await runWalletTool(args)
            guard result.ok == true else {
                statusMessage = result.error ?? "转账失败"
                return
            }
            lastTxid = result.txid ?? ""
            statusMessage = lastTxid.isEmpty ? "已广播" : "转账成功: \(lastTxid.prefix(16))…"
            await refreshBalance()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteWallet() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
        hasWallet = false
        address = ""
        mnemonicPreview = ""
        balanceConfirmed = 0
        balanceUnconfirmed = 0
        statusMessage = "钱包已删除"
    }

    func exportMnemonic() -> String? {
        loadMnemonic()
    }

    private func refreshAddress(mnemonic: String) async {
        do {
            var args = ["address"]
            args.append(contentsOf: mnemonic.split(separator: " ").map(String.init))
            let result = try await runWalletTool(args)
            if result.ok == true, let addr = result.address {
                address = addr
                statusMessage = "钱包就绪"
                await refreshBalance()
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private struct ToolResult: Decodable {
        let ok: Bool?
        let mnemonic: String?
        let address: String?
        let txid: String?
        let error: String?
    }

    private func runWalletTool(_ args: [String]) async throws -> ToolResult {
        try await Task.detached(priority: .userInitiated) {
            guard let py = AppPaths.findPython() else {
                throw NSError(domain: "wallet", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到 python3"])
            }
            let tool = AppPaths.walletTool.path
            guard FileManager.default.fileExists(atPath: tool) else {
                throw NSError(domain: "wallet", code: 2, userInfo: [NSLocalizedDescriptionKey: "缺少 wallet_tool.py"])
            }
            let proc = Process()
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: py)
            proc.arguments = [tool] + args
            proc.currentDirectoryURL = AppPaths.appRoot
            proc.standardOutput = pipe
            proc.standardError = pipe
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            guard let line = text.split(separator: "\n").last,
                  let json = line.data(using: .utf8),
                  let result = try? JSONDecoder().decode(ToolResult.self, from: json) else {
                throw NSError(domain: "wallet", code: 3, userInfo: [NSLocalizedDescriptionKey: text.isEmpty ? "wallet 工具无输出" : text])
            }
            if proc.terminationStatus != 0, result.ok != true {
                throw NSError(domain: "wallet", code: 4, userInfo: [NSLocalizedDescriptionKey: result.error ?? text])
            }
            return result
        }.value
    }

    private func saveMnemonic(_ mnemonic: String) throws {
        let data = mnemonic.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "mnemonic",
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "wallet", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain 保存失败 (\(status))"])
        }
    }

    private func loadMnemonic() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "mnemonic",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func maskMnemonic(_ mnemonic: String) -> String {
        let words = mnemonic.split(separator: " ")
        guard words.count >= 4 else { return "****" }
        return "\(words.prefix(2).joined(separator: " ")) … \(words.suffix(2).joined(separator: " "))"
    }
}

@MainActor
final class PoolStatsManager: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage = ""
    @Published var totalHashrate = "—"
    @Published var pendingBalance = "—"
    @Published var pendingShares = "—"
    @Published var workers: [(name: String, hashrate: String, sps: String)] = []
    @Published var samples: [(time: String, hashrate: String)] = []

    func refresh(address: String) async {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard addr.hasPrefix("cc1") else {
            errorMessage = "请填写 cc1 收款地址"
            return
        }
        isLoading = true
        errorMessage = ""
        defer { isLoading = false }
        do {
            let stats = try await BTCCApiClient.fetchPoolStats(address: addr)
            totalHashrate = BTCCApiClient.formatHashrate(stats.totalHashrateHS)
            if let pb = stats.pendingBalance {
                pendingBalance = String(format: "%.8f BTCC", pb)
            }
            if let ps = stats.pendingShares {
                pendingShares = String(format: "%.2f", ps)
            }
            workers = stats.workerRows.map {
                (name: $0.name,
                 hashrate: BTCCApiClient.formatHashrate($0.hashrateHS),
                 sps: String(format: "%.4f/s", $0.sharesPerSecond))
            }
            samples = (stats.performanceSamples ?? []).suffix(12).map { sample in
                let hs = sample.workers?.values.compactMap(\.hashrate).reduce(0, +) ?? 0
                let t = sample.created?.replacingOccurrences(of: "T", with: " ").prefix(16) ?? "—"
                return (time: String(t), hashrate: BTCCApiClient.formatHashrate(hs))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
