import Foundation

// Adapted from Codenotch (https://github.com/vinzdg/codenotch), MIT License,
// Copyright (c) 2026 Vinz.

/// How much to trust a provider's numbers. The UI never presents a derived or
/// manual figure as if a vendor had published it.
enum Fidelity: String, Codable, Equatable {
    case official
    case derived
    case manual

    /// Prefix shown in front of a percentage that we worked out ourselves.
    var qualifier: String { self == .official ? "" : "~" }
}

enum ProviderStatus: Equatable {
    case ok
    case stale(since: Date)
    case needsAuth
    /// macOS was asked for a credential that exists, and refused.
    case accessDenied
    case unsupported(String)
    case error(String)

    var isStale: Bool { if case .stale = self { return true }; return false }

    /// When the reading behind this status was actually taken.
    var staleSince: Date? { if case .stale(let since) = self { return since }; return nil }
}

/// One metered window a provider exposes — Claude has several (the rolling
/// session, the weekly all-models window, and per-model weekly windows such
/// as Fable), others have one.
struct LimitWindow: Identifiable, Codable, Equatable {
    let id: String
    let label: String
    /// 0...1+, where 1 means the limit is spent. Nil when the provider reports
    /// what is left but never says what the limit was.
    let usedFraction: Double?
    /// How many are left, when that is what the provider reports.
    let remaining: Int?
    /// How many have been spent, when the provider counts up rather than down
    /// and never states the ceiling.
    let used: Int?
    /// Nil when the provider does not say when the window rolls over.
    let resetsAt: Date?

    init(id: String, label: String, usedFraction: Double? = nil,
         remaining: Int? = nil, used: Int? = nil, resetsAt: Date? = nil) {
        self.id = id
        self.label = label
        self.usedFraction = usedFraction
        self.remaining = remaining
        self.used = used
        self.resetsAt = resetsAt
    }

    /// What the tooltip says on the line under the bar. Both ends of the same
    /// figure, because vendors do not agree on which to show.
    var summary: String {
        if let usedFraction {
            let used = Int((usedFraction * 100).rounded())
            return "\(used)% Used · \(max(0, 100 - used))% left"
        }
        if let remaining {
            return remaining == 1 ? "1 left" : "\(remaining) left"
        }
        if let used {
            return used == 1 ? "1 used" : "\(used) used"
        }
        return "No reading"
    }
}

struct ProviderSnapshot: Identifiable, Equatable {
    let id: String
    let displayName: String
    let glyph: ProviderGlyph
    let fidelity: Fidelity
    var status: ProviderStatus
    let windows: [LimitWindow]
    /// Which window the ring means, declared by the provider rather than left
    /// to position. Without it a window dropping out of the response would
    /// silently promote another one.
    var headlineID: String?

    /// The number on the cell: the provider's declared primary window — for
    /// Claude, the current session, the same window Claude Code's own `/usage`
    /// leads with. A missing declared window shows no reading rather than
    /// promoting a different one.
    var headline: LimitWindow? {
        guard let headlineID else { return windows.first }
        return windows.first { $0.id == headlineID }
    }

    var usedFraction: Double? { headline?.usedFraction }

    /// What the cell prints under the ring.
    var headlineText: String {
        if let usedFraction { return "\(Int((usedFraction * 100).rounded()))%" }
        if let remaining = headline?.remaining { return "\(remaining)" }
        if let used = headline?.used { return "\(used)" }
        return "—"
    }

    /// True when there is no reading to show — the cell draws an empty ring
    /// and a dash rather than an authoritative-looking 0%.
    var hasReading: Bool { !windows.isEmpty }

    /// The window closest to running out, for a compact readout that has room
    /// for one number and wants the one that will stop you first.
    var mostConstrained: LimitWindow? {
        windows.max { ($0.usedFraction ?? -1) < ($1.usedFraction ?? -1) }
    }

    /// A per-model weekly window (Fable, Opus, Sonnet…), as opposed to the
    /// session and the all-models week every plan has.
    static func isPerModelWindow(_ id: String) -> Bool {
        id.hasPrefix("weekly_") && id != "weekly_all"
    }

    /// The same reading, shaped the way the user asked to see it: without the
    /// per-model weekly windows if they turned those off, and with the ring
    /// following the window they chose.
    func shaped(headline: UsageHeadline, showPerModelWindows: Bool) -> ProviderSnapshot {
        let kept = showPerModelWindows ? windows : windows.filter { !Self.isPerModelWindow($0.id) }
        var chosen = headlineID
        if headline == .mostConstrained,
           let top = kept.max(by: { ($0.usedFraction ?? -1) < ($1.usedFraction ?? -1) }) {
            chosen = top.id
        }
        // A headline the user has hidden falls back to the first window kept,
        // rather than leaving the ring with nothing to point at.
        let resolved = chosen.flatMap { id in kept.contains { $0.id == id } ? id : nil } ?? kept.first?.id
        return ProviderSnapshot(
            id: id, displayName: displayName, glyph: glyph, fidelity: fidelity,
            status: status, windows: kept, headlineID: resolved
        )
    }

    /// Signing in means something different per provider, so the prompt has
    /// to say which door to knock on.
    private var authPrompt: String {
        switch id {
        case "claude": return "Sign in to Claude Code to read your usage"
        case _ where ClaudeProfile.isClaude(providerID: id):
            let slug = ClaudeProfile.slug(fromProviderID: id) ?? ""
            return "Sign in to Claude Code in ~/.claude-\(slug) to read your usage"
        case "cursor": return "Sign in to Cursor in the editor"
        case "codex": return "Sign in to Codex to read your usage"
        case "grok": return "Run grok login to read your usage"
        default: return "Sign in to \(displayName) to read your usage"
        }
    }

    /// What to show instead of limit rows when there is nothing to show.
    var statusMessage: String? {
        if hasReading { return nil }
        switch status {
        case .needsAuth: return authPrompt
        case .accessDenied:
            return "Portly was refused access to \(displayName)'s saved login. "
                + "Click this ring to ask again, and choose Always Allow."
        case .unsupported(let why): return why
        case .error(let why): return "Couldn't read usage — \(why)"
        case .stale, .ok: return "Waiting for the first reading…"
        }
    }
}
