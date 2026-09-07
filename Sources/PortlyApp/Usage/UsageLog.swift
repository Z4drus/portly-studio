import os

/// Usage readings come from other apps' credentials and undocumented
/// endpoints, so anything worth diagnosing goes to the unified log:
///
///     log stream --predicate 'subsystem == "dev.portly.app"' --level debug
enum UsageLog {
    static let usage = Logger(subsystem: "dev.portly.app", category: "usage")
    static let sessions = Logger(subsystem: "dev.portly.app", category: "sessions")
}
