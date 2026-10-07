// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Minimal Bird contributors
import PackageDescription

let package = Package(
    name: "MinimalBird",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MinimalBird", targets: ["MinimalBird"])],
    targets: [
        .target(name: "FocusCore"),
        .executableTarget(name: "MinimalBird", dependencies: ["FocusCore"],
                          resources: [.copy("Resources")]),
        .testTarget(name: "FocusCoreTests", dependencies: ["FocusCore"])
    ],
    swiftLanguageModes: [.v5]
)
