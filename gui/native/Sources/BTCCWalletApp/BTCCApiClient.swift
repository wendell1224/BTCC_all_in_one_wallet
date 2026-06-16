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

struct ExplorerAddressHistory: Decodable {
    let txCount: Int
    let transactions: [ExplorerTransaction]
    let limit: Int
    let offset: Int
    let nextOffset: Int?
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case txCount = "tx_count"
        case transactions
        case limit
        case offset
        case nextOffset = "next_offset"
        case hasMore = "has_more"
    }
}

struct ExplorerTransaction: Decodable {
    let txid: String
    let height: Int?
    let timeISO: String?
    let confirmations: Int?
    let delta: ExplorerDelta?

    enum CodingKeys: String, CodingKey {
        case txHash = "tx_hash"
        case txid, hash, id, height, confirmations, delta
        case timeISO = "time_iso"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        txid = try c.decodeIfPresent(String.self, forKey: .txHash)
            ?? c.decodeIfPresent(String.self, forKey: .txid)
            ?? c.decodeIfPresent(String.self, forKey: .hash)
            ?? c.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        timeISO = try c.decodeIfPresent(String.self, forKey: .timeISO)
        confirmations = try c.decodeIfPresent(Int.self, forKey: .confirmations)
        delta = try c.decodeIfPresent(ExplorerDelta.self, forKey: .delta)
    }
}

struct ExplorerDelta: Decodable {
    let receivedSats: Int64
    let sentSats: Int64
    let netSats: Int64

    enum CodingKeys: String, CodingKey {
        case receivedSats = "received_sats"
        case sentSats = "sent_sats"
        case netSats = "net_sats"
    }
}

struct OTCOverview: Decodable {
    let count24h: Int
    let lastPrice: Double
    let lastToken: String
    let priceChange24h: Double
    let totalCount: Int
    let totalVolume: Double
    let volume24h: Double
    let volumeUSDT24h: Double
    let volumeUSDTTotal: Double

    enum CodingKeys: String, CodingKey {
        case count24h = "count_24h"
        case lastPrice = "last_price"
        case lastToken = "last_token"
        case priceChange24h = "price_change_24h"
        case totalCount = "total_count"
        case totalVolume = "total_volume"
        case volume24h = "volume_24h"
        case volumeUSDT24h = "volume_usdt_24h"
        case volumeUSDTTotal = "volume_usdt_total"
    }
}

enum BTCCApiClient {
    static let poolBase = "https://pool.btc-classic.org"
    static let walletBase = "https://api.btc-classic.org"
    static let explorerBase = "https://explorer.btc-classic.org"
    static let otcBase = "https://otc.btc-classic.org"

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

    static func fetchExplorerAddressHistory(address: String, limit: Int, offset: Int) async throws -> ExplorerAddressHistory {
        let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? address
        guard var components = URLComponents(string: "\(explorerBase)/api/v1/explorer/address/\(encoded)") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "include_history", value: "true"),
            URLQueryItem(name: "limit", value: "\(max(1, limit))"),
            URLQueryItem(name: "offset", value: "\(max(0, offset))"),
            URLQueryItem(name: "summary_limit", value: "1000"),
            URLQueryItem(name: "utxo_limit", value: "1")
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("BTCCWallet/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ExplorerAddressHistory.self, from: data)
    }

    static func fetchOTCOverview() async throws -> OTCOverview {
        let url = URL(string: "\(otcBase)/otc/api/stats/overview")!
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("https://otc.btc-classic.org/otc/", forHTTPHeaderField: "Referer")
        req.setValue("BTCCWallet/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(OTCOverview.self, from: data)
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
