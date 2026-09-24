import SwiftUI

public struct LocalLogView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @State private var fileURL: URL?
    @State private var errorMessage: String?
    @State private var copied = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("This local file is also used for email feedback.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let fileURL {
                    Text(fileURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("local_log_text")
            }
            .padding()
        }
        .navigationTitle("Local Log")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(copied ? "Copied" : "Copy Log", systemImage: "doc.on.doc") {
                    PasteboardHelper.copy(text)
                    copied = true
                }
                .disabled(fileURL == nil)
                .accessibilityIdentifier("local_log_copy")

                if let fileURL {
                    ShareLink(item: fileURL) {
                        Label("Share Log", systemImage: "square.and.arrow.up")
                    }
                }

                Button("Refresh", systemImage: "arrow.clockwise", action: reload)
                    .accessibilityIdentifier("local_log_refresh")
            }
        }
        .task { reload() }
        .refreshable { reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                reload()
            }
        }
    }

    private func reload() {
        do {
            let url = try NetworkRequestLogger.shared.writeLocalLog()
            text = try String(contentsOf: url, encoding: .utf8)
            fileURL = url
            errorMessage = nil
            copied = false
        } catch {
            fileURL = nil
            text = ""
            errorMessage = error.localizedDescription
        }
    }
}
