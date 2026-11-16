import AppKit
import SwiftUI
import Testing

@testable import Kaset

/// The window toolbar's item order.
///
/// The order is the mechanism, not a detail: each tracking separator bounds the region before it, and the
/// region's items are laid out against its trailing edge — so "the page's controls stop at the Now Playing
/// column" is a statement about this array, and about nothing else. It is covered here because the window
/// it drives cannot be.
@Suite("Window toolbar item order")
@MainActor
struct WindowToolbarLayoutTests {
    private func items(
        tracksColumn: Bool = false,
        showsAI: Bool = false,
        showsNowPlayingToggle: Bool = false,
        canGoBack: Bool = false,
        pageTitle: String = "Test Page",
        hasPageControls: Bool = false,
        hasSidebarHeader: Bool = false
    ) -> WindowToolbarItems {
        WindowToolbarItems(
            tracksColumn: tracksColumn,
            showsAI: showsAI,
            showsNowPlayingToggle: showsNowPlayingToggle,
            canGoBack: canGoBack,
            pageTitle: pageTitle,
            pageControls: hasPageControls
                ? PageToolbarContribution(id: "test", content: AnyView(EmptyView()))
                : nil,
            sidebarHeader: hasSidebarHeader
                ? NowPlayingSidebarToolbarHeader(title: "Up Next", onBack: {})
                : nil,
            onBack: {},
            onAI: {}
        )
    }

    @Test("A window with only a sidebar is the sidebar's toggle, separator, and the page's name")
    func sidebarOnly() throws {
        let identifiers = self.items().identifiers
        #expect(identifiers.first == .toggleSidebar)
        let separator = try #require(identifiers.firstIndex(of: .sidebarTrackingSeparator))
        #expect(separator == 1)
        // The page's name is always in the toolbar — it is what the window's hidden title would say.
        let title = try #require(identifiers.firstIndex(of: WindowToolbarItem.pageTitle))
        #expect(title == separator + 1)
        #expect(identifiers.count == 3)
    }

    @Test("The page's back control is the first item in the page's own region, and only while it can pop")
    func backControlLeadsThePageRegion() throws {
        let identifiers = self.items(canGoBack: true, hasPageControls: true).identifiers
        let separator = try #require(identifiers.firstIndex(of: .sidebarTrackingSeparator))
        let back = try #require(identifiers.firstIndex(of: WindowToolbarItem.back))
        #expect(back == separator + 1, "the back control must lead the region the sidebar bounds")
        let title = try #require(identifiers.firstIndex(of: WindowToolbarItem.pageTitle))
        #expect(title == back + 2, "the page's name sits beside the back control, past the space that ends its capsule")
        let controls = try #require(identifiers.firstIndex(of: WindowToolbarItem.pageControls))
        #expect(title < controls, "the name comes before anything the page does")
    }

    @Test("The page's name is a hosted plain-text view, and it draws at a size")
    func pageTitleIsHosted() throws {
        let controller = WindowToolbarController()
        controller.apply(
            items: self.items(canGoBack: true, pageTitle: "My Playlist 1"),
            onAI: {}
        )
        let item = try #require(
            controller.toolbar(
                NSToolbar(identifier: NSToolbar.Identifier("Kaset.tests.pageTitle")),
                itemForItemIdentifier: WindowToolbarItem.pageTitle,
                willBeInsertedIntoToolbar: true
            )
        )
        #expect(item.view is NSHostingView<AnyView>)
        // Unbordered: the name is plain titlebar text, and a bordered item is what AppKit draws the
        // glass capsule behind.
        #expect(item.isBordered == false)

        // Plain text, not a control: a name that collapsed to zero width would leave a pushed page
        // anonymous, and one drawn as a button would read as part of the back control.
        let host = NSHostingView(
            rootView: WindowToolbarTitleView(title: "My Playlist 1")
        )
        host.layout()
        #expect(host.fittingSize.width > 20)
        #expect(host.fittingSize.height > 10)
    }

    @Test("At a root the page's name leads the region with no back control ahead of it")
    func pageTitleLeadsAtTheRoot() throws {
        let identifiers = self.items().identifiers
        let separator = try #require(identifiers.firstIndex(of: .sidebarTrackingSeparator))
        let title = try #require(identifiers.firstIndex(of: WindowToolbarItem.pageTitle))
        #expect(title == separator + 1)
        #expect(!identifiers.contains(WindowToolbarItem.back))
    }

    @Test("A page that cannot pop has no back control")
    func noBackControlAtTheRoot() {
        #expect(!self.items().identifiers.contains(WindowToolbarItem.back))
        #expect(!self.items(tracksColumn: true, hasPageControls: true).identifiers.contains(WindowToolbarItem.back))
    }

    @Test("An open column adds its tracking separator")
    func openColumn() {
        #expect(self.items(tracksColumn: true).identifiers.contains(.inspectorTrackingSeparator))
    }

    @Test("A closed column has no inspector region and no separator")
    func closedColumnHasNoRegion() {
        #expect(!self.items().identifiers.contains(.inspectorTrackingSeparator))
    }

    @Test("The column's toggle is the window's last item, open or closed")
    func toggleIsLast() {
        #expect(self.items(showsNowPlayingToggle: true).identifiers.last == WindowToolbarItem.nowPlaying)
        let open = self.items(tracksColumn: true, showsNowPlayingToggle: true).identifiers
        #expect(open.last == WindowToolbarItem.nowPlaying)
        // The last item of a run is not the same as the trailing edge: what the reader sees is the
        // flexible space in the toggle's own region, which `toggleAlwaysTrailsItsRegion` states.
    }

    /// The closed column is the case a reader hit: with no page controls and no Ask AI button, the page
    /// region's right-aligned run is empty, so the toggle had nothing in front of it to carry it right and
    /// was drawn beside the page's name.
    @Test("A closed column's toggle is still the window's trailing control, with nothing else on the right")
    func closedColumnToggleIsTrailing() {
        #expect(
            self.items(showsNowPlayingToggle: true).identifiers == [
                .toggleSidebar,
                .sidebarTrackingSeparator,
                WindowToolbarItem.pageTitle,
                .flexibleSpace,
                WindowToolbarItem.nowPlaying,
            ]
        )
        // And on a pushed page the back control and the name lead, ahead of the same flexible space.
        #expect(
            self.items(showsNowPlayingToggle: true, canGoBack: true).identifiers == [
                .toggleSidebar,
                .sidebarTrackingSeparator,
                WindowToolbarItem.back,
                .space,
                WindowToolbarItem.pageTitle,
                .flexibleSpace,
                WindowToolbarItem.nowPlaying,
            ]
        )
    }

    /// Whatever the window has on screen, the toggle is the last item and its own region holds the flexible
    /// space that pushes it to the trailing edge. This is stated as a sweep because the placement is what
    /// the reader sees, and every input the toolbar takes can change the items around it.
    @Test("The toggle trails its region in every combination the window can be in")
    func toggleAlwaysTrailsItsRegion() throws {
        for tracksColumn in [false, true] {
            for showsAI in [false, true] {
                for hasPageControls in [false, true] {
                    for canGoBack in [false, true] {
                        for hasHeader in [false, true] {
                            let identifiers = self.items(
                                tracksColumn: tracksColumn,
                                showsAI: showsAI,
                                showsNowPlayingToggle: true,
                                canGoBack: canGoBack,
                                hasPageControls: hasPageControls,
                                hasSidebarHeader: hasHeader
                            ).identifiers

                            #expect(identifiers.last == WindowToolbarItem.nowPlaying, "toggle is not last in \(identifiers)")
                            // The region the toggle lives in: after the last tracking separator, before it.
                            let regionStart = identifiers.lastIndex {
                                $0 == .sidebarTrackingSeparator || $0 == .inspectorTrackingSeparator
                            }
                            let region = identifiers[(regionStart ?? 0)...].dropLast()
                            #expect(
                                region.contains(.flexibleSpace),
                                "nothing pushes the toggle right in \(identifiers)"
                            )
                            // A closed column has one region, so exactly one flexible space keeps its run
                            // — toggle included — together at the trailing edge.
                            if !tracksColumn {
                                #expect(
                                    identifiers.filter { $0 == .flexibleSpace }.count == 1,
                                    "the page region's run is split in \(identifiers)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("While the column is open the toggle is pushed to the inspector region's trailing edge")
    func toggleIsTrailingInTheInspectorRegion() throws {
        let identifiers = self.items(tracksColumn: true, showsNowPlayingToggle: true).identifiers
        let separator = try #require(identifiers.firstIndex(of: .inspectorTrackingSeparator))
        let space = try #require(identifiers.firstIndex(of: .flexibleSpace))
        let toggle = try #require(identifiers.firstIndex(of: WindowToolbarItem.nowPlaying))
        // Without the space the item would sit against the separator — the leading edge of the region
        // above the column — instead of the window's trailing edge, where an inspector toggle belongs.
        #expect(separator < space)
        #expect(space < toggle)
    }

    @Test("A closed column's toggle shares the page's right-aligned run, so it is not a gap of its own")
    func closedColumnToggleSharesTheRun() throws {
        let identifiers = self.items(showsNowPlayingToggle: true, hasPageControls: true).identifiers
        let space = try #require(identifiers.firstIndex(of: .flexibleSpace))
        let controls = try #require(identifiers.firstIndex(of: WindowToolbarItem.pageControls))
        let toggle = try #require(identifiers.firstIndex(of: WindowToolbarItem.nowPlaying))
        #expect(space < controls, "the run must be pushed by the flexible space")
        #expect(controls < toggle, "the toggle comes after the page's own controls")
        #expect(identifiers.filter { $0 == .flexibleSpace }.count == 1)
        // A fixed space ends the page's capsule, so the toggle is drawn as its own control: macOS 26
        // fills one glass platter behind a contiguous run of bordered items.
        #expect(identifiers[toggle - 1] == .space, "the toggle is drawn as part of the page's controls")
    }

    @Test("The page's controls sit before the column's tracking separator, not after it")
    func pageControlsAreBoundedByTheColumn() throws {
        let identifiers = self.items(tracksColumn: true, hasPageControls: true).identifiers
        let controls = try #require(identifiers.firstIndex(of: WindowToolbarItem.pageControls))
        let separator = try #require(identifiers.firstIndex(of: .inspectorTrackingSeparator))
        #expect(controls < separator)
    }

    @Test("One flexible space pushes the page's controls to the region's trailing edge")
    func oneFlexibleSpacePushesTheRun() throws {
        let identifiers = self.items(hasPageControls: true).identifiers
        let space = try #require(identifiers.firstIndex(of: .flexibleSpace))
        let controls = try #require(identifiers.firstIndex(of: WindowToolbarItem.pageControls))
        #expect(space < controls)
        #expect(identifiers.filter { $0 == .flexibleSpace }.count == 1)
    }

    @Test("With nothing right-aligned there is nothing to push, and no flexible space")
    func noRunMeansNoFlexibleSpace() {
        #expect(!self.items().identifiers.contains(.flexibleSpace))
        #expect(!self.items(tracksColumn: true).identifiers.contains(.flexibleSpace))
    }

    @Test("A page with no controls adds no item")
    func noContributionMeansNoItem() {
        #expect(!self.items(tracksColumn: true).identifiers.contains(WindowToolbarItem.pageControls))
    }

    @Test("The column's header leads the region above the column, and the toggle still trails it")
    func sidebarHeaderLeadsTheColumnRegion() throws {
        let identifiers = self.items(
            tracksColumn: true,
            showsNowPlayingToggle: true,
            hasSidebarHeader: true
        ).identifiers
        let separator = try #require(identifiers.firstIndex(of: .inspectorTrackingSeparator))
        let header = try #require(identifiers.firstIndex(of: WindowToolbarItem.sidebarHeader))
        #expect(header == separator + 1, "the column's header must lead the region above the column")
        // The header is not part of a right-aligned run, so the flexible space after it still pushes only
        // the toggle to the window's trailing edge.
        let space = try #require(identifiers.firstIndex(of: .flexibleSpace))
        let toggle = try #require(identifiers.firstIndex(of: WindowToolbarItem.nowPlaying))
        #expect(header < space)
        #expect(space < toggle)
        #expect(identifiers.filter { $0 == .flexibleSpace }.count == 1)
    }

    @Test("The column's header item is a hosted view, and the header it draws has a size")
    func sidebarHeaderIsHosted() throws {
        let controller = WindowToolbarController()
        let item = try #require(
            controller.toolbar(
                NSToolbar(identifier: NSToolbar.Identifier("Kaset.tests.header")),
                itemForItemIdentifier: WindowToolbarItem.sidebarHeader,
                willBeInsertedIntoToolbar: true
            )
        )
        #expect(item.view is NSHostingView<AnyView>)

        // The header is the same shape the column used to draw itself, so it must lay out to more than
        // nothing — a hosted view that collapses to zero width is an item the toolbar would draw as a gap.
        let host = NSHostingView(
            rootView: NowPlayingSidebarToolbarHeaderView(
                header: NowPlayingSidebarToolbarHeader(title: "Up Next", onBack: {})
            )
        )
        host.layout()
        #expect(host.fittingSize.width > 20)
        #expect(host.fittingSize.height > 10)
    }

    @Test("No column header without a page of the column, and none while the column is closed")
    func noSidebarHeaderWithoutAPage() {
        #expect(!self.items(tracksColumn: true).identifiers.contains(WindowToolbarItem.sidebarHeader))
        // A closed column has no region above it, so the header has nowhere to be drawn.
        #expect(
            !self.items(hasSidebarHeader: true).identifiers.contains(WindowToolbarItem.sidebarHeader),
            "a header was stated for a column that is not open"
        )
    }

    @Test("The AI button and the page's controls share one right-aligned run, AI first")
    func sharedRightAlignedRun() throws {
        let identifiers = self.items(showsAI: true, hasPageControls: true).identifiers
        let space = try #require(identifiers.firstIndex(of: .flexibleSpace))
        let ai = try #require(identifiers.firstIndex(of: WindowToolbarItem.ai))
        let controls = try #require(identifiers.firstIndex(of: WindowToolbarItem.pageControls))
        #expect(space < ai)
        #expect(ai < controls)
    }

    @Test("Two bordered controls are separated, so macOS cannot draw them as one capsule")
    func borderedControlsAreSeparated() throws {
        let identifiers = self.items(showsAI: true, hasPageControls: true).identifiers
        let ai = try #require(identifiers.firstIndex(of: WindowToolbarItem.ai))
        let controls = try #require(identifiers.firstIndex(of: WindowToolbarItem.pageControls))
        // macOS 26 fills one glass capsule behind a contiguous run of items. A fixed space is a real item,
        // so the run is broken and the Ask AI button and the page's controls keep their own shapes.
        #expect(controls == ai + 2)
        #expect(identifiers[ai + 1] == .space)
    }

    @Test("A lone bordered control needs no separator")
    func loneControlKeepsNoSeparator() {
        #expect(!self.items(hasPageControls: true).identifiers.contains(.space))
        #expect(!self.items(showsAI: true).identifiers.contains(.space))
    }
}

/// The name the Now Playing column's header shows, per page.
///
/// The column draws no header of its own any more, so this is what the toolbar puts in the band above the
/// column — and the overview must state none, because it *is* the top of the column: there is nothing
/// above it to go back to, and no name to label it with.
@Suite("Now Playing column header titles")
@MainActor
struct NowPlayingSidebarHeaderTitleTests {
    @Test("Every page but the overview names itself")
    func pageTitles() {
        #expect(NowPlayingSidebarPage.overview.toolbarTitle == nil)
        #expect(NowPlayingSidebarPage.lyrics.toolbarTitle != nil)
        #expect(NowPlayingSidebarPage.queue.toolbarTitle != nil)
        // Two pages, two names: a header that showed the same word for both would not say where the
        // reader is.
        #expect(NowPlayingSidebarPage.lyrics.toolbarTitle != NowPlayingSidebarPage.queue.toolbarTitle)
    }
}

/// What the page on screen publishes, and what happens when pages come and go.
@Suite("Page toolbar contributions")
@MainActor
struct PageToolbarModelTests {
    @Test("A page's controls are published, and taken away again by the same page")
    func publishAndRetract() {
        let model = PageToolbarModel()
        #expect(model.contribution == nil)

        model.contribute(PageToolbarContribution(id: "library", content: AnyView(EmptyView())))
        #expect(model.contribution?.id == "library")

        model.retract(id: "library")
        #expect(model.contribution == nil)
    }

    @Test("A retraction from a page that is no longer published is ignored")
    func staleRetractionIsIgnored() {
        let model = PageToolbarModel()
        model.contribute(PageToolbarContribution(id: "library", content: AnyView(EmptyView())))
        // The incoming page appears before the outgoing one disappears, so the outgoing page's retraction
        // must not clear the controls the reader is now looking at.
        model.contribute(PageToolbarContribution(id: "playlist-1", content: AnyView(EmptyView())))

        model.retract(id: "library")

        #expect(model.contribution?.id == "playlist-1")
    }

    @Test("Popping a destination falls back to the root underneath, which never retracted")
    func popFallsBackToTheRoot() {
        let model = PageToolbarModel()
        // The root stays mounted while the destination is pushed over it: it publishes once and never
        // retracts until the whole page goes away.
        model.contribute(PageToolbarContribution(id: "library", content: AnyView(EmptyView())))
        model.contribute(PageToolbarContribution(id: "playlist-1", content: AnyView(EmptyView())))
        #expect(model.contribution?.id == "playlist-1")

        model.retract(id: "playlist-1")
        #expect(model.contribution?.id == "library")
    }

    @Test("A re-publication moves the page back on top instead of stacking a duplicate")
    func republishMovesOnTop() {
        let model = PageToolbarModel()
        model.contribute(PageToolbarContribution(id: "library", content: AnyView(EmptyView())))
        model.contribute(PageToolbarContribution(id: "playlist-1", content: AnyView(EmptyView())))
        model.contribute(PageToolbarContribution(id: "library", content: AnyView(EmptyView())))

        model.retract(id: "library")
        #expect(model.contribution?.id == "playlist-1")
        model.retract(id: "playlist-1")
        #expect(model.contribution == nil)
    }

    @Test("The last page to publish wins")
    func lastPublisherWins() {
        let model = PageToolbarModel()
        model.contribute(PageToolbarContribution(id: "library", content: AnyView(EmptyView())))
        model.contribute(PageToolbarContribution(id: "history", content: AnyView(EmptyView())))

        #expect(model.contribution?.id == "history")
    }
}

// MARK: - Window toolbar geometry

/// Where the window actually draws the toolbar's controls.
///
/// The item list is the mechanism (`WindowToolbarLayoutTests` covers it), but "the toggle is at the
/// window's trailing edge" is a claim about a laid-out window: a flexible space only does that if AppKit
/// honours it, and the item before the toggle is what a reader sees beside it. So this hosts the app's
/// toolbar the way the app does — one split view with a sidebar, a page and the Now Playing column — and
/// measures the control in it.
///
/// The control is found by the accessibility label of the item the app states (`NSToolbarItem.label`),
/// not by AppKit's private item-viewer class name: the label is the item's own, so it survives AppKit
/// rebuilding its views.
@Suite("Window toolbar geometry", .serialized)
@MainActor
struct WindowToolbarGeometryTests {
    private static let windowWidth: CGFloat = 1240

    /// The app's window, minus the app: the same split view items and the same toolbar controller.
    private func host(
        tracksColumn: Bool,
        showsAI: Bool = false,
        hasPageControls: Bool = false,
        canGoBack: Bool = false
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 800),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // The chrome the shell asserts (`WindowShellController.applyWindowChrome`): the titlebar is the
        // toolbar's band, and the title itself is hidden, so nothing flexible sits ahead of the items.
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        let split = NSSplitViewController()
        let sidebar = NSViewController()
        sidebar.view = NSView()
        let content = NSViewController()
        content.view = NSView()
        let inspector = NSViewController()
        inspector.view = NSView()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = true
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = !tracksColumn
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        split.addSplitViewItem(inspectorItem)

        window.contentViewController = split
        window.setContentSize(NSSize(width: Self.windowWidth, height: 800))
        window.layoutIfNeeded()

        let controller = WindowToolbarController()
        controller.apply(
            items: WindowToolbarItems(
                tracksColumn: tracksColumn,
                showsAI: showsAI,
                showsNowPlayingToggle: true,
                canGoBack: canGoBack,
                pageTitle: canGoBack ? "Album" : "Home",
                pageControls: hasPageControls
                    ? PageToolbarContribution(id: "geometry-test", content: AnyView(Button("Search") {}))
                    : nil,
                sidebarHeader: nil,
                onBack: {},
                onAI: {}
            ),
            onAI: {}
        )
        controller.install(in: window)
        window.layoutIfNeeded()
        self.pump()
        return window
    }

    /// Runs the run loop long enough for the toolbar to lay its items out.
    private func pump() {
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// The Now Playing toggle's frame in window coordinates, or `nil` while the toolbar has none.
    private func toggleFrame(in window: NSWindow) -> NSRect? {
        self.frame(ofItem: WindowToolbarItem.nowPlaying, in: window)
    }

    /// A toolbar item's control, in window coordinates, found by the item's own label.
    ///
    /// Matched by the label of the item the app stated, so the lookup does not depend on a localized
    /// string or on a private view class.
    private func frame(ofItem identifier: NSToolbarItem.Identifier, in window: NSWindow) -> NSRect? {
        guard let item = window.toolbar?.items.first(where: { $0.itemIdentifier == identifier }) else {
            return nil
        }
        // A hosted item (the page's name, the column's header, the page's controls) has a view of the
        // app's own, so its frame is the item's. A system-drawn one has none and is found by its label.
        if let hosted = item.view, hosted.window != nil {
            return hosted.convert(hosted.bounds, to: nil)
        }
        let label = item.label
        guard let root = window.contentView?.superview else { return nil }

        var found: NSRect?
        func walk(_ view: NSView) {
            if view is NSButton, view.accessibilityLabel() == label {
                found = view.convert(view.bounds, to: nil)
            }
            for subview in view.subviews {
                walk(subview)
            }
        }
        walk(root)
        return found
    }

    private func assertTrailing(_ frame: NSRect, in window: NSWindow, _ description: Comment) {
        let width = window.contentView?.bounds.width ?? 0
        // The control's own trailing margin — a few points, the toolbar's inset — not a gap that
        // depends on how much the items to its left happen to occupy.
        #expect(
            frame.maxX >= width - 12,
            "\(description): the toggle's right edge is at \(Int(frame.maxX)) in a \(Int(width))pt window"
        )
        // And it is not in the page region's leading run, where the page's name is.
        #expect(
            frame.minX > width * 0.75,
            "\(description): the toggle sits at x=\(Int(frame.minX)) — beside the page's leading items, not the trailing edge"
        )
    }

    @Test("A closed column leaves the Now Playing toggle at the window's trailing edge")
    func closedColumnToggleIsTrailing() throws {
        // The page a reader starts on: no page controls and no Ask AI button, so nothing else is in
        // the right-aligned run — the case the toggle used to be drawn beside the page's name in.
        let window = self.host(tracksColumn: false)
        defer { window.orderOut(nil) }
        let toggle = try #require(self.toggleFrame(in: window), "the toolbar drew no Now Playing toggle")
        self.assertTrailing(toggle, in: window, "closed column, nothing else on the right")
    }

    @Test("An open column leaves the Now Playing toggle at the window's trailing edge")
    func openColumnToggleIsTrailing() throws {
        let window = self.host(tracksColumn: true)
        defer { window.orderOut(nil) }
        let toggle = try #require(self.toggleFrame(in: window), "the toolbar drew no Now Playing toggle")
        self.assertTrailing(toggle, in: window, "open column")
    }

    @Test("A page's own controls and the AI button do not push the toggle in from the edge")
    func crowdedPageKeepsTheToggleTrailing() throws {
        let window = self.host(tracksColumn: false, showsAI: true, hasPageControls: true)
        defer { window.orderOut(nil) }
        let toggle = try #require(self.toggleFrame(in: window), "the toolbar drew no Now Playing toggle")
        self.assertTrailing(toggle, in: window, "closed column, Ask AI and page controls")
    }

    /// The reported macOS 26 defect, stated as the number it is: the back control and the page's name are
    /// laid out **after** the window's title view, so a title view left in the row moves them — and every
    /// item after them — towards the right-hand run. At 1240pt with the sidebar at its 200pt minimum they
    /// lead the page's region at x=187/229. With a title view ahead of them they measured x=347/391, beside
    /// the page's other controls.
    @Test("A pushed page's back control and name lead the page's region, not the right-hand run")
    func backControlLeadsThePageRegion() throws {
        let window = self.host(tracksColumn: false, canGoBack: true)
        defer { window.orderOut(nil) }

        let back = try #require(
            self.frame(ofItem: WindowToolbarItem.back, in: window),
            "the toolbar drew no back control"
        )
        // The region starts at the sidebar's divider: a page at its 200pt minimum puts every item it
        // leads in the first third of a 1240pt window. The number that matters is that it is not in the
        // right-hand run — where the failure puts it.
        #expect(
            back.minX < Self.windowWidth / 3,
            "the back control sits at x=\(Int(back.minX)) — laid out after the window's title view"
        )

        let title = try #require(
            self.frame(ofItem: WindowToolbarItem.pageTitle, in: window),
            "the toolbar drew no page name"
        )
        #expect(title.minX < Self.windowWidth / 2, "the page's name sits at x=\(Int(title.minX))")
        #expect(back.maxX <= title.minX, "the name is not beside the control it belongs to")
    }

    /// The row itself: with the title hidden there must be no title view ahead of the items, and the first
    /// item must start at the window's leading edge. This is AppKit's state, not the app's, which is why it
    /// is read out of the window's view tree (`ToolbarRowSnapshot`) and asserted here.
    @Test("A hidden title leaves no title view in the toolbar's row")
    func hiddenTitleLeavesNoTitleViewInTheRow() throws {
        let window = self.host(tracksColumn: true)
        defer { window.orderOut(nil) }
        let root = try #require(window.contentView?.superview)
        let reading = ToolbarRowSnapshot.read(root)
        #expect(
            !reading.hasTitleView,
            "AppKit kept a \(Int(reading.titleViewWidth ?? 0))pt title view in the row while the title is hidden"
        )
        let first = try #require(reading.firstItemX, "the toolbar laid no items out")
        #expect(first < 140, "the row's first item starts at x=\(Int(first)), not at the window's leading edge")
    }

    /// What the repair in `WindowShellController.checkTitleSlot` has to see: AppKit's own title
    /// view, found in the row it holds. With the title hidden on macOS 27 there is nothing to find — which
    /// is why the repair is a no-op here — so the view has to be raised by showing the title.
    @Test("The row's title view is found where AppKit draws one, and not while the title is hidden")
    func titleViewIsFound() throws {
        let window = self.host(tracksColumn: false, canGoBack: true)
        defer { window.orderOut(nil) }
        let root = try #require(window.contentView?.superview)

        #expect(ToolbarRowSnapshot.read(root).titleView == nil, "a hidden title left a view to drop")

        window.titleVisibility = .visible
        self.pump()

        let reading = ToolbarRowSnapshot.read(root)
        let titleView = try #require(reading.titleView, "the row holds a title but the read did not see it")
        #expect(titleView.convert(titleView.bounds, to: nil).width > 100, "the title view has no width to reclaim")
    }

    /// The repair's lever, measured: the page's name is drawn after the title view, so stating the title
    /// hidden is what moves it — and the page's region with it. Touching the view itself does not: hiding
    /// it leaves the frame the row was laid out around, and AppKit reinstates a removed one (both measured),
    /// which is why `checkTitleSlot` re-states the visibility and rebuilds the toolbar rather than
    /// reaching into AppKit's hierarchy.
    @Test("Stating the title hidden is what moves the page's name back to the leading edge")
    func hiddenTitleMovesThePageNameBack() throws {
        let window = self.host(tracksColumn: false, canGoBack: true)
        defer { window.orderOut(nil) }
        let root = try #require(window.contentView?.superview)

        let leading = try #require(self.frame(ofItem: WindowToolbarItem.pageTitle, in: window))

        // The state the repair exists for: a title view in the row, with the page's name laid out after
        // it — the reported "buttons and title in the wrong place".
        window.titleVisibility = .visible
        self.pump()
        let shifted = try #require(self.frame(ofItem: WindowToolbarItem.pageTitle, in: window))
        #expect(ToolbarRowSnapshot.read(root).hasTitleView)
        #expect(
            shifted.minX > leading.minX + 100,
            "the name sits at x=\(Int(shifted.minX)) — the title view did not move it"
        )

        window.titleVisibility = .hidden
        self.pump()

        #expect(!ToolbarRowSnapshot.read(root).hasTitleView)
        let moved = try #require(self.frame(ofItem: WindowToolbarItem.pageTitle, in: window))
        #expect(
            abs(moved.minX - leading.minX) < 20,
            "the name is back at x=\(Int(moved.minX)), not where the app placed it (x=\(Int(leading.minX)))"
        )
        #expect(moved.minX < Self.windowWidth / 2)
    }
}

// MARK: - Title slot repair

/// What the repair is allowed to act on.
///
/// It runs a runloop turn after the install that asked for it, so by then the shell can have been handed to
/// another window, or the window's toolbar can be something else's. Reconfiguring either would strip a
/// toolbar from a window the app no longer draws, or fight whatever replaced the app's.
@Suite("Toolbar title slot repair", .serialized)
@MainActor
struct ToolbarTitleSlotRepairTests {
    /// The shell hosted in its own window, with the app's toolbar installed.
    private func host() async -> (window: NSWindow, shell: WindowShellController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        // Not on the desktop: the window only has to exist for AppKit to lay it out.
        window.alphaValue = 0
        window.collectionBehavior = [.transient, .ignoresCycle]
        let shell = WindowShellController()
        window.contentViewController = shell
        window.orderBack(nil)

        // The install is deferred by one main-actor turn, so the toolbar arrives after a layout pass.
        try? await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
        return (window, shell)
    }

    @Test("It acts on the window it is hosting, and not over a toolbar it does not own")
    func actsOnlyOnItsOwnToolbar() async {
        let (window, shell) = await self.host()
        defer { window.orderOut(nil) }
        #expect(
            window.toolbar?.identifier == WindowToolbarController.toolbarIdentifier,
            "the shell did not install the app's toolbar"
        )
        #expect(
            shell.hostedWindow(window) === window,
            "the shell would not act on the window it is hosting"
        )

        window.toolbar = NSToolbar(identifier: NSToolbar.Identifier("Kaset.tests.foreign"))
        #expect(
            shell.hostedWindow(window) == nil,
            "the shell would reconfigure a toolbar that is not the app's"
        )
    }

    @Test("A window the shell no longer hosts is not acted on")
    func doesNotActOnAWindowItLeft() async {
        let (window, shell) = await self.host()
        defer { window.orderOut(nil) }

        window.contentViewController = NSViewController()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(
            shell.hostedWindow(window) == nil,
            "the shell would reconfigure a window it no longer hosts"
        )
    }
}

// MARK: - Tracking separators

/// The two separators that bound the page's region.
///
/// Left to itself AppKit aligns the standard separator identifiers with a split view it *discovers*, and the
/// app states its item list before the toolbar goes into the window. The app states each separator's split
/// view and divider index instead, so the region a page's controls are laid out in is the app's statement
/// rather than AppKit's inference — the piece of this bar that can differ between macOS versions.
@Suite("Toolbar tracking separators")
@MainActor
struct WindowToolbarTrackingSeparatorTests {
    private func controller(tracking splitView: NSSplitView?) -> WindowToolbarController {
        let controller = WindowToolbarController()
        controller.trackedSplitView = splitView
        controller.apply(
            items: WindowToolbarItems(
                tracksColumn: true,
                showsAI: false,
                showsNowPlayingToggle: true,
                canGoBack: true,
                pageTitle: "Album",
                pageControls: nil,
                sidebarHeader: nil,
                onBack: {},
                onAI: {}
            ),
            onAI: {}
        )
        return controller
    }

    @Test("Each separator is an item bound to the shell's own divider")
    func separatorsAreBoundToTheShellsDividers() throws {
        let split = NSSplitViewController()
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        split.addSplitViewItem(NSSplitViewItem(inspectorWithViewController: NSViewController()))
        let controller = self.controller(tracking: split.splitView)
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("Kaset.tests.separators"))

        let sidebar = try #require(
            controller.toolbar(
                toolbar,
                itemForItemIdentifier: .sidebarTrackingSeparator,
                willBeInsertedIntoToolbar: true
            ) as? NSTrackingSeparatorToolbarItem
        )
        #expect(sidebar.dividerIndex == 0, "the sidebar's divider is the first")
        #expect(sidebar.splitView === split.splitView)

        let column = try #require(
            controller.toolbar(
                toolbar,
                itemForItemIdentifier: .inspectorTrackingSeparator,
                willBeInsertedIntoToolbar: true
            ) as? NSTrackingSeparatorToolbarItem
        )
        #expect(column.dividerIndex == 1, "the column's divider is the second")
        #expect(column.splitView === split.splitView)
    }

    @Test("A controller with no split view leaves the separators to AppKit")
    func noSplitViewLeavesTheStandardSeparators() {
        let controller = self.controller(tracking: nil)
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("Kaset.tests.separators.none"))
        #expect(
            controller.toolbar(
                toolbar,
                itemForItemIdentifier: .sidebarTrackingSeparator,
                willBeInsertedIntoToolbar: true
            ) == nil
        )
        #expect(
            controller.toolbar(
                toolbar,
                itemForItemIdentifier: .inspectorTrackingSeparator,
                willBeInsertedIntoToolbar: true
            ) == nil
        )
    }
}
