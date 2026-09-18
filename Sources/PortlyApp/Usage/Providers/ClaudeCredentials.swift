import Foundation

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
    /// into the status the UI should show.
    ///
    /// The secret is read by `/usr/bin/security`, not by this process, and that
    /// is the whole fix for a prompt that kept coming back. A keychain item
    /// only hands its data to the applications on its access list. Claude Code
    /// reads and writes this item through the `security` tool, so `security` is
    /// the application on that list; Portly is not, and "Always Allow" could
    /// never stick, because Claude Code files a fresh item (with a fresh list)
    /// every time it rotates the token, about once an hour. Asking through the
    /// same tool the owner uses is answered silently, every time, by design.
    static func read(service: String) throws -> ClaudeCredentials {
        // Attributes only: never prompts. Picks the newest of the duplicates
        // Claude Code leaves behind, and says which account to ask for.
        guard let winner = KeychainItem.newest(service: service) else {
            UsageLog.usage.error("keychain read failed: no item under \(service, privacy: .public)")
            throw UsageProviderError.needsAuth
        }

        let result = SecurityTool.findGenericPassword(service: service, account: winner.account)
        guard result.status == 0, let data = result.secret else {
            UsageLog.usage.error("security could not read \(service, privacy: .public): exit \(result.status)")
            throw SecurityTool.error(forExitStatus: result.status)
        }
        return try decode(data)
    }

    /// The stored JSON, as Claude Code writes it. `security -w` prints a secret
    /// it considers unprintable as hex, so that form is accepted too.
    static func decode(_ data: Data) throws -> ClaudeCredentials {
        struct Payload: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                /// Milliseconds since the epoch.
                let expiresAt: Double
                let subscriptionType: String?
            }
            let claudeAiOauth: OAuth
        }

        let decoder = JSONDecoder()
        let payload = (try? decoder.decode(Payload.self, from: data))
            ?? SecurityTool.dataFromHex(data).flatMap { try? decoder.decode(Payload.self, from: $0) }
        guard let payload else { throw UsageProviderError.needsAuth }

        return ClaudeCredentials(
            accessToken: payload.claudeAiOauth.accessToken,
            expiresAt: Date(timeIntervalSince1970: payload.claudeAiOauth.expiresAt / 1000),
            subscriptionType: payload.claudeAiOauth.subscriptionType
        )
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

    /// Whatever is already held, without going anywhere for it. For callers on
    /// the main thread, which must never wait on another process.
    func held() -> ClaudeCredentials? { cache.held }

    /// Forget the held copy: the server rejected it, or the user asked for a
    /// fresh read.
    func forgetCached() { cache.forget() }
}
