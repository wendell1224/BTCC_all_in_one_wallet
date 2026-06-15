import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var runner: MinerRunner
    @StateObject private var settings = MinerSettings()
    @StateObject private var wallet = WalletManager()
    @StateObject private var poolStats = PoolStatsManager()

    @State private var importMnemonic = ""
    @State private var sendTo = ""
    @State private var sendAmount = ""
    @State private var showMnemonicSheet = false
    @State private var createdMnemonic = ""

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            TabView {
                walletTab
                    .tabItem { Label("钱包", systemImage: "wallet.pass") }
                poolStatsTab
                    .tabItem { Label("矿池算力", systemImage: "chart.line.uptrend.xyaxis") }
                stratumTab
                    .tabItem { Label("矿池挖矿", systemImage: "network") }
                soloTab
                    .tabItem { Label("Solo", systemImage: "server.rack") }
                toolsTab
                    .tabItem { Label("工具", systemImage: "wrench.and.screwdriver") }
            }
            .padding(12)
            Divider()
            logPanel
        }
        .sheet(isPresented: $showMnemonicSheet) {
            mnemonicBackupSheet
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 16) {
            Label(runner.statusMessage, systemImage: runner.isRunning ? "bolt.fill" : "bolt.slash")
                .foregroundColor(runner.isRunning ? .green : .secondary)
            Spacer()
            Text("算力: \(runner.hashrate)")
                .font(.system(.body, design: .monospaced))
            Text("Shares: \(runner.shares)")
                .font(.system(.body, design: .monospaced))
            gpuBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var gpuBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: runner.gpuReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(runner.gpuReady ? .green : .orange)
            Text(runner.gpuReady ? "GPU 就绪" : "GPU 未编译")
                .font(.caption)
        }
    }

    // MARK: - Stratum

    private var stratumTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormRow(label: "收款地址 (cc1...)") {
                HStack {
                    TextField("cc1q...", text: $settings.address)
                        .textFieldStyle(.roundedBorder)
                    if !wallet.address.isEmpty {
                        Button("用钱包地址") { settings.address = wallet.address }
                            .buttonStyle(.borderless)
                    }
                }
            }
            FormRow(label: "Worker 名称") {
                TextField(settings.worker, text: $settings.worker)
                    .textFieldStyle(.roundedBorder)
            }
            FormRow(label: "矿池 URL") {
                TextField("stratum+tcp://...", text: $settings.poolURL)
                    .textFieldStyle(.roundedBorder)
            }
            FormRow(label: "代理 (可选)") {
                TextField("http://127.0.0.1:7890", text: $settings.proxy)
                    .textFieldStyle(.roundedBorder)
            }
            FormRow(label: "建议难度 (-1=自动)") {
                TextField("-1", text: $settings.suggestDifficulty)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            Text("用户名 = 地址.worker  |  国内用户请填 Clash 代理并确保规则放行矿池")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                Button(action: { Task { await runner.startStratum(settings: settings) } }) {
                    if runner.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .frame(minWidth: 120)
                    } else {
                        Label("开始挖矿", systemImage: "play.fill")
                            .frame(minWidth: 120)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(runner.isRunning || runner.isBusy)

                Button(action: { runner.stop() }) {
                    Label("停止", systemImage: "stop.fill")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!runner.isRunning)
                .tint(.red)
            }
        }
    }

    // MARK: - Pool stats

    private var poolStatsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormRow(label: "矿工地址") {
                HStack {
                    TextField("cc1q...", text: $settings.address)
                        .textFieldStyle(.roundedBorder)
                    if !wallet.address.isEmpty {
                        Button("用钱包地址") { settings.address = wallet.address }
                            .buttonStyle(.borderless)
                    }
                }
            }

            HStack(spacing: 12) {
                Button(action: { Task { await poolStats.refresh(address: settings.address) } }) {
                    if poolStats.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("查询矿池算力", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(poolStats.isLoading)

                Text("数据来源: pool.btc-classic.org")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !poolStats.errorMessage.isEmpty {
                Text(poolStats.errorMessage).foregroundColor(.red).font(.caption)
            }

            Group {
                statRow("当前总算力", poolStats.totalHashrate)
                statRow("待结算余额", poolStats.pendingBalance)
                statRow("待结算份额", poolStats.pendingShares)
            }

            if !poolStats.workers.isEmpty {
                Text("Worker 算力").font(.headline).padding(.top, 4)
                ForEach(poolStats.workers, id: \.name) { w in
                    HStack {
                        Text(w.name).frame(width: 140, alignment: .leading)
                        Text(w.hashrate).font(.system(.body, design: .monospaced))
                        Spacer()
                        Text("share \(w.sps)").font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            if !poolStats.samples.isEmpty {
                Text("24h 采样").font(.headline).padding(.top, 4)
                ForEach(Array(poolStats.samples.enumerated()), id: \.offset) { _, s in
                    HStack {
                        Text(s.time).font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Text(s.hashrate).font(.system(.caption, design: .monospaced))
                    }
                }
            }

            Spacer()
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
    }

    // MARK: - Wallet

    private var walletTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if wallet.hasWallet {
                walletOverview
            } else {
                walletCreateImport
            }
            Spacer()
        }
    }

    private var walletOverview: some View {
        Group {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("地址").font(.caption).foregroundColor(.secondary)
                    Text(wallet.address).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Spacer()
                Button("复制地址") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(wallet.address, forType: .string)
                }
            }

            HStack(spacing: 20) {
                VStack(alignment: .leading) {
                    Text("已确认").font(.caption).foregroundColor(.secondary)
                    Text(BTCCApiClient.formatBTCC(wallet.balanceConfirmed)).font(.headline)
                }
                VStack(alignment: .leading) {
                    Text("未确认").font(.caption).foregroundColor(.secondary)
                    Text(BTCCApiClient.formatBTCC(wallet.balanceUnconfirmed)).font(.headline)
                }
                Spacer()
                Button("刷新余额") { Task { await wallet.refreshBalance() } }
                    .disabled(wallet.isBusy)
            }

            Text("助记词: \(wallet.mnemonicPreview)").font(.caption).foregroundColor(.secondary)

            Divider().padding(.vertical, 4)

            Text("转账").font(.headline)
            FormRow(label: "收款地址") {
                TextField("cc1q...", text: $sendTo).textFieldStyle(.roundedBorder)
            }
            FormRow(label: "金额 (BTCC)") {
                TextField("0.001", text: $sendAmount).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            HStack(spacing: 10) {
                Button("发送") {
                    Task { await wallet.send(to: sendTo, amountBTCC: sendAmount) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(wallet.isBusy || sendTo.isEmpty || sendAmount.isEmpty)

                Button("用于挖矿") { settings.address = wallet.address }
                    .disabled(wallet.address.isEmpty)

                Button("删除钱包", role: .destructive) { wallet.deleteWallet() }
            }

            Text(wallet.statusMessage).font(.caption).foregroundColor(.secondary)
        }
    }

    private var walletCreateImport: some View {
        Group {
            Text("BIP39 助记词钱包（BIP84 路径 m/84'/0'/0'/0/0，cc1 地址）")
                .font(.caption).foregroundColor(.secondary)

            HStack(spacing: 10) {
                Button("创建新钱包") {
                    Task {
                        await wallet.createWallet()
                        if let m = wallet.exportMnemonic() {
                            createdMnemonic = m
                            showMnemonicSheet = true
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(wallet.isBusy)
            }

            Divider().padding(.vertical, 6)

            Text("导入助记词").font(.headline)
            TextEditor(text: $importMnemonic)
                .font(.system(.body, design: .monospaced))
                .frame(height: 72)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            Button("导入钱包") {
                Task { await wallet.importWallet(mnemonic: importMnemonic) }
            }
            .disabled(wallet.isBusy || importMnemonic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Text(wallet.statusMessage).font(.caption).foregroundColor(.secondary)
        }
    }

    private var mnemonicBackupSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("请备份助记词").font(.title2.bold())
            Text("助记词是恢复钱包的唯一凭证，请抄写在纸上妥善保管，切勿截图或上传云端。")
                .foregroundColor(.secondary)
            Text(createdMnemonic)
                .font(.system(.body, design: .monospaced))
                .padding()
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
                .textSelection(.enabled)
            HStack {
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(createdMnemonic, forType: .string)
                }
                Spacer()
                Button("我已备份") { showMnemonicSheet = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    // MARK: - Solo

    private var soloTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormRow(label: "RPC 主机") {
                TextField("127.0.0.1", text: $settings.rpcHost).textFieldStyle(.roundedBorder)
            }
            FormRow(label: "RPC 端口") {
                TextField("28476", text: $settings.rpcPort).textFieldStyle(.roundedBorder).frame(width: 100)
            }
            FormRow(label: "RPC 用户") {
                TextField("user", text: $settings.rpcUser).textFieldStyle(.roundedBorder)
            }
            FormRow(label: "RPC 密码") {
                SecureField("pass", text: $settings.rpcPassword).textFieldStyle(.roundedBorder)
            }
            FormRow(label: "收款地址 (可选)") {
                TextField("留空则节点自动分配", text: $settings.soloAddress).textFieldStyle(.roundedBorder)
            }

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                Button(action: { Task { await runner.startSolo(settings: settings) } }) {
                    Label("开始 Solo", systemImage: "play.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(runner.isRunning || runner.isBusy)

                Button(action: { runner.stop() }) {
                    Label("停止", systemImage: "stop.fill")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!runner.isRunning)
            }
        }
    }

    // MARK: - Tools

    private var toolsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("首次使用请先编译 Metal GPU Helper（需要 Xcode Command Line Tools）")
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Button("编译 Metal Helper") {
                    Task { await runner.buildMetal() }
                }
                .disabled(runner.isRunning || runner.isBusy)

                Button("GPU 冒烟测试") {
                    Task { await runner.runSmokeTest() }
                }
                .disabled(runner.isRunning || runner.isBusy)

                Button("测试代理") {
                    Task { await runner.runProxyTest(proxy: settings.proxy) }
                }
                .disabled(runner.isRunning || runner.isBusy)
            }

            Text("项目路径: \(AppPaths.appRoot.path)")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Log

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("运行日志")
                    .font(.headline)
                Spacer()
                Button("清空") { runner.clearLog() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.logText.isEmpty ? "等待操作…" : runner.logText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("logbottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .onChange(of: runner.logText) { _ in
                    proxy.scrollTo("logbottom", anchor: .bottom)
                }
            }
        }
        .frame(minHeight: 180, maxHeight: 260)
    }
}

struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 140, alignment: .trailing)
            content
        }
    }
}
