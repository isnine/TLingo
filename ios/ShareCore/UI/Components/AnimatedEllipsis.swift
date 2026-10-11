//
//  AnimatedEllipsis.swift
//  ShareCore
//

import SwiftUI

/// Three dots that grow and shrink while a model is still producing output.
public struct AnimatedEllipsis: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let stepInterval: TimeInterval = 0.35
    private static let visibleCounts = [1, 2, 3, 2]

    public init() {}

    public var body: some View {
        TimelineView(.periodic(from: .now, by: Self.stepInterval)) { context in
            let visibleCount = reduceMotion ? 3 : Self.visibleCount(at: context.date)
            // Hidden dots keep their width so neighbouring text does not shift.
            HStack(spacing: 0) {
                ForEach(0 ..< 3, id: \.self) { index in
                    Text(verbatim: ".")
                        .opacity(index < visibleCount ? 1 : 0)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Generating..."))
    }

    private static func visibleCount(at date: Date) -> Int {
        let step = Int(date.timeIntervalSinceReferenceDate / stepInterval)
        return visibleCounts[step % visibleCounts.count]
    }
}
