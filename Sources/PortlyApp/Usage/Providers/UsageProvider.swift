import Foundation

// Adapted from Codenotch (https://github.com/vinzdg/codenotch), MIT License,
// Copyright (c) 2026 Vinz.

/// One source of usage numbers. Each adapter declares how trustworthy it is,
/// and the UI never dresses a derived number up as an official one.
///
/// Portly never signs in anywhere: every reading is borrowed from a credential
/// a tool on this Mac already holds.
protocol UsageProvider {
    var id: String { get }
    /// Enough to draw the cell even when a fetch has never succeeded.
    var displayName: String { get }
    var glyph: ProviderGlyph { get }
    func fetchSnapshot() async throws -> ProviderSnapshot
    /// Whose readings these are. Declared here rather than only in an
    /// extension so the call dispatches to the implementation.
    func account() -> ProviderAccount?
    /// Where the user goes to sign in, when there is no account to read.
    var signInRoute: SignInRoute { get }
    /// The vendor's own usage page. Static on purpose: reading it must never
    /// touch a credential, since the sidebar asks for it on every row.
    var usageURL: URL? { get }
    /// Drop any credential held in memory, so the next read goes to the
    /// keychain for real — the remedy for a declined keychain prompt.
    func forgetCachedCredential()
}

extension UsageProvider {
    func account() -> ProviderAccount? { nil }

    var signInRoute: SignInRoute {
        .guidance("Sign in with the tool that owns this account.")
    }

    func forgetCachedCredential() {}
}

enum UsageProviderError: Error {
    /// No usable credential — the user has to sign in again.
    case needsAuth
    /// The credential is there, and macOS refused to hand it over.
    case accessDenied
    /// The credential is there but has expired, and the app that owns it will
    /// refresh it the next time it runs. The last reading is still true.
    case credentialExpired
    /// The endpoint answered, but not with anything we understand.
    case badResponse(status: Int)
    /// Asked to slow down. Carries the server's own retry hint when it gave one.
    case rateLimited(retryAfter: TimeInterval)
    /// The account is readable, but there is genuinely no quota being counted.
    case nothingMetered(String)
}

/// Whose readings these are. Worth showing plainly, because a borrowed
/// credential can belong to a different account than the one you expect.
struct ProviderAccount: Equatable {
    /// Email or display name, where the credential carries one.
    let label: String?
    /// The plan, named the way the provider names it.
    let plan: String?
    /// Which app's credential this borrows.
    let source: String
    /// The provider's own usage page, for checking this against the source.
    let manageURL: URL?

    /// One line for the settings row.
    var summary: String {
        [label, plan.map { $0.capitalized }, "via \(source)"]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// Where to go when a provider has no usable credential.
enum SignInRoute: Equatable {
    /// Launch the app that owns the credential.
    case openApp(bundleID: String, name: String)
    /// Nothing to launch; Claude Code is a command, not an application.
    case guidance(String)

    var explanation: String {
        switch self {
        case .openApp(_, let name): return "Sign in with \(name) to read this account."
        case .guidance(let text): return text
        }
    }

    /// How to change which account is being read: always in the tool that
    /// owns the credential.
    var switchHint: String {
        switch self {
        case .openApp(_, let name): return "Switch accounts in \(name); Portly follows."
        case .guidance: return "Switch accounts in the tool that owns it; Portly follows."
        }
    }
}

/// A provider as the settings screen needs it.
struct ProviderSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let glyph: ProviderGlyph
    let account: ProviderAccount?
    let signIn: SignInRoute
    /// Whether macOS refused this credential on the last fetch — the one
    /// state "Allow access…" can actually repair.
    var wasRefusedAccess: Bool = false

    /// Only a keychain-backed credential can be refused by macOS; Cursor,
    /// Codex and Grok read ordinary files and never prompt.
    var usesKeychain: Bool { ClaudeProfile.isClaude(providerID: id) }
}
