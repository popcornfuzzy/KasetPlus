import Foundation

// MARK: - LyricsAnimationStyle

/// How a word-synced lyric line lights up as it is sung.
///
/// Two looks, because they answer different questions. `appleMusic` is the wipe the panel and the
/// player shipped with: a softly feathered gradient, a halo, and one slow crest of emphasis riding
/// the fill edge. `betterLyrics` ports the combined swipe, word wobble and staggered per-letter
/// wave of the Better Lyrics renderer (<https://github.com/better-lyrics/better-lyrics>; its engine
/// lives in <https://github.com/better-lyrics/braccato>), where a word moves as it is sung and a
/// word held for a long time details itself differently from a short one.
///
/// Both are drawn from the same word timings and the same measured layout; only the envelopes and
/// the layers they are drawn with differ (`RichLyricsAnimation` against `KaraokeFillModel`). See
/// [ADR-0036](../../docs/adr/0036-lyrics-word-animation-styles.md).
enum LyricsAnimationStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Better Lyrics' rich-sync look: a crisp highlight that overshoots each word, a small pop of
    /// the whole word, and a wave through its letters.
    case betterLyrics

    /// Apple Music's look: a soft feathered wipe, a halo, and one crest of emphasis per word.
    case appleMusic

    /// The style a reader gets before choosing one.
    static let standard: LyricsAnimationStyle = .betterLyrics

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .betterLyrics: String(localized: "Better Lyrics")
        case .appleMusic: String(localized: "Apple Music")
        }
    }

    var detail: String {
        switch self {
        case .betterLyrics:
            String(localized: "A crisp highlight that sweeps each word, a small pop, and a wave through its letters that swells on a word held a long time.")
        case .appleMusic:
            String(localized: "A soft sweep with a glow, and one slow rise per word.")
        }
    }
}
