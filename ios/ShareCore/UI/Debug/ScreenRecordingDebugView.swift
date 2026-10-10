#if os(macOS)
    import AppKit
    import CoreGraphics
    import Security
    import SwiftUI

    /// Shows which TLingo copy is running and whether its signature can keep a
    /// Screen Recording grant. TCC stores one grant per bundle ID bound to a code
    /// requirement, so another copy with a different signature reads as denied.
    public struct ScreenRecordingDebugView: View {
        @State private var snapshot = Snapshot.current()
        @State private var copiedItem: String?

        public init() {}

        public var body: some View {
            Form {
                Section {
                    row("Preflight", snapshot.isGranted ? "Granted" : "Not granted")
                    row("Running copy", snapshot.bundlePath)
                    row("Version", snapshot.version)
                    row("Team", snapshot.teamIdentifier ?? "None")
                    row("Requirement", snapshot.designatedRequirement ?? "Unavailable")
                    if snapshot.isAdHoc {
                        Text(verbatim: "Ad-hoc signature: the grant is bound to this exact binary and is lost on every rebuild.")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text(verbatim: "This Process")
                }

                Section {
                    ForEach(snapshot.registeredCopies, id: \.self) { path in
                        HStack {
                            Text(verbatim: path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                            if path == snapshot.bundlePath {
                                Text(verbatim: "Running")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.green)
                            }
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text(verbatim: "Registered Copies (\(snapshot.registeredCopies.count))")
                } footer: {
                    Text(verbatim: "All copies share one Screen Recording entry in System Settings. Grant it from the copy you run, then relaunch that copy.")
                }

                Section {
                    Button("Request Access" as String) {
                        CGRequestScreenCaptureAccess()
                        refresh()
                    }
                    Button("Open Screen Recording Settings" as String) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Relaunch This Copy" as String, action: relaunch)
                    copyButton("Copy Reset Command", "tccutil reset ScreenCapture \(Bundle.main.bundleIdentifier ?? "")")
                    copyButton("Copy Diagnostics", snapshot.report)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(verbatim: "Screen Recording"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh" as String, systemImage: "arrow.clockwise", action: refresh)
                }
            }
        }

        private func refresh() {
            snapshot = .current()
            copiedItem = nil
        }

        /// Opens the bundle only after this process has exited, so a quit that
        /// fails or stalls never leaves two copies running.
        private func relaunch() {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = [
                "-c",
                "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                "relaunch",
                String(ProcessInfo.processInfo.processIdentifier),
                Bundle.main.bundleURL.path,
            ]
            do {
                try task.run()
                NSApp.terminate(nil)
            } catch {
                NSSound.beep()
            }
        }

        private func copyButton(_ title: String, _ text: String) -> some View {
            Button(copiedItem == title ? "Copied" : title) {
                PasteboardHelper.copy(text)
                copiedItem = title
            }
        }

        private func row(_ title: String, _ value: String) -> some View {
            LabeledContent {
                Text(verbatim: value)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            } label: {
                Text(verbatim: title)
            }
        }
    }

    private struct Snapshot {
        var isGranted: Bool
        var bundlePath: String
        var version: String
        var teamIdentifier: String?
        var designatedRequirement: String?
        var registeredCopies: [String]

        var isAdHoc: Bool {
            designatedRequirement?.contains("cdhash") == true
        }

        var report: String {
            ([
                "preflight: \(isGranted)",
                "running: \(bundlePath)",
                "version: \(version)",
                "team: \(teamIdentifier ?? "none")",
                "requirement: \(designatedRequirement ?? "unavailable")",
                "registered copies:",
            ] + registeredCopies.map { "  \($0)" }).joined(separator: "\n")
        }

        static func current() -> Snapshot {
            let bundle = Bundle.main
            let info = bundle.infoDictionary ?? [:]
            let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
            let copies = bundle.bundleIdentifier.map {
                NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0).map(\.standardizedFileURL.path)
            } ?? []
            let signing = signingInfo()
            return Snapshot(
                isGranted: CGPreflightScreenCaptureAccess(),
                bundlePath: bundle.bundleURL.standardizedFileURL.path,
                version: version,
                teamIdentifier: signing.team,
                designatedRequirement: signing.requirement,
                registeredCopies: copies
            )
        }

        private static func signingInfo() -> (team: String?, requirement: String?) {
            var code: SecCode?
            var staticCode: SecStaticCode?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
                  SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
            else { return (nil, nil) }

            var info: CFDictionary?
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String

            var requirement: SecRequirement?
            var text: CFString?
            if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement {
                SecRequirementCopyString(requirement, [], &text)
            }
            return (team, text as String?)
        }
    }
#endif
