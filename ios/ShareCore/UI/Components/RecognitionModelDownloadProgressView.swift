import SwiftUI

public struct RecognitionModelDownloadProgressView: View {
    public let status: RecognitionModelDownloadStatus

    public init(status: RecognitionModelDownloadStatus) {
        self.status = status
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(status.phaseDescription)
                Spacer(minLength: 8)
                if status.phase != .preparing {
                    Text(status.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            }
            if status.phase == .preparing {
                ProgressView()
                    .controlSize(.small)
            } else {
                ProgressView(value: status.fractionCompleted)
            }
            if !status.transferDescription.isEmpty {
                Text(status.transferDescription)
                    .monospacedDigit()
            }
            if let remaining = status.remainingDescription {
                Text(remaining)
            }
        }
        .font(.caption)
        .foregroundStyle(Color.secondary)
        .accessibilityElement(children: .combine)
    }
}
