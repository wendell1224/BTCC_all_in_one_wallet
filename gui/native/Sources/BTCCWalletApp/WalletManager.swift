import Foundation

@MainActor
final class WalletManager: ObservableObject {
    struct TransactionRecord: Identifiable {
        let id: String
        let txid: String
        let height: Int?
        let action: String
        let amountSats: Int64
        let timeISO: String?
        let confirmations: Int?
    }

    struct HistoryPage {
        let items: [TransactionRecord]
        let page: Int
        let pageCount: Int
        let total: Int
    }

    @Published var hasWallet = false
    @Published var address = ""
    @Published var mnemonicPreview = ""
    @Published var balanceConfirmed: Int64 = 0
    @Published var balanceUnconfirmed: Int64 = 0
    @Published var statusMessage = "未创建钱包"
    @Published var isBusy = false
    @Published var lastTxid = ""
    @Published var transactionHistory: [TransactionRecord] = []
    @Published var historyPageIndex = 0
    @Published var historyPageSize = 25
    @Published var historyTotal = 0
    @Published var historyHasMore = false
    @Published var historyNextOffset: Int?
    @Published var isHistoryLoading = false

    var lastTxExplorerURL: URL? {
        guard !lastTxid.isEmpty else { return nil }
        return URL(string: "https://explorer.btc-classic.org/tx/\(lastTxid)")
    }

    init() {
        reloadWallet()
    }

    func reloadWallet() {
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
            await refreshHistory()
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
            await refreshHistory()
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

    func refreshHistory() async {
        guard !address.isEmpty else { return }
        let pageSize = max(1, min(historyPageSize, 100))
        let offset = max(0, historyPageIndex) * pageSize
        isHistoryLoading = true
        defer { isHistoryLoading = false }
        do {
            let result = try await BTCCApiClient.fetchExplorerAddressHistory(
                address: address,
                limit: pageSize,
                offset: offset
            )
            historyTotal = result.txCount
            historyHasMore = result.hasMore
            historyNextOffset = result.nextOffset
            transactionHistory = result.transactions.filter { !$0.txid.isEmpty }.map { tx in
                let delta = tx.delta
                let netSats = delta?.netSats ?? 0
                return TransactionRecord(
                    id: tx.txid,
                    txid: tx.txid,
                    height: tx.height,
                    action: Self.historyAction(delta),
                    amountSats: netSats,
                    timeISO: tx.timeISO,
                    confirmations: tx.confirmations
                )
            }
            let maxPage = max(0, historyPageCount(total: historyTotal, pageSize: pageSize) - 1)
            if historyPageIndex > maxPage {
                historyPageIndex = maxPage
            }
        } catch {
            transactionHistory = []
            historyHasMore = false
            historyNextOffset = nil
            statusMessage = "历史查询失败: \(error.localizedDescription)"
        }
    }

    func historyPage() -> HistoryPage {
        let pageSize = max(1, historyPageSize)
        let pageCount = historyPageCount(total: historyTotal, pageSize: pageSize)
        let page = min(max(historyPageIndex, 0), pageCount - 1)
        return HistoryPage(items: transactionHistory, page: page, pageCount: pageCount, total: historyTotal)
    }

    func historyNextPage() async {
        let info = historyPage()
        guard info.page + 1 < info.pageCount else { return }
        historyPageIndex += 1
        await refreshHistory()
    }

    func historyPrevPage() async {
        guard historyPageIndex > 0 else { return }
        historyPageIndex -= 1
        await refreshHistory()
    }

    func setHistoryPageSize(_ pageSize: Int) async {
        historyPageSize = max(1, min(pageSize, 100))
        historyPageIndex = 0
        await refreshHistory()
    }

    func send(to: String, amountBTCC: String, memo: String = "") async {
        guard let mnemonic = loadMnemonic() else {
            statusMessage = "无钱包"
            return
        }
        let dest = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidRecipientAddress(dest) else {
            statusMessage = "收款地址校验失败"
            return
        }
        let amount = amountBTCC.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard Self.amountSats(amount) != nil else {
            statusMessage = "金额格式错误"
            return
        }
        let memoText = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.memoBytesOK(memoText) else {
            statusMessage = "备注最长 80 字节"
            return
        }
        isBusy = true
        statusMessage = "转账中…"
        lastTxid = ""
        defer { isBusy = false }
        do {
            var args = ["send"]
            args.append(contentsOf: mnemonic.split(separator: " ").map(String.init))
            args += ["--to", dest, "--amount", amount]
            if !memoText.isEmpty {
                args += ["--memo", memoText]
            }
            let result = try await runWalletTool(args)
            guard result.ok == true else {
                statusMessage = result.error ?? "转账失败"
                return
            }
            lastTxid = result.txid ?? ""
            statusMessage = lastTxid.isEmpty ? "已广播，等待节点返回 TXID" : "转账成功，交易已广播"
            await refreshBalance()
            await refreshHistory()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteWallet() {
        try? FileManager.default.removeItem(at: AppPaths.walletStore)
        hasWallet = false
        address = ""
        mnemonicPreview = ""
        balanceConfirmed = 0
        balanceUnconfirmed = 0
        lastTxid = ""
        transactionHistory = []
        historyPageIndex = 0
        historyTotal = 0
        historyHasMore = false
        historyNextOffset = nil
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
                historyPageIndex = 0
                await refreshHistory()
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private static func historyAction(_ delta: ExplorerDelta?) -> String {
        guard let delta else { return "未知" }
        if delta.netSats > 0 { return "收到" }
        if delta.netSats < 0 { return "转账" }
        if delta.receivedSats > 0 && delta.sentSats > 0 { return "自转账" }
        return "未知"
    }

    private func historyPageCount(total: Int, pageSize: Int) -> Int {
        max(1, Int(ceil(Double(total) / Double(max(1, pageSize)))))
    }

    private struct ToolResult: Decodable {
        let ok: Bool?
        let mnemonic: String?
        let address: String?
        let txid: String?
        let error: String?
        let transactions: [HistoryItem]?
    }

    private struct HistoryItem: Decodable {
        let txid: String
        let height: Int?
        let action: String?
        let amountSats: Int64?

        enum CodingKeys: String, CodingKey {
            case txid
            case height
            case action
            case amountSats = "amount_sats"
        }
    }

    private struct WalletStore: Codable {
        let mnemonic: String
        let createdAt: String
    }

    private static func amountSats(_ amount: String) -> Int64? {
        guard let decimal = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")),
              !decimal.isNaN else {
            return nil
        }
        let sats = decimal * Decimal(100_000_000)
        var rounded = Decimal()
        var value = sats
        NSDecimalRound(&rounded, &value, 0, .plain)
        guard rounded == sats,
              let amountSats = Int64(exactly: NSDecimalNumber(decimal: rounded)),
              amountSats > 0 else {
            return nil
        }
        return amountSats
    }

    private static func isValidRecipientAddress(_ address: String) -> Bool {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if addr.hasPrefix("cc1"), let separator = addr.lastIndex(of: "1") {
            let hrp = String(addr[..<separator])
            return hrp == "cc"
        }
        return addr.first == "1" || addr.first == "3"
    }

    private static func memoBytesOK(_ memo: String) -> Bool {
        memo.isEmpty || memo.utf8.count <= 80
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
            if result.ok != true {
                throw NSError(domain: "wallet", code: 4, userInfo: [NSLocalizedDescriptionKey: result.error ?? text])
            }
            if proc.terminationStatus != 0 {
                throw NSError(domain: "wallet", code: 5, userInfo: [NSLocalizedDescriptionKey: result.error ?? "wallet 工具退出码 \(proc.terminationStatus)"])
            }
            return result
        }.value
    }

    private func saveMnemonic(_ mnemonic: String) throws {
        let store = WalletStore(
            mnemonic: mnemonic,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        let data = try JSONEncoder().encode(store)
        let url = AppPaths.walletStore
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func loadMnemonic() -> String? {
        let url = AppPaths.walletStore
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(WalletStore.self, from: data) else {
            return nil
        }
        let words = store.mnemonic.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
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

@MainActor
final class OTCStatsManager: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage = ""
    @Published var overview: OTCOverview?
    @Published var lastUpdated = ""

    func refresh() async {
        isLoading = true
        errorMessage = ""
        defer { isLoading = false }
        do {
            overview = try await BTCCApiClient.fetchOTCOverview()
            lastUpdated = Self.timeString(Date())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
