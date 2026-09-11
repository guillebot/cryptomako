// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "cryptomako",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "cryptomako", targets: ["CryptoMakoCLI"]),
        .library(name: "CryptoMakoVault", targets: ["CryptoMakoVault"]),
        .library(name: "CryptoMakoS3", targets: ["CryptoMakoS3"]),
    ],
    dependencies: [
        .package(url: "https://github.com/cryptomator/cryptolib-swift.git", .upToNextMinor(from: "1.1.0")),
        .package(url: "https://github.com/soto-project/soto.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "CryptoMakoS3",
            dependencies: [
                .product(name: "SotoS3", package: "soto"),
            ]
        ),
        .target(
            name: "CryptoMakoVault",
            dependencies: [
                "CryptoMakoS3",
                .product(name: "CryptomatorCryptoLib", package: "cryptolib-swift"),
            ]
        ),
        .executableTarget(
            name: "CryptoMakoCLI",
            dependencies: [
                "CryptoMakoVault",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "CryptoMakoVaultTests",
            dependencies: [
                "CryptoMakoVault",
            ]
        ),
    ]
)
