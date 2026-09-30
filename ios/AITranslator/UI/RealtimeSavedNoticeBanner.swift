import ShareCore
import SwiftUI

/// Tappable bubble shown after a realtime session ends and its audio was saved to History.
struct RealtimeSavedNoticeBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var preferences = AppPreferences.shared
    let onTap: () -> Void

    private var colors: AppColorPalette {
        AppColors.Palette(colorScheme: colorScheme, accentTheme: preferences.accentTheme)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording saved to History")
                        .font(.subheadline.weight(.semibold))
                    Text("Tap to view")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(colors.divider, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("realtime_saved_notice")
    }
}

private struct RealtimeSavedNoticeModifier: ViewModifier {
    @ObservedObject var store: RealtimeSessionStore
    let onOpenHistory: (UUID) -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let notice = store.savedHistoryNotice {
                    RealtimeSavedNoticeBanner {
                        store.dismissSavedHistoryNotice()
                        onOpenHistory(notice.requestID)
                    }
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notice.id) {
                        try? await Task.sleep(for: .seconds(6))
                        guard !Task.isCancelled else { return }
                        store.dismissSavedHistoryNotice()
                    }
                }
            }
            .animation(.spring(duration: 0.35), value: store.savedHistoryNotice)
    }
}

extension View {
    func realtimeSavedNotice(store: RealtimeSessionStore, onOpenHistory: @escaping (UUID) -> Void) -> some View {
        modifier(RealtimeSavedNoticeModifier(store: store, onOpenHistory: onOpenHistory))
    }
}
