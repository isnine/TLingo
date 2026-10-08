//
//  RealtimeLiveActivity.swift
//  TLingoWidgets
//

import ActivityKit
import SwiftUI
import WidgetKit

struct RealtimeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RealtimeActivityAttributes.self) { context in
            RealtimeLockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(nil)
                .widgetURL(URL(string: "tlingo://realtime"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusIcon(isPaused: context.state.isPaused)
                        .font(.title3)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.languagePair)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CaptionText(state: context.state, translationLineLimit: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                StatusIcon(isPaused: context.state.isPaused)
            } compactTrailing: {
                Text(context.state.isPaused ? "Paused" : "Live")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(context.state.isPaused ? Color.secondary : Color.accentColor)
            } minimal: {
                StatusIcon(isPaused: context.state.isPaused)
            }
            .widgetURL(URL(string: "tlingo://realtime"))
        }
    }
}

private struct RealtimeLockScreenView: View {
    let attributes: RealtimeActivityAttributes
    let state: RealtimeActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusIcon(isPaused: state.isPaused)
                Text("Realtime Translation")
                    .font(.footnote.weight(.semibold))
                Spacer(minLength: 8)
                Text(attributes.languagePair)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            CaptionText(state: state, translationLineLimit: 2)
        }
        .padding(16)
    }
}

private struct CaptionText: View {
    let state: RealtimeActivityAttributes.ContentState
    let translationLineLimit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.translation.isEmpty, state.source.isEmpty {
                Text(state.isPaused ? "Paused" : "Listening…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                if !state.translation.isEmpty {
                    Text(state.translation)
                        .font(.body.weight(.medium))
                        .lineLimit(translationLineLimit)
                        .truncationMode(.head)
                }
                if !state.source.isEmpty {
                    Text(state.source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
    }
}

private struct StatusIcon: View {
    let isPaused: Bool

    var body: some View {
        Image(systemName: isPaused ? "pause.circle.fill" : "waveform")
            .foregroundStyle(isPaused ? Color.secondary : Color.accentColor)
            .symbolEffect(.variableColor.iterative, isActive: !isPaused)
    }
}
