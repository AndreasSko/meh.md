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
                "Assets.xcassets", "CloudKitSmokeCheck.swift",
                "NotebookSyncLabApp.swift",
                "Info-iCloud.plist", "Info.plist",
                "PrivacyInfo.xcprivacy",
                "MarkdownEditor.swift", "EditorTextSizeControl.swift",
                "MarkdownEditingCommands.swift",
                "MarkdownTableEditing.swift",
                "MarkdownTableScrolling.swift",
                "MarkdownTableAccessibility.swift",
                "MarkdownLivePreview.swift",
                "EditorWritingControls.swift",
                "MarkdownPresentation.swift", "MarkdownTablePresentation.swift", "MarkdownSyntax.swift", "MyApp.swift",
                "NotebookAppDelegate.swift", "NotebookApplicationView.swift",
                "NotebookQuickActionRequests.swift",
                "NotebookBackupBackgroundScheduler.swift",
                "NotebookSettingsView.swift",
                "NotebookImportView.swift", "NotebookNoteEditor.swift",
                "NotebookTrashView.swift", "NotebookMoveSheet.swift",
                "NotebookSyncStatusView.swift", "NotebookView.swift", "icon.icon",
                "NotebookSidebarStyle.swift", "NotebookSearchViews.swift",
                "NoteHistoryBrowserView.swift", "NotebookRecentUIKitList.swift",
                "NotebookRecentsExpansion.swift",
                "iOS-iCloud.entitlements", "iOS.entitlements",
                "macOS-iCloud.entitlements", "macOS.entitlements",
            ],
            sources: [
                "NotebookWorkspace.swift",
                "NotebookSyncIndicator.swift",
                "NotebookNoteName.swift",
                "NotebookBrowserOrdering.swift",
                "NotebookBrowserSelection.swift",
                "NotebookNavigationState.swift",
                "NotebookRecentPreview.swift", "NotebookSearchState.swift",
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
                "MyApp.swift", "Assets.xcassets",
                "NotebookView.swift", "NotebookNoteEditor.swift", "NotebookWorkspace.swift",
                "NotebookTrashView.swift", "NotebookMoveSheet.swift",
                "NotebookSyncIndicator.swift",
                "NotebookSidebarStyle.swift", "NotebookSearchViews.swift",
                "NoteHistoryBrowserView.swift", "NotebookRecentUIKitList.swift",
                "NotebookRecentsExpansion.swift",
                "NotebookApplicationView.swift", "UnavailableDevelopmentTransport.swift",
                "NotebookSettingsView.swift",
                "NotebookImportView.swift", "NotebookSyncStatusView.swift",
                "NotebookNoteName.swift",
                "NotebookBrowserOrdering.swift",
                "NotebookBrowserSelection.swift",
                "NotebookNavigationState.swift",
                "NotebookRecentPreview.swift", "NotebookSearchState.swift",
                "icon.icon", "Info-iCloud.plist", "Info.plist", "macOS.entitlements",
                "PrivacyInfo.xcprivacy",
                "iOS.entitlements", "CloudKitSmokeCheck.swift",
                "NotebookSyncLabApp.swift",
                "NotebookAppDelegate.swift", "NotebookBackupBackgroundScheduler.swift",
                "NotebookQuickActionRequests.swift",
                "iOS-iCloud.entitlements", "macOS-iCloud.entitlements",
            ],
            sources: [
                "MarkdownEditor.swift",
                "EditorTextSizeControl.swift",
                "MarkdownEditingCommands.swift",
                "MarkdownTableEditing.swift",
                "MarkdownTableScrolling.swift",
                "MarkdownTableAccessibility.swift",
                "MarkdownLivePreview.swift",
                "EditorWritingControls.swift",
                "MarkdownPresentation.swift",
                "MarkdownTablePresentation.swift",
                "MarkdownSyntax.swift",
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "NativeEditorTests",
            dependencies: ["NativeEditor"],
            path: "Tests/NativeEditorTests"
        ),
    ]
)
