import AppKit
import SwiftUI

// MARK: - ErrorView

/// Reusable error view with title, message, and the action that can actually resolve it.
/// Uses native `ContentUnavailableView` for platform-consistent styling.
@available(macOS 14.0, *)
struct ErrorView: View {
    @Environment(AuthService.self) private var authService: AuthService?

    let title: String
    let message: String
    let isRetryable: Bool
    /// Whether the session expired, in which case the only useful action is signing in again.
    let isAuthExpired: Bool
    let retryAction: (() -> Void)?

    @State private var didCopyDetails = false

    /// Creates an ErrorView with explicit parameters.
    init(
        title: String = String(localized: "Unable to load content"),
        message: String,
        isRetryable: Bool = true,
        isAuthExpired: Bool = false,
        retryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.isRetryable = isRetryable
        self.isAuthExpired = isAuthExpired
        self.retryAction = retryAction
    }

    /// Creates an ErrorView from a LoadingError.
    init(
        error: LoadingError,
        retryAction: (() -> Void)? = nil
    ) {
        self.title = error.title
        self.message = error.message
        self.isRetryable = error.isRetryable
        self.isAuthExpired = error.isAuthExpired
        self.retryAction = retryAction
    }

    var body: some View {
        ContentUnavailableView {
            Label(self.title, systemImage: self.isAuthExpired ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle")
        } description: {
            Text(self.message)
        } actions: {
            if self.isAuthExpired {
                Button(String(localized: "Sign In Again")) {
                    self.authService?.startLogin()
                }
                .buttonStyle(.borderedProminent)
            } else {
                if self.isRetryable, let action = self.retryAction {
                    Button(String(localized: "Try Again")) {
                        action()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(self.didCopyDetails ? String(localized: "Copied") : String(localized: "Copy Details")) {
                    self.copyDetails()
                }
            }
        }
    }

    /// Puts the failure on the clipboard for a bug report, since the message is all the reader can
    /// show a maintainer.
    private func copyDetails() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("\(self.title): \(self.message)", forType: .string)

        self.didCopyDetails = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.didCopyDetails = false
        }
    }
}

#Preview {
    ErrorView(message: "Something went wrong") {
        // No-op for preview
    }
}
