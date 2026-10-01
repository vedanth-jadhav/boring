// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BoringNotchLocal",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "boringNotch", targets: ["boringNotch"])],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/AsyncXPCConnection", exact: "1.3.0"),
        .package(url: "https://github.com/TheBoredTeam/MacroVisionKit", exact: "0.2.0"),
        .package(url: "https://github.com/Lakr233/SkyLightWindow", exact: "1.0.0"),
        .package(url: "https://github.com/airbnb/lottie-spm.git", exact: "4.6.1"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", exact: "1.1.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.6.0"),
        .package(url: "https://github.com/siteline/swiftui-introspect", exact: "26.1.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0"),
        .package(url: "https://github.com/sindresorhus/Defaults", exact: "9.0.9")
    ],
    targets: [
        .executableTarget(
            name: "boringNotch", dependencies: [
                .product(name: "AsyncXPCConnection", package: "AsyncXPCConnection"),
                .product(name: "MacroVisionKit", package: "MacroVisionKit"),
                .product(name: "SkyLightWindow", package: "SkyLightWindow"),
                .product(name: "Lottie", package: "lottie-spm"),
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "SwiftUIIntrospect", package: "swiftui-introspect"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Defaults", package: "Defaults")
            ], path: ".", exclude: [
                "BoringNotchXPCHelper", "boringNotchTests", "Configuration", "Scripts",
                "mediaremote-adapter", "octave-brave-extension", "updater", ".github", "build",
                "CODE_OF_CONDUCT.md", "CONTRIBUTING.md", "LICENSE", "README.md",
                "SECURITY.md", "THIRD_PARTY_LICENSES", "crowdin.yml",
                "boringNotch/Assets.xcassets", "boringNotch/Preview Content",
                "boringNotch/Localizable.xcstrings", "boringNotch/Info.plist",
                "boringNotch/boringNotch.entitlements", "boringNotch/boring.m4a",
                "boringNotch/components/Music/LottieAnimationView.swift"
            ], sources: ["boringNotch", "Shared"],
            swiftSettings: [.define("BORING_LOCAL_BUILD")]
        ),
        .executableTarget(name: "BoringNotchXPCHelper", path: ".spm-generated/helper")
    ],
    swiftLanguageModes: [.v5]
)
