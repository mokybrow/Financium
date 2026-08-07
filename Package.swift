// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "FinanciumApp",
    platforms: [.iOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.36.1"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.3.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", exact: "2.2.1"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport", exact: "2.5.0")
    ],
    targets: [
        .executableTarget(
            name: "FinanciumApp",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport")
            ],
            path: "Financium",
            exclude: ["Assets.xcassets", "Financium.entitlements"]
        )
    ]
)
