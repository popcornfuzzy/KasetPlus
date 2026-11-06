import AppKit
import SwiftUI
import Testing

@testable import Kaset

/// The sidebar's window observations, and the moment they can be installed.
///
/// The coordinator follows the **window**: its key state decides the selected row's emphasis, and who
/// holds its focus is what a page takes away when it focuses a control of its own. Both are facts about
/// a window, and SwiftUI runs `makeNSView`/`updateNSView` while the representable's view is not in one.
/// The observations were installed from there, so they were never installed at all: the rows were stamped
/// once by the retry loop and nothing restored them when AppKit un-emphasised the selected row on the
/// focus change — a grey pill the reader could see, with no effect in the app's source to find.
///
/// This states the arrangement that broke: attach with the view in no window (what SwiftUI does), then
/// put the view in one. The install has to happen on the second step, and `BackingView.viewDidMoveToWindow`
/// is what makes it.
@MainActor
@Suite(.tags(.model))
struct SidebarWindowObservationTests {
    /// A table with a row count the test can move, so a scroll can reach a list that has rows.
    private final class StubSource: NSObject, NSTableViewDataSource {
        var rows = 0

        func numberOfRows(in tableView: NSTableView) -> Int {
            self.rows
        }
    }

    /// Advances the run loop so the view's move into the window is delivered.
    private func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
    }

    private func host(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.orderBack(nil)
        return window
    }

    @Test("The window observations install when the view enters a window, not before")
    func observationsInstallWhenTheViewEntersAWindow() {
        let configurator = SidebarBackingStyleConfigurator()
        let coordinator = configurator.makeCoordinator()
        let view = SidebarBackingStyleConfigurator.BackingView(frame: NSRect(x: 0, y: 0, width: 240, height: 320))
        view.coordinator = coordinator

        // What SwiftUI does: the view is built and attached with no window behind it yet.
        coordinator.attach(to: view)
        #expect(
            !coordinator.isObservingWindow,
            "the coordinator claimed to be observing a window it has none of"
        )

        let window = self.host(view)
        self.pump(0.5)

        #expect(
            coordinator.isObservingWindow,
            "the sidebar went into a window without ever observing it — the selected row's emphasis can then never be repaired after a page takes the focus"
        )
        window.orderOut(nil)
    }

    @Test("Repeated attaches do not stack a second set of observations")
    func attachingRepeatedlyIsIdempotent() {
        let configurator = SidebarBackingStyleConfigurator()
        let coordinator = configurator.makeCoordinator()
        let view = SidebarBackingStyleConfigurator.BackingView(frame: NSRect(x: 0, y: 0, width: 240, height: 320))
        view.coordinator = coordinator

        let window = self.host(view)
        self.pump(0.2)
        for _ in 0 ..< 5 {
            coordinator.attach(to: view)
        }
        self.pump(0.2)

        #expect(coordinator.isObservingWindow)
        // The window's observers are registered under the key-state notification only once: five attaches
        // must not leave five of them behind, each re-walking every row on a focus change.
        #expect(
            coordinator.windowObserverCount <= 2,
            "the coordinator registered \(coordinator.windowObserverCount) window observers"
        )
        window.orderOut(nil)
    }

    /// A row the list builds *after* the emphasis loop has looked once still gets the window's emphasis.
    ///
    /// This is the launch report: the window was key and the selected row drew with the dimmed highlight,
    /// and a click in the sidebar was what put it right. The click was a focus change, which is a repair
    /// this coordinator already follows — the rows themselves were not, and the list builds them late (the
    /// library arrives after launch, and a row scrolled into view is built the same way). A corrected pass
    /// therefore has to be followed by a list that keeps being followed.
    @Test("A row built after the first pass is stamped when the list scrolls")
    func scrollingRestampsRows() {
        let source = StubSource()
        source.rows = 40
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 320))
        table.dataSource = source
        table.rowHeight = 24
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = table

        let row = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 320))
        pane.addSubview(scrollView)
        pane.addSubview(row)

        let configurator = SidebarBackingStyleConfigurator()
        let coordinator = configurator.makeCoordinator()

        let anchor = SidebarBackingStyleConfigurator.BackingView(frame: NSRect(x: 0, y: 0, width: 240, height: 320))
        anchor.coordinator = coordinator
        pane.addSubview(anchor)

        let splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        splitView.isVertical = true
        splitView.addSubview(pane)
        let window = self.host(splitView)

        // A row as the list builds one: not in the window's state.
        let emphasized = window.isKeyWindow
        row.isEmphasized = !emphasized
        coordinator.attach(to: anchor)
        self.pump(0.3)

        #expect(coordinator.observedTable === table, "the coordinator never found the list's table")
        #expect(row.isEmphasized == emphasized, "the first pass did not stamp the row")

        // What a scroll does: the row is a fresh view in the wrong state, and only a re-stamp of the rows
        // on screen can bring it back in step.
        row.isEmphasized = !emphasized
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 96))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        self.pump(0.3)

        #expect(row.isEmphasized == emphasized, "the list's scroll left the row in the dimmed style")
        window.orderOut(nil)
    }
}
