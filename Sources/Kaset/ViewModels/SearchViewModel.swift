import Foundation
import Observation
import os

/// View model for the Search view.
@MainActor
@Observable
final class SearchViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Current search query.
    ///
    /// The field writes here, and the model owns what follows: the autocomplete fetch, the results a
    /// new query keeps on screen until its response arrives, and the panel's state. See ADR-0054.
    var query: String = "" {
        didSet {
            guard self.query != oldValue else { return }

            self.searchTask?.cancel()
            // A new edit is a new list: a panel dismissed for the old text no longer applies.
            self.isSuggestionListDismissed = false

            guard !self.query.isEmpty else {
                self.suggestionsTask?.cancel()
                self.suggestions = []
                self.results = .empty
                self.loadingState = .idle
                self.lastSearchedQuery = nil
                self.client.clearSearchContinuation()
                return
            }

            if self.query != self.lastSearchedQuery {
                // The results on screen stay while the reader refines the query: the next response
                // replaces them, so refining never empties the page. Only pagination belongs to the
                // query that produced the rows, so its token goes.
                self.client.clearSearchContinuation()
                self.loadingState = self.results.isEmpty ? .idle : .loaded
            }

            self.scheduleSuggestions()
        }
    }

    /// Search results.
    private(set) var results: SearchResponse = .empty

    /// The query that produced the current results.
    private var lastSearchedQuery: String?

        /// Search suggestions for autocomplete.
    private(set) var suggestions: [SearchSuggestion] = []

    /// Set when the panel was closed on purpose — Escape, or a search that consumed a suggestion.
    /// The next edit clears it, which is what makes typing reopen the list.
    private(set) var isSuggestionListDismissed = false

    /// Whether the field should draw its suggestion panel at all.
    var isSuggestionsVisible: Bool {
        !Self.term(from: self.query).isEmpty && !self.isSuggestionListDismissed
    }

    /// How many rows the panel may draw, the typed query's own row included.
    private static let suggestionRowLimit = 8

    /// The panel's rows, in order: the text in the field first, then the provider's completions with
    /// the query itself and any repeats removed.
    ///
    /// The first row is what makes the panel belong to the field: Return always has something to run,
    /// even before the provider has answered, and a click on it means "search what I typed".
    var suggestionRows: [String] {
        let term = Self.term(from: self.query)
        guard !term.isEmpty else { return [] }

        var rows = [term]
        var seen: Set<String> = [term.lowercased()]

        for suggestion in self.suggestions {
            let candidate = Self.term(from: suggestion.query)
            guard !candidate.isEmpty, seen.insert(candidate.lowercased()).inserted else { continue }
            rows.append(candidate)
            if rows.count == Self.suggestionRowLimit { break }
        }

        return rows
    }

    /// Filter for result types.
    var selectedFilter: SearchFilter = .all {
        didSet {
            if oldValue != self.selectedFilter, !self.query.isEmpty, self.lastSearchedQuery != nil {
                // Filter changed - perform a new filtered search
                self.search()
            }
        }
    }

    /// Whether more results are available to load.
    var hasMoreResults: Bool {
        // For "All" filter, we don't support pagination (mixed results)
        guard self.selectedFilter != .all else { return false }
        return self.client.hasMoreSearchResults
    }

    /// Available filters.
    enum SearchFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case songs = "Songs"
        case albums = "Albums"
        case artists = "Artists"
        case featuredPlaylists = "Featured playlists"
        case communityPlaylists = "Community playlists"
        case podcasts = "Podcasts"

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .all:
                String(localized: "All")
            case .songs:
                String(localized: "Songs")
            case .albums:
                String(localized: "Albums")
            case .artists:
                String(localized: "Artists")
            case .featuredPlaylists:
                String(localized: "Featured playlists")
            case .communityPlaylists:
                String(localized: "Community playlists")
            case .podcasts:
                String(localized: "Podcasts")
            }
        }
    }

    /// Filtered results based on selected filter.
    var filteredItems: [SearchResultItem] {
        switch self.selectedFilter {
        case .all:
            SearchResultRanker.ranked(self.results)
        case .songs:
            SearchResultRanker.audioPreferred(self.results.songs).map { .song($0) }
        case .albums:
            self.results.albums.map { .album($0) }
        case .artists:
            self.results.artists.map { .artist($0) }
        case .featuredPlaylists, .communityPlaylists:
            self.results.playlists.map { .playlist($0) }
        case .podcasts:
            self.results.podcastShows.map { .podcastShow($0) }
        }
    }

    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api
    /// Tasks for search operations, cancelled in deinit.
    /// nonisolated(unsafe) required for deinit access; Swift 6.2 warning is expected.
    nonisolated(unsafe) private var searchTask: Task<Void, Never>?
    nonisolated(unsafe) private var suggestionsTask: Task<Void, Never>?

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    deinit {
        searchTask?.cancel()
        suggestionsTask?.cancel()
    }

    // MARK: - Suggestions

    /// Fetches completions for the query after a short pause, so a typed word costs one request.
    private func scheduleSuggestions() {
        self.suggestionsTask?.cancel()

        let term = Self.term(from: self.query)
        guard !term.isEmpty else {
            self.suggestions = []
            return
        }

        // The previous rows stay on screen while the new ones arrive: an emptied panel that fills a
        // moment later makes every keystroke flash.
        self.suggestionsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await self?.fetchSuggestions(for: term)
        }
    }

    /// Performs the actual suggestions fetch.
    private func fetchSuggestions(for term: String) async {
        do {
            let fetchedSuggestions = try await client.getSearchSuggestions(query: term)

            // A newer edit, or a panel the reader already closed, owns the list now.
            guard !Task.isCancelled,
                  Self.term(from: self.query) == term,
                  !self.isSuggestionListDismissed
            else { return }

            self.suggestions = fetchedSuggestions
        } catch {
            if !Task.isCancelled {
                // Suggestions are an extra: a failed fetch leaves the field quiet, never an error.
                self.logger.debug("Failed to fetch suggestions: \(error.localizedDescription)")
            }
        }
    }

    /// Puts a query in the field, closes the panel, and searches — one step, so every path into a
    /// search (a click, Return, a recent search) behaves the same.
    func accept(query: String) {
        let term = Self.term(from: query)
        guard !term.isEmpty else { return }

        if self.query != term {
            self.query = term
        }

        self.search()
    }

    /// Closes the panel without touching the field, which is what Escape does first.
    func dismissSuggestions() {
        self.suggestionsTask?.cancel()
        self.isSuggestionListDismissed = true
    }

    // MARK: - Search

    /// Runs the query in the field now.
    ///
    /// No debounce: the only callers are an explicit Return, a chosen suggestion, a filter change and
    /// the recent-searches shelf. Typing reaches the network through the debounced suggestions only.
    func search() {
        self.searchTask?.cancel()
        self.suggestionsTask?.cancel()
        self.suggestions = []
        self.isSuggestionListDismissed = true
        self.client.clearSearchContinuation()

        let term = Self.term(from: self.query)
        guard !term.isEmpty else {
            self.results = .empty
            self.loadingState = .idle
            return
        }

        // Stated here, not in the task: the page must not draw the "press Return" placeholder for
        // the frame between the action and the task's first hop.
        self.loadingState = .loading

        self.searchTask = Task {
            await self.performSearch(term)
        }
    }

    /// Performs the actual search.
    private func performSearch(_ term: String) async {
        // Check cancellation before updating state
        guard !Task.isCancelled else { return }

        let currentFilter = self.selectedFilter
        self.logger.info("Searching for: \(term) with filter: \(currentFilter.rawValue)")

        do {
            let searchResults = try await self.results(for: term, filter: currentFilter)

            // Check cancellation and query change before updating results
            // This handles the race condition where query changed during the request
            guard !Task.isCancelled, Self.term(from: self.query) == term, self.selectedFilter == currentFilter else {
                self.logger.debug("Search results discarded: query changed or task cancelled")
                return
            }

            self.results = searchResults
            self.lastSearchedQuery = term
            self.loadingState = .loaded
            self.logger.info("Search complete: \(searchResults.allItems.count) results, hasMore: \(searchResults.hasMore)")
        } catch {
            // CancellationError is thrown when task is cancelled during URLSession request
            if !Task.isCancelled, Self.term(from: self.query) == term {
                self.logger.error("Search failed: \(error.localizedDescription)")
                self.loadingState = .error(LoadingError(from: error))
            }
        }
    }

    /// Requests the results for one query and filter.
    private func results(for term: String, filter: SearchFilter) async throws -> SearchResponse {
        // Use filtered search for specific filters to get more results
        switch filter {
        case .all:
            try await self.client.search(query: term)
        case .songs:
            try await self.client.searchSongsWithPagination(query: term)
        case .albums:
            try await self.client.searchAlbums(query: term)
        case .artists:
            try await self.client.searchArtists(query: term)
        case .featuredPlaylists:
            try await self.client.searchFeaturedPlaylists(query: term)
        case .communityPlaylists:
            try await self.client.searchCommunityPlaylists(query: term)
        case .podcasts:
            try await self.client.searchPodcasts(query: term)
        }
    }

    /// Loads more search results via continuation.
    func loadMore() async {
        // Only load more for filtered searches
        guard self.selectedFilter != .all else { return }
        guard self.loadingState == .loaded else { return }
        guard self.hasMoreResults else { return }

        self.loadingState = .loadingMore
        self.logger.info("Loading more search results")

        do {
            guard let continuation = try await client.getSearchContinuation() else {
                self.loadingState = .loaded
                return
            }

            // The query moved on while the page loaded: its rows belong to a search that is gone.
            guard self.loadingState == .loadingMore,
                  let lastQuery = self.lastSearchedQuery,
                  Self.term(from: self.query) == lastQuery
            else { return }

            // Merge continuation results with existing results
            let mergedResults = SearchResponse(
                songs: self.results.songs + continuation.songs,
                albums: self.results.albums + continuation.albums,
                artists: self.results.artists + continuation.artists,
                playlists: self.results.playlists + continuation.playlists,
                podcastShows: self.results.podcastShows + continuation.podcastShows,
                continuationToken: continuation.continuationToken,
                orderedItems: self.results.allItems + continuation.allItems
            )

            self.results = mergedResults
            self.loadingState = .loaded
            self.logger.info("Loaded more results: now \(mergedResults.allItems.count) total, hasMore: \(mergedResults.hasMore)")
        } catch {
            self.logger.error("Failed to load more: \(error.localizedDescription)")
            self.loadingState = .loaded // Revert to loaded state to allow retry
        }
    }

    /// Clears search results.
    func clear() {
        self.searchTask?.cancel()
        self.suggestionsTask?.cancel()
        self.query = ""
        self.results = .empty
        self.suggestions = []
        self.isSuggestionListDismissed = false
        self.lastSearchedQuery = nil
        self.loadingState = .idle
        self.client.clearSearchContinuation()
    }

    // MARK: - Helpers

    /// The text a request is made for: what the reader typed, without the whitespace around it.
    private static func term(from query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
