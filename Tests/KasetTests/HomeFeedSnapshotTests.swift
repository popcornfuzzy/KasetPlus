import AppKit
import Testing
@testable import Kaset

/// Coverage for the snapshot Home's collection view applies.
@Suite(.serialized, .tags(.viewModel))
@MainActor
struct HomeFeedSnapshotTests {
    @Test("A shelf becomes a title section and a row section")
    func shelfBecomesTwoSections() {
        let section = TestFixtures.makeHomeSection(title: "Quick picks", itemCount: 4)
        let snapshot = HomeFeedSnapshot.make(sections: [section])

        #expect(snapshot.numberOfSections == 2)
        #expect(snapshot.itemIdentifiers(inSection: .header(section.id)).count == 1)
        #expect(snapshot.itemIdentifiers(inSection: .items(section.id)).count == 4)
    }

    @Test("The same item in two shelves keeps unique identifiers")
    func repeatedItemsStayUnique() {
        let first = TestFixtures.makeHomeSection(id: "first", title: "A", itemCount: 3)
        let second = HomeSection(id: "second", title: "B", items: first.items)
        let snapshot = HomeFeedSnapshot.make(sections: [first, second])

        let identifiers = snapshot.itemIdentifiers
        #expect(Set(identifiers).count == identifiers.count)
        #expect(identifiers.count == 2 + first.items.count + second.items.count)
    }

    @Test("Only a chart shelf ranks its cards")
    func chartsRankCards() {
        let chart = TestFixtures.makeHomeSection(title: "Top songs", itemCount: 3, isChart: true)
        let plain = TestFixtures.makeHomeSection(title: "New releases", itemCount: 3)
        let snapshot = HomeFeedSnapshot.make(sections: [chart, plain])

        let ranks = snapshot.itemIdentifiers.compactMap { item -> Int? in
            guard case let .card(_, _, rank) = item else { return nil }
            return rank
        }
        #expect(ranks == [1, 2, 3])
    }
}
