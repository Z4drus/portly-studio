import AppKit
import PortlyCore
import SwiftUI
import UniformTypeIdentifiers

/// Result of dropping files onto a project.
struct DropOutcome: Equatable {
    var copied: [String]
    var skipped: [String]
    var failed: [String]
}

/// Copies dropped files to the project root. Anything already inside the
/// project is left where it is; name clashes get a numeric suffix.
enum ProjectFileDrop {
    static func copy(urls: [URL], toRoot root: String) -> DropOutcome {
        let directory = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath).standardizedFileURL
        var outcome = DropOutcome(copied: [], skipped: [], failed: [])
        let fm = FileManager.default
        for url in urls {
            let source = url.standardizedFileURL
            if source.path.hasPrefix(directory.path + "/") || source.path == directory.path {
                outcome.skipped.append(source.lastPathComponent)
                continue
            }
            let destination = uniqueDestination(for: source, in: directory)
            do {
                try fm.copyItem(at: source, to: destination)
                outcome.copied.append(destination.lastPathComponent)
            } catch {
                outcome.failed.append(source.lastPathComponent)
            }
        }
        return outcome
    }

    private static func uniqueDestination(for source: URL, in directory: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = directory.appendingPathComponent(source.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    /// The sentence typed into the focused terminal, so the agent knows what
    /// just landed at the root and can go organise it.
    static func agentMessage(for names: [String]) -> String {
        let list = names.joined(separator: ", ")
        return "J'ai ajouté à la racine du projet : \(list). "
    }

    static func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = item as? URL {
                    url = direct
                }
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }
}

/// Makes a view a drop target for the project root, with a hover overlay and
/// a toast that can hand the file names to the focused agent terminal.
struct ProjectDropTarget: ViewModifier {
    let project: Project

    @State private var targeted = false
    @State private var outcome: DropOutcome?
    @State private var dismissWork: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                ProjectFileDrop.loadURLs(from: providers) { urls in
                    guard !urls.isEmpty else { return }
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = ProjectFileDrop.copy(urls: urls, toRoot: project.root)
                        DispatchQueue.main.async { show(result) }
                    }
                }
                return true
            }
            .overlay {
                if targeted {
                    dropOverlay
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if let outcome {
                    DropToast(project: project, outcome: outcome) { dismissToast() }
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.banner, value: targeted)
            .animation(Motion.banner, value: outcome)
    }

    private var dropOverlay: some View {
        ZStack {
            Rectangle()
                .fill(Color.accentColor.opacity(0.08))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(Color.accentColor.opacity(0.7))
                .padding(14)
            VStack(spacing: 10) {
                NucleoIconView(.dropZone, size: 34)
                    .foregroundStyle(Color.accentColor)
                Text("Drop to copy into \(project.name)")
                    .font(PortlyTypography.title)
                Text(NSString(string: project.root).abbreviatingWithTildeInPath)
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .allowsHitTesting(false)
    }

    private func show(_ result: DropOutcome) {
        outcome = result
        dismissWork?.cancel()
        let work = DispatchWorkItem { dismissToast() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    private func dismissToast() {
        dismissWork?.cancel()
        dismissWork = nil
        outcome = nil
    }
}

private struct DropToast: View {
    let project: Project
    let outcome: DropOutcome
    let onDismiss: () -> Void

    @ObservedObject private var workspace = StudioWorkspace.shared

    var body: some View {
        HStack(spacing: 12) {
            NucleoIconView(outcome.failed.isEmpty ? .checkCircle : .warning, size: 16)
                .foregroundStyle(outcome.failed.isEmpty ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(PortlyTypography.bodyMedium)
                Text(detail)
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: 420, alignment: .leading)

            if !outcome.copied.isEmpty {
                Button {
                    workspace.insertIntoFocusedTerminal(ProjectFileDrop.agentMessage(for: outcome.copied))
                    onDismiss()
                } label: {
                    NucleoLabel("Tell the agent", icon: .paperPlane, size: 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Type the file names into the focused terminal, without sending")

                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: NSString(string: project.root).expandingTildeInPath)
                } label: {
                    NucleoLabel("Reveal", icon: .folder, size: 12)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button(action: onDismiss) {
                NucleoIconView(.xmark, size: 11)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private var headline: String {
        let count = outcome.copied.count
        if count == 0 {
            return outcome.failed.isEmpty ? "Nothing to copy" : "Copy failed"
        }
        return count == 1 ? "1 file copied to the project root" : "\(count) files copied to the project root"
    }

    private var detail: String {
        var parts: [String] = []
        if !outcome.copied.isEmpty { parts.append(outcome.copied.joined(separator: ", ")) }
        if !outcome.skipped.isEmpty { parts.append("already inside the project: \(outcome.skipped.joined(separator: ", "))") }
        if !outcome.failed.isEmpty { parts.append("failed: \(outcome.failed.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }
}

extension View {
    func projectDropTarget(_ project: Project?) -> some View {
        Group {
            if let project {
                modifier(ProjectDropTarget(project: project))
            } else {
                self
            }
        }
    }
}
