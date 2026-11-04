import Foundation

// MARK: - LyricsSearchInfo

/// Information needed to search for lyrics.
struct LyricsSearchInfo: Sendable {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval? // seconds
    let videoId: String
}

// MARK: - LyricsCapability

/// Fidelity of a lyrics result, from lowest to highest. Providers declare the
/// best they can produce so the search knows whether a higher-quality result
/// might still arrive while a lower-quality one is already on screen.
///
/// - `plain`: Untimed plain-text lyrics.
/// - `line`: Line-synced lyrics (timestamps per line, no word timings).
/// - `word`: Word-synced lyrics (per-word timings for karaoke display).
enum LyricsCapability: Int, Comparable, Sendable {
    case plain = 0
    case line = 1
    case word = 2

    static func < (lhs: LyricsCapability, rhs: LyricsCapability) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - LyricsProvider

/// Protocol all lyrics providers conform to.
protocol LyricsProvider: Sendable {
    var name: String { get }

    /// Highest fidelity this provider is capable of returning. Used to decide
    /// whether a better result may still arrive after the first one is shown.
    var capability: LyricsCapability { get }

    func search(info: LyricsSearchInfo) async -> LyricResult
}

// MARK: - LyricsVariant

/// An alternative version of a song's lyrics that the user can switch to.
///
/// Only providers backed by community submissions (currently Unison) produce
/// these — a song can have several synced versions of differing fidelity, and
/// the highest-ranked one is not always the one a listener wants.
struct LyricsVariant: Identifiable, Equatable, Sendable {
    /// Provider-scoped identifier, stable for the lifetime of the variant list.
    let id: String

    /// Short label for the variant picker (e.g. `"Word-synced · username"`).
    let label: String

    /// The lyrics this variant renders, including its attribution.
    let result: LyricResult

    /// Net community votes for this version, when the provider reports them.
    var voteCount: Int? = nil

    /// The listener's own vote on this version, when the provider reports it.
    var userVote: LyricsVoteDirection? = nil
}

// MARK: - LyricsVariantProvider

/// A lyrics provider that can list alternative versions of a track's lyrics.
///
/// The service asks only the provider that produced the displayed result, so a
/// provider that wins a search can advertise what else it has for that song.
protocol LyricsVariantProvider: LyricsProvider {
    /// Every alternative this provider has for the track, best-ranked first.
    func variants(for info: LyricsSearchInfo) async -> [LyricsVariant]
}

// MARK: - LyricsVoteProvider

/// A lyrics provider whose community lets listeners vote on a version.
///
/// A vote is a write, and Unison authenticates writes with a signed key, so the
/// provider also answers how *this* listener voted. Only Unison implements it.
protocol LyricsVoteProvider: LyricsProvider {
    /// The record's community standing, including this listener's own vote.
    /// `nil` when the provider no longer serves that record.
    func voteState(lyricsID: Int) async throws -> LyricsVoteState?

    /// Records `direction`, or removes the listener's vote when it is `nil`.
    func vote(_ direction: LyricsVoteDirection?, lyricsID: Int) async throws
}

// MARK: - Result capability

extension LyricResult {
    /// Fidelity derived from the actual payload — a provider that "can" return
    /// word timings still produces a line-tier result when a song only has an
    /// LRC fallback.
    var capability: LyricsCapability {
        switch self {
        case let .synced(lyrics):
            lyrics.hasWordTiming ? .word : .line
        case .plain:
            .plain
        case .unavailable:
            .plain
        }
    }

    /// Numeric rank used for replacement decisions; `.unavailable` sorts below
    /// every real result so the first valid arrival is always displayed.
    var capabilityRank: Int {
        switch self {
        case .unavailable: -1
        case let .synced(lyrics): lyrics.hasWordTiming ? 2 : 1
        case .plain: 0
        }
    }
}
