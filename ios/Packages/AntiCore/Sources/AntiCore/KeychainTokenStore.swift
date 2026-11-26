import Foundation
#if canImport(Security)
import Security
#endif

public protocol TokenStore: Sendable {
    func token(for hostID: UUID) throws -> String?
    func save(token: String, for hostID: UUID) throws
    func deleteToken(for hostID: UUID) throws
}

public enum TokenStoreError: Error, LocalizedError, Sendable {
    case encodingFailed
    case keychainFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not encode authentication token."
        case .keychainFailure(let status):
            return "Keychain operation failed (OSStatus \(status))."
        }
    }
}

#if canImport(Security)
/// Stores host bearer tokens exclusively in iOS Keychain (`AfterFirstUnlockThisDeviceOnly`).
public struct KeychainTokenStore: TokenStore {
    private let service: String

    public init(service: String = "com.antiremote.bridge.tokens") {
        self.service = service
    }

    public func token(for hostID: UUID) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: hostID.uuidString,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw TokenStoreError.keychainFailure(status)
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    public func save(token: String, for hostID: UUID) throws {
        guard let data = token.data(using: .utf8) else {
            throw TokenStoreError.encodingFailed
        }
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: hostID.uuidString,
        ]

        let attributesToUpdate: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw TokenStoreError.keychainFailure(addStatus)
            }
            return
        }
        throw TokenStoreError.keychainFailure(updateStatus)
    }

    public func deleteToken(for hostID: UUID) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: hostID.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychainFailure(status)
        }
    }
}
#endif

/// Thread-safe in-memory token store for Swift Testing and Xcode Previews.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    public init(initial: [UUID: String] = [:]) {
        self.storage = initial
    }

    public func token(for hostID: UUID) throws -> String? {
        lock.withLock { storage[hostID] }
    }

    public func save(token: String, for hostID: UUID) throws {
        lock.withLock { storage[hostID] = token }
    }

    public func deleteToken(for hostID: UUID) throws {
        lock.withLock { _ = storage.removeValue(forKey: hostID) }
    }
}
