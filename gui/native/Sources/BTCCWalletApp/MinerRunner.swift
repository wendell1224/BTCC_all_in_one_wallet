import Foundation
import Combine

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(contentsOf lines: [String]) {
        lock.lock()
        storage.append(contentsOf: lines)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        let lines = storage
        lock.unlock()
        return lines
    }
}

@MainActor
final class MinerRunner: ObservableObject {
    @Published var logText = ""
    @Published var isRunning = false
    @Published var isBusy = false
    @Published var hashrate = "—"
    @Published var shares = "0"
    @Published var statusMessage = "就绪"
    @Published var gpuReady = AppPaths.gpuReady

    private var process: Process?
    private var pipe: Pipe?
    private var waitTask: Task<Void, Never>?

    init() {
        _ = AppPaths.seedGpuBinaryIfNeeded()
        refreshGPUStatus()
    }

    func appendLog(_ line: String) {
        logText += line + "\n"
        if logText.count > 200_000 {
            logText = String(logText.suffix(150_000))
        }
        parseStatus(line)
    }

    private func parseStatus(_ line: String) {
        if line.range(of: #"mining ~[\d.]+ MH/s"#, options: .regularExpression) != nil {
            if let m = line.range(of: #"~([\d.]+) MH/s"#, options: .regularExpression) {
                let seg = String(line[m])
                if let num = seg.dropFirst().split(separator: " ").first {
                    hashrate = "\(num) MH/s"
                }
            }
        }
        if line.contains("SHARE ACCEPTED") {
            if let n = Int(shares) { shares = "\(n + 1)" } else { shares = "1" }
        }
        if let range = line.range(of: #"total accepted: (\d+)"#, options: .regularExpression) {
            let tail = line[range]
            if let num = tail.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) {
                shares = num
            }
        }
    }

    func clearLog() {
        logText = ""
        hashrate = "—"
        shares = "0"
    }

    func refreshGPUStatus() {
        _ = AppPaths.seedGpuBinaryIfNeeded()
        gpuReady = AppPaths.gpuReady
    }

    // MARK: - Background helpers (never block MainActor)

    private struct BashResult {
        let ok: Bool
        let lines: [String]
        let exitCode: Int32
    }

    private func runBashOffMain(_ script: String, arguments: [String] = [],
                                env: [String: String] = [:]) async -> BashResult {
        await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: script) else {
                return BashResult(ok: false, lines: ["[错误] 脚本不存在: \(script)"], exitCode: -1)
            }
            let proc = Process()
            let outPipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [script] + arguments
            proc.currentDirectoryURL = AppPaths.appRoot
            var environment = ProcessInfo.processInfo.environment
            for (k, v) in env { environment[k] = v }
            proc.environment = environment
            proc.standardOutput = outPipe
            proc.standardError = outPipe

            let lines = LockedLines()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                lines.append(contentsOf: chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            }

            do {
                try proc.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                return BashResult(ok: false, lines: ["[错误] \(error.localizedDescription)"], exitCode: -1)
            }

            proc.waitUntilExit()
            outPipe.fileHandleForReading.readabilityHandler = nil
            return BashResult(ok: proc.terminationStatus == 0, lines: lines.snapshot(), exitCode: proc.terminationStatus)
        }.value
    }

    private func findPythonOffMain() async -> String? {
        await Task.detached(priority: .userInitiated) {
            AppPaths.findPython()
        }.value
    }

    func ensureGPU() async -> Bool {
        refreshGPUStatus()
        if AppPaths.gpuReady { return true }

        if AppPaths.isBundledApp, AppPaths.seedGpuBinaryIfNeeded() {
            refreshGPUStatus()
            return true
        }

        appendLog("[gui] 正在编译 Metal Helper …")
        statusMessage = "编译 GPU …"
        let out = AppPaths.writableGpuBinary.path
        let result = await runBashOffMain(
            AppPaths.buildMetal.path,
            env: ["GPU_BIN": out]
        )
        for line in result.lines { appendLog(line) }
        refreshGPUStatus()
        if result.ok && AppPaths.gpuReady {
            appendLog("[gui] GPU Helper 就绪: \(AppPaths.gpuBinary.path)")
            return true
        }
        appendLog("[gui] 编译失败。请安装 Xcode CLT: xcode-select --install")
        statusMessage = "GPU 编译失败"
        return false
    }

    // MARK: - Stratum

    func startStratum(settings: MinerSettings) async {
        guard !isRunning, !isBusy else { return }
        guard !settings.address.trimmingCharacters(in: .whitespaces).isEmpty else {
            statusMessage = "请填写收款地址"
            return
        }

        isBusy = true
        statusMessage = "启动中…"
        defer { isBusy = false }

        appendLog("[gui] appRoot = \(AppPaths.appRoot.path)")
        appendLog("[gui] gpu     = \(AppPaths.gpuBinary.path)")

        guard await ensureGPU() else { return }
        guard let py = await findPythonOffMain() else {
            statusMessage = "未找到 Python 3"
            appendLog("[错误] 未找到 python3。请运行: xcode-select --install")
            return
        }
        appendLog("[gui] python  = \(py)")

        guard FileManager.default.fileExists(atPath: AppPaths.stratumMiner.path) else {
            statusMessage = "缺少矿工程序"
            appendLog("[错误] 找不到 \(AppPaths.stratumMiner.path)")
            return
        }

        let worker = settings.worker.trimmingCharacters(in: .whitespaces).isEmpty
            ? AppPaths.defaultWorker : settings.worker.trimmingCharacters(in: .whitespaces)
        let user = "\(settings.address.trimmingCharacters(in: .whitespaces)).\(worker)"
        let pool = settings.poolURL.trimmingCharacters(in: .whitespaces)

        var args = [
            AppPaths.stratumMiner.path,
            "--url", pool,
            "--user", user,
            "--pass", "x",
            "--gpu", "--gpu-binary", AppPaths.gpuBinary.path,
        ]
        let proxy = settings.proxy.trimmingCharacters(in: .whitespaces)
        if !proxy.isEmpty { args += ["--proxy", proxy] }
        let suggest = settings.suggestDifficulty.trimmingCharacters(in: .whitespaces)
        if !suggest.isEmpty { args += ["--suggest-difficulty", suggest] }

        shares = "0"
        hashrate = "—"
        appendLog("[gui] 启动矿池挖矿: \(user) @ \(pool)")
        if !proxy.isEmpty { appendLog("[gui] 代理: \(proxy)") }
        launch(python: py, scriptArgs: args)
    }

    // MARK: - Solo

    func startSolo(settings: MinerSettings) async {
        guard !isRunning, !isBusy else { return }
        isBusy = true
        statusMessage = "启动中…"
        defer { isBusy = false }

        guard await ensureGPU() else { return }
        guard let py = await findPythonOffMain() else {
            statusMessage = "未找到 Python 3"
            appendLog("[错误] 未找到 python3")
            return
        }

        var args = [
            AppPaths.gbtMiner.path,
            "--rpchost", settings.rpcHost,
            "--rpcport", settings.rpcPort,
            "--rpcuser", settings.rpcUser,
            "--rpcpassword", settings.rpcPassword,
            "--gpu", "--gpu-binary", AppPaths.gpuBinary.path,
        ]
        let addr = settings.soloAddress.trimmingCharacters(in: .whitespaces)
        if !addr.isEmpty { args += ["--address", addr] }

        appendLog("[gui] 启动 Solo 挖矿 …")
        launch(python: py, scriptArgs: args)
    }

    // MARK: - Tools

    func runSmokeTest() async {
        guard !isRunning, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard await ensureGPU() else { return }
        guard let py = await findPythonOffMain() else { return }
        appendLog("[gui] 运行 GPU 冒烟测试 …")
        launch(python: py, scriptArgs: [AppPaths.smokeTest.path])
    }

    func runProxyTest(proxy: String) async {
        guard !isRunning, !isBusy else { return }
        isBusy = true
        statusMessage = "测试代理…"
        defer { isBusy = false }
        let px = proxy.trimmingCharacters(in: .whitespaces).isEmpty
            ? "http://127.0.0.1:7890" : proxy.trimmingCharacters(in: .whitespaces)
        appendLog("[gui] 测试代理: \(px)")
        let result = await runBashOffMain(AppPaths.testProxy.path, arguments: [px])
        for line in result.lines { appendLog(line) }
        statusMessage = result.ok ? "代理测试通过" : "代理测试失败"
    }

    func buildMetal() async {
        guard !isRunning, !isBusy else { return }
        isBusy = true
        statusMessage = "编译 GPU …"
        defer { isBusy = false }
        let result = await runBashOffMain(
            AppPaths.buildMetal.path,
            env: ["GPU_BIN": AppPaths.writableGpuBinary.path]
        )
        for line in result.lines { appendLog(line) }
        refreshGPUStatus()
        statusMessage = result.ok ? "编译完成" : "编译失败"
    }

    // MARK: - Process control

    private func launch(python: String, scriptArgs: [String]) {
        let proc = Process()
        let outPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = scriptArgs
        proc.currentDirectoryURL = AppPaths.appRoot
        proc.standardOutput = outPipe
        proc.standardError = outPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            Task { @MainActor [weak self] in
                for line in lines { self?.appendLog(line) }
            }
        }

        do {
            try proc.run()
        } catch {
            appendLog("[错误] 启动失败: \(error.localizedDescription)")
            statusMessage = "启动失败"
            return
        }

        process = proc
        pipe = outPipe
        isRunning = true
        statusMessage = "挖矿中…"

        // waitUntilExit MUST run off the main thread
        waitTask = Task { [weak self] in
            let rc = await Task.detached {
                proc.waitUntilExit()
                return proc.terminationStatus
            }.value
            guard let self else { return }
            outPipe.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            self.isRunning = false
            self.statusMessage = "就绪"
            self.appendLog("[gui] 进程结束 (exit=\(rc))")
            self.refreshGPUStatus()
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else { return }
        appendLog("[gui] 正在停止 …")
        proc.interrupt()
        Task.detached {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if proc.isRunning { proc.terminate() }
        }
    }
}
