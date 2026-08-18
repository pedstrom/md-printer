// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "MarkdownPrinter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MarkdownPrinterCore", targets: ["MarkdownPrinterCore"]),
        .library(name: "MarkdownPrinterUI", targets: ["MarkdownPrinterUI"]),
        .executable(name: "MarkdownPrinter", targets: ["MarkdownPrinter"]),
        .executable(name: "MarkdownPrinterCLI", targets: ["MarkdownPrinterCLI"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.2"
        )
    ],
    targets: [
        .target(name: "MarkdownPrinterCore"),
        .target(
            name: "MarkdownPrinterUI",
            dependencies: [
                "MarkdownPrinterCore",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .executableTarget(
            name: "MarkdownPrinter",
            dependencies: ["MarkdownPrinterCore", "MarkdownPrinterUI"]
        ),
        .executableTarget(
            name: "MarkdownPrinterCLI",
            dependencies: ["MarkdownPrinterCore"]
        ),
        .testTarget(
            name: "MarkdownPrinterCoreTests",
            dependencies: ["MarkdownPrinterCore", "MarkdownPrinterUI"]
        )
    ],
    swiftLanguageModes: [.v5]
)
