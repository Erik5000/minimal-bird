// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Min Twitter contributors

import XCTest
@testable import FocusCore

final class NavigationPolicyTests: XCTestCase {
    func testComposerAndLogin() {
        for link in ["https://x.com/compose/post", "https://twitter.com/compose/tweet?text=hello", "https://x.com/compose/post/"] {
            XCTAssertEqual(NavigationPolicy.destination(for: URL(string: link)!), .composer)
        }
        for path in ["i/flow/login", "i/jf/onboarding/web", "login", "account/access", "account/begin_password_reset"] {
            XCTAssertEqual(NavigationPolicy.destination(for: URL(string: "https://x.com/" + path)!), .authentication)
        }
    }

    func testFeedsAndEscapesAreBlocked() {
        for link in ["https://x.com/notifications", "https://x.com/explore", "https://x.com/someone",
                     "https://x.com/someone/status/123", "https://x.com/messages", "http://x.com/compose/post",
                     "https://x.com.evil.test/compose/post", "https://evil.test/?x.com/compose/post",
                     "https://x.com@evil.test/compose/post", "https://someone@x.com/compose/post",
                     "https://x.com:8443/compose/post", "file:///tmp/index.html", "javascript:alert(1)"] {
            XCTAssertEqual(NavigationPolicy.destination(for: URL(string: link)!), .blocked, link)
        }
    }

    func testLandingPagesNeedCurtain() {
        for path in ["/", "/home"] {
            XCTAssertEqual(NavigationPolicy.destination(for: URL(string: "https://x.com" + path)!), .landing)
        }
    }
}
