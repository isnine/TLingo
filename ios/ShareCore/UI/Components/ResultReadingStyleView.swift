import SwiftUI
import UniformTypeIdentifiers

public struct ResultReadingStyleView: View {
    struct OnlineFont: Identifiable {
        let name: String
        let detail: LocalizedStringKey
        let url: URL

        var id: String {
            name
        }
    }

    static let onlineFonts: [OnlineFont] = [
        OnlineFont(
            name: "LXGW WenKai",
            detail: "Chinese · Handwritten",
            url: URL(string: "https://github.com/lxgw/LxgwWenKai/releases/latest/download/LXGWWenKai-Regular.ttf")!
        ),
        OnlineFont(
            name: "Noto Sans SC",
            detail: "Chinese · Sans Serif",
            url: URL(string: "https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf")!
        ),
        OnlineFont(
            name: "Noto Serif SC",
            detail: "Chinese · Serif",
            url: URL(string: "https://raw.githubusercontent.com/google/fonts/main/ofl/notoserifsc/NotoSerifSC%5Bwght%5D.ttf")!
        ),
        OnlineFont(
            name: "Inter",
            detail: "Latin · Sans Serif",
            url: URL(string: "https://raw.githubusercontent.com/google/fonts/main/ofl/inter/Inter%5Bopsz,wght%5D.ttf")!
        ),
        OnlineFont(
            name: "JetBrains Mono",
            detail: "Latin · Monospaced",
            url: URL(string: "https://raw.githubusercontent.com/google/fonts/main/ofl/jetbrainsmono/JetBrainsMono%5Bwght%5D.ttf")!
        ),
    ]

    private let previewText: String
    private let embedsInNavigationStack: Bool

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = ResultFontLibrary.shared
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var downloadingFonts: Set<String> = []

    public init(previewText: String = "", embedsInNavigationStack: Bool = true) {
        self.previewText = previewText
        self.embedsInNavigationStack = embedsInNavigationStack
    }
    @ThemeColors private var colors: AppColorPalette

    private var sampleText: String {
        previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Tomorrow is another day.\n明天又是新的一天。"
            : String(previewText.prefix(600))
    }

    public var body: some View {
        if embedsInNavigationStack {
            NavigationStack {
                content
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 440, idealWidth: 480, minHeight: 640, idealHeight: 740)
            #endif
        } else {
            content
        }
    }

    private var content: some View {
            VStack(spacing: 0) {
                preview
                Form {
                    Section("Text Size") {
                        HStack {
                            Text("Text Size")
                            Spacer()
                            Text("\(Int(library.style.textSize)) pt")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Stepper("Text Size", value: $library.style.textSize, in: ResultFontLibrary.textSizeRange)
                                .labelsHidden()
                        }
                        Slider(value: $library.style.textSize, in: ResultFontLibrary.textSizeRange, step: 1)
                            .accessibilityLabel("Text Size")
                            .accessibilityIdentifier("result_text_size_slider")
                    }

                    Section {
                        fontRow(name: String(localized: "System Default"), postScriptName: nil)
                        ForEach(library.fonts) { font in
                            fontRow(name: font.displayName, postScriptName: font.postScriptName)
                                .contextMenu {
                                    Button("Remove Font", role: .destructive) {
                                        remove(font)
                                    }
                                }
                                .swipeActions {
                                    Button("Remove Font", role: .destructive) {
                                        remove(font)
                                    }
                                }
                        }
                        Button("Import Font…", systemImage: "square.and.arrow.down") {
                            isImporting = true
                        }
                        .accessibilityIdentifier("result_import_font_button")
                    } header: {
                        Text("Fonts")
                    } footer: {
                        Text(
                            "Import TTF or OTF files from Files. Fonts stay on this device. Missing characters use a fallback font."
                        )
                    }

                    Section {
                        ForEach(Self.onlineFonts) { item in
                            onlineFontRow(item)
                        }
                    } header: {
                        Text("Download Fonts")
                    } footer: {
                        Text("Open-source fonts licensed under the SIL Open Font License. Chinese fonts are about 20 MB.")
                    }

                    Section {
                        Button("Reset Reading Style") {
                            library.style = ResultReadingStyle()
                        }
                        .disabled(library.style == ResultReadingStyle())
                    }
                }
                .formStyle(.grouped)
            }
            .background(colors.background)
            .navigationTitle("Reading Style")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .fileImporter(
                    isPresented: $isImporting,
                    allowedContentTypes: [
                        UTType(filenameExtension: "ttf") ?? .font,
                        UTType(filenameExtension: "otf") ?? .font,
                    ]
                ) { result in
                    do {
                        try library.importFont(from: result.get())
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .alert("Fonts", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: {
                        if !$0 {
                            errorMessage = nil
                        }
                    }
                )) {
                    Button("OK", role: .cancel) { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "")
                }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(library.fonts.first(where: { $0.postScriptName == library.style.fontName })?.displayName
                    ?? String(localized: "System Default"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ScrollView {
                MarkdownContentView(text: sampleText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
            .accessibilityIdentifier("result_font_preview")
        }
        .padding(16)
        .background(colors.cardBackground, in: .rect(cornerRadius: 16))
        .padding(16)
    }

    private func fontRow(name: String, postScriptName: String?) -> some View {
        Button {
            library.style.fontName = postScriptName
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: name)
                        .font(.subheadline.weight(.medium))
                    Text(verbatim: String(sampleText.prefix(90)).replacingOccurrences(of: "\n", with: " "))
                        .font(ResultReadingStyle(fontName: postScriptName).font(size: 16))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: library.style.fontName == postScriptName ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(library.style.fontName == postScriptName ? colors.accent : colors.textSecondary)
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(library.style.fontName == postScriptName ? .isSelected : [])
    }

    private func onlineFontRow(_ item: OnlineFont) -> some View {
        let installed = library.fonts.first { $0.displayName.hasPrefix(item.name) }
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.name)
                    .foregroundStyle(colors.textPrimary)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if downloadingFonts.contains(item.id) {
                ProgressView()
                    .controlSize(.small)
            } else if let installed {
                Button(library.style.fontName == installed.postScriptName ? "In Use" : "Use") {
                    library.style.fontName = installed.postScriptName
                }
                .disabled(library.style.fontName == installed.postScriptName)
            } else {
                Button("Download", systemImage: "arrow.down.circle") {
                    download(item)
                }
                .labelStyle(.iconOnly)
                .font(.title3)
            }
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .combine)
    }

    private func download(_ item: OnlineFont) {
        downloadingFonts.insert(item.id)
        Task {
            defer { downloadingFonts.remove(item.id) }
            do {
                try await library.downloadFont(from: item.url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func remove(_ font: ImportedResultFont) {
        do {
            try library.remove(font)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
