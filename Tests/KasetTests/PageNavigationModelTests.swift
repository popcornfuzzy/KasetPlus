import Testing

@testable import Kaset

/// The window's register of whether the page on screen can be popped.
///
/// The window's toolbar is the app's own `NSToolbar`, so the back control a pushed page needs is an item the
/// app supplies (`WindowToolbarItem.back`), and this is what tells it whether to draw one. It is covered
/// here because the window it drives cannot be: the state is small, and every one of its rules is a rule
/// about *two* pages — the one leaving and the one arriving — which is exactly where a toolbar goes wrong.
@Suite("Page navigation back control")
@MainActor
struct PageNavigationModelTests {
    @Test("Nothing is back-navigable until a page says so")
    func startsClosed() {
        #expect(PageNavigationModel().canGoBack == false)
    }

    @Test("A page that publishes a depth is back-navigable, and popping runs its own action")
    func publishAndPop() {
        let model = PageNavigationModel()
        var popped = 0
        model.publish(id: "home", canGoBack: true) { popped += 1 }

        #expect(model.canGoBack == true)
        model.goBack()
        #expect(popped == 1)
    }

    @Test("A page at its root publishes no back control, and popping is a no-op")
    func rootPageHasNothingToPop() {
        let model = PageNavigationModel()
        var popped = 0
        model.publish(id: "home", canGoBack: false) { popped += 1 }

        #expect(model.canGoBack == false)
        model.goBack()
        #expect(popped == 0, "a page with nothing to pop must not pop")
    }

    @Test("The outgoing page's retraction cannot clear the page that replaced it")
    func retractionIsKeyedByPage() {
        let model = PageNavigationModel()
        model.publish(id: "home", canGoBack: true) {}

        // The incoming page publishes first, then the outgoing page disappears — the order SwiftUI can
        // deliver when the sidebar selection changes.
        model.publish(id: "search", canGoBack: false) {}
        model.retract(id: "home")

        #expect(model.canGoBack == false)

        model.publish(id: "search", canGoBack: true) {}
        model.retract(id: "search")
        #expect(model.canGoBack == false, "the page on screen took its own control away")
    }

    @Test("A stale pop after the page changed does not run the old page's action")
    func popFollowsTheCurrentPage() {
        let model = PageNavigationModel()
        var oldPops = 0
        var newPops = 0
        model.publish(id: "home", canGoBack: true) { oldPops += 1 }
        model.publish(id: "search", canGoBack: true) { newPops += 1 }

        model.goBack()
        #expect(newPops == 1)
        #expect(oldPops == 0)
    }

    @Test("An opened page goes onto the stack of the page on screen, not the one that left")
    func openFollowsTheCurrentPage() {
        let model = PageNavigationModel()
        let album = DetailNavigationRoute.album(Playlist(
            id: "MPREb_test",
            title: "Test Album",
            description: nil,
            thumbnailURL: nil,
            trackCount: 10,
            author: nil
        ))
        var oldOpened: [DetailNavigationRoute] = []
        var newOpened: [DetailNavigationRoute] = []
        model.publish(id: "home", canGoBack: false, goBack: {}, open: { oldOpened.append($0) })
        model.publish(id: "search", canGoBack: false, goBack: {}, open: { newOpened.append($0) })

        #expect(model.open(album) == true, "a page on screen takes the route")
        #expect(newOpened == [album])
        #expect(oldOpened.isEmpty, "the outgoing page's stack must not receive the push")
    }

    @Test("Opening a page while no page is on screen does nothing")
    func openWithoutAPageIsANoOp() {
        let model = PageNavigationModel()
        var opened = 0
        model.publish(id: "home", canGoBack: false, goBack: {}, open: { _ in opened += 1 })
        model.retract(id: "home")

        // `false` is what the window answers by showing the page in the content pane: a page with no stack
        // (Home, Search, an artist page) must not make the column's credits a click that does nothing.
        #expect(model.open(.artist(Artist(id: "UCtest", name: "Test Artist"))) == false)
        #expect(opened == 0, "a page that is gone must not push anything")
    }
}
