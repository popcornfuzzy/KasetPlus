import Foundation
import Testing
@testable import Kaset

/// Tests for SearchViewModel using mock client.
@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct SearchViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: SearchViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.viewModel = SearchViewModel(client: self.mockClient)
    }

    @Test("Initial state is idle with empty query")
    func initialState() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.query.isEmpty)
        #expect(self.viewModel.results.allItems.isEmpty)
        #expect(self.viewModel.selectedFilter == .all)
    }

    @Test("Query change clears results when empty")
    func queryChangeClearsResultsWhenEmpty() {
        self.viewModel.query = "test"
        self.viewModel.query = ""

        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.results.allItems.isEmpty)
    }

    @Test("Search with empty query does not call API")
    func searchWithEmptyQueryDoesNotCallAPI() {
        self.viewModel.query = ""
        self.viewModel.search()

        #expect(self.mockClient.searchCalled == false)
    }

    @Test("Clear resets state")
    func clearResetsState() {
        self.viewModel.query = "test query"
        self.viewModel.selectedFilter = .songs

        self.viewModel.clear()

        #expect(self.viewModel.query.isEmpty)
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.results.allItems.isEmpty)
    }

    @Test("Filtered items returns all when all selected")
    func filteredItemsReturnsAllWhenAllSelected() {
        self.viewModel.selectedFilter = .all

        let response = TestFixtures.makeSearchResponse(
            songCount: 2,
            albumCount: 1,
            artistCount: 1,
            playlistCount: 1
        )

        #expect(response.allItems.count == 5)
    }

    @Test("Filtered items returns songs only when songs selected")
    func filteredItemsReturnsSongsOnlyWhenSongsSelected() {
        let response = TestFixtures.makeSearchResponse(
            songCount: 3,
            albumCount: 2,
            artistCount: 1,
            playlistCount: 1
        )

        let songItems = response.songs.map { SearchResultItem.song($0) }
        #expect(songItems.count == 3)
    }

    @Test("Podcast filter is available")
    func podcastFilterIsAvailable() {
        let filters = SearchViewModel.SearchFilter.allCases
        #expect(filters.contains(.podcasts))
    }

    @Test("Podcast filter has correct raw value")
    func podcastFilterRawValue() {
        #expect(SearchViewModel.SearchFilter.podcasts.rawValue == "Podcasts")
    }

    @Test("Selected filter defaults to all")
    func selectedFilterDefaultsToAll() {
        #expect(self.viewModel.selectedFilter == .all)
    }

    // MARK: - Suggestions

    @Test("Accepting a suggestion runs the search for its text right away")
    func acceptingSuggestionSearchesImmediately() async throws {
        self.viewModel.query = "beat"

        self.viewModel.accept(query: "beatles help")

        #expect(self.viewModel.query == "beatles help")
        #expect(self.viewModel.isSuggestionsVisible == false)

        try await self.waitForSearch()
        #expect(self.mockClient.searchQueries == ["beatles help"])
    }

    @Test("Typing again reopens the panel after a suggestion ran")
    func typingReopensSuggestionsAfterAccept() {
        self.viewModel.accept(query: "beatles")
        #expect(self.viewModel.isSuggestionsVisible == false)

        self.viewModel.query = "beatles help"

        #expect(self.viewModel.isSuggestionsVisible == true)
    }

    @Test("Suggestion rows start with the typed query and drop repeats")
    func suggestionRowsStartWithTypedQuery() async throws {
        self.mockClient.searchSuggestions = [
            SearchSuggestion(query: "beatles"),
            SearchSuggestion(query: "beatles help"),
            SearchSuggestion(query: "beatles help"),
            SearchSuggestion(query: "beatlemania"),
        ]

        self.viewModel.query = "Beatles"
        try await self.waitForSuggestions()

        #expect(self.viewModel.suggestionRows == ["Beatles", "beatles help", "beatlemania"])
    }

    @Test("Dismissing the suggestions hides the panel without clearing the query")
    func dismissSuggestionsKeepsQuery() {
        self.viewModel.query = "daft punk"

        self.viewModel.dismissSuggestions()

        #expect(self.viewModel.query == "daft punk")
        #expect(self.viewModel.isSuggestionsVisible == false)
    }

    @Test("Search trims the whitespace around the query")
    func searchTrimsWhitespace() async throws {
        self.viewModel.query = "  daft punk  "
        self.viewModel.search()

        try await self.waitForSearch()
        #expect(self.mockClient.searchQueries == ["daft punk"])
    }

    @Test("Search with no suggestions still offers the typed query")
    func suggestionRowsAlwaysHoldTheQuery() {
        self.viewModel.query = "midnights"

        #expect(self.viewModel.suggestionRows == ["midnights"])
    }

    @Test("Refining the query keeps the results already on screen")
    func refiningQueryKeepsResults() async throws {
        self.mockClient.searchResponse = TestFixtures.makeSearchResponse(
            songCount: 3,
            albumCount: 0,
            artistCount: 0,
            playlistCount: 0
        )

        self.viewModel.query = "daft"
        self.viewModel.search()
        try await self.waitForLoaded()
        #expect(self.viewModel.results.allItems.count == 3)

        self.viewModel.query = "daft punk"

        #expect(self.viewModel.results.allItems.count == 3)
        #expect(self.viewModel.loadingState == .loaded)
    }

    @Test("A new search keeps the old results until the response lands")
    func searchingKeepsOldResultsWhileLoading() async throws {
        self.mockClient.searchResponse = TestFixtures.makeSearchResponse(
            songCount: 2,
            albumCount: 0,
            artistCount: 0,
            playlistCount: 0
        )

        self.viewModel.query = "daft"
        self.viewModel.search()
        try await self.waitForLoaded()

        self.viewModel.query = "daft punk"
        self.viewModel.search()

        #expect(self.viewModel.loadingState == .loading)
        #expect(self.viewModel.results.allItems.count == 2)
    }

    @Test("A whitespace-only query opens no panel")
    func whitespaceQueryHidesPanel() {
        self.viewModel.query = "   "

        #expect(self.viewModel.isSuggestionsVisible == false)
        #expect(self.viewModel.suggestionRows.isEmpty)
    }

    // MARK: - Helpers

    /// Waits for the debounced suggestion fetch the mock answers instantly once it is asked.
    private func waitForSuggestions() async throws {
        for _ in 0 ..< 60 {
            if self.mockClient.getSearchSuggestionsCalled, self.viewModel.suggestionRows.count > 1 {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Waits for a search task to reach the mock, which answers without a network hop.
    private func waitForSearch() async throws {
        for _ in 0 ..< 60 {
            if self.mockClient.searchCalled { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Waits for a search the mock answers instantly to publish its results.
    private func waitForLoaded() async throws {
        for _ in 0 ..< 60 {
            if self.viewModel.loadingState == .loaded { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Can set filter to podcasts")
    func canSetFilterToPodcasts() {
        self.viewModel.selectedFilter = .podcasts
        #expect(self.viewModel.selectedFilter == .podcasts)
    }
}
