import SwiftUI

struct CompactMarkdownContent: View {
    let text: String

    var body: some View {
        MarkdownContentView(text: text, preset: .compact)
    }
}
