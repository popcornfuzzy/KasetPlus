// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Kaset",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(
            name: "Kaset",
            targets: ["Kaset"]
        ),
        .executable(
            name: "api-explorer",
            targets: ["APIExplorer"]
        ),
        // The non-sandboxed helper the app talks to for Discord Rich Presence. See
        // docs/adr/0039-discord-rich-presence.md.
        .executable(
            name: "KasetPresenceBridge",
            targets: ["KasetPresenceBridge"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1"),
    ],
    targets: [
        // Wire format shared by the app and its Discord presence helper.
        .target(
            name: "DiscordBridge",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // The helper itself. Signed without the App Sandbox: it is the one process that may
        // talk to the Discord client's IPC socket.
        .executableTarget(
            name: "KasetPresenceBridge",
            dependencies: ["DiscordBridge"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        // Main app executable
        .executableTarget(
            name: "Kaset",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "DiscordBridge",
            ],
            resources: [
                // Resources ships .lproj/Localizable.strings files. Do not add a
                // Localizable.xcstrings catalog: SwiftPM emits one compile task per
                // catalog localization, which collides with the .lproj output paths
                // and fails the build.
                // See docs/adr/0016-strings-files-as-localization-source-of-truth.md.
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        // API Explorer CLI tool
        .executableTarget(
            name: "APIExplorer",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // Unit tests
        .testTarget(
            name: "KasetTests",
            dependencies: ["Kaset", "DiscordBridge"],
            resources: [
                .process("Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
