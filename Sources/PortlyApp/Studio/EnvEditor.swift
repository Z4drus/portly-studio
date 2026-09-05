import AppKit
import PortlyCore
import SwiftUI

/// The `.env*` files at a project root: `.env` first, then its variants, then
/// the example.
struct EnvFile: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var isExample: Bool { name.contains("example") || name.contains("sample") || name.contains("template") }

    static func scan(root: String) -> [EnvFile] {
        let directory = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }
        let files = entries.filter { url in
            let name = url.lastPathComponent
            guard name == ".env" || name.hasPrefix(".env.") else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        return files
            .map(EnvFile.init(url:))
            .sorted { lhs, rhs in
                if lhs.name == ".env" { return true }
                if rhs.name == ".env" { return false }
                if lhs.isExample != rhs.isExample { return !lhs.isExample }
                return lhs.name < rhs.name
            }
    }
}

// MARK: - Panel

/// Environment files in a floating panel, the same shape as the quick
/// terminal: pick a file from the tabs, edit with dotenv colouring, ⌘S saves.
struct EnvEditorPanel: View {
    let project: Project

    @ObservedObject private var workspace = StudioWorkspace.shared
    @AppStorage("envEditorMonospace") private var monospace = false
    @State private var files: [EnvFile] = []
    @State private var selected: EnvFile?
    @State private var text = ""
    @State private var original = ""
    @State private var status: String?
    @State private var errorMessage: String?
    @State private var size: CGSize = .zero
    @State private var dragStartSize: CGSize?

    private let minimumSize = CGSize(width: 520, height: 320)
    private var isDirty: Bool { text != original }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if selected != nil {
                EnvHighlightingEditor(text: $text, monospace: monospace)
            } else {
                emptyState
            }
            Divider()
            footer
        }
        .frame(
            width: max(size.width, minimumSize.width),
            height: max(size.height, minimumSize.height)
        )
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        }
        .overlay(alignment: .bottomLeading) { resizeHandle }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        .onAppear {
            size = workspace.config.envPanelSize
            reload()
        }
        .alert("Unable to write the file", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            NucleoIconView(.key, size: 13)
                .foregroundStyle(Color(hex: project.color))
            Text(project.name)
                .font(PortlyTypography.bodyMedium)
                .lineLimit(1)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(files) { file in
                        tab(file)
                    }
                    createMenu
                }
            }

            Spacer(minLength: 4)

            Toggle(isOn: $monospace) {
                NucleoIconView(.textSize, size: 12)
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help(monospace ? "Use the app font" : "Use a monospaced font")
            .accessibilityLabel("Monospaced font")

            headerButton(.xmark, help: "Close (⇧⌘E)") { close() }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 40)
    }

    private func tab(_ file: EnvFile) -> some View {
        let isSelected = selected?.id == file.id
        return Button {
            select(file)
        } label: {
            HStack(spacing: 5) {
                NucleoIconView(file.isExample ? .file : .key, size: 10)
                    .foregroundStyle(isSelected ? Color(hex: project.color) : Color.secondary)
                Text(file.name)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular, design: .rounded))
                if isSelected, isDirty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("Unsaved changes")
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(isSelected ? Color.primary.opacity(0.1) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: isSelected)
        .help(file.url.path)
    }

    private var createMenu: some View {
        Menu {
            if !files.contains(where: { $0.name == ".env" }) {
                if let example = files.first(where: \.isExample) {
                    Button("Create .env from \(example.name)") { create(named: ".env", from: example) }
                }
                Button("Create empty .env") { create(named: ".env") }
            }
            if !files.contains(where: { $0.name == ".env.local" }) {
                Button("Create .env.local") { create(named: ".env.local") }
            }
            if !files.contains(where: { $0.name == ".env.example" }) {
                if let env = files.first(where: { $0.name == ".env" }) {
                    Button("Create .env.example from .env (values stripped)") { createExample(from: env) }
                }
                Button("Create empty .env.example") { create(named: ".env.example") }
            }
        } label: {
            NucleoIconView(.plus, size: 11)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Create an environment file")
    }

    private func headerButton(_ icon: AppIcon, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NucleoIconView(icon, size: 11)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Body & footer

    private var emptyState: some View {
        VStack(spacing: 10) {
            NucleoIconView(.key, size: 28)
                .foregroundStyle(.tertiary)
            Text(files.isEmpty ? "No .env files at the project root." : "Pick a file above.")
                .foregroundStyle(.secondary)
            if files.isEmpty {
                Button("Create .env") { create(named: ".env") }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let selected {
                Text(NSString(string: selected.url.path).abbreviatingWithTildeInPath)
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let status {
                Text(status)
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            Spacer()
            if selected != nil {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    flash("Copied")
                } label: {
                    NucleoLabel("Copy", icon: .copy, size: 11)
                }
                Button {
                    if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected.url]) }
                } label: {
                    NucleoLabel("Reveal", icon: .folder, size: 11)
                }
                Button("Revert") { text = original }
                    .disabled(!isDirty)
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartSize == nil { dragStartSize = size }
                        guard let start = dragStartSize else { return }
                        size = CGSize(
                            width: max(minimumSize.width, start.width - value.translation.width),
                            height: max(minimumSize.height, start.height + value.translation.height)
                        )
                    }
                    .onEnded { _ in
                        dragStartSize = nil
                        workspace.setEnvPanelSize(size)
                    }
            )
            .accessibilityLabel("Resize panel")
    }

    // MARK: Actions

    private func close() {
        if isDirty { save() }
        workspace.envPanelProjectID = nil
    }

    private func reload() {
        files = EnvFile.scan(root: project.root)
        if let selected, let refreshed = files.first(where: { $0.id == selected.id }) {
            select(refreshed)
        } else {
            select(files.first)
        }
    }

    private func select(_ file: EnvFile?) {
        if isDirty { save() }
        selected = file
        guard let file else {
            text = ""
            original = ""
            return
        }
        let content = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
        text = content
        original = content
    }

    private func save() {
        guard let selected, isDirty else { return }
        do {
            try text.write(to: selected.url, atomically: true, encoding: .utf8)
            original = text
            flash("Saved")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func create(named name: String, from template: EnvFile? = nil) {
        let content = template.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } ?? ""
        write(name: name, content: content)
    }

    /// `.env.example` from `.env`: same keys and comments, values blanked.
    private func createExample(from env: EnvFile) {
        let content = (try? String(contentsOf: env.url, encoding: .utf8)) ?? ""
        let stripped = content.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { return String(line) }
            return String(line[..<equals]) + "="
        }.joined(separator: "\n")
        write(name: ".env.example", content: stripped)
    }

    private func write(name: String, content: String) {
        let root = URL(fileURLWithPath: NSString(string: project.root).expandingTildeInPath)
        let url = root.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            files = EnvFile.scan(root: project.root)
            select(files.first { $0.url == url })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func flash(_ message: String) {
        withAnimation(Motion.state) { status = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(Motion.state) {
                if status == message { status = nil }
            }
        }
    }
}

// MARK: - Highlighting

/// dotenv colouring: keys, quoted values, comments, `${interpolation}`, and
/// a red mark on the one mistake that silently breaks everything, an unclosed
/// quote.
enum EnvHighlighter {
    struct Palette {
        var key: NSColor
        var string: NSColor
        var value: NSColor
        var comment: NSColor
        var punctuation: NSColor
        var keyword: NSColor
        var interpolation: NSColor
        var error: NSColor

        static let standard = Palette(
            key: .systemBlue,
            string: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.62, green: 0.83, blue: 0.55, alpha: 1)
                : NSColor(srgbRed: 0.10, green: 0.50, blue: 0.22, alpha: 1) },
            value: .labelColor,
            comment: .secondaryLabelColor,
            punctuation: .tertiaryLabelColor,
            keyword: .systemPurple,
            interpolation: .systemTeal,
            error: .systemRed
        )
    }

    enum Token: Equatable {
        case key, string, value, comment, punctuation, keyword, interpolation, error
    }

    struct Span: Equatable {
        let range: NSRange
        let token: Token
    }

    /// Pure: line ranges to tokens, so it can be unit-tested without AppKit.
    static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        var spans: [Span] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { line, range, _, _ in
            guard let line else { return }
            spans.append(contentsOf: lineSpans(line, offset: range.location))
        }
        return spans
    }

    private static func lineSpans(_ line: String, offset: Int) -> [Span] {
        let ns = line as NSString
        let trimmedStart = ns.rangeOfCharacter(from: CharacterSet.whitespaces.inverted)
        guard trimmedStart.location != NSNotFound else { return [] }
        let content = ns.substring(from: trimmedStart.location)
        let base = offset + trimmedStart.location

        if content.hasPrefix("#") {
            return [Span(range: NSRange(location: base, length: (content as NSString).length), token: .comment)]
        }

        let cns = content as NSString
        let equals = cns.range(of: "=")
        guard equals.location != NSNotFound else {
            return [Span(range: NSRange(location: base, length: cns.length), token: .error)]
        }

        var spans: [Span] = []
        var keyStart = 0
        if content.hasPrefix("export ") {
            spans.append(Span(range: NSRange(location: base, length: 6), token: .keyword))
            keyStart = 7
        }
        let keyLength = max(0, equals.location - keyStart)
        let key = cns.substring(with: NSRange(location: keyStart, length: keyLength)).trimmingCharacters(in: .whitespaces)
        let keyValid = !key.isEmpty && key.range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
        spans.append(Span(range: NSRange(location: base + keyStart, length: keyLength), token: keyValid ? .key : .error))
        spans.append(Span(range: NSRange(location: base + equals.location, length: 1), token: .punctuation))

        let valueStart = equals.location + 1
        let value = cns.substring(from: valueStart)
        spans.append(contentsOf: valueSpans(value, offset: base + valueStart))
        return spans
    }

    private static func valueSpans(_ rawValue: String, offset: Int) -> [Span] {
        let ns = rawValue as NSString
        let firstNonSpace = ns.rangeOfCharacter(from: CharacterSet.whitespaces.inverted)
        guard firstNonSpace.location != NSNotFound else { return [] }
        let start = firstNonSpace.location
        let opener = ns.character(at: start)

        if opener == 0x22 || opener == 0x27 { // " or '
            let closing = ns.range(of: String(UnicodeScalar(UInt8(opener))), options: [], range: NSRange(location: start + 1, length: ns.length - start - 1))
            guard closing.location != NSNotFound else {
                return [Span(range: NSRange(location: offset + start, length: ns.length - start), token: .error)]
            }
            let stringRange = NSRange(location: offset + start, length: closing.location + 1 - start)
            var spans = [Span(range: stringRange, token: .string)]
            spans.append(contentsOf: interpolations(in: ns.substring(with: NSRange(location: start, length: stringRange.length)), offset: offset + start))
            let rest = ns.substring(from: closing.location + 1)
            let restNS = rest as NSString
            let hash = restNS.range(of: "#")
            if hash.location != NSNotFound {
                spans.append(Span(range: NSRange(location: offset + closing.location + 1 + hash.location, length: restNS.length - hash.location), token: .comment))
            } else if !rest.trimmingCharacters(in: .whitespaces).isEmpty {
                spans.append(Span(range: NSRange(location: offset + closing.location + 1, length: restNS.length), token: .error))
            }
            return spans
        }

        // Unquoted: a ` #` starts a trailing comment.
        let commentMarker = ns.range(of: " #", options: [], range: NSRange(location: start, length: ns.length - start))
        let valueEnd = commentMarker.location == NSNotFound ? ns.length : commentMarker.location
        var spans = [Span(range: NSRange(location: offset + start, length: valueEnd - start), token: .value)]
        spans.append(contentsOf: interpolations(in: ns.substring(with: NSRange(location: start, length: valueEnd - start)), offset: offset + start))
        if commentMarker.location != NSNotFound {
            spans.append(Span(range: NSRange(location: offset + commentMarker.location + 1, length: ns.length - commentMarker.location - 1), token: .comment))
        }
        return spans
    }

    private static func interpolations(in text: String, offset: Int) -> [Span] {
        guard let regex = try? NSRegularExpression(pattern: "\\$\\{[^}]*\\}|\\$[A-Za-z_][A-Za-z0-9_]*") else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            Span(range: NSRange(location: offset + $0.range.location, length: $0.range.length), token: .interpolation)
        }
    }

    static func apply(to storage: NSTextStorage, font: NSFont, palette: Palette = .standard) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: palette.value], range: full)
        for span in spans(in: storage.string) {
            guard span.range.location + span.range.length <= storage.length else { continue }
            switch span.token {
            case .key: storage.addAttribute(.foregroundColor, value: palette.key, range: span.range)
            case .string: storage.addAttribute(.foregroundColor, value: palette.string, range: span.range)
            case .value: storage.addAttribute(.foregroundColor, value: palette.value, range: span.range)
            case .comment: storage.addAttribute(.foregroundColor, value: palette.comment, range: span.range)
            case .punctuation: storage.addAttribute(.foregroundColor, value: palette.punctuation, range: span.range)
            case .keyword: storage.addAttribute(.foregroundColor, value: palette.keyword, range: span.range)
            case .interpolation: storage.addAttribute(.foregroundColor, value: palette.interpolation, range: span.range)
            case .error:
                storage.addAttributes([
                    .foregroundColor: palette.error,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: palette.error,
                    .backgroundColor: palette.error.withAlphaComponent(0.12),
                ], range: span.range)
            }
        }
        storage.endEditing()
    }
}

/// `NSTextView` with dotenv colouring and none of the prose helpers: no smart
/// quotes, dashes or spell-check, so `KEY="value"` stays exactly what you typed.
struct EnvHighlightingEditor: NSViewRepresentable {
    @Binding var text: String
    var monospace: Bool

    private var font: NSFont {
        monospace
            ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            : NSFont.systemFont(ofSize: 13)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 12, height: 14)
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        textView.string = text
        context.coordinator.font = font
        context.coordinator.highlight(textView)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        let fontChanged = context.coordinator.font != font
        context.coordinator.font = font
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selection
            context.coordinator.highlight(textView)
        } else if fontChanged {
            textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
            context.coordinator.highlight(textView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, font: font) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>
        var font: NSFont

        init(text: Binding<String>, font: NSFont) {
            self.text = text
            self.font = font
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
            highlight(view)
        }

        func highlight(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            EnvHighlighter.apply(to: storage, font: font)
            view.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        }
    }
}
