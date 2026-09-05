import AppKit
import SwiftUI

/// One glyph from the bundled Nucleo "glyph-duo" set, addressed as
/// `category/name` (the on-disk layout under `Resources/Icons`).
struct NucleoIcon: Identifiable, Hashable {
    let id: String
    let category: String
    let name: String
    /// Everything a search can hit, lowercased and stripped of diacritics.
    let haystack: String
    /// Name tokens ("code", "brackets") kept apart for ranking.
    let nameTokens: [String]

    init(id: String, keywordsEN: [String], keywordsFR: [String]) {
        self.id = id
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        category = parts.first ?? ""
        name = parts.count > 1 ? parts[1] : id
        nameTokens = name.split(separator: "-").map { IconCatalog.fold(String($0)) }
        let words = [name.replacingOccurrences(of: "-", with: " "), category.replacingOccurrences(of: "-", with: " ")]
            + keywordsEN + keywordsFR
        haystack = IconCatalog.fold(words.joined(separator: " "))
    }

    var displayName: String {
        name.replacingOccurrences(of: "-", with: " ")
    }
}

/// Loads the catalog once and answers searches in French or English.
final class IconCatalog {
    static let shared = IconCatalog()

    private(set) var icons: [NucleoIcon] = []
    private var byID: [String: NucleoIcon] = [:]
    private(set) var categories: [String] = []

    private init() {
        load()
    }

    private struct Entry: Decodable {
        let id: String
        let en: [String]
        let fr: [String]
    }

    private func load() {
        guard let url = Bundle.module.url(forResource: "icon-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else {
            icons = []
            return
        }
        icons = entries.map { NucleoIcon(id: $0.id, keywordsEN: $0.en, keywordsFR: $0.fr) }
        byID = Dictionary(uniqueKeysWithValues: icons.map { ($0.id, $0) })
        categories = Array(Set(icons.map(\.category))).sorted()
    }

    func icon(_ id: String) -> NucleoIcon? { byID[id] }

    func contains(_ id: String) -> Bool { byID[id] != nil }

    /// Lowercase, diacritic-free, hyphens as spaces: "Développeur" and
    /// "developpeur" become the same needle.
    static func fold(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    /// Every term must match; results are ranked so exact and prefix name hits
    /// come before keyword-only hits.
    func search(_ query: String, category: String? = nil, limit: Int = 600) -> [NucleoIcon] {
        let terms = Self.fold(query)
            .split(whereSeparator: { $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty }

        var pool = icons
        if let category {
            pool = pool.filter { $0.category == category }
        }
        guard !terms.isEmpty else { return Array(pool.prefix(limit)) }

        var scored: [(NucleoIcon, Int)] = []
        scored.reserveCapacity(256)
        for icon in pool {
            var score = 0
            var allMatched = true
            for term in terms {
                if icon.nameTokens.contains(term) {
                    score += 100
                } else if icon.nameTokens.contains(where: { $0.hasPrefix(term) }) {
                    score += 60
                } else if icon.haystack.contains(term) {
                    score += 10
                } else {
                    allMatched = false
                    break
                }
            }
            guard allMatched else { continue }
            // Short names are usually the canonical glyph ("code" before
            // "code-pull-request-closed").
            score -= icon.nameTokens.count
            scored.append((icon, score))
        }
        scored.sort { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.name < rhs.0.name
        }
        return scored.prefix(limit).map(\.0)
    }
}

/// Template `NSImage`s for the glyphs, rasterised lazily and shared. The SVGs
/// are two-tone through alpha, so tinting a template keeps the duo look.
enum IconImageCache {
    private static var images: [String: NSImage] = [:]
    private static let lock = NSLock()

    static func image(for id: String) -> NSImage? {
        lock.lock()
        if let cached = images[id] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let url = Bundle.module.url(
                forResource: parts[1],
                withExtension: "svg",
                subdirectory: "Icons/\(parts[0])"
              ),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        lock.lock()
        images[id] = image
        lock.unlock()
        return image
    }
}

/// Renders a Nucleo glyph at a given point size, tinted by the current
/// foreground style. Unknown ids fall back to the default project glyph so an
/// old config with an SF Symbol name never draws an empty square.
struct NucleoIconView: View {
    let id: String
    var size: CGFloat = 14

    init(_ id: String, size: CGFloat = 14) {
        self.id = id
        self.size = size
    }

    init(_ icon: AppIcon, size: CGFloat = 14) {
        self.id = icon.rawValue
        self.size = size
    }

    var body: some View {
        if let image = IconImageCache.image(for: id) ?? IconImageCache.image(for: AppIcon.projectDefault.rawValue) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

/// `Label` whose icon is a Nucleo glyph. Works in toolbars, menus and lists.
struct NucleoLabel: View {
    let title: String
    let icon: String
    var size: CGFloat = 14

    init(_ title: String, icon: AppIcon, size: CGFloat = 14) {
        self.title = title
        self.icon = icon.rawValue
        self.size = size
    }

    init(_ title: String, iconID: String, size: CGFloat = 14) {
        self.title = title
        self.icon = iconID
        self.size = size
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            NucleoIconView(icon, size: size)
        }
    }
}

extension Image {
    /// An `Image` for places that need one (toolbar `Label`, menu items). The
    /// template rendering picks up the surrounding foreground style.
    static func nucleo(_ icon: AppIcon) -> Image {
        nucleo(id: icon.rawValue)
    }

    static func nucleo(id: String) -> Image {
        if let image = IconImageCache.image(for: id) ?? IconImageCache.image(for: AppIcon.projectDefault.rawValue) {
            return Image(nsImage: image).renderingMode(.template)
        }
        return Image(nsImage: NSImage(size: NSSize(width: 18, height: 18)))
    }
}

/// Every glyph the chrome itself uses, so a swap happens in one place.
enum AppIcon: String, CaseIterable {
    case projectDefault = "shopping/box-2"
    case play = "sound-music/media-play"
    case stop = "sound-music/media-stop"
    case pause = "sound-music/media-pause"
    case restart = "arrows/refresh"
    case retry = "arrows/arrow-rotate-clockwise"
    case plus = "ui-layout/plus"
    case circlePlus = "ui-layout/circle-plus"
    case settings = "ui-layout/gear"
    case settingsAlt = "ui-layout/gear-3"
    case sliders = "ui-layout/sliders"
    case terminal = "design-development/terminal"
    case terminalSquare = "design-development/square-terminal"
    case code = "design-development/code"
    case network = "business-finance/globe"
    case networkOff = "technology-devices/wifi-off"
    case server = "technology-devices/server"
    case memory = "technology-devices/ram"
    case cpu = "technology-devices/microchip"
    case chartLine = "charts/chart-line"
    case chartBar = "charts/chart-bar"
    case chartActivity = "charts/chart-activity"
    case warning = "ui-layout/triangle-warning"
    case warningOctagon = "ui-layout/octagon-warning"
    case info = "ui-layout/circle-info"
    case question = "ui-layout/circle-question"
    case checkCircle = "ui-layout/circle-check"
    case badgeCheck = "ui-layout/badge-check"
    case check = "ui-layout/check"
    case xmarkCircle = "ui-layout/circle-xmark"
    case xmark = "ui-layout/xmark"
    case search = "filtering-sorting/magnifier"
    case clock = "time/clock"
    case timer = "time/timer"
    case hourglass = "time/hourglass"
    case history = "arrows/clock-rotate-anticlockwise"
    case folder = "files/folder"
    case folderOpen = "files/folder-open"
    case shield = "security/shield-check"
    case lock = "security/lock"
    case key = "security/key"
    case browser = "arrows/open-in-browser"
    case externalLink = "arrows/external-link"
    case arrowUpRight = "arrows/arrow-up-right"
    case eraser = "editing/eraser"
    case broom = "editing/broom"
    case wrench = "ui-layout/wrench-screwdriver"
    case chevronRight = "arrows/chevron-right"
    case chevronDown = "arrows/chevron-down"
    case chevronLeft = "arrows/chevron-left"
    case sparkle = "editing/sparkle"
    case hashtag = "shopping/hashtag"
    case desktop = "technology-devices/monitor"
    case laptop = "technology-devices/laptop"
    case layers = "design-development/layers"
    case stack = "ui-layout/stack-2"
    case signal = "technology-devices/signal"
    case grid = "ui-layout/grid"
    case appStack = "ui-layout/app-stack"
    case bolt = "weather/bolt"
    case cube = "ar-vr/cube"
    case splitRight = "design-development/split-obj-x"
    case splitDown = "design-development/split-obj-y"
    case expand = "arrows/expand"
    case fullscreen = "ui-layout/window-full-screen"
    case textBigger = "editing/text-size-increase"
    case textSmaller = "editing/text-size-decrease"
    case textSize = "editing/text-size"
    case file = "files/file"
    case files = "files/files"
    case upload = "arrows/upload"
    case download = "arrows/download"
    case dropZone = "arrows/square-dashed-upload"
    case importFiles = "arrows/import"
    case chat = "communication/chat-bubble"
    case chats = "communication/messages"
    case bot = "communication/chat-bot"
    case robot = "technology-devices/robot"
    case aiDeveloper = "technology-devices/ai-developer"
    case claude = "design-development/cloude-code"
    case magicWand = "design-development/magic-wand"
    case pen = "communication/pen"
    case copy = "ui-layout/copy"
    case dots = "ui-layout/dots"
    case eye = "ui-layout/eye"
    case eyeSlash = "ui-layout/eye-slash"
    case house = "home-buildings/house"
    case bell = "time/bell"
    case trash = "ui-layout/trash"
    case sidebarLeft = "ui-layout/sidebar-left"
    case windowLayout = "design-development/window-layout"
    case inbox = "files/inbox"
    case rocket = "gaming/rocket"
    case power = "technology-devices/circle-power-off"
    case exit = "arrows/exit-door"
    case keyboard = "technology-devices/keyboard"
    case command = "design-development/command"
    case returnKey = "arrows/return-key"
    case paperPlane = "communication/paper-plane"
    case user = "users/user"
    case lightbulb = "business-finance/lightbulb"
    case pin = "maps-location/pin"
    case arrowLeft = "arrows/arrow-left"
    case arrowRight = "arrows/arrow-right"
    case arrowDown = "arrows/arrow-down"
    case arrowUp = "arrows/arrow-up"
    case windowCode = "design-development/window-code"
    case magnifierPlus = "filtering-sorting/magnifier-plus"
    case coffee = "food/coffee"
    case wifi = "technology-devices/wifi"
    case battery = "technology-devices/battery"
    case moon = "weather/moon"
    case magnifierMinus = "filtering-sorting/magnifier-minus"
}

/// Old configs store SF Symbol names. Map the ones Portly used to ship with,
/// so nothing changes visually beyond the glyph style.
enum LegacyProjectIcons {
    static let map: [String: String] = [
        "shippingbox.fill": "shopping/box-2",
        "cube.fill": "ar-vr/cube",
        "globe": "business-finance/globe",
        "server.rack": "technology-devices/server",
        "bolt.fill": "weather/bolt",
        "cloud.fill": "weather/cloud",
        "hammer.fill": "ui-layout/hammer",
        "flask.fill": "school-education/flask",
        "cart.fill": "shopping/cart-shopping",
        "envelope.fill": "communication/envelope",
        "chart.bar.fill": "charts/chart-bar",
        "star.fill": "bookmarks-favorites/star",
        "heart.fill": "bookmarks-favorites/heart",
        "gamecontroller.fill": "gaming/gamepad",
        "camera.fill": "photography-video/camera",
        "music.note": "sound-music/music-note",
        "book.fill": "school-education/book",
        "terminal.fill": "design-development/terminal",
    ]

    /// Resolve whatever is stored to a glyph that exists in the bundle.
    static func resolve(_ stored: String) -> String {
        if IconCatalog.shared.contains(stored) { return stored }
        if let mapped = map[stored], IconCatalog.shared.contains(mapped) { return mapped }
        return AppIcon.projectDefault.rawValue
    }
}
