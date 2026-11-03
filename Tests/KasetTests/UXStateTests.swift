import Foundation
import Testing

@testable import Kaset

// MARK: - SearchHistoryStoreTests

@MainActor
@Suite("SearchHistoryStore")
struct SearchHistoryStoreTests {
    private func makeStore() -> (SearchHistoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KasetSearchHistoryTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("search-history.json")
        return (SearchHistoryStore(fileURL: fileURL), fileURL)
    }

    @Test func recordsNewestFirstAndDeduplicatesCaseInsensitively() {
        let (store, _) = self.makeStore()

        store.record("daft punk")
        store.record("air")
        store.record("DAFT PUNK")

        #expect(store.queries == ["DAFT PUNK", "air"])
    }

    @Test func keepsOnlyTheMostRecentQueries() {
        let (store, _) = self.makeStore()

        for index in 0 ..< 12 {
            store.record("query \(index)")
        }

        #expect(store.queries.count == 8)
        #expect(store.queries.first == "query 11")
        #expect(store.queries.last == "query 4")
    }

    @Test func ignoresBlankAndSingleCharacterQueries() {
        let (store, _) = self.makeStore()

        store.record(" ")
        store.record("a")

        #expect(store.queries.isEmpty)
    }

    @Test func persistsAcrossInstances() {
        let (store, fileURL) = self.makeStore()
        store.record("nils frahm")

        let reloaded = SearchHistoryStore(fileURL: fileURL)

        #expect(reloaded.queries == ["nils frahm"])
    }

    @Test func removeAndClearArePersisted() {
        let (store, fileURL) = self.makeStore()
        store.record("air")
        store.record("daft punk")

        store.remove("air")
        #expect(store.queries == ["daft punk"])

        store.clear()
        #expect(store.queries.isEmpty)
        #expect(SearchHistoryStore(fileURL: fileURL).queries.isEmpty)
    }
}

// MARK: - ToastCenterTests

@MainActor
@Suite("ToastCenter")
struct ToastCenterTests {
    @Test func undoRunsTheStoredActionAndClearsTheToast() {
        let center = ToastCenter()
        var undone = false

        center.show("Removed from Favorites", undoTitle: "Undo") {
            undone = true
        }
        #expect(center.current != nil)

        center.undoCurrent()

        #expect(undone)
        #expect(center.current == nil)
    }

    @Test func aNewToastReplacesThePreviousOne() {
        let center = ToastCenter()

        center.show("First")
        let firstID = center.current?.id
        center.show("Second")

        #expect(center.current?.id != firstID)
        #expect(center.current?.message == "Second")
    }

    @Test func dismissRemovesTheToastWithoutRunningUndo() {
        let center = ToastCenter()
        var undone = false

        center.show("Added to Queue", undoTitle: "Undo") {
            undone = true
        }
        center.dismiss()

        #expect(center.current == nil)
        #expect(!undone)
    }
}
