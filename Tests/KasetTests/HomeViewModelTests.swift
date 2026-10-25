import Foundation
import Testing
@testable import Kaset

/// Tests for HomeViewModel using mock client.
@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct HomeViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: HomeViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.viewModel = HomeViewModel(client: self.mockClient)
    }

    @Test("Initial state is idle with empty sections")
    func initialState() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.sections.isEmpty)
    }

    @Test("Load success sets sections")
    func loadSuccess() async {
        let expectedSections = [
            TestFixtures.makeHomeSection(title: "Quick picks"),
            TestFixtures.makeHomeSection(title: "Recommended"),
        ]
        self.mockClient.homeResponse = HomeResponse(sections: expectedSections)

        await self.viewModel.load()

        #expect(self.mockClient.getHomeCalled == true)
        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.count == 2)
        #expect(self.viewModel.sections[0].title == "Quick picks")
        #expect(self.viewModel.sections[1].title == "Recommended")
    }

    @Test("Load error sets error state")
    func loadError() async {
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.viewModel.load()

        #expect(self.mockClient.getHomeCalled == true)
        if case let .error(error) = viewModel.loadingState {
            #expect(!error.message.isEmpty)
            #expect(error.isRetryable)
        } else {
            Issue.record("Expected error state")
        }
        #expect(self.viewModel.sections.isEmpty)
    }

    @Test("Load does not duplicate when already loading")
    func loadDoesNotDuplicateWhenAlreadyLoading() async {
        self.mockClient.homeResponse = TestFixtures.makeHomeResponse(sectionCount: 1)

        await self.viewModel.load()
        await self.viewModel.load()

        #expect(self.mockClient.getHomeCallCount == 2)
    }

    /// Home is refreshed when the active account changes, and the request for the feed on screen is
    /// still in flight at that moment. Its response used to land afterwards — the previous channel's
    /// home, on the new channel's screen — so a refresh now discards everything requested before it.
    @Test("Refresh discards a load that was already in flight")
    func refreshDiscardsInFlightLoad() async {
        self.mockClient.homeResponses = [
            HomeResponse(sections: [TestFixtures.makeHomeSection(title: "Previous channel")]),
            HomeResponse(sections: [TestFixtures.makeHomeSection(title: "Current channel")]),
        ]
        self.mockClient.homeResponseDelays = [.milliseconds(200), .zero]

        let staleLoad = Task { await self.viewModel.load() }
        // Wait for the first request to be in flight — the mock counts it before its delay — then
        // refresh the way an account switch does, so the refresh is the second request.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while self.mockClient.getHomeCallCount == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await self.viewModel.refresh()
        await staleLoad.value

        #expect(self.viewModel.sections.map(\.title) == ["Current channel"])
        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.mockClient.getHomeCallCount == 2)
    }

    @Test("Refresh clears sections and reloads")
    func refreshClearsSectionsAndReloads() async {
        self.mockClient.homeResponse = TestFixtures.makeHomeResponse(sectionCount: 2)
        await self.viewModel.load()
        #expect(self.viewModel.sections.count == 2)

        self.mockClient.homeResponse = TestFixtures.makeHomeResponse(sectionCount: 3)
        await self.viewModel.refresh()

        #expect(self.viewModel.sections.count == 3)
        #expect(self.mockClient.getHomeCallCount == 2)
    }
}
