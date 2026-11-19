import SwiftUI

struct CompactMarkdownContent: View {
    let text: String
    var timingTrace: TranslationTimingTrace?

    var body: some View {
        MarkdownContentView(text: text, preset: .compact, timingTrace: timingTrace)
    }
}
