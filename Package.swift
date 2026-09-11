// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "cryptomako",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "cryptomako", targets: ["CryptoMakoCLI"]),
        .executable(name: "CryptoMakoApp", targets: ["CryptoMakoApp"]),
        .library(name: "CryptoMakoVault", targets: ["CryptoMakoVault"]),
        .library(name: "CryptoMakoS3", targets: ["CryptoMakoS3"]),
        .library(name: "CryptoMakoShared", targets: ["CryptoMakoShared"]),
    ],
    dependencies: [
        .package(url: "https://github.com/cryptomator/cryptolib-swift.git", .upToNextMinor(from: "1.1.0")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "CryptoMakoS3"),
        .target(name: "CryptoMakoShared"),
        // Built here purely so `swift build` type-checks the extension; the
        // shipping appex is compiled from these same sources by Xcode.
        .target(
            name: "CryptoMakoFileProvider",
            dependencies: [
                "CryptoMakoVault",
                "CryptoMakoS3",
                "CryptoMakoShared",
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
                "CryptoMakoShared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "CryptoMakoApp",
            dependencies: [
                "CryptoMakoVault",
                "CryptoMakoS3",
                "CryptoMakoShared",
            ]
        ),
        .testTarget(
            name: "CryptoMakoVaultTests",
            dependencies: [
                "CryptoMakoVault",
                "CryptoMakoS3",
                "CryptoMakoShared",
            ]
        ),
    ]
)
