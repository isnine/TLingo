import SwiftUI

/// A horizontal scrollable row of image thumbnails with delete buttons.
/// Shared across HomeView, MenuBarPopoverView, and ConversationInputBar.
public struct ImageAttachmentPreview: View {
    let images: [ImageAttachment]
    let onRemove: (UUID) -> Void

    public init(images: [ImageAttachment], onRemove: @escaping (UUID) -> Void) {
        self.images = images
        self.onRemove = onRemove
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { attachment in
                    ImageThumbnailView(attachment: attachment, onRemove: onRemove)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}

/// A single image thumbnail with a delete (X) button.
/// Uses ZStack instead of overlay+offset so the button's hit-test area
/// stays within the layout bounds (fixes taps failing in tight containers).
private struct ImageThumbnailView: View {
    let attachment: ImageAttachment
    let onRemove: (UUID) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            attachment.thumbnailImage
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.top, 8)
                .padding(.trailing, 8)

            Button {
                onRemove(attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Inline thumbnail images for displaying in message bubbles (no delete button).
public struct ImageAttachmentInline: View {
    let images: [ImageAttachment]

    public init(images: [ImageAttachment]) {
        self.images = images
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(images) { attachment in
                    attachment.thumbnailImage
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
