import AppKit
import SwiftUI
import Testing

@testable import Kaset

/// Both sidebars' collapse and reopen, driven in an offscreen window.
///
/// The toggles are AppKit's, so whether a pane opens again is not something the app's source states: it
/// is whether the split item can be expanded in the width the window has, and whether a visibility the app
/// states is still current when it reaches the pane.
///
/// The waits are `Task.sleep`, not a pumped run loop: the shell defers its toolbar install and its column
/// visibility to the main actor (`installToolbar`, `scheduleInspectorVisibility`), and those tasks do not
/// run while a synchronous test spins `RunLoop.current` — a run-loop harness tests a shell that never
/// installs its toolbar and never applies a state change.
@MainActor
@Suite(.tags(.model))
struct WindowShellSidebarToggleTests {
    /// What the shell reports back to the app, recorded and — like `MainWindow` — fed back as app state.
    @MainActor
    private final class Recorder {
        var collapsedEvents: [Bool] = []
    }

    /// Holds the harness for the shell's callback, which is built before `self` exists.
    @MainActor
    private final class MirrorBox {
        weak var harness: Harness?
    }

    /// The shell hosted the way `MainWindow` hosts it, with the app's real numbers.
    @MainActor
    private final class Harness {
        let controller: WindowShellController
        let window: NSWindow
        let recorder: Recorder
        /// Whether a collapse the shell reports is fed back as the app's page state, as `MainWindow` does.
        var mirrorsAppState = true
        private let layout: WindowShellLayout

        init(width: CGFloat, showsInspector: Bool = true, usesPageStack: Bool = false) {
            let recorder = Recorder()
            self.recorder = recorder
            let box = MirrorBox()
            let layout = WindowShellLayout(
                minSidebarWidth: 200,
                maxSidebarWidth: 300,
                minContentWidth: 765,
                contentSqueezeWidth: 500,
                minWindowWidth: 900,
                minInspectorWidth: 300,
                maxInspectorWidth: 560,
                // Unique per harness: AppKit persists divider positions *and* collapse state under this
                // name, so a shared one lets one test's collapsed pane be restored into another's window.
                autosaveName: "KasetTests.WindowShellSidebarToggle.\(UUID().uuidString)"
            )
            self.layout = layout

            let content = AnyView(ShellPane { size, _ in
                let page = Color.green.frame(width: size.width, height: size.height)
                if usesPageStack {
                    // The page's own navigation stack, as every page in the window has one.
                    NavigationStack { page.navigationBarBackButtonHidden(true) }
                } else {
                    page
                }
            })
            let shell = WindowShell(
                sidebar: AnyView(ShellPane { size, _ in Color.red.frame(width: size.width, height: size.height) }),
                content: content,
                inspector: AnyView(ShellPane { size, _ in Color.blue.frame(width: size.width, height: size.height) }),
                layout: layout,
                showsInspector: showsInspector,
                seedInspectorWidth: 380,
                onInspectorCollapsedChange: { collapsed in
                    recorder.collapsedEvents.append(collapsed)
                    guard let harness = box.harness, harness.mirrorsAppState else { return }
                    // `MainWindow` answers on the next SwiftUI update, not inside AppKit's toggle.
                    Task { @MainActor in harness.apply(showsInspector: !collapsed) }
                },
                toolbar: WindowToolbarItems(
                    tracksColumn: showsInspector,
                    showsAI: false,
                    showsNowPlayingToggle: true,
                    canGoBack: false,
                    pageTitle: "Test",
                    pageControls: nil,
                    sidebarHeader: nil,
                    onBack: {},
                    onAI: {}
                ),
                windowTitle: "Test"
            )
            let hosting = NSHostingController(
                rootView: AnyView(
                    shell.frame(minWidth: layout.minimumWindowWidth(tracksColumn: showsInspector), minHeight: 600)
                )
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 820),
                styleMask: [.titled, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            self.window = window
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: width, height: 820))
            window.makeKeyAndOrderFront(nil)
            window.layoutIfNeeded()

            if let found = Self.splitController(inView: hosting.view) {
                self.controller = found
            } else {
                Issue.record("the shell did not install a split view controller")
                self.controller = WindowShellController()
            }
            box.harness = self
        }

        var sidebarItem: NSSplitViewItem? {
            self.controller.splitViewItems.first
        }

        var inspectorItem: NSSplitViewItem? {
            self.controller.splitViewItems.last
        }

        var splitWidth: CGFloat {
            self.controller.splitView.bounds.width
        }

        /// The width a pane is actually drawn at, which is what "open" has to mean.
        func paneWidth(_ index: Int) -> CGFloat {
            let panes = self.controller.splitView.arrangedSubviews
            guard panes.indices.contains(index) else { return -1 }
            return panes[index].frame.width
        }

        /// The toolbar item the window's sidebar toggle is, if the app's toolbar is in the window.
        var toolbarSidebarToggle: NSToolbarItem? {
            self.window.toolbar?.items.first { $0.itemIdentifier == .toggleSidebar }
        }

        private static func splitController(inView view: NSView) -> WindowShellController? {
            var stack = [view]
            while let candidate = stack.popLast() {
                if candidate is NSSplitView {
                    var responder: NSResponder? = candidate
                    while let current = responder {
                        if let shell = current as? WindowShellController { return shell }
                        responder = current.nextResponder
                    }
                }
                stack.append(contentsOf: candidate.subviews)
            }
            return nil
        }

        static func pause(_ milliseconds: Int) async {
            try? await Task.sleep(for: .milliseconds(milliseconds))
        }

        /// Waits for a pane to settle, rather than guessing how long AppKit's animation takes on a machine
        /// that is also running the rest of the suite.
        func waitUntil(
            _ description: String,
            timeout: TimeInterval = 3,
            _ condition: () -> Bool
        ) async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                await Self.pause(10)
            }
            Issue.record("timed out waiting for \(description)")
        }

        /// Lets the shell's deferred work run, and an AppKit animation finish, then lays the window out.
        func settle() async {
            try? await Task.sleep(for: .milliseconds(200))
            self.window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(500))
            self.window.layoutIfNeeded()
            self.controller.view.layoutSubtreeIfNeeded()
        }

        /// What `WindowShell.updateNSViewController` does when the app's state changes.
        func apply(showsInspector: Bool) {
            self.controller.apply(
                sidebar: AnyView(ShellPane { size, _ in Color.red.frame(width: size.width, height: size.height) }),
                content: AnyView(ShellPane { size, _ in Color.green.frame(width: size.width, height: size.height) }),
                inspector: AnyView(ShellPane { size, _ in Color.blue.frame(width: size.width, height: size.height) }),
                layout: self.layout,
                state: WindowShellState(showsInspector: showsInspector, seedInspectorWidth: 380),
                toolbar: WindowToolbarItems(
                    tracksColumn: showsInspector,
                    showsAI: false,
                    showsNowPlayingToggle: true,
                    canGoBack: false,
                    pageTitle: "Test",
                    pageControls: nil,
                    sidebarHeader: nil,
                    onBack: {},
                    onAI: {}
                ),
                windowTitle: "Test",
                onInspectorCollapsedChange: { collapsed in
                    self.recorder.collapsedEvents.append(collapsed)
                    guard self.mirrorsAppState else { return }
                    Task { @MainActor in self.apply(showsInspector: !collapsed) }
                }
            )
        }
    }

    @Test("The navigation sidebar reopens after its own toggle collapses it")
    func sidebarReopensAfterCollapse() async {
        let harness = Harness(width: 1280)
        defer { harness.window.orderOut(nil) }
        await harness.settle()

        guard let item = harness.sidebarItem else {
            Issue.record("no sidebar item")
            return
        }
        #expect(item.isCollapsed == false, "the sidebar did not start open")

        harness.controller.toggleSidebar(nil)
        await harness.settle()
        #expect(item.isCollapsed == true, "the toggle did not collapse the sidebar")

        harness.controller.toggleSidebar(nil)
        await harness.settle()
        #expect(item.isCollapsed == false, "the sidebar did not reopen")
        #expect(harness.paneWidth(0) >= 199, "the sidebar reopened at \(harness.paneWidth(0))pt wide")
    }

    @Test("The toolbar's own sidebar item reopens the sidebar")
    func toolbarItemReopensSidebar() async {
        let harness = Harness(width: 1280)
        defer { harness.window.orderOut(nil) }
        await harness.settle()

        guard let toggle = harness.toolbarSidebarToggle, let action = toggle.action else {
            Issue.record("the window has no sidebar toggle item")
            return
        }
        #expect(toggle.isEnabled, "the toggle starts disabled")

        _ = NSApplication.shared.sendAction(action, to: nil, from: toggle)
        await harness.settle()
        #expect(harness.sidebarItem?.isCollapsed == true, "the toolbar's toggle did not collapse the sidebar")

        harness.window.toolbar?.validateVisibleItems()
        #expect(toggle.isEnabled, "the toggle is disabled once the sidebar is collapsed")

        _ = NSApplication.shared.sendAction(action, to: nil, from: toggle)
        await harness.settle()
        #expect(harness.sidebarItem?.isCollapsed == false, "the toolbar's toggle did not reopen the sidebar")
    }

    @Test("The navigation sidebar reopens after a drag collapses it")
    func sidebarReopensAfterDragCollapse() async {
        let harness = Harness(width: 1280)
        defer { harness.window.orderOut(nil) }
        await harness.settle()

        guard let item = harness.sidebarItem else {
            Issue.record("no sidebar item")
            return
        }

        // A drag past the pane's minimum is AppKit's own collapse for a collapsible sidebar item.
        let split = harness.controller.splitView
        var x = item.viewController.view.frame.width
        while x > 0 {
            x -= 20
            split.setPosition(max(0, x), ofDividerAt: 0)
            harness.window.layoutIfNeeded()
            await Harness.pause(10)
        }
        split.setPosition(0, ofDividerAt: 0)
        await harness.settle()
        #expect(item.isCollapsed == true, "the drag did not collapse the sidebar")

        harness.controller.toggleSidebar(nil)
        await harness.settle()
        #expect(item.isCollapsed == false, "the toggle did not reopen a sidebar a drag collapsed")
        #expect(harness.paneWidth(0) >= 199, "the sidebar reopened at \(harness.paneWidth(0))pt wide")
    }

    @Test("The navigation sidebar reopens while a page's navigation stack is hosted")
    func sidebarReopensWithAPageStack() async {
        let harness = Harness(width: 1280, usesPageStack: true)
        defer { harness.window.orderOut(nil) }
        await harness.settle()

        guard let item = harness.sidebarItem else {
            Issue.record("no sidebar item")
            return
        }
        #expect(item.isCollapsed == false, "the sidebar did not start open")

        harness.controller.toggleSidebar(nil)
        await harness.settle()
        #expect(item.isCollapsed == true, "the toggle did not collapse the sidebar")
        #expect(harness.window.toolbar?.items.contains { $0.itemIdentifier == .toggleSidebar } == true, "the page's stack took the window's sidebar toggle")

        harness.controller.toggleSidebar(nil)
        await harness.settle()
        #expect(item.isCollapsed == false, "the sidebar did not reopen with a page's stack hosted")
        #expect(harness.paneWidth(0) >= 199, "the sidebar reopened at \(harness.paneWidth(0))pt wide")
    }

    @Test("The Now Playing column reopens after the navigation sidebar was collapsed")
    func inspectorReopensAfterSidebarCollapse() async {
        let harness = Harness(width: 1280)
        defer { harness.window.orderOut(nil) }
        await harness.settle()

        harness.controller.toggleSidebar(nil)
        await harness.settle()
        #expect(harness.sidebarItem?.isCollapsed == true)

        guard let inspector = harness.inspectorItem else {
            Issue.record("no inspector item")
            return
        }
        #expect(inspector.isCollapsed == false, "the column did not start open")

        harness.controller.toggleNowPlayingColumn()
        await harness.settle()
        #expect(inspector.isCollapsed == true, "the toggle did not close the column")

        harness.controller.toggleNowPlayingColumn()
        await harness.settle()
        #expect(inspector.isCollapsed == false, "the column did not reopen")
        #expect(harness.paneWidth(2) >= 299, "the column reopened at \(harness.paneWidth(2))pt wide")
    }

    /// The regression behind "the right sidebar won't open again".
    ///
    /// The reader's press collapses the pane and is reported to the app, whose state reaches the shell a
    /// turn later. If the reader presses again in between, the shell's next layout pass was still holding
    /// the previous visibility and re-applied it — closing a column the reader had just opened. The app's
    /// own log shows the pair: `collapsed=false`, then `collapsed=true` 33 ms later, on every press.
    @Test("A layout pass after the reader reopens the column does not close it again")
    func staleLayoutPassDoesNotCloseTheReopenedColumn() async {
        let harness = Harness(width: 1280)
        defer { harness.window.orderOut(nil) }
        await harness.settle()
        // Hold the app's answer back, so the stale pass is the same turn as the reader's second press.
        harness.mirrorsAppState = false

        guard let inspector = harness.inspectorItem else {
            Issue.record("no inspector item")
            return
        }
        #expect(inspector.isCollapsed == false)

        harness.controller.toggleNowPlayingColumn()
        await harness.waitUntil("the press to close the column") { inspector.isCollapsed }
        // Let AppKit's close animation finish, so the next press starts from a settled pane.
        await harness.settle()
        #expect(inspector.isCollapsed == true, "the press did not close the column")

        // The app catches up to "closed"; the reader opens the column again before the shell has run the
        // layout pass for that state.
        harness.apply(showsInspector: false)
        harness.controller.toggleNowPlayingColumn()
        harness.window.layoutIfNeeded()
        await Harness.pause(60)
        harness.window.layoutIfNeeded()
        await harness.settle()

        #expect(inspector.isCollapsed == false, "a layout pass re-closed the column the reader had opened")
        #expect(harness.paneWidth(2) >= 299, "the column ended at \(harness.paneWidth(2))pt wide")
    }
}
