import Foundation
import Observation

// MARK: - ToastCenter

/// App-wide transient feedback for actions that would otherwise succeed silently.
///
/// One toast is visible at a time; a new one replaces the last. A toast may carry an undo closure,
/// which is what lets a reversible action (removing a favorite, for instance) be taken back without
/// hunting for the item again.
@MainActor
@Observable
final class ToastCenter {
    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        var isError = false
        var undoTitle: String?
        var undo: (() -> Void)?
    }

    static let shared = ToastCenter()

    /// The toast currently on screen, if any.
    private(set) var current: Toast?

    /// How long a toast stays before it dismisses itself.
    static var displayDuration: Duration = .seconds(4)

    private var dismissTask: Task<Void, Never>?

    func show(
        _ message: String,
        isError: Bool = false,
        undoTitle: String? = nil,
        undo: (() -> Void)? = nil
    ) {
        self.dismissTask?.cancel()

        let toast = Toast(
            message: message,
            isError: isError,
            undoTitle: undoTitle,
            undo: undo
        )
        self.current = toast

        self.dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.displayDuration)
            guard !Task.isCancelled else { return }
            self?.dismiss(id: toast.id)
        }
    }

    func dismiss() {
        self.dismissTask?.cancel()
        self.dismissTask = nil
        self.current = nil
    }

    /// Runs the visible toast's undo, if it has one.
    func undoCurrent() {
        let undo = self.current?.undo
        self.dismiss()
        undo?()
    }

    // MARK: - Private

    private func dismiss(id: UUID) {
        guard self.current?.id == id else { return }
        self.current = nil
        self.dismissTask = nil
    }
}
