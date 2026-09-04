// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "FinanciumApp",
    platforms: [.iOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.36.1")
    ],
    targets: [
        .executableTarget(
            name: "FinanciumApp",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
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
