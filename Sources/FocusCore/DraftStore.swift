// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Minimal Bird contributors

import Foundation

/// Text of an unposted post or thread. Attachments and polls stay with X.
public struct Draft: Codable, Equatable, Identifiable {
    public let id: UUID
    public var posts: [String]
    public var updated: Date

    /// The first line with text, for compact lists.
    public var preview: String {
        for post in posts {
            if let line = post.split(whereSeparator: \.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
                return line
            }
        }
        return ""
    }

    public static func hasText(_ posts: [String]) -> Bool {
        posts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Local drafts for one account, newest first. Stored as a private JSON file
/// on this Mac; nothing is sent anywhere. Changes are kept in memory until
/// `persist()`, so callers can save on every keystroke and write less often.
public final class DraftStore {
    public static let limit = 200
    public private(set) var drafts: [Draft] = []
    private let url: URL?
    private var dirty = false

    /// Pass nil for a store that is never written to disk.
    public init(url: URL?) {
        self.url = url
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let saved = try? decoder.decode([Draft].self, from: data) {
            var seen = Set<UUID>()
            drafts = saved.filter { Draft.hasText($0.posts) && seen.insert($0.id).inserted }
                .sorted { $0.updated > $1.updated }
        }
    }

    public static func defaultURL(for account: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Minimal Bird/Drafts/\(account.uuidString).json")
    }

    public func draft(_ id: UUID) -> Draft? { drafts.first { $0.id == id } }

    /// Saves `posts` under `id`, or as a new draft when `id` is nil or unknown.
    /// Text-free posts remove the draft instead. Returns the draft's id.
    @discardableResult
    public func save(_ posts: [String], id: UUID?, now: Date = Date()) -> UUID? {
        guard Draft.hasText(posts) else {
            if let id { remove(id) }
            return nil
        }
        if let id, let index = drafts.firstIndex(where: { $0.id == id }) {
            guard drafts[index].posts != posts else { return id }
            var draft = drafts.remove(at: index)
            draft.posts = posts
            draft.updated = now
            drafts.insert(draft, at: 0)
            dirty = true
            return id
        }
        let draft = Draft(id: id ?? UUID(), posts: posts, updated: now)
        drafts.insert(draft, at: 0)
        if drafts.count > Self.limit { drafts.removeLast(drafts.count - Self.limit) }
        dirty = true
        return draft.id
    }

    public func remove(_ id: UUID) {
        let count = drafts.count
        drafts.removeAll { $0.id == id }
        if drafts.count != count { dirty = true }
    }

    /// Writes pending changes atomically, readable only by this user.
    public func persist() {
        guard dirty, let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(drafts) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            dirty = false
        } catch {
            // Keep the changes in memory; the next persist() tries again.
        }
    }
}
