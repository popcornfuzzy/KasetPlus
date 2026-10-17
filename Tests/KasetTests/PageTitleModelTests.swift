import Testing

@testable import Kaset

/// The window's register of what the page on screen is called.
///
/// The pages state their title here instead of `.navigationTitle`, which is toolbar-managed content:
/// SwiftUI's window controller answered each one by replacing the window's toolbar — and the app's own
/// toolbar, back control and all, went with it until the shell re-took it. This is covered here because
/// the window it drives cannot be: the rules are the same keyed publish/retract ones the toolbar's own
/// contribution model follows.
@Suite("Page title publication")
@MainActor
struct PageTitleModelTests {
    @Test("A page's title is published, and taken away again by the same page")
    func publishAndRetract() {
        let model = PageTitleModel()
        #expect(model.title == "Kaset")

        model.publish(id: "library", title: "Library")
        #expect(model.title == "Library")

        model.retract(id: "library")
        #expect(model.title == "Kaset")
    }

    @Test("Going back home restores the home title, which never retracted")
    func popFallsBackToTheRoot() {
        let model = PageTitleModel()
        // The root stays mounted while the album is pushed over it: it publishes once on appearance
        // and has no disappearance to retract from until the whole page goes away.
        model.publish(id: "home", title: "Home")
        model.publish(id: "playlist-1", title: "My Playlist 1")
        #expect(model.title == "My Playlist 1")

        model.retract(id: "playlist-1")
        #expect(model.title == "Home")
    }

    @Test("A retraction from a page that is no longer published is ignored")
    func staleRetractionIsIgnored() {
        let model = PageTitleModel()
        model.publish(id: "library", title: "Library")
        // The incoming page appears before the outgoing one disappears, so the outgoing page's
        // retraction must not re-title the window for a page the reader has left.
        model.publish(id: "playlist-1", title: "My Playlist 1")

        model.retract(id: "library")

        #expect(model.title == "My Playlist 1")
    }

    @Test("The last page to publish wins")
    func lastPublisherWins() {
        let model = PageTitleModel()
        model.publish(id: "library", title: "Library")
        model.publish(id: "history", title: "Listening History")

        #expect(model.title == "Listening History")
    }

    @Test("A detail that loads renames the window with its header")
    func detailTitleFollowsTheLoad() {
        let model = PageTitleModel()
        model.publish(id: "playlist-1", title: "Playlist")
        model.publish(id: "playlist-1", title: "My Playlist 1")

        #expect(model.title == "My Playlist 1")
    }
}
