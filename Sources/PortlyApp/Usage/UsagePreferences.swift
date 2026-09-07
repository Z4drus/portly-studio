import Combine
import Foundation

/// How much of itself the notch shows when you are not using it.
///
/// Three states rather than two, because the default is neither: at rest the
/// notch is already a small pill that opens on contact.
enum NotchVisibility: String, CaseIterable, Identifiable {
    /// Pinned open. The readings are always on screen.
    case alwaysShow
    /// A pill at the edge that unfolds when the pointer reaches it. The default.
    case onHover
    /// Nothing on screen at all.
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alwaysShow: return "Always show"
        case .onHover: return "Show on hover"
        case .hidden: return "Hide"
        }
    }

    var explanation: String {
        switch self {
        case .alwaysShow:
            return "The notch stays open with every reading visible."
        case .onHover:
            return "A small pill at the screen edge that opens when you reach it."
        case .hidden:
            return "Nothing on the screen edge. The sidebar section keeps working."
        }
    }
}

/// Which window the ring's number stands for.
enum UsageHeadline: String, CaseIterable, Identifiable {
    /// The provider's own primary window: for Claude, the current session,
    /// the same one Claude Code's `/usage` leads with.
    case session
    /// Whichever window is closest to running out, which is what "am I about
    /// to get cut off" actually means.
    case mostConstrained

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: return "Current session"
        case .mostConstrained: return "Closest to the limit"
        }
    }

    var explanation: String {
        switch self {
        case .session:
            return "The ring and the percentage follow the rolling session window, the way Claude's own usage panel leads."
        case .mostConstrained:
            return "The ring and the percentage follow whichever window is highest, so a weekly or Fable limit about to run out shows first."
        }
    }
}

/// What the user has chosen about AI usage, kept in `UserDefaults`.
@MainActor
final class UsagePreferences: ObservableObject {
    /// Providers whose credential Portly may read. Stored as the *enabled*
    /// set, so a tool you never asked about is never touched: Claude Code is
    /// on by default, everything else is opt-in.
    @Published var enabledProviders: Set<String> {
        didSet { defaults.set(Array(enabledProviders).sorted(), forKey: Keys.enabled) }
    }

    /// How much of itself the notch shows at rest.
    @Published var notchVisibility: NotchVisibility {
        didSet { defaults.set(notchVisibility.rawValue, forKey: Keys.visibility) }
    }

    /// Which screen edge the notch is welded to.
    @Published var notchEdge: NotchEdge {
        didSet { defaults.set(notchEdge.rawValue, forKey: Keys.edge) }
    }

    /// Whether the readings also sit in the main window's sidebar.
    @Published var showInSidebar: Bool {
        didSet { defaults.set(showInSidebar, forKey: Keys.sidebar) }
    }

    /// Whether the readings also sit in the menu bar popover, which is the
    /// one place left when the window is closed and the notch is hidden.
    @Published var showInMenuBar: Bool {
        didSet { defaults.set(showInMenuBar, forKey: Keys.menuBar) }
    }

    /// Which window the ring's number stands for.
    @Published var headline: UsageHeadline {
        didSet { defaults.set(headline.rawValue, forKey: Keys.headline) }
    }

    /// Whether the per-model weekly windows (Fable, Opus, Sonnet…) are listed
    /// beside the session and the all-models week.
    @Published var showPerModelWindows: Bool {
        didSet { defaults.set(showPerModelWindows, forKey: Keys.perModelWindows) }
    }

    /// Whether live Claude Code sessions spin the ring and are listed.
    @Published var showSessions: Bool {
        didSet { defaults.set(showSessions, forKey: Keys.sessions) }
    }

    private let defaults: UserDefaults
    private enum Keys {
        static let enabled = "usage.enabledProviders"
        static let visibility = "usage.notchVisibility"
        static let edge = "usage.notchEdge"
        static let sidebar = "usage.showInSidebar"
        static let menuBar = "usage.showInMenuBar"
        static let headline = "usage.headline"
        static let perModelWindows = "usage.showPerModelWindows"
        static let sessions = "usage.showSessions"
    }

    init(defaults: UserDefaults = .standard, defaultEnabled: Set<String>) {
        self.defaults = defaults
        self.enabledProviders = defaults.stringArray(forKey: Keys.enabled).map(Set.init) ?? defaultEnabled
        // Absent means never chosen, which is the hover behaviour the notch
        // was designed around.
        self.notchVisibility = defaults.string(forKey: Keys.visibility)
            .flatMap(NotchVisibility.init(rawValue:)) ?? .onHover
        // The right edge is the one side of a Mac no system chrome claims.
        self.notchEdge = defaults.string(forKey: Keys.edge)
            .flatMap(NotchEdge.init(rawValue:)) ?? .right
        self.showInSidebar = defaults.object(forKey: Keys.sidebar) as? Bool ?? true
        self.showInMenuBar = defaults.object(forKey: Keys.menuBar) as? Bool ?? true
        self.headline = defaults.string(forKey: Keys.headline)
            .flatMap(UsageHeadline.init(rawValue:)) ?? .session
        self.showPerModelWindows = defaults.object(forKey: Keys.perModelWindows) as? Bool ?? true
        self.showSessions = defaults.object(forKey: Keys.sessions) as? Bool ?? true
    }

    func isEnabled(_ providerID: String) -> Bool {
        enabledProviders.contains(providerID)
    }

    func setEnabled(_ enabled: Bool, for providerID: String) {
        if enabled {
            enabledProviders.insert(providerID)
        } else {
            enabledProviders.remove(providerID)
        }
    }
}
