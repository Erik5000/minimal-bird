// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Minimal Bird contributors

import XCTest
@testable import FocusCore

final class AccountProfilesTests: XCTestCase {
    func testSeparateAccountsPersistAndKeepOriginalSession() throws {
        let suite = "MinimalBirdTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountProfiles(defaults: defaults)
        let original = try XCTUnwrap(accounts.profiles.first)
        XCTAssertTrue(original.usesDefaultStore)
        let second = accounts.add()
        XCTAssertFalse(second.usesDefaultStore)
        XCTAssertNotEqual(original.id, second.id)
        accounts.updateLabel("@writer_two", for: second.id)
        accounts.select(original.id)
        accounts.select(UUID()) // Unknown IDs must not replace a valid selection.
        let restored = AccountProfiles(defaults: defaults)
        XCTAssertEqual(restored.profiles, accounts.profiles)
        XCTAssertEqual(restored.selectedID, original.id)
        XCTAssertEqual(restored.profiles[1].label, "@writer_two")
        XCTAssertEqual(restored.profiles.filter(\.usesDefaultStore).count, 1)
    }

    func testDamagedMetadataFallsBackToOriginalSession() throws {
        let suite = "MinimalBirdTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid".utf8), forKey: "AccountProfiles.v1")
        let accounts = AccountProfiles(defaults: defaults)
        XCTAssertEqual(accounts.profiles.count, 1)
        XCTAssertTrue(accounts.profiles[0].usesDefaultStore)
        XCTAssertEqual(accounts.selectedID, accounts.profiles[0].id)
    }
}
