// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BTCCWalletApp",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "BTCCWalletApp", targets: ["BTCCWalletApp"]),
    ],
    targets: [
        .executableTarget(
            name: "BTCCWalletApp",
            path: "Sources/BTCCWalletApp"
        ),
    ]
)
