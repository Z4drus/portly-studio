import Foundation

/// Holds a borrowed credential so the keychain is read as rarely as possible.
///
/// Every read of the *data* is a chance for macOS to interrupt someone. The
/// question the cache asks is not "is the held token still valid" but "has the
/// item **changed**", which `KeychainItem.modifiedAt` answers without touching
/// the data and without prompting. Re-reading an unchanged item cannot produce
/// a different answer; it can only produce another dialogue.
final class CredentialCache<Credential>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Credential?
    /// The item's modification date the last time we *asked* about it, on a
    /// refusal as much as on a success, so a refused read is never retried on
    /// every tick.
    private var attemptedStamp: Date?
    private var attemptedAt: Date?
    private var lastError: Error?

    private let isExpired: (Credential) -> Bool
    /// How long to sit with what we have when the probe cannot tell us
    /// whether the item moved.
    private let recheckAfter: TimeInterval
    /// How long to leave macOS alone after it has said no.
    private let retryAfterFailure: TimeInterval
    private let now: () -> Date

    init(recheckAfter: TimeInterval = 5 * 60,
         retryAfterFailure: TimeInterval = 5 * 60,
         now: @escaping () -> Date = Date.init,
         isExpired: @escaping (Credential) -> Bool) {
        self.recheckAfter = recheckAfter
        self.retryAfterFailure = retryAfterFailure
        self.now = now
        self.isExpired = isExpired
    }

    /// The held credential, or a fresh one when the item behind it has moved.
    /// `reload` runs outside the lock: it can block on a keychain prompt.
    func value(itemModifiedAt: () -> Date? = { nil },
               reload: () throws -> Credential) throws -> Credential {
        lock.lock()
        let held = stored
        let askedStamp = attemptedStamp
        let askedAt = attemptedAt
        let failure = lastError
        lock.unlock()

        if let held, !isExpired(held) { return held }

        let current = itemModifiedAt()

        let alreadyAsked: Bool
        if let current, let askedStamp {
            alreadyAsked = current == askedStamp
        } else if let askedAt {
            let wait = failure == nil ? recheckAfter : retryAfterFailure
            alreadyAsked = now().timeIntervalSince(askedAt) < wait
        } else {
            alreadyAsked = false
        }

        if alreadyAsked {
            if let held { return held }
            if let failure { throw failure }
        }

        do {
            let fresh = try reload()
            lock.lock()
            stored = fresh
            attemptedStamp = current
            attemptedAt = now()
            lastError = nil
            lock.unlock()
            return fresh
        } catch {
            lock.lock()
            attemptedStamp = current
            attemptedAt = now()
            lastError = error
            lock.unlock()
            throw error
        }
    }

    /// Drop what is held, so the next read goes to the keychain for real.
    func forget() {
        lock.lock()
        stored = nil
        attemptedStamp = nil
        attemptedAt = nil
        lastError = nil
        lock.unlock()
    }
}
