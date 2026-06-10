// swift-tools-version: 6.2

import PackageDescription

enum Module {
    static let core = "RinCore"
    static let cli = "RinterCLI"
    static let plugin = "Rinter"
    static let tests = "RinTests"
}

let package = Package(
    name: "Rin",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "rinter", targets: [Module.cli]),
        .plugin(name: Module.plugin, targets: [Module.plugin])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "602.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(
            name: Module.core,
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax")
            ]
        ),
        .executableTarget(
            name: Module.cli,
            dependencies: [
                .target(name: Module.core),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .plugin(
            name: Module.plugin,
            capability: .command(
                intent: .custom(
                    verb: "rinter",
                    description: "Run semantic policy checks from Rinfile.swift"
                )
            ),
            dependencies: [
                .target(name: Module.cli)
            ]
        ),
        .testTarget(
            name: Module.tests,
            dependencies: [
                .target(name: Module.core)
            ]
        )
    ]
)
