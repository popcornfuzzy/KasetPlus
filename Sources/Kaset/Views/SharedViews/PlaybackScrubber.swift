import SwiftUI

/// The app's playback scrubber: Apple Music's thin bar with no knob, and a bar that swells under a
/// drag and settles back.
///
/// One implementation for both surfaces that scrub — the fullscreen player and the player bar — so
/// their behaviour cannot drift apart. The owner keeps the position: `value` is what it follows
/// playback with and what a drag writes, exactly as it would a `Slider`'s.
@available(macOS 26.0, *)
struct PlaybackScrubber: View {
    /// Where the times sit relative to the bar.
    enum TimePlacement {
        /// Above the bar, at its two ends — the fullscreen player.
        case above
        /// Beside the bar, one at either end — the player bar.
        case beside
    }

    /// Played fraction of the track, 0...1.
    @Binding var value: Double
    /// Length of the track, so a drag can be read back as a position and the remaining time can be
    /// worked out.
    var duration: TimeInterval = 0
    /// Colour of the bar. The times are drawn in ``labelColor``.
    var tint: Color = .primary
    var labelColor: Color = .secondary
    var timePlacement: TimePlacement = .above
    /// Time formatting, so each surface keeps its own — the player bar shows hours on long items.
    var formatTime: @MainActor (TimeInterval) -> String = PlaybackScrubber.minutesAndSeconds
    var accessibilityLabel: String = String(localized: "Playback Position")
    var accessibilityIdentifier: String?
    /// Called when a drag starts (`true`) and ends (`false`), like `Slider`'s editing callback.
    var onEditingChanged: @MainActor (Bool) -> Void = { _ in }

    @State private var isDragging = false
    @State private var isHovering = false

    private var fraction: Double { min(max(self.value, 0), 1) }
    private var elapsed: TimeInterval { self.fraction * self.duration }

    var body: some View {
        Group {
            switch self.timePlacement {
            case .above: self.stacked
            case .beside: self.beside
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.accessibilityLabel)
        .accessibilityValue("\(self.formatTime(self.elapsed)) / \(self.formatTime(self.duration))")
        .ifLet(self.accessibilityIdentifier) { view, identifier in
            view.accessibilityIdentifier(identifier)
        }
        // A bar with no knob still has to be reachable without a pointer.
        .accessibilityAdjustableAction { direction in
            guard self.duration > 0 else { return }
            let step = 5 / self.duration
            switch direction {
            case .increment: self.value = min(1, self.fraction + step)
            case .decrement: self.value = max(0, self.fraction - step)
            @unknown default: return
            }
            self.onEditingChanged(false)
        }
    }

    /// Times in a row above the bar, one at each end.
    private var stacked: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                self.elapsedLabel
                Spacer(minLength: 0)
                self.remainingLabel
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(self.labelColor)
            .monospacedDigit()

            self.bar
        }
    }

    /// Times either side of the bar, which is what the player bar has room for.
    private var beside: some View {
        HStack(spacing: 12) {
            self.elapsedLabel
                .frame(minWidth: 45, alignment: .trailing)
            self.bar
            self.remainingLabel
                .frame(minWidth: 45, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(self.labelColor)
        .monospacedDigit()
    }

    private var elapsedLabel: some View { Text(self.formatTime(self.elapsed)) }

    private var remainingLabel: some View { Text(self.formatTime(max(0, self.duration - self.elapsed))) }

    private var bar: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            // Nothing is drawn at the ends of the bar, so a drag has to be able to land anywhere on
            // it: the bar itself is the target.
            let barHeight: CGFloat = self.isDragging ? 9 : (self.isHovering ? 6 : 4)
            ZStack(alignment: .leading) {
                Capsule().fill(self.tint.opacity(0.24)).frame(height: barHeight)
                Capsule().fill(self.tint).frame(width: width * self.fraction, height: barHeight)
            }
            .frame(width: width, height: 12, alignment: .leading)
            // Hovering thickens the bar before it is grabbed, so the bar answers the pointer the way
            // a control does rather than waiting for the drag.
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: barHeight)
            .contentShape(Rectangle())
            .gesture(self.scrubGesture(width: width))
            .onHover { hovering in self.isHovering = hovering }
        }
        .frame(height: 12)
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard self.duration > 0 else { return }
                if !self.isDragging {
                    self.isDragging = true
                    self.onEditingChanged(true)
                }
                self.value = min(max(gesture.location.x / width, 0), 1)
            }
            .onEnded { _ in
                guard self.isDragging else { return }
                self.isDragging = false
                self.onEditingChanged(false)
            }
    }

    static func minutesAndSeconds(_ time: TimeInterval) -> String {
        guard time.isFinite, time > 0 else { return "0:00" }
        let totalSeconds = Int(time)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
