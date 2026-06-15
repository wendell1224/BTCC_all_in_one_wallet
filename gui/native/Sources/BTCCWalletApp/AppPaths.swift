import Foundation

/// Locate bundled miner resources and a working python3.
enum AppPaths {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("BTCCWallet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var appRoot: URL {
        if let dev = ProcessInfo.processInfo.environment["BTCC_WALLET_DEV_ROOT"]
            ?? ProcessInfo.processInfo.environment["BTCC_MINER_DEV_ROOT"],
           !dev.isEmpty {
            return URL(fileURLWithPath: dev)
        }
        if let url = Bundle.main.resourceURL?.appendingPathComponent("app", isDirectory: true),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let exec = Bundle.main.executableURL {
            let candidate = exec.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("src/stratum_miner.py").path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    static var isBundledApp: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var srcDir: URL { appRoot.appendingPathComponent("src") }
    static var scriptsDir: URL { appRoot.appendingPathComponent("scripts") }
    static var stratumMiner: URL { srcDir.appendingPathComponent("stratum_miner.py") }
    static var gbtMiner: URL { srcDir.appendingPathComponent("gbt_miner.py") }
    static var bundledGpuBinary: URL { srcDir.appendingPathComponent("metal_nonce_finder") }
    static var writableGpuBinary: URL { supportDir.appendingPathComponent("metal_nonce_finder") }
    static var buildMetal: URL { scriptsDir.appendingPathComponent("build_metal.sh") }
    static var testProxy: URL { scriptsDir.appendingPathComponent("test_proxy.sh") }
    static var smokeTest: URL {
        appRoot.appendingPathComponent("tests/smoke_metal_nonce_finder.py")
    }
    static var walletTool: URL { srcDir.appendingPathComponent("wallet_tool.py") }

    /// GPU binary used for mining: bundled copy if executable, else user-writable copy.
    static var gpuBinary: URL {
        if isExecutable(bundledGpuBinary) { return bundledGpuBinary }
        if isExecutable(writableGpuBinary) { return writableGpuBinary }
        return isBundledApp ? writableGpuBinary : bundledGpuBinary
    }

    static var gpuReady: Bool {
        isExecutable(bundledGpuBinary) || isExecutable(writableGpuBinary)
    }

    static var defaultWorker: String {
        Host.current().localizedName ?? "worker"
    }

    static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Seed bundled GPU binary into Application Support (installed .app is read-only).
    static func seedGpuBinaryIfNeeded() -> Bool {
        if isExecutable(writableGpuBinary) { return true }
        guard isExecutable(bundledGpuBinary) else { return false }
        do {
            if FileManager.default.fileExists(atPath: writableGpuBinary.path) {
                try FileManager.default.removeItem(at: writableGpuBinary)
            }
            try FileManager.default.copyItem(at: bundledGpuBinary, to: writableGpuBinary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: writableGpuBinary.path)
            return isExecutable(writableGpuBinary)
        } catch {
            return false
        }
    }

    /// Find python3 off the main thread.
    static func findPython() -> String? {
        let env = ProcessInfo.processInfo.environment["BTCC_PYTHON"]
        var candidates: [String] = []
        if let env, !env.isEmpty { candidates.append(env) }
        candidates += [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        for path in candidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["-c", "import hashlib, json, struct"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 { return path }
            } catch { continue }
        }
        return nil
    }
}

/// Settings persisted in UserDefaults.
final class MinerSettings: ObservableObject {
    @Published var address: String {
        didSet { UserDefaults.standard.set(address, forKey: "address") }
    }
    @Published var worker: String {
        didSet { UserDefaults.standard.set(worker, forKey: "worker") }
    }
    @Published var poolURL: String {
        didSet { UserDefaults.standard.set(poolURL, forKey: "poolURL") }
    }
    @Published var proxy: String {
        didSet { UserDefaults.standard.set(proxy, forKey: "proxy") }
    }
    @Published var suggestDifficulty: String {
        didSet { UserDefaults.standard.set(suggestDifficulty, forKey: "suggestDifficulty") }
    }

    @Published var rpcHost: String {
        didSet { UserDefaults.standard.set(rpcHost, forKey: "rpcHost") }
    }
    @Published var rpcPort: String {
        didSet { UserDefaults.standard.set(rpcPort, forKey: "rpcPort") }
    }
    @Published var rpcUser: String {
        didSet { UserDefaults.standard.set(rpcUser, forKey: "rpcUser") }
    }
    @Published var rpcPassword: String {
        didSet { UserDefaults.standard.set(rpcPassword, forKey: "rpcPassword") }
    }
    @Published var soloAddress: String {
        didSet { UserDefaults.standard.set(soloAddress, forKey: "soloAddress") }
    }

    init() {
        let d = UserDefaults.standard
        address = d.string(forKey: "address") ?? ""
        worker = d.string(forKey: "worker") ?? AppPaths.defaultWorker
        poolURL = d.string(forKey: "poolURL") ?? "stratum+tcp://pool.btc-classic.org:63101"
        proxy = d.string(forKey: "proxy") ?? ""
        suggestDifficulty = d.string(forKey: "suggestDifficulty") ?? "-1"
        rpcHost = d.string(forKey: "rpcHost") ?? "127.0.0.1"
        rpcPort = d.string(forKey: "rpcPort") ?? "28476"
        rpcUser = d.string(forKey: "rpcUser") ?? "user"
        rpcPassword = d.string(forKey: "rpcPassword") ?? "pass"
        soloAddress = d.string(forKey: "soloAddress") ?? ""
    }
}
