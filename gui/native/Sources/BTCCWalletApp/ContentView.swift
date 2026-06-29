import SwiftUI
import AppKit

struct ContentView: View {
    private enum MainTab: Hashable {
        case wallet, otc, poolStats, stratum, solo, tools
    }

    @EnvironmentObject var runner: MinerRunner
    @StateObject private var settings = MinerSettings()
    @StateObject private var wallet = WalletManager()
    @StateObject private var poolStats = PoolStatsManager()
    @StateObject private var otcStats = OTCStatsManager()

    @State private var importMnemonic = ""
    @State private var sendTo = ""
    @State private var sendAmount = ""
    @State private var sendMemo = ""
    @State private var showMnemonicSheet = false
    @State private var createdMnemonic = ""
    @State private var selectedTab: MainTab = .wallet
    @State private var copiedMinerAddress = ""

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            TabView(selection: $selectedTab) {
                walletTab
                    .tabItem { Label("钱包", systemImage: "wallet.pass") }
                    .tag(MainTab.wallet)
                otcTab
                    .tabItem { Label("OTC", systemImage: "chart.bar.xaxis") }
                    .tag(MainTab.otc)
                poolStatsTab
                    .tabItem { Label("矿池算力", systemImage: "chart.line.uptrend.xyaxis") }
                    .tag(MainTab.poolStats)
                stratumTab
                    .tabItem { Label("矿池挖矿", systemImage: "network") }
                    .tag(MainTab.stratum)
                soloTab
                    .tabItem { Label("Solo", systemImage: "server.rack") }
                    .tag(MainTab.solo)
                toolsTab
                    .tabItem { Label("工具", systemImage: "wrench.and.screwdriver") }
                    .tag(MainTab.tools)
            }
            .padding(12)
            if selectedTab == .wallet || selectedTab == .poolStats || selectedTab == .stratum {
                Divider()
                bottomPanel
            }
        }
        .onChange(of: selectedTab) { tab in
            if tab == .otc, otcStats.overview == nil, !otcStats.isLoading {
                Task { await otcStats.refresh() }
            }
            if tab == .poolStats, poolStats.topMiners.isEmpty, !poolStats.isRankingLoading {
                Task { await poolStats.refreshRanking() }
            }
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
            miningPowerControls

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

            Divider().padding(.vertical, 4)

            poolRankingPanel

            Spacer()
        }
    }

    private var poolRankingPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("算力排行榜")
                    .font(.headline)
                Text("Solo Top")
                    .font(.caption.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundColor(.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                if !poolStats.rankingUpdatedAt.isEmpty {
                    Text("更新 \(poolStats.rankingUpdatedAt)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { Task { await poolStats.refreshRanking() } }) {
                    if poolStats.isRankingLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("刷新排行", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(poolStats.isRankingLoading)
            }

            if !poolStats.rankingErrorMessage.isEmpty {
                Text(poolStats.rankingErrorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            VStack(spacing: 0) {
                HStack {
                    Text("#").frame(width: 34, alignment: .leading)
                    Text("矿工地址")
                    Spacer()
                    Text("Worker").frame(width: 52, alignment: .trailing)
                    Text("1h").frame(width: 100, alignment: .trailing)
                    Text("1d").frame(width: 100, alignment: .trailing)
                    Text("7d").frame(width: 100, alignment: .trailing)
                    Text("Best").frame(width: 76, alignment: .trailing)
                }
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                Divider()

                if poolStats.isRankingLoading && poolStats.topMiners.isEmpty {
                    Text("加载排行榜…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                } else if poolStats.topMiners.isEmpty {
                    Text("暂无排行榜数据")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                } else {
                    ForEach(poolStats.topMiners) { row in
                        poolRankingRow(row)
                        if row.id != poolStats.topMiners.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .task {
            if poolStats.topMiners.isEmpty && !poolStats.isRankingLoading {
                await poolStats.refreshRanking()
            }
        }
    }

    private func poolRankingRow(_ row: PoolStatsManager.TopMinerRow) -> some View {
        HStack(spacing: 8) {
            Text("\(row.rank)")
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundColor(rankingColor(row.rank))
                .frame(width: 34, alignment: .leading)
            Button(action: { copyMinerAddress(row.address) }) {
                Text(row.address)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("点击复制: \(row.address)")
            if copiedMinerAddress == row.address {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                    .help("已复制")
            }
            Spacer()
            Text(row.workers)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .trailing)
            Text(row.hashrate1hr)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(row.hashrate1d)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 100, alignment: .trailing)
            Text(row.hashrate7d)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(row.bestShare)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func copyMinerAddress(_ address: String) {
        settings.address = address
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(address, forType: .string)
        copiedMinerAddress = address
    }

    private func rankingColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return .orange
        case 2: return .secondary
        case 3: return .brown
        default: return .primary
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
    }

    // MARK: - OTC

    private var otcTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            otcToolbar

            if !otcStats.errorMessage.isEmpty {
                Label(otcStats.errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if let overview = otcStats.overview {
                otcOverviewPanel(overview)
                otcMetricGrid(overview)
            } else {
                otcEmptyPanel
            }

            Spacer(minLength: 0)
        }
        .task {
            if otcStats.overview == nil, !otcStats.isLoading {
                await otcStats.refresh()
            }
        }
    }

    private var otcToolbar: some View {
        HStack(spacing: 10) {
            Label("OTC 行情", systemImage: "chart.bar.xaxis")
                .font(.headline)
            Text("otc.btc-classic.org")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            if !otcStats.lastUpdated.isEmpty {
                Text("更新 \(otcStats.lastUpdated)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Link(destination: URL(string: "https://otc.btc-classic.org/otc/")!) {
                Label("打开 OTC", systemImage: "safari")
            }
            .buttonStyle(.borderless)

            Button(action: { Task { await otcStats.refresh() } }) {
                if otcStats.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .disabled(otcStats.isLoading)
        }
    }

    private func otcOverviewPanel(_ overview: OTCOverview) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("最新成交价")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(formatDecimal(overview.lastPrice, digits: 4))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                    Text(overview.lastToken)
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
            }

            Divider()
                .frame(height: 56)

            VStack(alignment: .leading, spacing: 8) {
                Label("24h \(formatSignedDecimal(overview.priceChange24h, digits: 2))%", systemImage: overview.priceChange24h >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.headline)
                    .foregroundColor(otcChangeColor(overview.priceChange24h))
                Text("24h 成交 \(formatDecimal(overview.volume24h, digits: 2)) BTCC")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("成交额 \(formatDecimal(overview.volumeUSDT24h, digits: 2)) USDT")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        )
    }

    private func otcMetricGrid(_ overview: OTCOverview) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            spacing: 10
        ) {
            OTCMetricTile(title: "24h 成交笔数", value: "\(overview.count24h)", subtitle: "最近 24 小时", icon: "number")
            OTCMetricTile(title: "总成交笔数", value: "\(overview.totalCount)", subtitle: "累计订单", icon: "sum")
            OTCMetricTile(title: "24h 成交量", value: formatDecimal(overview.volume24h, digits: 2), subtitle: "BTCC", icon: "bitcoinsign.circle")
            OTCMetricTile(title: "总成交量", value: formatDecimal(overview.totalVolume, digits: 2), subtitle: "BTCC", icon: "chart.pie")
            OTCMetricTile(title: "24h 成交额", value: formatDecimal(overview.volumeUSDT24h, digits: 2), subtitle: "USDT", icon: "dollarsign.circle")
            OTCMetricTile(title: "总成交额", value: formatDecimal(overview.volumeUSDTTotal, digits: 2), subtitle: "USDT", icon: "banknote")
        }
    }

    private var otcEmptyPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if otcStats.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .foregroundColor(.secondary)
                }
                Text(otcStats.isLoading ? "加载 OTC 数据…" : "暂无 OTC 数据")
                    .foregroundColor(.secondary)
            }
            Button("刷新") {
                Task { await otcStats.refresh() }
            }
            .disabled(otcStats.isLoading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func otcChangeColor(_ value: Double) -> Color {
        if value > 0 { return .green }
        if value < 0 { return .red }
        return .secondary
    }

    private func formatDecimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    private func formatSignedDecimal(_ value: Double, digits: Int) -> String {
        let prefix = value > 0 ? "+" : ""
        return prefix + formatDecimal(value, digits: digits)
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
                TextField("cc1 / 1 / 3 地址", text: $sendTo).textFieldStyle(.roundedBorder)
            }
            FormRow(label: "金额 (BTCC)") {
                TextField("0.001", text: $sendAmount).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            FormRow(label: "备注") {
                TextField("可选", text: $sendMemo).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 10) {
                Button("发送") {
                    Task { await wallet.send(to: sendTo, amountBTCC: sendAmount, memo: sendMemo) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(wallet.isBusy || sendTo.isEmpty || sendAmount.isEmpty)

                Button("删除钱包", role: .destructive) { wallet.deleteWallet() }
            }

            Text(wallet.statusMessage).font(.caption).foregroundColor(.secondary)

            if !wallet.lastTxid.isEmpty {
                txResultView
            }
        }
    }

    private var txResultView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("交易 ID").font(.caption).foregroundColor(.secondary)
            Text(wallet.lastTxid)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Button("复制 TXID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(wallet.lastTxid, forType: .string)
                }
                if let url = wallet.lastTxExplorerURL {
                    Link("区块浏览器", destination: url)
                }
            }
        }
        .padding(.top, 4)
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
            miningPowerControls

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

    private var miningPowerControls: some View {
        FormRow(label: "低功耗在线") {
            HStack(spacing: 12) {
                Toggle("启用", isOn: $settings.lowPowerMining)
                    .toggleStyle(.checkbox)
                    .disabled(runner.isRunning)
                Slider(value: $settings.miningDutyPercent, in: 5...100, step: 5)
                    .frame(width: 180)
                    .disabled(!settings.lowPowerMining || runner.isRunning)
                Text("\(Int(settings.miningDutyPercent))%")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 48, alignment: .trailing)
                    .foregroundColor(settings.lowPowerMining ? .primary : .secondary)
                Text(settings.lowPowerMining ? "低占用保持在线" : "全性能")
                    .font(.caption)
                    .foregroundColor(.secondary)
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

    // MARK: - Bottom Panels

    @ViewBuilder
    private var bottomPanel: some View {
        switch selectedTab {
        case .wallet:
            walletHistoryPanel
        case .poolStats, .stratum:
            logPanel
        case .otc, .solo, .tools:
            EmptyView()
        }
    }

    @ViewBuilder
    private var walletHistoryPanel: some View {
        let page = wallet.historyPage()
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("钱包历史")
                    .font(.headline)
                Spacer()
                Text("\(page.total) 笔  \(page.page + 1)/\(page.pageCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if wallet.isHistoryLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Stepper(
                    "",
                    value: Binding(
                        get: { wallet.historyPageSize },
                        set: { newValue in
                            Task { await wallet.setHistoryPageSize(newValue) }
                        }
                    ),
                    in: 5...50,
                    step: 5
                )
                    .labelsHidden()
                    .frame(width: 90)
                    .disabled(wallet.isHistoryLoading)
                Button("上一页") { Task { await wallet.historyPrevPage() } }
                    .buttonStyle(.borderless)
                    .disabled(wallet.isHistoryLoading || page.page == 0)
                Button("下一页") { Task { await wallet.historyNextPage() } }
                    .buttonStyle(.borderless)
                    .disabled(wallet.isHistoryLoading || page.page + 1 >= page.pageCount)
                Button("刷新") { Task { await wallet.refreshHistory() } }
                    .buttonStyle(.borderless)
                    .disabled(wallet.isHistoryLoading || wallet.address.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if wallet.isHistoryLoading && wallet.transactionHistory.isEmpty {
                        Text("加载中…")
                            .foregroundColor(.secondary)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if wallet.transactionHistory.isEmpty {
                        Text(wallet.hasWallet ? "暂无交易记录" : "未创建钱包")
                            .foregroundColor(.secondary)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(page.items) { tx in
                            HStack(spacing: 10) {
                                Text(tx.action)
                                    .font(.caption.bold())
                                    .frame(width: 48, alignment: .leading)
                                    .foregroundColor(historyActionColor(tx.action))
                                Text(historyAmountText(tx))
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(width: 132, alignment: .trailing)
                                    .foregroundColor(historyAmountColor(tx))
                                Text(tx.height.map { "#\($0)" } ?? "未确认")
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(width: 72, alignment: .leading)
                                    .foregroundColor(.secondary)
                                Text(historyTimeText(tx))
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(width: 118, alignment: .leading)
                                    .foregroundColor(.secondary)
                                Text(tx.txid)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Spacer()
                                if let url = URL(string: "https://explorer.btc-classic.org/tx/\(tx.txid)") {
                                    Link("浏览", destination: url)
                                }
                            }
                        }
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(minHeight: 180, maxHeight: 260)
    }

    private func historyAmountText(_ tx: WalletManager.TransactionRecord) -> String {
        guard tx.action != "未知" else { return "--" }
        let prefix = tx.amountSats > 0 ? "+" : ""
        return prefix + BTCCApiClient.formatBTCC(tx.amountSats)
    }

    private func historyAmountColor(_ tx: WalletManager.TransactionRecord) -> Color {
        if tx.amountSats > 0 { return .green }
        if tx.amountSats < 0 { return .red }
        return .secondary
    }

    private func historyActionColor(_ action: String) -> Color {
        switch action {
        case "收到":
            return .green
        case "转账":
            return .red
        case "自转账":
            return .orange
        default:
            return .secondary
        }
    }

    private func historyTimeText(_ tx: WalletManager.TransactionRecord) -> String {
        guard let timeISO = tx.timeISO, !timeISO.isEmpty else { return "—" }
        return timeISO
            .replacingOccurrences(of: "T", with: " ")
            .replacingOccurrences(of: "Z", with: "")
            .prefix(16)
            .description
    }

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

struct OTCMetricTile: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(.headline, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
    }
}
