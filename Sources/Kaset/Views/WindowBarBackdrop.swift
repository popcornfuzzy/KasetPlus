import AppKit

// MARK: - WindowBarBackdropView

/// The bar's surface over the page column, and the page column's titlebar.
///
/// AppKit draws the toolbar's items but no surface behind them in windowed mode, and its titlebar drag
/// reaches the sidebars (their item views accept it) but not the page, whose presses landed on whichever
/// SwiftUI view was under the pointer. This view is both missing pieces over the page: an
/// `NSVisualEffectView` with the `.titlebar` material, which also takes the press and drags the window.
///
/// It spans the page column only — the sidebars are full height and carry surfaces of their own — and sits
/// in the theme frame above the content and below the titlebar, so the toolbar's items keep their clicks.
/// See [ADR-0035](../../docs/adr/0035-standard-window-chrome.md).
@MainActor
final class WindowBarBackdropView: NSView {
    /// The height of the bar, matching AppKit's toolbar row.
    static let height: CGFloat = 52

    /// The system's titlebar material; `.headerView` is for table headers and left the bar looking absent.
    static let surfaceMaterial: NSVisualEffectView.Material = .titlebar

    /// The band's rectangle for a page column, in the theme frame's coordinates: the page's width at the
    /// window's top edge, and nothing beside it.
    static func band(pane: NSRect, themeFrameHeight: CGFloat) -> NSRect {
        NSRect(
            x: pane.minX,
            y: themeFrameHeight - Self.height,
            width: max(0, pane.width),
            height: Self.height
        )
    }

    private let effect = NSVisualEffectView()
    private var trackingArea: NSTrackingArea?
    /// Called when the pointer enters or leaves the band.
    var onHoverChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.alphaValue = 0

        // No fade at the bottom: the blur is what keeps the edge from reading as a rectangle laid over
        // the page.
        self.effect.material = Self.surfaceMaterial
        self.effect.blendingMode = .withinWindow
        self.effect.state = .followsWindowActiveState
        self.effect.autoresizingMask = [.width, .height]
        self.addSubview(self.effect)
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        self.effect.frame = self.bounds
    }

    /// The band itself takes presses, not the effect view inside it: a drag has to keep arriving after
    /// the press, and AppKit sends `mouseDragged` to the view that took the press.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = self.convert(point, from: superview)
        return self.bounds.contains(local) ? self : nil
    }

    /// Where the window was, and where the pointer was, when the press came in.
    private var dragOrigin: NSPoint?
    private var dragMouse: NSPoint?
    /// The pointer has to move this far before the window follows, so a click stays a click.
    private static let dragThreshold: CGFloat = 2.5

    /// Dragging the strip moves the window, exactly as dragging the titlebar does.
    ///
    /// Tracked here rather than handed to the window server (`NSWindow.performDrag(with:)`): the strip
    /// reported that press and the window never moved.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        self.dragOrigin = window.frame.origin
        self.dragMouse = NSEvent.mouseLocation
        guard event.clickCount == 2 else { return }
        self.dragOrigin = nil
        self.dragMouse = nil
        Self.performDoubleClickAction(on: window)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let origin = self.dragOrigin,
              let start = self.dragMouse else { return }
        let now = NSEvent.mouseLocation
        let delta = NSPoint(x: now.x - start.x, y: now.y - start.y)
        guard abs(delta.x) > Self.dragThreshold || abs(delta.y) > Self.dragThreshold else { return }
        window.setFrameOrigin(Self.draggedOrigin(from: origin, mouse: start, to: now))
    }

    /// The window's origin while the pointer is at `current`: the origin at the press plus the pointer's
    /// move since. Stated as a function so the sign convention is covered without a window.
    static func draggedOrigin(from origin: NSPoint, mouse: NSPoint, to current: NSPoint) -> NSPoint {
        NSPoint(x: origin.x + (current.x - mouse.x), y: origin.y + (current.y - mouse.y))
    }

    override func mouseUp(with _: NSEvent) {
        self.dragOrigin = nil
        self.dragMouse = nil
    }

    /// The window menu AppKit shows on a titlebar right-click.
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.contentView?.superview?.menu(for: event) ?? super.menu(for: event)
    }

    /// The strip covers the page's top edge, so a scroll there must still reach the page.
    override func scrollWheel(with event: NSEvent) {
        guard let window, let content = window.contentView,
              let target = content.hitTest(content.convert(event.locationInWindow, from: nil))
        else {
            super.scrollWheel(with: event)
            return
        }
        target.scrollWheel(with: event)
    }

    /// The system's double-click action on a titlebar (`AppleActionOnDoubleClick`).
    private static func performDoubleClickAction(on window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
        case "Minimize":
            window.performMiniaturize(nil)
        case "None":
            break
        default:
            window.performZoom(nil)
        }
    }

    /// Enter/exit tracking is what tells the controller the pointer reached the band; the click path is
    /// the drag's (see `mouseDown`), and the two must describe the same strip.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            self.removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        self.addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        self.onHoverChange?(true)
    }

    override func mouseExited(with _: NSEvent) {
        self.onHoverChange?(false)
    }

    /// The last state a fade was started for. The controller re-evaluates on every layout pass; without
    /// this, each pass during a resize restarted the fade from its current alpha.
    private(set) var isSurfaceVisible = false

    /// Fades the surface in or out. A bar that pops would draw more attention than the content it covers.
    func setVisible(_ visible: Bool) {
        guard self.isSurfaceVisible != visible else { return }
        self.isSurfaceVisible = visible
        DiagnosticsLogger.ui.debug("Bar surface visible=\(visible, privacy: .public)")
        let target: CGFloat = visible ? 1 : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            self.animator().alphaValue = target
        }
    }
}

// MARK: - WindowBarBackdropPolicy

/// When the bar's surface is shown.
///
/// A value type so the rule is covered without a window: present over content that has scrolled beneath the
/// bar or while the pointer is at the top edge, absent over a page sitting at its top, and never in
/// fullscreen (AppKit draws its own bar there). **The content's position holds the surface up, not the
/// gesture that moved it** — a scroll ending, or the pointer leaving the window, is no reason to uncover
/// content the bar is drawing over.
struct WindowBarBackdropPolicy: Equatable {
    var isFullscreen: Bool
    var isToolbarVisible: Bool
    var isPointerInBand: Bool
    /// The page is scrolled past its top, so its content passes under the band.
    var isContentUnderBar: Bool

    var showsSurface: Bool {
        guard self.isToolbarVisible, !self.isFullscreen else { return false }
        return self.isPointerInBand || self.isContentUnderBar
    }
}

// MARK: - WindowBarBackdropController

/// Owns the surface and the two signals that show it: the pointer reaching the window's top edge, and the
/// page having content under the band.
///
/// The second signal is the page's scroll position, never the scroll gesture: a gesture-held flag dropped
/// the bar off content still underneath it as soon as the pointer left the window, and kept it over a page
/// scrolled back to its top.
@MainActor
final class WindowBarBackdropController {
    private weak var window: NSWindow?
    private let backdrop = WindowBarBackdropView(frame: .zero)

    /// The page column: the one region the band covers. Weak, because the split item owns it.
    private weak var contentPane: NSView?
    /// Fires when the column moves or resizes — a divider drag, the column opening, a window resize.
    private var paneFrameObserver: (any NSObjectProtocol)?
    /// The page's own scroll view: the one whose content passes under the band.
    private weak var pageScrollView: NSScrollView?
    /// Fires on every change of that scroll view's visible origin — wheel, trackpad, momentum, scrollbar
    /// drag and keyboard scrolling alike.
    private var pageScrollObserver: (any NSObjectProtocol)?

    private var mouseMonitor: Any?
    private var fullscreenObservers: [any NSObjectProtocol] = []
    /// The window's toolbar visibility is the policy's other input, and hiding the toolbar changes no
    /// frame the shell would lay out — so it is watched rather than read on the next layout pass.
    private var toolbarVisibilityObserver: NSKeyValueObservation?
    private weak var observedToolbar: NSToolbar?

    private var isFullscreen = false
    private var isPointerInBand = false
    private var isContentUnderBar = false
    private var lastLoggedBand: NSRect?

    /// Stops listening and leaves the window. Called when the shell's view leaves its window.
    func remove() {
        if let monitor = self.mouseMonitor { NSEvent.removeMonitor(monitor) }
        self.mouseMonitor = nil
        self.toolbarVisibilityObserver = nil
        self.observedToolbar = nil
        self.stopTrackingPane()
        for observer in self.fullscreenObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.fullscreenObservers = []
        self.backdrop.removeFromSuperview()
        self.window = nil
    }

    /// Puts the surface in the window and keeps it there. Idempotent: called from every layout pass.
    ///
    /// `contentPane` is the page column's view: the band is laid over that column and follows it, so the
    /// sidebars are never under the surface.
    func install(in window: NSWindow, contentPane pane: NSView) {
        if self.window !== window {
            self.window = window
            self.installInThemeFrame(of: window)
            self.installMonitors()
            self.observeFullscreen(of: window)
        }
        self.trackToolbar(of: window)
        self.trackPane(pane)
        self.refresh()
    }

    /// Follows the window's toolbar visibility: the fullscreen now-playing view hides the toolbar, and the
    /// bar goes with it — and comes back with it over a page that is still scrolled.
    ///
    /// KVO because AppKit has no notification for this, and no frame changes for the shell to notice it by.
    private func trackToolbar(of window: NSWindow) {
        let toolbar = window.toolbar
        guard toolbar !== self.observedToolbar else { return }
        self.toolbarVisibilityObserver = nil
        self.observedToolbar = toolbar
        self.toolbarVisibilityObserver = toolbar?.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    private func installInThemeFrame(of window: NSWindow) {
        guard let themeFrame = window.contentView?.superview else { return }
        window.acceptsMouseMovedEvents = true
        // No autoresizing: the band's width is the page column's, not the window's, so its frame is
        // computed from the column rather than scaled with the window (see `updateBackdropFrame`).
        self.backdrop.autoresizingMask = []
        self.backdrop.onHoverChange = { [weak self] inBand in
            self?.isPointerInBand = inBand
            self?.refresh()
        }
        // Below the titlebar, not above it: the toolbar's items are the titlebar's subviews, and the
        // band must never be the view a click on them lands on.
        if let titlebar = themeFrame.subviews.first(where: {
            String(describing: type(of: $0)).contains("Titlebar")
        }) {
            themeFrame.addSubview(self.backdrop, positioned: .below, relativeTo: titlebar)
        } else {
            themeFrame.addSubview(self.backdrop, positioned: .above, relativeTo: window.contentView)
        }
    }

    /// Follows the page column: a divider drag resizes the pane without a layout pass of the shell.
    private func trackPane(_ pane: NSView) {
        guard self.contentPane !== pane else { return }
        self.stopTrackingPane()
        self.contentPane = pane
        self.paneFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: pane,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateBackdropFrame()
            }
        }
        self.updateBackdropFrame()
        self.updatePageScrollView()
    }

    private func stopTrackingPane() {
        if let observer = self.paneFrameObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        self.paneFrameObserver = nil
        self.stopTrackingPageScrollView()
        self.contentPane = nil
        self.isContentUnderBar = false
    }

    /// Follows the page's own scroll view, which SwiftUI builds inside the column and replaces per page.
    private func updatePageScrollView() {
        guard let pane = self.contentPane else { return }
        let scrollView = Self.pageScrollView(in: pane)
        guard scrollView !== self.pageScrollView else { return }
        self.stopTrackingPageScrollView()
        guard let scrollView else { return }
        scrollView.contentView.postsBoundsChangedNotifications = true
        self.pageScrollView = scrollView
        self.pageScrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setContentUnderBar()
            }
        }
    }

    private func stopTrackingPageScrollView() {
        if let observer = self.pageScrollObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        self.pageScrollObserver = nil
        self.pageScrollView = nil
    }

    /// The page's own scroll view: the outermost, tallest one in the column. The scroll views inside its
    /// content (a row of cards) sit at their own top while the page does not, so they would report a
    /// scrolled page as an unscrolled one.
    static func pageScrollView(in pane: NSView) -> NSScrollView? {
        var outermost: [NSScrollView] = []
        var pending = pane.subviews
        while let view = pending.popLast() {
            if let scrollView = view as? NSScrollView {
                outermost.append(scrollView)
                continue
            }
            pending.append(contentsOf: view.subviews)
        }
        return outermost.max { $0.frame.height < $1.frame.height }
    }

    /// Re-reads the page's scroll view and its position, and settles the surface on the result.
    private func setContentUnderBar() {
        self.updatePageScrollView()
        let underBar = self.pageScrollView.map(Self.isScrolled) ?? false
        guard underBar != self.isContentUnderBar else { return }
        self.isContentUnderBar = underBar
        self.refresh()
    }

    /// Lays the band over the page column's current rectangle.
    private func updateBackdropFrame() {
        guard let window, let pane = self.contentPane else { return }
        guard let themeFrame = window.contentView?.superview else { return }
        let paneInTheme = themeFrame.convert(pane.bounds, from: pane)
        let band = WindowBarBackdropView.band(
            pane: paneInTheme,
            themeFrameHeight: themeFrame.bounds.height
        )
        self.backdrop.frame = band
        // The band's x and width are the claim that it spans the page column and not the sidebars.
        if band != self.lastLoggedBand {
            self.lastLoggedBand = band
            let message = "Bar band: x=\(Int(band.minX)) width=\(Int(band.width)) "
                + "window=\(Int(window.frame.width)) pane=\(Int(paneInTheme.width))"
            DiagnosticsLogger.ui.debug("\(message, privacy: .public)")
        }
    }

    private func installMonitors() {
        self.mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.pointerMoved(event)
            }
            return event
        }
    }

    private func observeFullscreen(of window: NSWindow) {
        let center = NotificationCenter.default
        self.fullscreenObservers = [
            center.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isFullscreen = true
                    self?.refresh()
                }
            },
            center.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isFullscreen = false
                    self?.refresh()
                }
            },
        ]
    }

    /// Re-evaluates the surface, e.g. after the shell hides or shows the toolbar.
    func refresh() {
        guard let window else { return }
        // A toolbar installed after this controller's first pass is the one whose visibility matters.
        self.trackToolbar(of: window)
        self.updateBackdropFrame()
        self.updatePageScrollView()
        self.isFullscreen = window.styleMask.contains(.fullScreen)
        self.isContentUnderBar = self.pageScrollView.map(Self.isScrolled) ?? false
        let policy = WindowBarBackdropPolicy(
            isFullscreen: self.isFullscreen,
            isToolbarVisible: window.toolbar?.isVisible ?? false,
            isPointerInBand: self.isPointerInBand,
            isContentUnderBar: self.isContentUnderBar
        )
        self.backdrop.setVisible(policy.showsSurface)
    }

    private func pointerMoved(_ event: NSEvent) {
        guard let window else { return }
        guard event.window === window else {
            // The pointer is over another window of the app; the band is not under it.
            if self.isPointerInBand {
                self.isPointerInBand = false
                self.refresh()
            }
            return
        }
        // The band's own rectangle is the rule, so a sidebar's top never raises the page's bar.
        guard let band = self.bandInScreen(of: window) else { return }
        let inBand = band.contains(NSEvent.mouseLocation)
        if inBand != self.isPointerInBand {
            self.isPointerInBand = inBand
            self.refresh()
        } else {
            // A page change can put a fresh scroll view in the column without a frame change of the pane.
            self.setContentUnderBar()
        }
    }

    /// The band's rectangle in screen coordinates — the one region that may raise or hold the surface.
    private func bandInScreen(of window: NSWindow) -> NSRect? {
        let inWindow = self.backdrop.convert(self.backdrop.bounds, to: nil)
        let origin = window.convertPoint(toScreen: inWindow.origin)
        return NSRect(origin: origin, size: inWindow.size)
    }

    /// Whether the surface is up. The state a test reads to see that the policy's inputs arrive.
    var isSurfaceShowing: Bool { self.backdrop.isSurfaceVisible }

    /// Whether the page's content has moved past the top of its scroll view, i.e. under the band.
    ///
    /// The top is not `0`: SwiftUI offsets the content by the safe area (the toolbar's 52pt), so at rest the
    /// clip view sits at `-contentInsets.top`. A larger origin means content has scrolled up under the bar.
    static func isScrolled(_ scrollView: NSScrollView) -> Bool {
        scrollView.contentView.bounds.origin.y > -scrollView.contentInsets.top + 0.5
    }
}
