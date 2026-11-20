import AppKit
import SwiftUI
import Testing

@testable import Kaset

/// Where the player bar lives.
///
/// The bar is drawn once, by the content pane (`PagePaneController`), as a sibling of the page's hosting
/// view — that is what keeps it still while the page slides (`PageSlideTransition`: a `CATransition` moves
/// the layer it is added to, so a bar drawn by the page went with it). A bar put back inside the page looks
/// exactly like a working app until a page is pushed, and the failure is invisible to every test of the
/// slide itself, so the placement is stated here: the bar's view is beside the page's, not under it, and its
/// band is the one the pages reserve.
///
/// The pane is built on its own rather than through `WindowShell`: a shell would install a toolbar into a
/// window and write split-view autosave state, and the suites run in parallel — measured: a windowed
/// version of this test made `WindowToolbarTakeoverTests` fail while it passed on its own.
@MainActor
@Suite(.serialized)
struct ContentPaneBarTests {
    private func pane() -> PagePaneController {
        let page = NSViewController()
        page.view = NSView()
        let bar = NSHostingController(rootView: Color.clear.frame(width: 100, height: PlayerBar.bandHeight))
        bar.sizingOptions = []
        return PagePaneController(page: page, bar: bar)
    }

    @Test("The player bar is hosted beside the page, in the band the pages reserve")
    func theBarIsASiblingOfThePage() throws {
        let pane = self.pane()
        pane.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        pane.view.layoutSubtreeIfNeeded()

        let page = try #require(pane.children.first?.view, "the page is the pane's first child")
        let bar = try #require(pane.children.last?.view, "the bar is the pane's second child")

        #expect(bar.superview === page.superview, "the bar is a sibling of the page, not inside it")
        #expect(!bar.isDescendant(of: page), "the bar is not inside the page's hosting view")
        #expect(bar.frame.height == PlayerBar.bandHeight, "the bar fills the band the pages reserve")
        #expect(bar.frame.minY == 0, "the bar sits on the pane's bottom edge")
        // The page spans the whole pane behind the bar, so its own background — an accent gradient
        // included — is what the bar's glass sits on.
        #expect(page.frame == pane.view.bounds)
    }
}
