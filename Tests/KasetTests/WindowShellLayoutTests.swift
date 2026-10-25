import AppKit
import Testing

@testable import Kaset

/// The window's column arithmetic: the width it may not go below, and how wide a side pane may be there.
///
/// These are the numbers behind three reports at once — a window opened too small to hold the Now Playing
/// column, a window that could be dragged narrow enough to cut the page off, and a split view that drew
/// itself wider than the window it was in. Each is a statement about three panes and two dividers, so it is
/// arithmetic, and arithmetic is testable without a window.
///
/// The app's own numbers are `MainWindow.Layout`: a 200pt navigation sidebar, a 765pt page (what the page's
/// content — the player bar — needs before it crops, measured in the running app), a 300pt Now Playing
/// column, and a 900pt floor the window has always had.
///
/// Two page floors are stated, and the difference is the whole point: `minContentWidth` sets the window's
/// minimum, and `contentSqueezeWidth` is what the split item enforces while a divider is dragged. With only
/// the first, the side panes had no range left at the window's own opening width, so their dividers were
/// pinned and a drag collapsed the pane instead of resizing it.
@MainActor
@Suite(.tags(.model))
struct WindowShellLayoutTests {
    /// The layout as the app states it.
    private var appLayout: WindowShellLayout {
        WindowShellLayout(
            minSidebarWidth: 200,
            maxSidebarWidth: 300,
            minContentWidth: 765,
            contentSqueezeWidth: 500,
            minWindowWidth: 900,
            minInspectorWidth: 300,
            maxInspectorWidth: 560
        )
    }

    @Test("The window's minimum is the panes' sum, and never below the floor the app states")
    func minimumWindowWidthIsThePanesSum() {
        let layout = self.appLayout
        // Closed: 200 + 765 + 2 dividers = 967, which is already above the stated 900pt floor.
        #expect(layout.minimumWindowWidth(tracksColumn: false) == 967)
        // Open: the column's own minimum comes with it — the width the window has to have before the page
        // can keep its own, which is the "the sidebar does not fit" report.
        #expect(layout.minimumWindowWidth(tracksColumn: true) == 1267)

        // The floor wins when the panes need less than it: 200 + 400 + 2 = 602 against a stated 900.
        let roomyFloor = WindowShellLayout(
            minSidebarWidth: 200,
            maxSidebarWidth: 300,
            minContentWidth: 400,
            contentSqueezeWidth: 400,
            minWindowWidth: 900,
            minInspectorWidth: 300,
            maxInspectorWidth: 560
        )
        #expect(roomyFloor.minimumWindowWidth(tracksColumn: false) == 900)
        // Open: 200 + 400 + 300 + 2 = 902, which is just past the floor.
        #expect(roomyFloor.minimumWindowWidth(tracksColumn: true) == 902)
    }

    @Test("The column has its whole range at the window's own minimum width")
    func columnHasItsWholeRangeAtTheWindowMinimum() {
        let layout = self.appLayout
        let minimum = layout.minimumWindowWidth(tracksColumn: true)

        // The regression: at 1267 the column used to be capped at its own 300pt minimum, so its divider
        // could not move and a drag inward collapsed it.
        let inspector = layout.inspectorMaximum(splitWidth: minimum, sidebarWidth: layout.minSidebarWidth)
        #expect(inspector == 560)
        // And the page it leaves is still a page: the squeeze floor is the most the drag may take.
        #expect(layout.minSidebarWidth + layout.contentSqueezeWidth + inspector + 2 <= minimum + 0.5)
    }

    @Test("A pane is never capped below its own minimum, however narrow the window is")
    func panesAreNeverCappedBelowTheirMinimum() {
        let layout = self.appLayout
        // A window far below the minimum the app enforces — a state AppKit should never be handed, and the
        // arithmetic has to stay sane for it anyway.
        for width in stride(from: 300, through: 1267, by: 100) {
            let width = CGFloat(width)
            let sidebar = layout.sidebarMaximum(
                splitWidth: width,
                inspectorWidth: 300,
                columnOpen: true
            )
            let inspector = layout.inspectorMaximum(splitWidth: width, sidebarWidth: sidebar)
            #expect(sidebar >= layout.minSidebarWidth)
            #expect(inspector >= layout.minInspectorWidth)
        }
    }

    @Test("The two side panes and the squeeze floor always add up to the split view")
    func panesAndSqueezeFloorAlwaysFit() {
        let layout = self.appLayout
        for width in stride(from: 1267, through: 2000, by: 1) {
            let width = CGFloat(width)
            let sidebar = layout.sidebarMaximum(splitWidth: width, inspectorWidth: 560, columnOpen: true)
            let inspector = layout.inspectorMaximum(splitWidth: width, sidebarWidth: sidebar)
            #expect(
                sidebar + layout.contentSqueezeWidth + inspector + 2 <= width,
                "the panes need more than \(Int(width))pt"
            )
        }
    }

    @Test("A wide window lets the panes reach their own maxima")
    func wideWindowLetsThePanesGrow() {
        let layout = self.appLayout
        // 500 + 200 + 560 + 2 = 1262 is where the column can be as wide as it is ever allowed to be.
        #expect(layout.inspectorMaximum(splitWidth: 1262, sidebarWidth: 200) == 560)
        #expect(layout.inspectorMaximum(splitWidth: 2000, sidebarWidth: 200) == 560)
        // The sidebar reaches its 300 at 500 + 300 + 300 + 2 = 1102.
        #expect(layout.sidebarMaximum(splitWidth: 1102, inspectorWidth: 300, columnOpen: true) == 300)
        // And the two are consistent: what is left for the column after a full-width sidebar is its own
        // share of the same window.
        let sidebar = layout.sidebarMaximum(splitWidth: 1400, inspectorWidth: 300, columnOpen: true)
        let inspector = layout.inspectorMaximum(splitWidth: 1400, sidebarWidth: sidebar)
        #expect(sidebar + layout.contentSqueezeWidth + inspector + 2 <= 1400)
    }

    @Test("A closed column does not reserve the column's width")
    func closedColumnDoesNotReserveItsWidth() {
        let layout = self.appLayout
        // With the column closed the sidebar keeps its whole range at the window's own minimum (967),
        // because nothing but the page is beside it — and the page is the pane that gives way.
        #expect(layout.sidebarMaximum(splitWidth: 967, inspectorWidth: 300, columnOpen: false) == 300)
        #expect(layout.sidebarMaximum(splitWidth: 1367, inspectorWidth: 300, columnOpen: false) == 300)
        #expect(layout.sidebarMaximum(splitWidth: 1267, inspectorWidth: 300, columnOpen: false) == 300)
    }
}
