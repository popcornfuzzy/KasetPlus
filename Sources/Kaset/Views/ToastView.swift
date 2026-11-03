// ToastView.swift
// Kaset
//
// A small, quiet notice for actions that would otherwise pass without a word.

import SwiftUI

// MARK: - ToastView

/// A transient confirmation, deliberately understated: a capsule of regular material, one grey glyph,
/// one line of grey text, and — when the action can be taken back — a small grey pill for undo.
@available(macOS 26.0, *)
struct ToastView: View {
    // MARK: - Properties

    /// The message to display in the toast.
    let message: String

    /// Whether this is an error toast. Changes the glyph only; the palette stays quiet.
    var isError: Bool = false

    /// Title of the action that takes the last change back, when the toast has one.
    var undoTitle: String?

    /// Runs when the undo action is chosen.
    var onUndo: (() -> Void)?

    /// Called when the toast should be dismissed.
    var onDismiss: (() -> Void)?

    // MARK: - Body

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: self.isError ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Text(self.message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let undoTitle, let undo = self.onUndo {
                ToastUndoButton(title: undoTitle, action: undo)
            }

            if let dismiss = self.onDismiss {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Dismiss"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
        }
        .glassEffectTransition(.materialize)
        .accessibilityIdentifier(AccessibilityID.Toast.container)
    }
}

// MARK: - ToastUndoButton

/// The undo affordance: a small grey pill that deepens slightly under the pointer.
@available(macOS 26.0, *)
private struct ToastUndoButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            self.action()
        } label: {
            Text(self.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background {
                    Capsule()
                        .fill(Color.secondary.opacity(self.isHovering ? 0.18 : 0.10))
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                self.isHovering = hovering
            }
        }
    }
}

// MARK: - AccountErrorToast

/// A toast that observes AccountService errors and auto-dismisses.
///
/// Add this to MainWindow as an overlay to show account switching errors.
@available(macOS 26.0, *)
struct AccountErrorToast: View {
    @Environment(AccountService.self) private var accountService

    @State private var isVisible = false
    @State private var dismissTask: Task<Void, Never>?

    /// Duration before auto-dismiss in seconds.
    private let autoDismissDelay: Duration = .seconds(4)

    var body: some View {
        Group {
            if self.isVisible, let error = accountService.lastError {
                ToastView(
                    message: self.errorMessage(for: error),
                    isError: true,
                    onDismiss: { self.dismiss() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: self.isVisible)
        .onChange(of: self.accountService.errorSequence) { _, _ in
            if self.accountService.lastError != nil {
                self.show()
            }
        }
    }

    // MARK: - Private Methods

    private func errorMessage(for error: Error) -> String {
        if let ytError = error as? YTMusicError {
            return ytError.localizedDescription
        }
        // Use appropriate message based on error context
        if self.accountService.lastErrorWasFetch {
            return String(localized: "Failed to load accounts. Please try again.")
        }
        return String(localized: "Failed to switch account. Please try again.")
    }

    private func show() {
        // Cancel any existing dismiss task
        self.dismissTask?.cancel()

        self.isVisible = true

        // Schedule auto-dismiss
        self.dismissTask = Task {
            try? await Task.sleep(for: self.autoDismissDelay)
            if !Task.isCancelled {
                await MainActor.run {
                    self.dismiss()
                }
            }
        }
    }

    private func dismiss() {
        self.isVisible = false
        self.accountService.clearError()
        self.dismissTask?.cancel()
        self.dismissTask = nil
    }
}

// MARK: - AppToastOverlay

/// Renders whatever transient feedback `ToastCenter` currently holds.
@available(macOS 26.0, *)
struct AppToastOverlay: View {
    @State private var center = ToastCenter.shared

    var body: some View {
        Group {
            if let toast = self.center.current {
                ToastView(
                    message: toast.message,
                    isError: toast.isError,
                    undoTitle: toast.undoTitle,
                    onUndo: toast.undo == nil ? nil : { self.center.undoCurrent() },
                    onDismiss: { self.center.dismiss() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: self.center.current?.id)
    }
}

// MARK: - AccessibilityID.Toast

extension AccessibilityID {
    enum Toast {
        static let container = "toast.container"
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview("Toast with undo") {
    ToastView(
        message: "Added to Late Night",
        undoTitle: "Undo",
        onUndo: {},
        onDismiss: {}
    )
    .padding()
}

@available(macOS 26.0, *)
#Preview("Error toast") {
    ToastView(message: "Failed to switch account. Please try again.", isError: true) {
        DiagnosticsLogger.ui.debug("Toast dismissed")
    }
    .padding()
}
