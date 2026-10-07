// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Min Twitter contributors

import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
