// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MehCore",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "NativeEditor", targets: ["NativeEditor"]),
    ],
    dependencies: [
        .package(path: "Spikes/AutomergeSpike"),
    ],
    targets: [
        .target(
            name: "NativeEditor",
            path: "meh.md",
            exclude: [
                "ContentView.swift", "MyApp.swift", "Assets.xcassets",
                "icon.icon",
            ],
            sources: [
                "MarkdownEditor.swift",
                "MarkdownPresentation.swift",
                "MarkdownSyntax.swift",
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "NativeEditorTests",
            dependencies: [
                "NativeEditor",
                .product(name: "AutomergeSpike", package: "AutomergeSpike"),
            ],
            path: "Tests/NativeEditorTests"
        ),
    ]
)
