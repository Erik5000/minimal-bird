// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Minimal Bird contributors

import Foundation

/// Metadata only. WebKit owns each account's cookies and credentials.
public struct AccountProfile: Codable, Equatable, Identifiable {
    public let id: UUID
    public var label: String
    public let usesDefaultStore: Bool
}

public final class AccountProfiles {
    private let defaults: UserDefaults
    private let key = "AccountProfiles.v1"
    public private(set) var profiles: [AccountProfile]
    public private(set) var selectedID: UUID

    private struct Saved: Codable {
        var profiles: [AccountProfile]
        var selectedID: UUID
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Saved.self, from: data),
           !saved.profiles.isEmpty, Set(saved.profiles.map(\.id)).count == saved.profiles.count,
           saved.profiles.filter(\.usesDefaultStore).count == 1 {
            profiles = saved.profiles
            selectedID = saved.profiles.contains(where: { $0.id == saved.selectedID }) ? saved.selectedID : saved.profiles[0].id
        } else {
            let original = AccountProfile(id: UUID(), label: "Your account", usesDefaultStore: true)
            profiles = [original]
            selectedID = original.id
        }
        save()
    }

    @discardableResult public func add() -> AccountProfile {
        let profile = AccountProfile(id: UUID(), label: "Account \(profiles.count + 1)", usesDefaultStore: false)
        profiles.append(profile)
        selectedID = profile.id
        save()
        return profile
    }

    public func select(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedID = id
        save()
    }

    public func updateLabel(_ label: String, for id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }), !label.isEmpty,
              profiles[index].label != label else { return }
        profiles[index].label = label
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Saved(profiles: profiles, selectedID: selectedID)) {
            defaults.set(data, forKey: key)
        }
    }
}
