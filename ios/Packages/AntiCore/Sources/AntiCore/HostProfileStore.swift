import Foundation

/// Persists non-secret host profile metadata while delegating bearer tokens exclusively to `TokenStore`.
public struct HostProfileRepository: Sendable {
    private static let profilesKey = "antiremote.hosts.v1"
    private static let selectedIDKey = "antiremote.selectedHostID.v1"

    private let suiteName: String?
    public let tokenStore: any TokenStore

    public init(suiteName: String? = nil, tokenStore: any TokenStore) {
        self.suiteName = suiteName
        self.tokenStore = tokenStore
    }

    private func defaults() -> UserDefaults {
        if let suiteName, let custom = UserDefaults(suiteName: suiteName) {
            return custom
        }
        return .standard
    }

    public func loadProfiles() -> [HostProfile] {
        guard let data = defaults().data(forKey: Self.profilesKey),
              let decoded = try? BridgeJSON.decoder.decode([HostProfile].self, from: data),
              !decoded.isEmpty
        else {
            return [.demo]
        }
        return decoded
    }

    public func saveProfiles(_ profiles: [HostProfile]) {
        let nonEmpty = profiles.isEmpty ? [HostProfile.demo] : profiles
        if let data = try? BridgeJSON.encoder.encode(nonEmpty) {
            defaults().set(data, forKey: Self.profilesKey)
        }
    }

    public func loadSelectedHostID(fallback: UUID) -> UUID {
        guard let raw = defaults().string(forKey: Self.selectedIDKey),
              let uuid = UUID(uuidString: raw)
        else {
            return fallback
        }
        return uuid
    }

    public func saveSelectedHostID(_ id: UUID) {
        defaults().set(id.uuidString, forKey: Self.selectedIDKey)
    }

    public func upsert(profile: HostProfile, token: String?) throws -> [HostProfile] {
        var list = loadProfiles()
        if let idx = list.firstIndex(where: { $0.id == profile.id }) {
            list[idx] = profile
        } else {
            list.insert(profile, at: 0)
        }
        if let token, !token.isEmpty {
            try tokenStore.save(token: token, for: profile.id)
        }
        saveProfiles(list)
        return list
    }

    public func remove(hostID: UUID) throws -> [HostProfile] {
        var list = loadProfiles()
        list.removeAll { $0.id == hostID && !$0.isDemo }
        try tokenStore.deleteToken(for: hostID)
        if list.isEmpty {
            list = [.demo]
        }
        saveProfiles(list)
        return list
    }

    public func token(for hostID: UUID) -> String? {
        try? tokenStore.token(for: hostID)
    }
}
