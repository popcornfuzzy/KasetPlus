import Foundation

// MARK: - LoadingState

/// Shared loading state for ViewModels.
enum LoadingState {
    case idle
    case loading
    case loaded
    case loadingMore
    case error(LoadingError)
}

// MARK: - LoadingError

/// Wraps error information for display in views.
/// Provides user-friendly messages and retry capability.
struct LoadingError {
    let title: String
    let message: String
    let isRetryable: Bool
    /// Whether the session itself is the problem, so retrying the request cannot help.
    let isAuthExpired: Bool
    let underlyingError: (any Error)?

    /// Creates a LoadingError from any Error.
    init(from error: any Error) {
        if let ytError = error as? YTMusicError {
            self.title = ytError.userFriendlyTitle
            self.message = ytError.userFriendlyMessage
            self.isRetryable = ytError.isRetryable
            self.isAuthExpired = if case .authExpired = ytError { true } else { false }
            self.underlyingError = ytError
        } else if (error as NSError).domain == NSURLErrorDomain {
            self.title = "Connection Error"
            self.message = "Unable to connect. Please check your internet connection."
            self.isRetryable = true
            self.isAuthExpired = false
            self.underlyingError = error
        } else {
            self.title = "Error"
            self.message = error.localizedDescription
            self.isRetryable = true
            self.isAuthExpired = false
            self.underlyingError = error
        }
    }

    /// Creates a LoadingError with a simple message.
    init(message: String, isRetryable: Bool = true) {
        self.title = "Error"
        self.message = message
        self.isRetryable = isRetryable
        self.isAuthExpired = false
        self.underlyingError = nil
    }

    /// Creates a LoadingError with title and message.
    init(title: String, message: String, isRetryable: Bool = true) {
        self.title = title
        self.message = message
        self.isRetryable = isRetryable
        self.isAuthExpired = false
        self.underlyingError = nil
    }
}

// MARK: - LoadingState + Equatable

extension LoadingState: Equatable {
    static func == (lhs: LoadingState, rhs: LoadingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.loaded, .loaded), (.loadingMore, .loadingMore):
            true
        case let (.error(lhsError), .error(rhsError)):
            lhsError.message == rhsError.message
        default:
            false
        }
    }
}

// MARK: - LoadingState + Content

extension LoadingState {
    /// Whether the page has content to keep on screen.
    ///
    /// A dropped connection should not replace a library or feed the reader already has in front of
    /// them; the pages use this to tell "nothing loaded yet" from "loaded, and now offline".
    var hasContent: Bool {
        self == .loaded || self == .loadingMore
    }
}
