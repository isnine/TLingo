#if os(macOS)
    import AppKit
    import Carbon
    import ShareCore

    /// Consumes popup URLs before AppKit hands them to SwiftUI, which would activate a main window.
    /// Every other Get URL event is forwarded to the previously installed handler.
    @MainActor
    final class PopupURLEventRouter {
        private var previousHandler: AEEventHandlerUPP?
        private var previousRefCon: UnsafeMutableRawPointer?
        private let onPopupURL: (URL) -> Void

        init(onPopupURL: @escaping (URL) -> Void) {
            self.onPopupURL = onPopupURL
        }

        /// The router must stay alive for the rest of the process once installed.
        func install() throws {
            let eventClass = AEEventClass(kInternetEventClass)
            let eventID = AEEventID(kAEGetURL)
            var status = AEGetEventHandler(eventClass, eventID, &previousHandler, &previousRefCon, false)
            if status == noErr {
                let context = Unmanaged.passUnretained(self).toOpaque()
                status = AEInstallEventHandler(eventClass, eventID, Self.callback, context, false)
            }
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }

        private static let callback: AEEventHandlerUPP = { event, reply, context in
            guard let event, let context else { return OSErr(errAEEventNotHandled) }
            return MainActor.assumeIsolated {
                Unmanaged<PopupURLEventRouter>.fromOpaque(context).takeUnretainedValue().handle(event, reply: reply)
            }
        }

        private func handle(_ event: UnsafePointer<AppleEvent>, reply: UnsafeMutablePointer<AppleEvent>?) -> OSErr {
            var copy = AEDesc()
            if AEDuplicateDesc(event, &copy) == noErr {
                let descriptor = NSAppleEventDescriptor(aeDescNoCopy: &copy)
                if let rawURL = descriptor.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
                   let url = URL(string: rawURL), TextPopupRequest.isPopupURL(url)
                {
                    onPopupURL(url)
                    return OSErr(noErr)
                }
            }
            guard let previousHandler else { return OSErr(errAEEventNotHandled) }
            return previousHandler(event, reply, previousRefCon)
        }
    }
#endif
