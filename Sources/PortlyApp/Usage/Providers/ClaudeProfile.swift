import CryptoKit
import Foundation

/// One Claude Code configuration directory, and so one account.
///
/// Claude Code keeps everything for an account under `~/.claude`, or wherever
/// `CLAUDE_CONFIG_DIR` points. People who keep a personal and a work login
/// apart alias the second one to `~/.claude-work`, each with its own token in
/// the keychain and its own `sessions` folder. A profile is that *convention*,
/// not the environment variable: the directories are the only trace left.
struct ClaudeProfile: Equatable, Hashable {
    static let defaultID = "claude"
    static let directoryPrefix = ".claude"

    /// Nil for `~/.claude`; the part after `.claude-` otherwise.
    let slug: String?
    let configDirectory: URL

    /// `~/.claude`, whether or not it exists.
    static func `default`(home: URL = homeDirectory) -> ClaudeProfile {
        ClaudeProfile(slug: nil,
                      configDirectory: home.appendingPathComponent(directoryPrefix))
    }

    static var homeDirectory: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    /// The default profile followed by every `~/.claude-<slug>` that Claude
    /// Code has actually used, slugs in alphabetical order so the rings never
    /// swap places between launches.
    static func discover(home: URL = homeDirectory,
                         fileManager: FileManager = .default) -> [ClaudeProfile] {
        let names = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []
        let extras = names.compactMap { name -> ClaudeProfile? in
            guard let slug = slug(fromDirectoryName: name) else { return nil }
            let directory = home.appendingPathComponent(name)
            guard isProfileDirectory(directory, fileManager: fileManager) else { return nil }
            return ClaudeProfile(slug: slug, configDirectory: directory)
        }
        return [ClaudeProfile.default(home: home)]
            + extras.sorted { $0.slug! < $1.slug! }
    }

    /// `.claude-work` → `work`; anything else → nil.
    static func slug(fromDirectoryName name: String) -> String? {
        let prefix = directoryPrefix + "-"
        guard name.hasPrefix(prefix) else { return nil }
        let slug = String(name.dropFirst(prefix.count))
        return slug.isEmpty ? nil : slug
    }

    /// Any of the files Claude Code creates the first time it runs against a
    /// directory. An empty directory someone made by hand is not a profile.
    private static let markers = ["sessions", "projects", "settings.json",
                                  "history.jsonl", ".claude.json"]

    static func isProfileDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return markers.contains {
            fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    // MARK: - Identity

    /// `claude` for the default, `claude-<slug>` for the rest. Doubles as the
    /// usage provider id and the session monitor key.
    var id: String { slug.map { "\(Self.defaultID)-\($0)" } ?? Self.defaultID }

    /// `Claude`, or `Claude (work)`.
    var displayName: String { slug.map { "Claude (\($0))" } ?? "Claude" }

    static func isClaude(providerID: String) -> Bool {
        providerID == defaultID || providerID.hasPrefix(defaultID + "-")
    }

    static func slug(fromProviderID id: String) -> String? {
        guard id.hasPrefix(defaultID + "-") else { return nil }
        let slug = String(id.dropFirst(defaultID.count + 1))
        return slug.isEmpty ? nil : slug
    }

    /// The directory as a person would type it.
    var displayPath: String {
        NSString(string: configDirectory.path).abbreviatingWithTildeInPath
    }

    // MARK: - What Claude Code keeps where

    /// Where Claude Code writes one file per running process.
    var sessionsDirectory: URL { configDirectory.appendingPathComponent("sessions") }

    /// The keychain service the OAuth token is filed under.
    ///
    /// The default directory uses the bare name. Any other `CLAUDE_CONFIG_DIR`
    /// gets a suffix: the first eight hex digits of the SHA-256 of the
    /// directory's absolute path. That is Claude Code's rule, not ours.
    var keychainService: String {
        guard slug != nil else { return Self.defaultKeychainService }
        return "\(Self.defaultKeychainService)-\(Self.keychainSuffix(forPath: configDirectory.path))"
    }

    static let defaultKeychainService = "Claude Code-credentials"

    static func keychainSuffix(forPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    // MARK: - Copy

    /// Which tool the credential is borrowed from, said so that two Claude
    /// rows in Settings can be told apart.
    var sourceName: String {
        slug == nil ? "Claude Code" : "Claude Code in \(displayPath)"
    }

    /// The command that signs this profile in.
    var signInCommand: String {
        slug == nil ? "claude" : "CLAUDE_CONFIG_DIR=\(displayPath) claude"
    }
}
