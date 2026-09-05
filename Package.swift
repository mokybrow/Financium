// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "FinanciumApp",
    platforms: [.iOS(.v26)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "FinanciumApp",
            dependencies: [],
            path: "Financium",
            exclude: [
                "Assets.xcassets",
                "Financium.entitlements",
                "DollarWallet.icon",
                "DollarWallet2.icon",
                "BigLetherWallet.icon",
                "LetherWallet.icon"
            ]
        )
    ]
)
