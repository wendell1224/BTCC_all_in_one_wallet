import SwiftUI

@main
struct BTCCWalletApp: App {
    @StateObject private var runner = MinerRunner()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(runner)
                .frame(minWidth: 820, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
