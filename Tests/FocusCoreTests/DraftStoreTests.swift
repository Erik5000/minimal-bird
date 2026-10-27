// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Minimal Bird contributors

import XCTest
@testable import FocusCore

final class DraftStoreTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MinimalBirdDrafts-" + UUID().uuidString)
            .appendingPathComponent("drafts.json")
    }

    func testSavingUpdatesOneDraftAndKeepsNewestFirst() throws {
        let store = DraftStore(url: nil)
        let first = try XCTUnwrap(store.save(["First thought"], id: nil, now: Date(timeIntervalSince1970: 10)))
        let second = try XCTUnwrap(store.save(["Second", "thread"], id: nil, now: Date(timeIntervalSince1970: 20)))
        XCTAssertEqual(store.drafts.map(\.id), [second, first])
        XCTAssertEqual(store.save(["First thought, revised"], id: first, now: Date(timeIntervalSince1970: 30)), first)
        XCTAssertEqual(store.drafts.map(\.id), [first, second])
        XCTAssertEqual(store.draft(first)?.posts, ["First thought, revised"])
        XCTAssertEqual(store.drafts.count, 2)
    }

    func testDraftsStayInDateOrder() throws {
        let store = DraftStore(url: nil)
        let older = try XCTUnwrap(store.save(["Older"], id: nil, now: Date(timeIntervalSince1970: 100)))
        let oldest = try XCTUnwrap(store.save(["Oldest"], id: nil, now: Date(timeIntervalSince1970: 50)))
        let newest = try XCTUnwrap(store.save(["Newest"], id: nil, now: Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(store.drafts.map(\.id), [newest, older, oldest])
    }

    func testClearingTextRemovesTheDraft() throws {
        let store = DraftStore(url: nil)
        let id = try XCTUnwrap(store.save(["Soon gone"], id: nil))
        XCTAssertNil(store.save(["", "  \n"], id: id))
        XCTAssertTrue(store.drafts.isEmpty)
        XCTAssertNil(store.save(["   "], id: nil))
        XCTAssertTrue(store.drafts.isEmpty)
    }

    func testPreviewUsesFirstLineWithText() {
        let draft = Draft(id: UUID(), posts: ["\n  \n  Hello there\nsecond line", "next"], updated: Date())
        XCTAssertEqual(draft.preview, "Hello there")
    }

    func testDraftsPersistPrivatelyAndReload() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DraftStore(url: url)
        let id = try XCTUnwrap(store.save(["Line one\nLine two", "Second post"], id: nil))
        try store.persist().get()
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        let reopened = DraftStore(url: url)
        XCTAssertEqual(reopened.drafts.map(\.id), [id])
        XCTAssertEqual(reopened.draft(id)?.posts, ["Line one\nLine two", "Second post"])
    }

    func testDamagedFileStartsEmpty() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(DraftStore(url: url).drafts.isEmpty)
    }

    func testFailedSaveReportsErrorAndCanBeRetried() throws {
        let url = temporaryURL()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A file where the parent directory should be forces a real write error.
        try Data().write(to: directory)
        let store = DraftStore(url: url)
        let id = try XCTUnwrap(store.save(["Keep this text"], id: nil))
        XCTAssertThrowsError(try store.persist().get())
        XCTAssertEqual(store.draft(id)?.posts, ["Keep this text"])
        try FileManager.default.removeItem(at: directory)
        try store.persist().get()
        XCTAssertEqual(DraftStore(url: url).draft(id)?.posts, ["Keep this text"])
    }

    func testPartialRestoreDoesNotEvictOriginalAtLimit() throws {
        let store = DraftStore(url: nil)
        let original = try XCTUnwrap(store.save(["First", "Second"], id: nil, now: .distantPast))
        for index in 1..<DraftStore.limit { store.save(["Other \(index)"], id: nil) }
        let partial = try XCTUnwrap(store.save(["First edited"], id: nil, preserving: original))
        XCTAssertEqual(store.drafts.count, DraftStore.limit)
        XCTAssertEqual(store.draft(original)?.posts, ["First", "Second"])
        XCTAssertEqual(store.draft(partial)?.posts, ["First edited"])
    }

    func testOldestDraftsAreDroppedAtTheLimit() {
        let store = DraftStore(url: nil)
        for index in 0...DraftStore.limit {
            store.save(["Draft \(index)"], id: nil, now: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(store.drafts.count, DraftStore.limit)
        XCTAssertEqual(store.drafts.first?.posts, ["Draft \(DraftStore.limit)"])
        XCTAssertFalse(store.drafts.contains { $0.posts == ["Draft 0"] })
    }
}
