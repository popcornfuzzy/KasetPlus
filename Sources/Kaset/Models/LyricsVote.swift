import Foundation

// MARK: - LyricsVoteDirection

/// The direction of a community vote on a lyrics version. The raw values are
/// the ones Unison's vote endpoint accepts.
enum LyricsVoteDirection: Int, Equatable, Sendable {
    case up = 1
    case down = -1
}

// MARK: - LyricsVoteState

/// The community standing of the lyrics version on screen: how many people
/// voted on it, and how the listener voted.
///
/// Both fields are optional because a provider may report only one of them: the
/// variant list carries counts, while the listener's own vote comes from
/// reading the record back with their key.
struct LyricsVoteState: Equatable, Sendable {
    /// Provider-scoped identifier of the lyrics record being voted on.
    let lyricsID: Int

    /// Net vote count, when the provider reports one.
    var count: Int?

    /// The listener's own vote, or `nil` when they have not voted.
    var direction: LyricsVoteDirection?

    /// The state after the listener's vote becomes `direction` (or is removed
    /// with `nil`). The count moves by one only when a vote appears or goes
    /// away — switching sides keeps it where it was.
    func applying(_ direction: LyricsVoteDirection?) -> LyricsVoteState {
        let delta = (direction == nil ? 0 : 1) - (self.direction == nil ? 0 : 1)
        var state = self
        state.direction = direction
        if let count = self.count {
            state.count = max(0, count + delta)
        }
        return state
    }
}
