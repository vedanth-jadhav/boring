// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CaffeineEngine", platforms: [.macOS(.v14)],
    products: [.library(name: "CaffeineEngine", targets: ["CaffeineEngine"])],
    targets: [.target(name: "CaffeineEngine", path: ".", exclude: ["LICENSE", "NOTICE.md"],
                      sources: ["CaffeineEngine.swift", "Core", "System", "Store", "Model"],
                      swiftSettings: [.swiftLanguageMode(.v6)])])
