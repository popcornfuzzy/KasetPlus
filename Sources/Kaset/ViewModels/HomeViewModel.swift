import Foundation
import Observation
import os

/// View model for the Home view.
@MainActor
@Observable
final class HomeViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Home sections to display.
    private(set) var sections: [HomeSection] = []

    /// Whether more sections are available to load.
    private(set) var hasMoreSections: Bool = true

    /// The API client (exposed for navigation to detail views).
    let client: any YTMusicClientProtocol
    /// The account whose feed is on screen.
    private(set) var accountID: String?
    private let logger = DiagnosticsLogger.api
    /// Task for background loading, cancelled in deinit.
    /// nonisolated(unsafe) required for deinit access; Swift 6.2 warning is expected.
    nonisolated(unsafe) private var backgroundLoadTask: Task<Void, Never>?

    /// Bumped by every refresh. A response requested before the bump belongs to the feed the
    /// reader has already left behind — after an account switch, the previous channel's — and
    /// must not be able to land on screen once the new request has started.
    private var loadGeneration: UInt64 = 0

    /// Number of background continuations loaded.
    private var continuationsLoaded = 0

    /// Maximum continuations to load in background.
    private static let maxContinuations = 4

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    deinit {
        self.backgroundLoadTask?.cancel()
    }

    /// Points the page at the account whose feed it should show, loading it the first time.
    ///
    /// Home is per account, so the feed on screen belongs to one: a change of account discards what is
    /// displayed rather than letting the other channel's home stand while the new request is out.
    func activate(accountID: String?) async {
        if self.accountID == accountID {
            if self.loadingState == .idle { await self.load() }
            return
        }

        self.accountID = accountID
        self.loadGeneration &+= 1
        self.backgroundLoadTask?.cancel()
        self.sections = []
        self.hasMoreSections = true
        self.continuationsLoaded = 0
        self.loadingState = .idle
        await self.load()
    }

    /// Loads home content with fast initial load.
    func load() async {
        guard self.loadingState != .loading else { return }

        let generation = self.loadGeneration
        // The skeleton is Home's launch state: a stored feed was painted first, and what it showed was
        // yesterday's home under a request that replaced it moments later. A feed already on screen
        // stays there — a refresh is the reader pulling on a page they can read.
        if self.sections.isEmpty {
            self.loadingState = .loading
        }
        self.logger.info("Loading home content")

        do {
            let response = try await client.getHome()
            guard generation == self.loadGeneration else {
                self.logger.debug("Discarding home content requested before the latest refresh")
                return
            }
            self.sections = response.sections
            self.hasMoreSections = self.client.hasMoreHomeSections
            self.loadingState = .loaded
            self.continuationsLoaded = 0
            let sectionCount = self.sections.count
            self.logger.info("Home content loaded: \(sectionCount) sections")
            let sectionSummary = self.sections
                .map { "\($0.title) (\($0.items.count))" }
                .joined(separator: ", ")
            self.logger.debug("Home sections: [\(sectionSummary)]")

            // Start background loading of additional sections
            self.startBackgroundLoading(generation: generation)
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry, unless a
            // readable feed is already on screen.
            guard generation == self.loadGeneration else { return }
            self.logger.debug("Home load cancelled")
            if self.sections.isEmpty { self.loadingState = .idle }
        } catch {
            guard generation == self.loadGeneration else { return }
            self.logger.error("Failed to load home: \(error.localizedDescription)")
            // A feed already on screen stays there instead of being replaced by an error page.
            if self.sections.isEmpty {
                self.loadingState = .error(LoadingError(from: error))
            }
        }
    }

    /// Loads more sections in the background progressively.
    private func startBackgroundLoading(generation: UInt64) {
        self.backgroundLoadTask?.cancel()
        self.backgroundLoadTask = Task { [weak self] in
            guard let self else { return }

            // Brief delay to let the UI settle
            try? await Task.sleep(for: .milliseconds(300))

            guard !Task.isCancelled else { return }

            await self.loadMoreSections(generation: generation)
        }
    }

    /// Loads additional sections from continuations progressively.
    private func loadMoreSections(generation: UInt64) async {
        while self.hasMoreSections, self.continuationsLoaded < Self.maxContinuations {
            guard self.loadingState == .loaded, generation == self.loadGeneration else { break }

            do {
                if let additionalSections = try await client.getHomeContinuation() {
                    // A continuation requested under one account continues that account's feed.
                    guard generation == self.loadGeneration else { break }
                    self.sections.append(contentsOf: additionalSections)
                    self.continuationsLoaded += 1
                    self.hasMoreSections = self.client.hasMoreHomeSections
                    let continuationNum = self.continuationsLoaded
                    self.logger.info("Background loaded \(additionalSections.count) more sections (continuation \(continuationNum))")
                } else {
                    self.hasMoreSections = false
                    break
                }
            } catch is CancellationError {
                self.logger.debug("Background loading cancelled")
                break
            } catch {
                self.logger.warning("Background section load failed: \(error.localizedDescription)")
                break
            }
        }

        let totalCount = self.sections.count
        self.logger.info("Background section loading completed, total sections: \(totalCount)")
    }

    /// Refreshes home content.
    func refresh() async {
        // The feed on screen belongs to the account that was active when it was requested. A
        // refresh is the app saying "this is a different reader now": the earlier request's
        // response is discarded when it arrives instead of replacing the new one, which is how
        // an account switch used to leave the other channel's home up.
        self.loadGeneration &+= 1
        self.backgroundLoadTask?.cancel()
        // The feed stays on screen while the new one is fetched: clearing it here is what put a skeleton
        // in front of the reader on every pull-to-refresh, for a page they could already read.
        self.hasMoreSections = true
        self.continuationsLoaded = 0
        // Let the load below start even though the discarded one is still in flight.
        if self.sections.isEmpty { self.loadingState = .idle }
        await self.load()
    }
}
