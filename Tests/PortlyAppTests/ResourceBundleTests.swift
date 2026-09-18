import Foundation
import XCTest
@testable import PortlyApp

final class ResourceBundleTests: XCTestCase {
    /// The crash this guards against only shows on a Mac that did not build the
    /// app: SwiftPM's `Bundle.module` falls back to the build machine's absolute
    /// `.build` path, so it works for whoever compiled it and aborts at launch
    /// for everyone else.
    func testSourcesNeverUseTheGeneratedBundleAccessor() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains("Bundle" + ".module") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "use PortlyResources, which also looks in Contents/Resources")
    }

    func testThePackagedLocationWinsOverTheOthers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portly-resources-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Contents/Resources", isDirectory: true)
        let beside = root.appendingPathComponent("Contents/MacOS", isDirectory: true)
        for directory in [resources, beside] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(PortlyResources.bundleName, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let found = try XCTUnwrap(PortlyResources.locate(among: [resources, beside]))
        XCTAssertEqual(found.bundleURL.deletingLastPathComponent().standardizedFileURL, resources.standardizedFileURL)
        XCTAssertNil(PortlyResources.locate(among: [root]), "a miss is nil, never a crash")
    }

    func testTheBundleIsFoundAndCarriesTheGlyphs() {
        XCTAssertNotNil(PortlyResources.bundle)
        XCTAssertFalse(IconCatalog.shared.icons.isEmpty)
        XCTAssertNotNil(IconImageCache.image(for: AppIcon.projectDefault.rawValue))
    }
}
