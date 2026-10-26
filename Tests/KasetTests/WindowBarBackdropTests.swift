import AppKit
import Testing

@testable import Kaset

/// The bar surface is the app's, so when it is visible is a rule worth stating: the pointer at the top
/// edge or content under the band shows it, a page sitting at its top does not, and fullscreen is
/// AppKit's own bar.
@Suite("Window bar surface")
struct WindowBarBackdropTests {
    private func policy(
        fullscreen: Bool = false,
        toolbarVisible: Bool = true,
        pointerInBand: Bool = false,
        contentUnderBar: Bool = false
    ) -> WindowBarBackdropPolicy {
        WindowBarBackdropPolicy(
            isFullscreen: fullscreen,
            isToolbarVisible: toolbarVisible,
            isPointerInBand: pointerInBand,
            isContentUnderBar: contentUnderBar
        )
    }

    @Test("An idle window shows no surface")
    func idleWindowHidesTheSurface() {
        #expect(!self.policy().showsSurface)
    }

    /// The surface is only worth showing if it is the *titlebar's* material: `.headerView` is a table-header
    /// material, and over a window-backed page it tinted the band by a handful of levels — the bar existed
    /// while looking absent.
    @Test("The surface uses the titlebar material")
    @MainActor
    func titlebarMaterial() {
        #expect(WindowBarBackdropView.surfaceMaterial == .titlebar)
    }

    /// The surface is the page column's. A band across the whole window painted over the navigation
    /// sidebar and the Now Playing column — the sidebars' own surfaces are why the panes run full height,
    /// so the band must stop at the page's edges.
    @Test("The band spans the page column and nothing else")
    @MainActor
    func bandSpansThePageColumn() {
        let themeHeight: CGFloat = 800
        let pane = NSRect(x: 201, y: 0, width: 680, height: themeHeight)
        let band = WindowBarBackdropView.band(pane: pane, themeFrameHeight: themeHeight)

        #expect(band.minX == pane.minX)
        #expect(band.maxX == pane.maxX)
        #expect(band.height == WindowBarBackdropView.height)
        // The band's top edge is the window's, so it sits under the titlebar rather than below it.
        #expect(band.maxY == themeHeight)
    }

    /// The page's top edge is the page's titlebar, so a drag there must move the window by exactly how
    /// far the pointer moved — no sign flips, no double counting.
    @Test("The strip's drag follows the pointer")
    @MainActor
    func dragFollowsThePointer() {
        let moved = WindowBarBackdropView.draggedOrigin(
            from: NSPoint(x: 100, y: 200),
            mouse: NSPoint(x: 500, y: 400),
            to: NSPoint(x: 540, y: 380)
        )
        #expect(moved == NSPoint(x: 140, y: 180))
    }

    /// The page's own scroll view is the tall one spanning the column, not a card row inside its content:
    /// a card row sits at its own top while the page does not.
    @Test("The page's scroll view is the outermost, tallest one")
    @MainActor
    func pageScrollViewIsTheOutermostTallest() {
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let page = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let row = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 140))
        page.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 4000))
        page.documentView?.addSubview(row)
        pane.addSubview(page)

        #expect(WindowBarBackdropController.pageScrollView(in: pane) === page)
    }

    /// At rest SwiftUI offsets the content by the bar's height, so the top is `-contentInsets.top` and nothing
    /// above it is content under the bar.
    @Test("A scroll view reports content under the bar only past its inset top")
    @MainActor
    func scrollPositionRule() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.contentInsets = NSEdgeInsets(top: 52, left: 0, bottom: 0, right: 0)

        scrollView.contentView.bounds.origin.y = -52
        #expect(!WindowBarBackdropController.isScrolled(scrollView))

        scrollView.contentView.bounds.origin.y = -20
        #expect(WindowBarBackdropController.isScrolled(scrollView))
    }

    /// The fullscreen Now Playing view hides the window's toolbar, and that is the bar's rule too — the
    /// surface has to go with it without waiting for the pointer to pass over the band, and come back
    /// with the toolbar over a page that is still scrolled.
    @Test("The surface follows the window's toolbar")
    @MainActor
    func surfaceFollowsToolbarVisibility() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.toolbar = NSToolbar(identifier: "test.toolbar")
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        let page = NSScrollView(frame: pane.bounds)
        // The window's own layout replaces automatically adjusted insets, so the test states them.
        page.automaticallyAdjustsContentInsets = false
        page.contentInsets = NSEdgeInsets(top: 52, left: 0, bottom: 0, right: 0)
        pane.addSubview(page)
        window.contentView = pane
        page.contentView.bounds.origin.y = -20

        let controller = WindowBarBackdropController()
        defer { controller.remove() }
        controller.install(in: window, contentPane: pane)
        #expect(controller.isSurfaceShowing)

        window.toolbar?.isVisible = false
        #expect(!controller.isSurfaceShowing)

        window.toolbar?.isVisible = true
        #expect(controller.isSurfaceShowing)
    }

    @Test("The pointer at the top edge shows the surface")
    func pointerInBandShowsTheSurface() {
        #expect(self.policy(pointerInBand: true).showsSurface)
    }

    /// The surface belongs to the content, not to the gesture: once the page is scrolled, the bar stays
    /// up while the pointer is anywhere else — another part of the window, another window, another app.
    @Test("Content under the band shows the surface without the pointer")
    func contentUnderBarShowsTheSurface() {
        #expect(self.policy(contentUnderBar: true).showsSurface)
    }

    @Test("A page back at its top hides the surface again")
    func contentAtTopHidesTheSurface() {
        #expect(!self.policy(contentUnderBar: false).showsSurface)
    }

    @Test("Fullscreen keeps the surface out of AppKit's way")
    func fullscreenHidesTheSurface() {
        #expect(!self.policy(fullscreen: true, pointerInBand: true, contentUnderBar: true).showsSurface)
    }

    @Test("A hidden toolbar takes the surface with it")
    func hiddenToolbarHidesTheSurface() {
        #expect(!self.policy(toolbarVisible: false, pointerInBand: true, contentUnderBar: true).showsSurface)
    }
}
