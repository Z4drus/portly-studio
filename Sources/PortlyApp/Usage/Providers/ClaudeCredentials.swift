import Foundation
import Security

/// The OAuth token Claude Code keeps in the login keychain.
///
/// Portly only ever *reads* this item. Refreshing is deliberately left to
/// Claude Code: minting a new token would mean writing a credential this app
/// does not own, so when the token expires the ring says so and waits for
/// Claude Code to refresh it in the ordinary course of being used.
struct ClaudeCredentials {
    let accessToken: String
    let expiresAt: Date
    /// "pro", "max", and so on — enough to show which plan the readings are for.
    let subscriptionType: String?

    var isExpired: Bool { expiresAt <= Date() }

    /// The keychain read itself, for one service name. Every failure is turned
    /// into the status the UI should show, and the raw OSStatus is logged so
    /// "not found" and "refused" stay distinct.
    static func read(service: String) throws -> ClaudeCredentials {
        guard let winner = KeychainItem.newest(service: service) else {
            UsageLog.usage.error("keychain read failed: no item under \(service, privacy: .public)")
            throw UsageProviderError.needsAuth
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecValuePersistentRef: winner.persistentRef,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data else {
            UsageLog.usage.error("keychain read of \(service, privacy: .public) failed: OSStatus \(status) (\(Self.explain(status), privacy: .public))")
            // A machine just woken from sleep answers -25320: awake enough to
            // run background work, not to show a dialogue. The credential is
            // unaffected, so the last reading merely ages.
            if Self.wasTransient(status) { throw UsageProviderError.credentialExpired }
            throw Self.wasRefused(status)
                ? UsageProviderError.accessDenied
                : UsageProviderError.needsAuth
        }

        struct Payload: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                /// Milliseconds since the epoch.
                let expiresAt: Double
                let subscriptionType: String?
            }
            let claudeAiOauth: OAuth
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw UsageProviderError.needsAuth
        }

        return ClaudeCredentials(
            accessToken: payload.claudeAiOauth.accessToken,
            expiresAt: Date(timeIntervalSince1970: payload.claudeAiOauth.expiresAt / 1000),
            subscriptionType: payload.claudeAiOauth.subscriptionType
        )
    }

    /// Whether macOS refused a credential that exists, rather than failing to
    /// find one. `errSecAuthFailed` and `userCanceled` are what Deny produces;
    /// `interactionNotAllowed` is the same refusal arriving without a prompt.
    static func wasRefused(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed
            || status == errSecUserCanceled
            || status == errSecInteractionNotAllowed
    }

    /// -25320, "in dark wake, no UI possible": a read that failed for a reason
    /// with nothing to do with the account.
    static func wasTransient(_ status: OSStatus) -> Bool {
        status == -25320
    }

    static func explain(_ status: OSStatus) -> String {
        switch status {
        case errSecItemNotFound: return "no such item — Claude Code has not signed in"
        case errSecInteractionNotAllowed: return "access not permitted without interaction"
        case errSecUserCanceled: return "the access prompt was dismissed or denied"
        case errSecAuthFailed: return "authorisation failed"
        default:
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown"
        }
    }
}

/// One profile's token, read as rarely as the keychain allows.
///
/// One of these per `ClaudeProfile`, because each profile's token is a
/// separate keychain item with its own access list.
final class ClaudeKeychain: @unchecked Sendable {
    let service: String

    /// Read once, then held until the item changes. Claude Code rotates this
    /// roughly hourly, so this is about one keychain read an hour.
    private let cache = CredentialCache<ClaudeCredentials> { $0.isExpired }

    init(service: String) {
        self.service = service
    }

    convenience init(profile: ClaudeProfile) {
        self.init(service: profile.keychainService)
    }

    /// Reads whatever is stored, expired or not. Judging expiry is the
    /// caller's job: "signed out" and "aged out overnight" differ.
    func load() throws -> ClaudeCredentials {
        try cache.value(
            itemModifiedAt: { KeychainItem.modifiedAt(service: service) },
            reload: { try ClaudeCredentials.read(service: service) }
        )
    }

    /// Forget the held copy: the server rejected it, or the user asked to be
    /// prompted again.
    func forgetCached() { cache.forget() }
}
