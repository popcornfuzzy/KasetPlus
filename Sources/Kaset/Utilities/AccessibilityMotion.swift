import AppKit
import Observation

/// The accessibility display setting the app's animations consult.
///
/// Read through an `@Observable` rather than querying `NSWorkspace` inside a view body, for two
/// reasons. The query is an AppKit round trip on every body evaluation, and artwork views are
/// evaluated constantly. More importantly, a view that only reads the setting inside its own body
/// never re-renders when it changes, so turning Reduce Motion on took effect only whenever something
/// else happened to redraw the view; observing it means the change lands immediately.
@MainActor
@Observable
final class AccessibilityMotion {
    static let shared = AccessibilityMotion()

    /// Whether the user asked the system to reduce motion.
    private(set) var reduceMotion: Bool

    private var observer: (any NSObjectProtocol)?

    private init() {
        self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        self.observer = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AccessibilityMotion.shared.reduceMotion =
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }
}
