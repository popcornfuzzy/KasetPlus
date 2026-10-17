import AppKit
import SwiftUI
import Testing

@testable import Kaset

/// The window's title, and the slot it holds in the toolbar's page region.
///
/// AppKit draws the window's title as a flexible view at the **leading** edge of the region right of the
/// sidebar's tracking separator, and lays the region's items out after it. So the page's own items cannot
/// lead their region while the title is visible, however the app orders them — which is what put the
/// back control next to the page's search/sort controls instead of at the left of the page, and what
/// stranded it there after leaving the fullscreen player. The page's name lives in the toolbar beside
/// the back control instead, so the title stays hidden in every state (see
/// `WindowShellController.applyTitleVisibility`).
///
/// This drives the real controller in a real window, because that is the only arrangement in which the
/// rule has any meaning: the title's visibility is the window's.
@MainActor
@Suite(.tags(.model))
struct WindowShellTitleTests {
    private func makeController() -> (WindowShellController, NSWindow) {
        let controller = WindowShellController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.orderBack(nil)
        window.layoutIfNeeded()
        return (controller, window)
    }

    private func apply(canGoBack: Bool, windowTitle: String = "Kaset", to controller: WindowShellController) {
        controller.apply(
            sidebar: AnyView(EmptyView()),
            content: AnyView(EmptyView()),
            inspector: AnyView(EmptyView()),
            layout: WindowShellLayout(),
            state: WindowShellState(showsInspector: false, seedInspectorWidth: 380),
            toolbar: WindowToolbarItems(
                tracksColumn: false,
                showsAI: false,
                showsNowPlayingToggle: false,
                canGoBack: canGoBack,
                pageTitle: "Test Page",
                pageControls: nil,
                sidebarHeader: nil,
                onBack: {},
                onAI: {}
            ),
            windowTitle: windowTitle,
            onInspectorCollapsedChange: { _ in }
        )
    }

    @Test("The title stays hidden with a back control, at a root, and after fullscreen")
    func titleStaysHiddenInEveryState() {
        let (controller, window) = self.makeController()
        defer { window.orderOut(nil) }

        // A pushed page: the back control leads only while the title holds no slot.
        self.apply(canGoBack: true, to: controller)
        #expect(
            window.titleVisibility == .hidden,
            "the title stayed visible, so the page's back control cannot lead its region"
        )

        // A root: the page's name is the toolbar's title item, so there is nothing to restore.
        self.apply(canGoBack: false, to: controller)
        #expect(
            window.titleVisibility == .hidden,
            "the title came back even though the page's name lives in the toolbar"
        )

        // Leaving the fullscreen player restores the toolbar with a visible title — the exact state
        // that used to strand the back control on the right until the window was reopened.
        window.toolbar?.isVisible = true
        window.titleVisibility = .visible
        self.apply(canGoBack: true, to: controller)
        #expect(
            window.titleVisibility == .hidden,
            "the shell left the restored title visible, so the back control cannot lead its region"
        )
    }

    @Test("The window's title follows the title the page on screen published")
    func windowTitleFollowsThePublishedTitle() {
        let (controller, window) = self.makeController()
        defer { window.orderOut(nil) }

        self.apply(canGoBack: false, windowTitle: "Library", to: controller)
        #expect(window.title == "Library")

        self.apply(canGoBack: true, windowTitle: "My Playlist 1", to: controller)
        #expect(window.title == "My Playlist 1")
    }

    @Test("A hidden toolbar keeps the title hidden — the fullscreen Now Playing state is not the shell's to undo")
    func hiddenToolbarKeepsTheTitleHidden() {
        let (controller, window) = self.makeController()
        defer { window.orderOut(nil) }

        // What `MainWindow.updateWindowTitleVisibility` does for the fullscreen experience: both go away.
        window.toolbar = NSToolbar(identifier: NSToolbar.Identifier("Kaset.tests.hiddenToolbar"))
        window.titleVisibility = .hidden
        window.toolbar?.isVisible = false

        self.apply(canGoBack: false, to: controller)
        #expect(
            window.titleVisibility == .hidden,
            "the shell un-hid the title while the toolbar itself was hidden"
        )
    }
}
