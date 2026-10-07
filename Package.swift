// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Min Twitter contributors
import PackageDescription

let package = Package(
    name: "MinTwitter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MinTwitter", targets: ["MinTwitter"])],
    targets: [
        .target(name: "FocusCore"),
        .executableTarget(name: "MinTwitter", dependencies: ["FocusCore"],
                          resources: [.copy("Resources")]),
        .testTarget(name: "FocusCoreTests", dependencies: ["FocusCore"])
    ],
    swiftLanguageModes: [.v5]
)
