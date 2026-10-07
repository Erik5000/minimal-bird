// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Min Twitter contributors

import Foundation

/// Only top-level navigation is restricted. X still loads its own scripts and media.
public enum NavigationPolicy {
    public static let composerURL = URL(string: "https://x.com/compose/post")!

    public enum Destination: Equatable {
        case composer, authentication, landing, blocked
    }

    public static func destination(for url: URL) -> Destination {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(host)
        else { return .blocked }

        let path = url.path.count > 1 ? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : ""
        switch path {
        case "compose/post", "compose/tweet": return .composer
        case "login", "i/flow/login", "i/jf/onboarding/web", "account/access", "account/login_challenge",
             "account/begin_password_reset", "account/reset_password": return .authentication
        // A sign-in/post can redirect here. It is allowed to load under the curtain,
        // then the app requests the composer. It is never a visible surface.
        case "", "home", "i/flow/consent_flow": return .landing
        default: return .blocked
        }
    }
}
