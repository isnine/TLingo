import Combine
import Foundation

/// Smoothed input level for listening indicators. Kept separate from `RealtimeSessionStore`
/// so frequent level updates only redraw the views that observe it.
@MainActor
public final class RealtimeInputLevel: ObservableObject {
    /// Speech usually sits between these bounds; mapping the full dBFS range would leave
    /// normal speech in the middle of the meter. Room noise stays below the floor, so silence
    /// reads as a flat, still meter.
    private static let floorDecibels: Float = -50
    private static let ceilingDecibels: Float = -20
    /// Below this, the signal is silence or room noise rather than speech.
    private static let audibleDecibels: Float = -52
    /// Speech peaking only below this for the whole window is too faint to recognize reliably.
    private static let faintPeakDecibels: Float = -40
    private static let faintWindow: TimeInterval = 3

    /// 0...1, rises quickly and decays slowly like a VU meter.
    @Published public private(set) var fraction: Double = 0
    /// True when sound is present but has stayed faint for a few seconds.
    @Published public private(set) var isFaint = false

    private var faintWindowStart: Date?
    private var faintWindowPeak: Float = -.infinity

    public init() {}

    func update(decibels: Float?, now: Date = Date()) {
        guard let decibels else {
            reset()
            return
        }

        let target = Double(
            (min(max(decibels, Self.floorDecibels), Self.ceilingDecibels) - Self.floorDecibels)
                / (Self.ceilingDecibels - Self.floorDecibels)
        )
        let smoothing = target > fraction ? 0.6 : 0.2
        var next = fraction + (target - fraction) * smoothing
        // The decay is asymptotic; snap to zero so silence stops the animation.
        if target == 0, next < 0.02 { next = 0 }
        if abs(next - fraction) > 0.005 {
            fraction = next
        }

        updateFaintState(decibels: decibels, now: now)
    }

    func reset() {
        if fraction != 0 { fraction = 0 }
        if isFaint { isFaint = false }
        faintWindowStart = nil
        faintWindowPeak = -.infinity
    }

    private func updateFaintState(decibels: Float, now: Date) {
        if decibels >= Self.faintPeakDecibels {
            // Clearly audible speech: restart the window.
            faintWindowStart = nil
            faintWindowPeak = -.infinity
            if isFaint { isFaint = false }
            return
        }

        let windowStart = faintWindowStart ?? now
        faintWindowStart = windowStart
        faintWindowPeak = max(faintWindowPeak, decibels)
        guard now.timeIntervalSince(windowStart) >= Self.faintWindow else { return }

        let faint = faintWindowPeak >= Self.audibleDecibels
        if isFaint != faint { isFaint = faint }
        faintWindowStart = now
        faintWindowPeak = -.infinity
    }
}
