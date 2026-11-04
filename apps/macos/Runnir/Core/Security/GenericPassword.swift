import Foundation
import Security

/// Generic-password Keychain items by service and account: the add-or-update,
/// read and delete steps the credential and local-run value stores share.
///
/// A build signed with its provisioning profile has an application
/// identifier and keeps its items in the data protection keychain, where
/// the app's identifier and team decide access and macOS never asks for the
/// password item by item (B48). A build without one (ad hoc, CI, a Mac
/// without the profile) uses the file-based keychain, which lists the
/// programs allowed on each item.
enum GenericPassword {
    /// The build's signature carries an application identifier, which only
    /// a provisioning profile authorizes.
    static let usesDataProtectionKeychain: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) != nil
    }()

    static func read(service: String, account: String) throws -> Data? {
        var query = base(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
        guard let data = item as? Data else { throw KeychainError.invalidData }
        return data
    }

    /// The accounts of a service, without reading any value.
    static func accounts(service: String) throws -> [String] {
        var query = base(service: service, account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
        return (items as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Adds the item, or replaces the data of the one already there.
    static func write(_ data: Data, service: String, account: String, label: String? = nil) throws {
        var query = base(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let label { query[kSecAttrLabel as String] = label }
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(base(service: service, account: account) as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError.unhandledStatus(update) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
    }

    /// Deletes one item, or every item of the service when `account` is nil.
    /// The file-based keychain deletes one matching item per call, so a
    /// whole service is deleted call by call until nothing matches; the data
    /// protection keychain deletes them all in the first.
    static func delete(service: String, account: String?,
                       deleteItem: (CFDictionary) -> OSStatus = SecItemDelete) throws {
        let query = base(service: service, account: account) as CFDictionary
        for _ in 0..<(account == nil ? maxItemsPerService : 1) {
            let status = deleteItem(query)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
        }
    }

    /// More items than a service of Runnir's ever holds; bounds the deletes.
    static let maxItemsPerService = 10_000

    static func base(service: String, account: String?, dataProtection: Bool = usesDataProtectionKeychain) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
}
