// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MehCore",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "NativeEditor", targets: ["NativeEditor"]),
        .library(name: "NoteCore", targets: ["NoteCore"]),
    ],
    dependencies: [
        .package(path: "Spikes/AutomergeSpike"),
        .package(
            url: "https://github.com/automerge/automerge-swift.git",
            exact: "0.7.2"
        ),
    ],
    targets: [
        .target(
            name: "NoteCore",
            dependencies: [
                .product(name: "Automerge", package: "automerge-swift"),
            ]
        ),
        .testTarget(
            name: "NoteCoreTests",
            dependencies: [
                "NoteCore",
                .product(name: "Automerge", package: "automerge-swift"),
            ]
        ),
        .target(
            name: "NativeEditor",
            path: "meh.md",
            exclude: [
                "ContentView.swift", "MyApp.swift", "AppWorkspace.swift", "Assets.xcassets",
                "NotebookView.swift", "NotebookNoteEditor.swift", "NotebookWorkspace.swift",
                "NotebookApplicationView.swift", "UnavailableDevelopmentTransport.swift",
                "NotebookImportView.swift",
                "icon.icon", "Info.plist", "macOS.entitlements",
                "iOS.entitlements", "CloudKitSmokeCheck.swift",
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
