// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AutomergeSpike",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "AutomergeSpike",
            targets: ["AutomergeSpike"]
        ),
        .executable(
            name: "AutomergeSpikeWriter",
            targets: ["AutomergeSpikeWriter"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/automerge/automerge-swift.git",
            exact: "0.7.2"
        ),
    ],
    targets: [
        .target(
            name: "AutomergeSpike",
            dependencies: [
                .product(
                    name: "Automerge",
                    package: "automerge-swift"
                ),
            ]
        ),
        .testTarget(
            name: "AutomergeSpikeTests",
            dependencies: [
                "AutomergeSpike",
                .product(name: "Automerge", package: "automerge-swift"),
            ]
        ),
        .executableTarget(
            name: "AutomergeSpikeWriter",
            dependencies: ["AutomergeSpike"]
        ),
    ]
)
