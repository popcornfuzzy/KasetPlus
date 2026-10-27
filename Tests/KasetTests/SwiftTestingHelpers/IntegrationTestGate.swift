import Foundation
import Testing

/// Whether the suites that depend on the machine rather than on the app's logic run.
///
/// Two kinds of suite sit behind this gate, and both would otherwise set the cost of a full run:
///
/// - **The on-device model** (`MusicIntentIntegrationTests`): the only suite whose result depends on a
///   language model's phrasing. 16 tests, each call taking a few seconds, each retrying up to three
///   times when an assertion misses.
/// - **Real AVFoundation playback** (`CanvasVideoViewTests`): a canvas player's first item has to bring up
///   the decode pipeline, which on a busy or paravirtualized machine has been measured at over 12s — and
///   when it never starts, each test waits out its 60s readiness deadline. Two of its tests are the
///   difference between a one-minute suite and a three-minute one.
///
/// The full unit suite is held to **two minutes** (see `docs/testing.md`), and these are the suites that
/// break that budget. They are opt-in and run deliberately, on their own:
///
/// ```bash
/// KASET_INTEGRATION_TESTS=1 swift test --skip KasetUITests --filter MusicIntentIntegrationTests
/// KASET_INTEGRATION_TESTS=1 swift test --skip KasetUITests --filter CanvasVideoViewTests
/// ```
///
/// The tags stay on the suites (`.integration`, `.slow`), so the Xcode test navigator groups them and
/// `-only-testing:` still reaches them.
enum IntegrationTestGate {
    /// Whether the environment-dependent suites were asked for.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["KASET_INTEGRATION_TESTS"] == "1"
    }

    /// What a suite states about itself when it is skipped, so a run that skips it says why.
    static let requirement: Comment = "run with KASET_INTEGRATION_TESTS=1: the environment-dependent suites are opt-in"
}
