import Foundation

/// Finds the SwiftPM resource bundle that carries the glyphs and their catalog.
///
/// Deliberately not `Bundle.module`. For an executable target SwiftPM generates
/// an accessor with exactly two candidates: the *root* of the main bundle, and
/// the absolute `.build` path of the machine that compiled the binary. A
/// packaged app keeps resource bundles in `Contents/Resources` (anything at the
/// bundle root breaks the code signature), so the first candidate never exists
/// and the second only exists on the build machine. Everywhere else the
/// accessor calls `fatalError` the first time an icon is drawn, which is a
/// crash at launch. This lookup knows where the bundle really is, and a miss
/// degrades to missing glyphs instead of taking the app down.
enum PortlyResources {
    static let bundleName = "Portly_PortlyApp.bundle"

    /// Nil only when the resource bundle is nowhere to be found.
    static let bundle: Bundle? = locate(among: candidateDirectories())

    /// Pure, so the order can be tested without touching the real bundle.
    static func locate(among directories: [URL], fileManager: FileManager = .default) -> Bundle? {
        for directory in directories {
            let url = directory.appendingPathComponent(bundleName, isDirectory: true)
            guard fileManager.fileExists(atPath: url.path), let bundle = Bundle(url: url) else { continue }
            return bundle
        }
        return nil
    }

    /// Most specific first: the packaged app, then the layouts `swift run` and
    /// `swift test` produce, where the bundle sits beside the binary.
    static func candidateDirectories(main: Bundle = .main) -> [URL] {
        var directories: [URL] = []
        if let resources = main.resourceURL { directories.append(resources) }
        directories.append(main.bundleURL)
        if let executable = main.executableURL {
            directories.append(executable.deletingLastPathComponent())
        }
        // Under `swift test` the main bundle is the xctest runner inside Xcode;
        // the products directory is the one that holds the test bundle.
        let testBundle = Bundle(for: BundleToken.self).bundleURL
        directories.append(testBundle)
        directories.append(testBundle.deletingLastPathComponent())
        return directories
    }

    static func url(forResource name: String, withExtension ext: String, subdirectory: String? = nil) -> URL? {
        bundle?.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    }

    private final class BundleToken {}
}
