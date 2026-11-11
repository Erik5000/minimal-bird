// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Minimal Bird contributors

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

    func testOnlyTheSignedInAccountsPostsAreAllowed() {
        func destination(_ path: String, _ handle: String? = "@Writer") -> NavigationPolicy.Destination {
            NavigationPolicy.destination(for: URL(string: "https://x.com" + path)!, ownHandle: handle)
        }
        // X's profile has Posts, Replies, Reposts and Media tabs. My posts reads
        // the first two. Standalone posts are only on the Posts tab.
        XCTAssertEqual(destination("/Writer"), .posts)
        XCTAssertEqual(destination("/writer/"), .posts)
        XCTAssertEqual(destination("/Writer/with_replies"), .posts)
        XCTAssertEqual(destination("/writer/with_replies/"), .posts)
        XCTAssertEqual(destination("/Writer/status/123"), .postTarget)
        for path in ["/Writer2/with_replies", "/Write/with_replies", "/someone/with_replies", "/someone/status/123",
                     "/Writer2", "/someone", "/Writer/media", "/Writer/reposts", "/Writer/likes",
                     "/Writer/status/abc", "/Writer/status/123/photo/1", "/Writer/status/123/analytics"] {
            XCTAssertEqual(destination(path), .blocked, path)
        }
        XCTAssertEqual(destination("/Writer", nil), .blocked)
        XCTAssertEqual(destination("/Writer/with_replies", nil), .blocked)
        XCTAssertEqual(destination("/Writer/status/123", nil), .blocked)
        XCTAssertEqual(destination("/compose/post?in_reply_to=123"), .composer)
    }

    func testLinksToOwnPostsAreValidated() {
        XCTAssertEqual(NavigationPolicy.postsURL(handle: "@Writer")?.absoluteString, "https://x.com/Writer")
        XCTAssertEqual(NavigationPolicy.postsURL(handle: "@Writer", tab: .replies)?.absoluteString, "https://x.com/Writer/with_replies")
        XCTAssertEqual(NavigationPolicy.statusURL(handle: "@Writer", id: "123")?.absoluteString, "https://x.com/Writer/status/123")
        XCTAssertEqual(NavigationPolicy.replyURL(to: "123")?.absoluteString, "https://x.com/compose/post?in_reply_to=123")
        XCTAssertNil(NavigationPolicy.postsURL(handle: "@bad/handle"))
        XCTAssertNil(NavigationPolicy.statusURL(handle: "@Writer", id: "12a"))
        XCTAssertNil(NavigationPolicy.replyURL(to: "123&text=hello"))
        XCTAssertNil(NavigationPolicy.replyURL(to: ""))
    }
}
