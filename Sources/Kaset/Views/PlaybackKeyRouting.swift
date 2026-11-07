import AppKit

// MARK: - PlaybackKeyRouting

/// Which keystrokes the app's own transport answers, rather than the page in the shared WebView.
///
/// The shared player WebView is a view in the main window, and AppKit makes it the first responder when
/// the window appears. `Space` is one of YouTube Music's own shortcuts, so the page answered the key
/// first: its player started or stopped music while Kaset — which never heard the press — kept saying
/// paused, over a song it could not name (see ADR-0027). The app installs a local key monitor, which runs
/// ahead of the responder chain, and this is the rule that monitor applies.
enum PlaybackKeyRouting {
    /// The key code of `Space`.
    static let playPauseKeyCode: UInt16 = 49

    /// Modifiers that say nothing about *which* chord was pressed, so they do not disqualify one.
    /// Caps lock is a state of the keyboard rather than part of a shortcut, and the function and numeric
    /// pad flags describe the event's source.
    static let ignoredModifiers: NSEvent.ModifierFlags = [.capsLock, .numericPad, .function]

    /// Whether this key is the app's play/pause rather than something for the page to type or play.
    ///
    /// - Parameter keyCode: the event's key code.
    /// - Parameter modifierFlags: the event's modifiers, as delivered.
    /// - Parameter isRepeat: whether the key is repeating from a held-down press. Holding play/pause must
    ///   not toggle the transport on every repeat.
    /// - Parameter firstResponder: what holds the keyboard. A text field's space is a space, and a sheet's
    ///   keyboard belongs to the sheet.
    static func answersPlaybackKey(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        isRepeat: Bool,
        firstResponder: NSResponder?
    ) -> Bool {
        guard keyCode == self.playPauseKeyCode, !isRepeat else { return false }

        let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.subtracting(self.ignoredModifiers).isEmpty else { return false }

        return !self.isEditingText(firstResponder)
    }

    /// Whether a key would be typed into text rather than asked of the transport.
    ///
    /// A window's text field hands the keyboard to the shared field editor, which is a text view, so both
    /// shapes are checked.
    static func isEditingText(_ responder: NSResponder?) -> Bool {
        switch responder {
        case is NSTextView, is NSTextField: true
        default: false
        }
    }
}
