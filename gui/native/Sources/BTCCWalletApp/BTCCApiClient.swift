import Foundation

struct PoolMinerStats: Codable {
    let pendingShares: Double?
    let pendingBalance: Double?
    let totalPaid: Double?
    let todayPaid: Double?
    let performance: PerformanceBlock?
    let performanceSamples: [PerformanceSample]?

    enum CodingKeys: String, CodingKey {
        case pendingShares, pendingBalance, totalPaid, todayPaid, performance, performanceSamples
    }

    struct PerformanceBlock: Codable {
        let created: String?
        let workers: [String: WorkerPerf]?
    }

    struct PerformanceSample: Codable {
        let created: String?
        let workers: [String: WorkerPerf]?
    }

    struct WorkerPerf: Codable {
        let hashrate: Double?
        let sharesPerSecond: Double?
    }

    var totalHashrateHS: Double {
        performance?.workers?.values.compactMap(\.hashrate).reduce(0, +) ?? 0
    }

    var workerRows: [(name: String, hashrateHS: Double, sharesPerSecond: Double)] {
        guard let workers = performance?.workers else { return [] }
        return workers.map { (name: $0.key, hashrateHS: $0.value.hashrate ?? 0, sharesPerSecond: $0.value.sharesPerSecond ?? 0) }
            .sorted { $0.hashrateHS > $1.hashrateHS }
    }
}

struct WalletBalance: Codable {
    let address: String?
    let confirmed: Int64?
    let unconfirmed: Int64?
    let total: Int64?
}

enum BTCCApiClient {
    static let poolBase = "https://pool.btc-classic.org"
    static let walletBase = "https://api.btc-classic.org"

    static func fetchPoolStats(address: String, perfMode: String = "Day") async throws -> PoolMinerStats {
        let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? address
        let url = URL(string: "\(poolBase)/api/pplns/pools/btcc-pplns/miners/\(encoded)?perfMode=\(perfMode)")!
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("BTCCWallet/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(PoolMinerStats.self, from: data)
    }

    static func fetchBalance(address: String) async throws -> WalletBalance {
        let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? address
        let url = URL(string: "\(walletBase)/api/v1/address/\(encoded)/balance")!
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(WalletBalance.self, from: data)
    }

    static func formatHashrate(_ hs: Double) -> String {
        if hs >= 1e12 { return String(format: "%.2f TH/s", hs / 1e12) }
        if hs >= 1e9 { return String(format: "%.2f GH/s", hs / 1e9) }
        if hs >= 1e6 { return String(format: "%.2f MH/s", hs / 1e6) }
        if hs >= 1e3 { return String(format: "%.2f kH/s", hs / 1e3) }
        return String(format: "%.0f H/s", hs)
    }

    static func formatBTCC(_ sats: Int64) -> String {
        let coins = Double(sats) / 100_000_000.0
        if coins >= 1 { return String(format: "%.8f BTCC", coins) }
        return String(format: "%.8f BTCC", coins)
    }
}
