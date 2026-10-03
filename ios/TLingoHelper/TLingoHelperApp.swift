import AppKit
import SwiftUI

@main
struct TLingoHelperApp: App {
    @NSApplicationDelegateAdaptor(HelperAppDelegate.self) private var appDelegate
    @StateObject private var model = HelperModel()

    var body: some Scene {
        MenuBarExtra {
            HelperMenu(model: model)
        } label: {
            Image(systemName: model.state.symbol)
        }

        Window("TLingoHelper", id: HelperSettingsView.windowID) {
            HelperSettingsView(model: model, permissionManager: model.permissionManager)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        // A menu bar helper only needs a window when setup is incomplete.
        .defaultLaunchBehavior(AXIsProcessTrusted() ? .suppressed : .presented)
    }
}

final class HelperAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}

// MARK: - Menu

private struct HelperMenu: View {
    @ObservedObject var model: HelperModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.state.title)
        Toggle("Text Selection Translation", isOn: Binding(get: { model.isEnabled }, set: model.setEnabled))
        if model.state == .needsAccessibility {
            Button("Grant Accessibility Access…") {
                openSettings()
                model.permissionManager.openAccessibilitySettings()
            }
        }
        Divider()
        Button("Open TLingo") { TLingoLink.openTLingo() }
        Button("Settings…") { openSettings() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit TLingoHelper") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openSettings() {
        openWindow(id: HelperSettingsView.windowID)
        NSApp.activate()
    }
}

// MARK: - Settings

struct HelperSettingsView: View {
    static let windowID = "settings"

    @ObservedObject var model: HelperModel
    @ObservedObject var permissionManager: AccessibilityPermissionManager

    var body: some View {
        Form {
            Section {
                header
            }

            Section {
                Toggle(isOn: Binding(get: { model.isEnabled }, set: model.setEnabled)) {
                    Text("Text Selection Translation")
                    StatusText(state: model.state)
                }
                Toggle("Open at Login", isOn: Binding(get: { model.opensAtLogin }, set: model.setOpensAtLogin))
            }

            Section {
                accessibilityRow
            } header: {
                Text("Permission")
            } footer: {
                if !model.isAccessibilityGranted {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Turn on TLingoHelper, not TLingo, in Privacy & Security › Accessibility.")
                        if permissionManager.showsReplacementHint {
                            Text("If TLingoHelper is already listed, remove it with − and add it again.")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                tlingoRow
            } header: {
                Text("TLingo")
            } footer: {
                Text("Text is sent to TLingo only when you click the dot. Translation, history and subscriptions stay in TLingo.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            model.refreshTLingoStatus()
            NSApp.activate()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("TLingoHelper")
                    .font(.title2.weight(.semibold))
                Text("Select text in any app, then click the dot to translate it with TLingo.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var accessibilityRow: some View {
        LabeledContent {
            if model.isAccessibilityGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant Access…") {
                    permissionManager.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
            }
        } label: {
            Text("Accessibility")
            Text("Reads the text you select in other apps.")
        }
    }

    private var tlingoRow: some View {
        LabeledContent {
            Button("Open TLingo") { TLingoLink.openTLingo() }
                .disabled(model.tlingoStatus == .notInstalled)
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: tlingoIcon)
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "TLingo")
                    tlingoStatusText
                        .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private var tlingoStatusText: some View {
        switch model.tlingoStatus {
        case let .running(application):
            Text("Running \(version(of: application.bundleURL))")
                .foregroundStyle(.secondary)
        case .installed:
            Text("Opens in the background when you translate")
                .foregroundStyle(.secondary)
        case .needsUpdate:
            Text("Update TLingo to use it with TLingoHelper.")
                .foregroundStyle(.orange)
        case .notInstalled:
            Text("Install TLingo to translate selected text.")
                .foregroundStyle(.red)
        }
    }

    private var tlingoIcon: NSImage {
        let url: URL? = switch model.tlingoStatus {
        case let .running(application): application.bundleURL
        case let .installed(url): url
        case .needsUpdate, .notInstalled: nil
        }
        return url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!
    }

    private func version(of url: URL?) -> String {
        url.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String } ?? ""
    }
}

private struct StatusText: View {
    let state: HelperModel.State

    var body: some View {
        Label {
            Text(state.title)
        } icon: {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
    }

    private var color: Color {
        switch state {
        case .paused: .secondary
        case .needsAccessibility: .orange
        case .ready: .green
        }
    }
}
