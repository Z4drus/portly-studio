import Foundation

// MARK: - Config model (what lives in ~/.config/portly/config.json)

public struct ServerAction: Codable, Identifiable, Hashable {
    public var name: String
    public var command: String

    public var id: String { name }

    public init(name: String, command: String) {
        self.name = name
        self.command = command
    }
}

public struct ServerConfig: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Shell command, run through `zsh -lc` so PATH / nvm / mise are inherited.
    public var command: String
    /// Port the server is expected to listen on. Drives the TCP health check.
    public var port: Int?
    /// Working directory. Relative paths resolve against the project root.
    public var directory: String?
    public var env: [String: String]
    /// Optional HTTP health check. Either a path ("/api/health") resolved against
    /// http://127.0.0.1:<port>, or a full URL.
    public var healthURL: String?
    /// Expected HTTP status for the health URL. Any 2xx/3xx if nil.
    public var healthStatus: Int?
    /// When false, a crash leaves the server stopped instead of restarting it.
    public var autoRestart: Bool
    /// Maintenance commands that run beside the server without restarting it.
    public var actions: [ServerAction]

    public init(
        id: String = ServerConfig.newID(),
        name: String,
        command: String,
        port: Int? = nil,
        directory: String? = nil,
        env: [String: String] = [:],
        healthURL: String? = nil,
        healthStatus: Int? = nil,
        autoRestart: Bool = true,
        actions: [ServerAction] = []
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.port = port
        self.directory = directory
        self.env = env
        self.healthURL = healthURL
        self.healthStatus = healthStatus
        self.autoRestart = autoRestart
        self.actions = actions
    }

    public static func newID() -> String { "srv_" + String(UUID().uuidString.prefix(8)).lowercased() }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ServerConfig.newID()
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode(String.self, forKey: .command)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        directory = try c.decodeIfPresent(String.self, forKey: .directory)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        healthURL = try c.decodeIfPresent(String.self, forKey: .healthURL)
        healthStatus = try c.decodeIfPresent(Int.self, forKey: .healthStatus)
        autoRestart = try c.decodeIfPresent(Bool.self, forKey: .autoRestart) ?? true
        actions = try c.decodeIfPresent([ServerAction].self, forKey: .actions) ?? []
    }
}

public enum MemoryLimitMode: String, Codable, Hashable, CaseIterable {
    case inherit
    case disabled
    case custom
}

public enum MemorySize {
    public static let minimumLimitBytes: UInt64 = 128 * 1_024 * 1_024
    public static let maximumLimitBytes: UInt64 = 1_024 * 1_024 * 1_024 * 1_024

    public static func parse(_ raw: String) -> UInt64? {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return nil }

        let units: [(suffix: String, multiplier: Double)] = [
            ("tib", 1_099_511_627_776), ("tb", 1_099_511_627_776), ("to", 1_099_511_627_776),
            ("gib", 1_073_741_824), ("gb", 1_073_741_824), ("go", 1_073_741_824),
            ("mib", 1_048_576), ("mb", 1_048_576), ("mo", 1_048_576),
        ]
        guard let unit = units.first(where: { normalized.hasSuffix($0.suffix) }) else { return nil }
        let number = normalized.dropLast(unit.suffix.count)
        guard let amount = Double(number), amount > 0 else { return nil }
        let bytes = amount * unit.multiplier
        guard bytes.isFinite, bytes >= Double(minimumLimitBytes), bytes <= Double(maximumLimitBytes) else {
            return nil
        }
        return UInt64(bytes.rounded())
    }

    public static func display(_ bytes: UInt64) -> String {
        let gibibyte: UInt64 = 1_073_741_824
        let mebibyte: UInt64 = 1_048_576
        if bytes >= gibibyte {
            let value = Double(bytes) / Double(gibibyte)
            return value.formatted(.number.precision(.fractionLength(value.rounded() == value ? 0 : 1))) + " GB"
        }
        return "\(bytes / mebibyte) MB"
    }
}

public struct Project: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Nucleo glyph id (`category/name`) drawn in the project's color. Old
    /// configs may still hold an SF Symbol name; the app maps those on read.
    public var icon: String
    /// Hex color used for the icon and the accent dot.
    public var color: String
    /// Absolute path to the project root.
    public var root: String
    public var servers: [ServerConfig]
    /// Inherit the global limit, explicitly disable it, or use a custom value.
    public var memoryLimitMode: MemoryLimitMode
    public var memoryLimitBytes: UInt64?

    public init(
        id: String = Project.newID(),
        name: String,
        icon: String = Project.defaultIcon,
        color: String = "#8E8E93",
        root: String,
        servers: [ServerConfig] = [],
        memoryLimitMode: MemoryLimitMode = .inherit,
        memoryLimitBytes: UInt64? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.root = root
        self.servers = servers
        self.memoryLimitMode = memoryLimitMode
        self.memoryLimitBytes = memoryLimitBytes
    }

    public static func newID() -> String { "prj_" + String(UUID().uuidString.prefix(8)).lowercased() }

    public static let defaultIcon = "shopping/box-2"

    /// A handful of sensible defaults. The app offers the full Nucleo set
    /// through its searchable picker; the CLI accepts any `category/name` id.
    public static let icons = [
        "shopping/box-2", "ar-vr/cube", "business-finance/globe", "technology-devices/server",
        "weather/bolt", "weather/cloud", "ui-layout/hammer", "school-education/flask",
        "shopping/cart-shopping", "communication/envelope", "charts/chart-bar", "bookmarks-favorites/star",
        "bookmarks-favorites/heart", "gaming/gamepad", "photography-video/camera",
        "sound-music/music-note", "school-education/book", "design-development/terminal",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Project.newID()
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? Project.defaultIcon
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#8E8E93"
        root = try c.decode(String.self, forKey: .root)
        servers = try c.decodeIfPresent([ServerConfig].self, forKey: .servers) ?? []
        memoryLimitMode = try c.decodeIfPresent(MemoryLimitMode.self, forKey: .memoryLimitMode) ?? .inherit
        memoryLimitBytes = try c.decodeIfPresent(UInt64.self, forKey: .memoryLimitBytes)
    }

    public func effectiveMemoryLimit(global: UInt64?) -> UInt64? {
        switch memoryLimitMode {
        case .inherit: return global
        case .disabled: return nil
        case .custom: return memoryLimitBytes
        }
    }
}

public struct PortlyConfig: Codable {
    public var version: Int
    /// Port of the local HTTP control API the CLI and agents talk to.
    public var apiPort: Int
    /// Seconds between health checks.
    public var healthIntervalSeconds: Int
    /// Consecutive failed restarts before a server is parked in `.failed`.
    public var maxRestartAttempts: Int
    /// Lines of scrollback kept in memory per server.
    public var logBufferLines: Int
    /// Per-server log file cap before rotation, in megabytes.
    public var logFileMaxMB: Int
    /// Default project footprint limit. Nil keeps automatic memory restarts off.
    public var globalMemoryLimitBytes: UInt64?
    /// When the configured port is busy, start on the next free one instead
    /// of failing. The runtime reports the port it actually used.
    public var autoSelectFreePort: Bool
    public var projects: [Project]

    public static let defaultAPIPort = 7737

    public init(
        version: Int = 1,
        apiPort: Int = PortlyConfig.defaultAPIPort,
        healthIntervalSeconds: Int = 10,
        maxRestartAttempts: Int = 5,
        logBufferLines: Int = 5000,
        logFileMaxMB: Int = 10,
        globalMemoryLimitBytes: UInt64? = nil,
        autoSelectFreePort: Bool = true,
        projects: [Project] = []
    ) {
        self.version = version
        self.apiPort = apiPort
        self.healthIntervalSeconds = healthIntervalSeconds
        self.maxRestartAttempts = maxRestartAttempts
        self.logBufferLines = logBufferLines
        self.logFileMaxMB = logFileMaxMB
        self.globalMemoryLimitBytes = globalMemoryLimitBytes
        self.autoSelectFreePort = autoSelectFreePort
        self.projects = projects
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        apiPort = try c.decodeIfPresent(Int.self, forKey: .apiPort) ?? PortlyConfig.defaultAPIPort
        healthIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .healthIntervalSeconds) ?? 10
        maxRestartAttempts = try c.decodeIfPresent(Int.self, forKey: .maxRestartAttempts) ?? 5
        logBufferLines = try c.decodeIfPresent(Int.self, forKey: .logBufferLines) ?? 5000
        logFileMaxMB = try c.decodeIfPresent(Int.self, forKey: .logFileMaxMB) ?? 10
        globalMemoryLimitBytes = try c.decodeIfPresent(UInt64.self, forKey: .globalMemoryLimitBytes)
        autoSelectFreePort = try c.decodeIfPresent(Bool.self, forKey: .autoSelectFreePort) ?? true
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
    }

    public func project(id: String) -> Project? { projects.first { $0.id == id } }

    public func server(id: String) -> (project: Project, server: ServerConfig)? {
        for p in projects {
            if let s = p.servers.first(where: { $0.id == id }) { return (p, s) }
        }
        return nil
    }

    /// Resolves a user-supplied identifier to a server: exact id, or a
    /// case-insensitive name match, optionally qualified as "project/server".
    public func resolveServer(_ query: String) -> (project: Project, server: ServerConfig)? {
        if let hit = server(id: query) { return hit }
        let parts = query.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            guard let p = resolveProject(parts[0]) else { return nil }
            if let s = p.servers.first(where: { $0.name.caseInsensitiveCompare(parts[1]) == .orderedSame }) {
                return (p, s)
            }
            return nil
        }
        for p in projects {
            if let s = p.servers.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
                return (p, s)
            }
        }
        return nil
    }

    public func resolveProject(_ query: String) -> Project? {
        if let p = project(id: query) { return p }
        return projects.first { $0.name.caseInsensitiveCompare(query) == .orderedSame }
    }
}

// MARK: - Runtime state

public enum ServerState: String, Codable, Hashable {
    case stopped
    case starting
    case running
    case unhealthy
    case restarting
    case failed
}

public struct ServerStatus: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var projectID: String
    public var projectName: String
    public var command: String
    public var port: Int?
    public var directory: String
    public var state: ServerState
    public var pid: Int32?
    public var startedAt: Date?
    public var restartCount: Int
    public var lastExitCode: Int32?
    public var lastError: String?
    public var healthy: Bool
    public var url: String?
    public var cpuPercent: Double?
    /// Total physical footprint, including compressed and swapped owned pages.
    public var memoryBytes: UInt64?
    /// Portion of the process tree currently resident in RAM.
    public var residentMemoryBytes: UInt64?
    public var processCount: Int?
    /// The port from the configuration when the server had to start elsewhere.
    public var configuredPort: Int?
    /// Every TCP port the process tree listens on, beyond the primary one.
    public var extraPorts: [Int]?

    public init(
        id: String, name: String, projectID: String, projectName: String,
        command: String, port: Int?, directory: String, state: ServerState,
        pid: Int32?, startedAt: Date?, restartCount: Int, lastExitCode: Int32?,
        lastError: String?, healthy: Bool, url: String?,
        cpuPercent: Double? = nil, memoryBytes: UInt64? = nil,
        residentMemoryBytes: UInt64? = nil, processCount: Int? = nil,
        configuredPort: Int? = nil, extraPorts: [Int]? = nil
    ) {
        self.id = id
        self.name = name
        self.projectID = projectID
        self.projectName = projectName
        self.command = command
        self.port = port
        self.directory = directory
        self.state = state
        self.pid = pid
        self.startedAt = startedAt
        self.restartCount = restartCount
        self.lastExitCode = lastExitCode
        self.lastError = lastError
        self.healthy = healthy
        self.url = url
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.residentMemoryBytes = residentMemoryBytes
        self.processCount = processCount
        self.configuredPort = configuredPort
        self.extraPorts = extraPorts
    }
}

public struct ProjectStatus: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var icon: String
    public var color: String
    public var root: String
    public var servers: [ServerStatus]
    public var memoryLimitMode: MemoryLimitMode
    public var memoryLimitBytes: UInt64?
    public var effectiveMemoryLimitBytes: UInt64?
    public var lastMemoryRestartAt: Date?
    public var lastMemoryRestartBytes: UInt64?

    public init(
        id: String,
        name: String,
        icon: String,
        color: String,
        root: String,
        servers: [ServerStatus],
        memoryLimitMode: MemoryLimitMode = .inherit,
        memoryLimitBytes: UInt64? = nil,
        effectiveMemoryLimitBytes: UInt64? = nil,
        lastMemoryRestartAt: Date? = nil,
        lastMemoryRestartBytes: UInt64? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.root = root
        self.servers = servers
        self.memoryLimitMode = memoryLimitMode
        self.memoryLimitBytes = memoryLimitBytes
        self.effectiveMemoryLimitBytes = effectiveMemoryLimitBytes
        self.lastMemoryRestartAt = lastMemoryRestartAt
        self.lastMemoryRestartBytes = lastMemoryRestartBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        color = try container.decode(String.self, forKey: .color)
        root = try container.decode(String.self, forKey: .root)
        servers = try container.decode([ServerStatus].self, forKey: .servers)
        memoryLimitMode = try container.decodeIfPresent(MemoryLimitMode.self, forKey: .memoryLimitMode) ?? .inherit
        memoryLimitBytes = try container.decodeIfPresent(UInt64.self, forKey: .memoryLimitBytes)
        effectiveMemoryLimitBytes = try container.decodeIfPresent(UInt64.self, forKey: .effectiveMemoryLimitBytes)
        lastMemoryRestartAt = try container.decodeIfPresent(Date.self, forKey: .lastMemoryRestartAt)
        lastMemoryRestartBytes = try container.decodeIfPresent(UInt64.self, forKey: .lastMemoryRestartBytes)
    }
}

public struct PortlyStatus: Codable {
    public var version: String
    public var apiPort: Int
    public var globalMemoryLimitBytes: UInt64?
    public var projects: [ProjectStatus]

    public init(
        version: String,
        apiPort: Int,
        globalMemoryLimitBytes: UInt64? = nil,
        projects: [ProjectStatus]
    ) {
        self.version = version
        self.apiPort = apiPort
        self.globalMemoryLimitBytes = globalMemoryLimitBytes
        self.projects = projects
    }
}

public struct PortOccupant: Codable, Hashable {
    public var port: Int
    public var pid: Int32
    public var command: String
    public var user: String
    /// True when the listener is one of Portly's own supervised servers.
    public var ownedByPortly: Bool
    public var serverID: String?
    /// Docker Desktop owns the host listener for published container ports.
    /// These fields identify the actual container Portly can stop safely.
    public var dockerContainerID: String?
    public var dockerContainerName: String?
    public var dockerComposeProject: String?
    public var dockerComposeService: String?

    public init(
        port: Int,
        pid: Int32,
        command: String,
        user: String,
        ownedByPortly: Bool,
        serverID: String?,
        dockerContainerID: String? = nil,
        dockerContainerName: String? = nil,
        dockerComposeProject: String? = nil,
        dockerComposeService: String? = nil
    ) {
        self.port = port
        self.pid = pid
        self.command = command
        self.user = user
        self.ownedByPortly = ownedByPortly
        self.serverID = serverID
        self.dockerContainerID = dockerContainerID
        self.dockerContainerName = dockerContainerName
        self.dockerComposeProject = dockerComposeProject
        self.dockerComposeService = dockerComposeService
    }
}
