// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MehCore",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "NotebookAppModel", targets: ["NotebookAppModel"]),
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
            name: "NotebookAppModel",
            dependencies: ["NoteCore"],
            path: "meh.md",
            exclude: [
                "AppWorkspace.swift", "Assets.xcassets", "CloudKitSmokeCheck.swift",
                "ContentView.swift", "Info-iCloud.plist", "Info.plist",
                "MarkdownEditor.swift", "EditorTextSizeControl.swift",
                "MarkdownEditingCommands.swift", "MarkdownLivePreview.swift",
                "EditorWritingControls.swift",
                "MarkdownPresentation.swift", "MarkdownSyntax.swift", "MyApp.swift",
                "NotebookAppDelegate.swift", "NotebookApplicationView.swift",
                "NotebookImportView.swift", "NotebookNoteEditor.swift",
                "NotebookSyncStatusView.swift", "NotebookView.swift", "icon.icon",
                "iOS-iCloud.entitlements", "iOS.entitlements",
                "macOS-iCloud.entitlements", "macOS.entitlements",
            ],
            sources: [
                "NotebookWorkspace.swift",
                "NotebookNoteName.swift",
                "NotebookBrowserOrdering.swift",
                "NotebookNavigationState.swift",
                "UnavailableDevelopmentTransport.swift",
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "NotebookAppModelTests",
            dependencies: ["NotebookAppModel", "NoteCore"],
            path: "Tests/NotebookAppModelTests"
        ),
        .target(
            name: "NativeEditor",
            path: "meh.md",
            exclude: [
                "ContentView.swift", "MyApp.swift", "AppWorkspace.swift", "Assets.xcassets",
                "NotebookView.swift", "NotebookNoteEditor.swift", "NotebookWorkspace.swift",
                "NotebookApplicationView.swift", "UnavailableDevelopmentTransport.swift",
                "NotebookImportView.swift", "NotebookSyncStatusView.swift",
                "NotebookNoteName.swift",
                "NotebookBrowserOrdering.swift",
                "NotebookNavigationState.swift",
                "icon.icon", "Info-iCloud.plist", "Info.plist", "macOS.entitlements",
                "iOS.entitlements", "CloudKitSmokeCheck.swift",
                "NotebookAppDelegate.swift", "iOS-iCloud.entitlements", "macOS-iCloud.entitlements",
            ],
            sources: [
                "MarkdownEditor.swift",
                "EditorTextSizeControl.swift",
                "MarkdownEditingCommands.swift",
                "MarkdownLivePreview.swift",
                "EditorWritingControls.swift",
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
