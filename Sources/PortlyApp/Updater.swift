import Foundation

/// This private fork ships no auto-updater: the upstream Sparkle feed would
/// silently replace the custom build with the stock Portly release.
enum PortlyUpdater {
    static let isAvailable = false
}
