import Foundation
import Security

/// Where the Talvo link is remembered on this Mac: the server address in the
/// defaults, the device token in the keychain. Nothing of it is in the
/// repository or in `config.json`, so a public build ships with no link at all.
enum TalvoCredentials {
    static let serverKey = "talvoServerURL"
    private static let service = "dev.portly.talvo"
    private static let account = "device-token"

    static var serverURL: URL? {
        get {
            UserDefaults.standard.string(forKey: serverKey).flatMap(TalvoClient.normalizedBaseURL)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.absoluteString, forKey: serverKey)
            } else {
                UserDefaults.standard.removeObject(forKey: serverKey)
            }
        }
    }

    /// The device token, or nil when none was saved. Portly's own item, so
    /// reading it never prompts.
    static func readToken() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let update: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData] = data
        item[kSecAttrLabel] = "Portly Studio · Talvo"
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func deleteToken() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
