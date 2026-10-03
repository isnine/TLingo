//
//  AppleScriptGrabber.swift
//  TLingo
//
//  Text selection via AppleScript for Safari and Chromium browsers (Tier 2).
//

#if os(macOS) && (DIRECT_DISTRIBUTION || TLINGO_HELPER)
    import AppKit

    enum AppleScriptGrabber {
        private static let selectionJavaScript = "window.getSelection().toString()"
        private static let chromiumBundleIDs: Set<String> = [
            "com.google.Chrome",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "company.thebrowser.Browser",
        ]

        /// Grab selected text from the frontmost browser using AppleScript + JavaScript.
        /// Chromium browsers require "Allow JavaScript from Apple Events" to be enabled.
        static func grabFromBrowser() async -> String? {
            guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return nil }

            let script: String
            if bundleID == "com.apple.Safari" {
                script = """
                tell application id "\(bundleID)"
                    do JavaScript "\(selectionJavaScript)" in front document
                end tell
                """
            } else if chromiumBundleIDs.contains(bundleID) {
                script = """
                tell application id "\(bundleID)"
                    execute front window's active tab javascript "\(selectionJavaScript)"
                end tell
                """
            } else {
                return nil
            }

            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let appleScript = NSAppleScript(source: script) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    var error: NSDictionary?
                    let result = appleScript.executeAndReturnError(&error)

                    if error != nil {
                        continuation.resume(returning: nil)
                    } else {
                        let text = result.stringValue
                        continuation.resume(returning: text?.isEmpty == false ? text : nil)
                    }
                }
            }
        }
    }
#endif
