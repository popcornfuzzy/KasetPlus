import AppKit
import Testing

@testable import Kaset

/// `Space` is Kaset's play/pause and also one of YouTube Music's own shortcuts, and the player page is a
/// view in the same window: whether the app hears the key depended on who held focus. The rule the monitor
/// applies is pinned here (see ADR-0027).
@MainActor
struct PlaybackKeyRoutingTests {
    @Test("An unmodified Space is the app's play/pause")
    func answersSpace() {
        #expect(PlaybackKeyRouting.answersPlaybackKey(
            keyCode: 49,
            modifierFlags: [],
            isRepeat: false,
            firstResponder: nil
        ))
        // Caps lock is a keyboard state, not part of the chord.
        #expect(PlaybackKeyRouting.answersPlaybackKey(
            keyCode: 49,
            modifierFlags: [.capsLock],
            isRepeat: false,
            firstResponder: nil
        ))
    }

    @Test("A modified Space belongs to its menu command, not to play/pause")
    func refusesModifiedSpace() {
        for modifier in [NSEvent.ModifierFlags.command, .option, .control, .shift] {
            #expect(!PlaybackKeyRouting.answersPlaybackKey(
                keyCode: 49,
                modifierFlags: modifier,
                isRepeat: false,
                firstResponder: nil
            ))
        }
    }

    @Test("Holding Space does not toggle the transport on every repeat")
    func refusesAutoRepeat() {
        #expect(!PlaybackKeyRouting.answersPlaybackKey(
            keyCode: 49,
            modifierFlags: [],
            isRepeat: true,
            firstResponder: nil
        ))
    }

    @Test("A text field's Space is a Space")
    func leavesTextEditingAlone() {
        for responder: NSResponder in [NSTextView(), NSTextField()] {
            #expect(PlaybackKeyRouting.isEditingText(responder))
            #expect(!PlaybackKeyRouting.answersPlaybackKey(
                keyCode: 49,
                modifierFlags: [],
                isRepeat: false,
                firstResponder: responder
            ))
        }
        #expect(!PlaybackKeyRouting.isEditingText(nil))
        #expect(!PlaybackKeyRouting.isEditingText(NSView()))
    }

    @Test("Only Space is answered")
    func leavesOtherKeysAlone() {
        for keyCode: UInt16 in [0, 36, 53, 123, 124] {
            #expect(!PlaybackKeyRouting.answersPlaybackKey(
                keyCode: keyCode,
                modifierFlags: [],
                isRepeat: false,
                firstResponder: nil
            ))
        }
    }
}
