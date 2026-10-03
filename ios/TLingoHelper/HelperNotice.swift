import AppKit
import SwiftUI

/// A transient, non-activating notice near the pointer, so failures never steal focus from the user's app.
@MainActor
final class HelperNotice {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, near point: CGPoint = NSEvent.mouseLocation) {
        dismiss()
        let hostingView = NSHostingView(rootView: NoticeView(message: message))
        let size = hostingView.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = hostingView

        var origin = CGPoint(x: point.x - size.width / 2, y: point.y + 14)
        if let frame = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame {
            origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - size.width - 8)
            if origin.y + size.height > frame.maxY {
                origin.y = point.y - size.height - 14
            }
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.dismiss(animated: true)
        }
    }

    func dismiss(animated: Bool = false) {
        hideTask?.cancel()
        hideTask = nil
        guard let panel else { return }
        self.panel = nil
        guard animated else {
            panel.close()
            return
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.close()
        }
    }
}

private struct NoticeView: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 320)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(6)
    }
}
