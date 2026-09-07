import Foundation
import Security

/// Asking about a keychain item without asking for what is inside it.
///
/// The access control on another app's item guards its **data**, not its
/// attributes: `kSecReturnAttributes` is answered from the item's metadata and
/// never raises the "wants to access your confidential information" dialogue,
/// where `kSecReturnData` always may. So this can be asked often, and the
/// expensive read only has to happen when the item has actually changed.
///
/// It is also what makes duplicates safe to resolve without a prompt. Claude
/// Code files a new keychain item on every token rotation rather than updating
/// one in place, so a long-used login accumulates several under the same
/// service name, and `kSecMatchLimitOne` gives no ordering guarantee across
/// them. Enumerating attributes finds the newest by comparison, not luck.
enum KeychainItem {
    /// One matching item, without its secret.
    struct Match {
        let modifiedAt: Date?
        /// Opaque to everything but `SecItemCopyMatching`. Reading the item
        /// this points at is the one call that can prompt.
        let persistentRef: Data
    }

    /// The most recently modified item under a service, or nil if there is
    /// none or macOS declined to say.
    static func newest(service: String, account: String? = nil) -> Match? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecReturnPersistentRef: true,
            kSecMatchLimit: kSecMatchLimitAll
        ]
        if let account { query[kSecAttrAccount] = account }

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        else { return nil }

        // A single match still comes back as one dictionary rather than an
        // array of one.
        let items = (result as? [[CFString: Any]]) ?? (result as? [CFString: Any]).map { [$0] } ?? []
        return winner(among: items)
    }

    /// The selection itself, apart from the query that produces its input, so
    /// it can be tested without a keychain.
    static func winner(among items: [[CFString: Any]]) -> Match? {
        items
            .compactMap { item -> Match? in
                guard let ref = item[kSecValuePersistentRef] as? Data else { return nil }
                return Match(modifiedAt: item[kSecAttrModificationDate] as? Date, persistentRef: ref)
            }
            .max { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }

    /// When the owning app last wrote the newest item under this service.
    static func modifiedAt(service: String, account: String? = nil) -> Date? {
        newest(service: service, account: account)?.modifiedAt
    }
}
