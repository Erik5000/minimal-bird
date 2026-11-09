// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Minimal Bird contributors

import Foundation

/// Only top-level navigation is restricted. X still loads its own scripts and media.
public enum NavigationPolicy {
    public static let composerURL = URL(string: "https://x.com/compose/post")!

    public enum Destination: Equatable {
        case composer, authentication, landing, posts, postTarget, blocked
    }

    /// `ownHandle` is the signed-in account. Its post pages load under the
    /// curtain only. They are never a visible surface.
    public static func destination(for url: URL, ownHandle: String? = nil) -> Destination {
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
        default: return ownPostDestination(path, handle: ownHandle)
        }
    }

    public static func postsURL(handle: String) -> URL? {
        username(handle).flatMap { URL(string: "https://x.com/\($0)/with_replies") }
    }

    public static func statusURL(handle: String, id: String) -> URL? {
        guard isStatusID(id), let name = username(handle) else { return nil }
        return URL(string: "https://x.com/\(name)/status/\(id)")
    }

    public static func replyURL(to id: String) -> URL? {
        isStatusID(id) ? URL(string: "https://x.com/compose/post?in_reply_to=\(id)") : nil
    }

    private static func ownPostDestination(_ path: String, handle: String?) -> Destination {
        guard let name = handle.flatMap(username) else { return .blocked }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first?.lowercased() == name.lowercased() else { return .blocked }
        if parts.count == 2, parts[1] == "with_replies" { return .posts }
        if parts.count == 3, parts[1] == "status", isStatusID(parts[2]) { return .postTarget }
        return .blocked
    }

    private static func username(_ handle: String) -> String? {
        let name = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        let allowed = name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }
        return allowed && (1...15).contains(name.utf8.count) ? name : nil
    }

    private static func isStatusID(_ id: String) -> Bool {
        (1...25).contains(id.utf8.count) && id.utf8.allSatisfy { (48...57).contains($0) }
    }
}
