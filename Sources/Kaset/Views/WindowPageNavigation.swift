import AppKit
import QuartzCore
import SwiftUI

// MARK: - DetailNavigationRoute

/// A page that can be opened from outside the navigation stack that shows it.
///
/// The Now Playing column is a sibling of the page, not a view inside its stack, so the credits under
/// the artwork have no `NavigationLink` to resolve against (nothing encloses them). They hand one of
/// these to the window instead, and the stack of the page on screen pushes it — see `PageNavigationModel`.
enum DetailNavigationRoute: Hashable {
    /// An album, which is shown as a playlist page: the same value the song menus' **Go to Album**
    /// `NavigationLink` pushes.
    case album(Playlist)
    case artist(Artist)
}

// MARK: - PageNavigationModel

/// The window's register of the page on screen's navigation stack: whether it has anywhere to go back to,
/// and how to open a page in it.
///
/// The window's toolbar is the app's own `NSToolbar` (see `WindowToolbarController`), so it holds the app's
/// items and nothing else — which means the back control a pushed page needs is the app's to supply too.
/// SwiftUI has one, and it draws it in *SwiftUI's* toolbar, the one the app replaces: taking that toolbar
/// back takes the back button with it, leaving a page that can be pushed into and not come back out of.
/// The reader's report is exact — on the pushed page "the other buttons are there but the back button
/// disappears".
///
/// So a page's stack states, while it is on screen, whether it can be popped and how to pop it. Both calls
/// are keyed by the page's id, the way `PageToolbarModel`'s are: a retraction from a page that is no longer
/// the published one is ignored, so the order of the outgoing page's `onDisappear` against the incoming
/// page's publication cannot leave the window showing a back control for a page that is gone.
@available(macOS 26.0, *)
@MainActor
@Observable
final class PageNavigationModel {
    /// Whether the page on screen can be popped. Read by the window when it builds the toolbar's items.
    private(set) var canGoBack = false

    /// The page that published the current state, and how it pops itself and opens a page.
    private var owner: String?
    private var goBackAction: (@MainActor () -> Void)?
    private var openAction: (@MainActor (DetailNavigationRoute) -> Void)?

    /// States that the page `id` is on screen, whether it has somewhere to go back to, and how to push
    /// onto its stack.
    func publish(
        id: String,
        canGoBack: Bool,
        goBack: @escaping @MainActor () -> Void,
        open: @escaping @MainActor (DetailNavigationRoute) -> Void = { _ in }
    ) {
        self.owner = id
        self.canGoBack = canGoBack
        self.goBackAction = goBack
        self.openAction = open
    }

    /// Takes a page's back control away — unless another page has already published its own.
    func retract(id: String) {
        guard self.owner == id else { return }
        self.owner = nil
        self.canGoBack = false
        self.goBackAction = nil
        self.openAction = nil
    }

    /// Pops the page on screen's navigation stack. A no-op when there is nothing to pop.
    ///
    /// The published action is only run while the page still says there is somewhere to go back to: the
    /// toolbar item that calls this is drawn from the same flag, and an action that outlived its page must
    /// never be able to pop a stack the reader is no longer looking at.
    func goBack() {
        guard self.canGoBack else { return }
        self.goBackAction?()
    }

    /// Pushes `route` onto the stack of the page on screen, and says whether a page took it.
    ///
    /// `false` while no page has published a stack — Home, Search and the artist pages do not have one, and
    /// a click on the Now Playing column's credits there must still open something. The window answers
    /// `false` by showing the page in the content pane instead (see `MainWindow`).
    ///
    /// A click that arrives after the page it belonged to is gone cannot navigate a page the reader is not
    /// looking at: nothing is published then, so it answers `false` too. Unlike ``goBack()`` this needs no
    /// gate of its own — pushing from a page at its root is how every link in the app opens a page.
    @discardableResult
    func open(_ route: DetailNavigationRoute) -> Bool {
        guard let openAction = self.openAction else { return false }
        openAction(route)
        return true
    }
}

// MARK: - PageSlideTransition

/// The slide a page has when it is pushed or popped: AppKit's push transition, which SwiftUI does not
/// offer on macOS.
///
/// `NavigationTransition` has one style on macOS — `.automatic` — and `.zoom` and `.crossFade` are
/// `@available(macOS, unavailable)`, so there is no navigation transition to choose. What the system apps
/// do instead is AppKit's push transition: a `CATransition` of type `.push` on the container that holds
/// the page. That is what is added here, to the layer of the pane the page is drawn into.
///
/// The layer is the nearest `NSHostingView` above the page's own SwiftUI: the shell hosts each pane in its
/// own hosting view, so it is the content pane — the page, and nothing of the sidebar or the Now Playing
/// column. It is found from a probe view once that view is in a window, and held weakly.
@available(macOS 26.0, *)
@MainActor
final class PageSlideTransition {
    /// How long a slide takes, which is AppKit's own push transition length.
    static let duration: CFTimeInterval = 0.25

    /// The key the transition is filed under.
    ///
    /// Stated as Core Animation's own name for it because that is the only key it answers to: a
    /// `CATransition` added under any other key is listed by `animationKeys()` as `transition`, and
    /// `animation(forKey:)` with the key it was added under comes back nil. A layer holds one transition,
    /// so a change in flight is replaced rather than stacked.
    static let animationKey = "transition"

    private weak var hostLayer: CALayer?

    /// What the layer was found to be — the pane class and its width — for the diagnostic a slide logs.
    private(set) var hostDescription = "none"

    /// Finds the layer that holds the page. Called by the probe whenever it reaches a window.
    func attach(probe: NSView) {
        guard let host = Self.hostingView(above: probe) else { return }
        self.hostLayer = host.layer
        let width = Int(host.bounds.width.rounded())
        self.hostDescription = "\(type(of: host)) w=\(width) layer=\(host.layer == nil ? "nil" : "yes")"
    }

    /// Slides the page for a change of the path's depth from `oldDepth` to `newDepth`.
    ///
    /// The new page comes in from the trailing edge on a push and from the leading edge on a pop, with the
    /// outgoing page leaving the other way — that pair is `CATransition`'s `.push`. Nothing is added when
    /// the depth did not change, or while the reader has asked the system to reduce motion: the page then
    /// swaps with no motion, which is what that setting asks for.
    @discardableResult
    func perform(
        from oldDepth: Int,
        to newDepth: Int,
        reduceMotion: Bool = AccessibilityMotion.shared.reduceMotion
    ) -> CATransition? {
        guard !reduceMotion, oldDepth != newDepth else { return nil }
        guard let layer = self.hostLayer else {
            DiagnosticsLogger.ui
                .info("Page slide: no layer to slide (host=\(self.hostDescription, privacy: .public))")
            return nil
        }
        let transition = CATransition()
        transition.type = .push
        transition.subtype = newDepth > oldDepth ? .fromRight : .fromLeft
        transition.duration = Self.duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(transition, forKey: Self.animationKey)
        let direction = newDepth > oldDepth ? "push" : "pop"
        DiagnosticsLogger.ui.info(
            "Page slide: \(direction, privacy: .public) depth=\(oldDepth)->\(newDepth) host=\(self.hostDescription, privacy: .public)"
        )
        return transition
    }

    /// The view the page's SwiftUI is drawn into: the nearest ancestor that hosts SwiftUI.
    private static func hostingView(above view: NSView) -> NSView? {
        var candidate = view.superview
        while let current = candidate {
            if NSStringFromClass(type(of: current)).contains("HostingView") {
                return current
            }
            candidate = current.superview
        }
        return nil
    }
}

// MARK: - PageSlideProbe

/// Puts a view in the page's hierarchy, so the slide can find the pane's layer.
///
/// It draws nothing and does not take part in the layout beyond the background it is; all it does is
/// report its ancestor hosting view to `PageSlideTransition` once it is in a window.
@available(macOS 26.0, *)
struct PageSlideProbe: NSViewRepresentable {
    let transition: PageSlideTransition

    func makeNSView(context: Context) -> PageSlideProbeView {
        let view = PageSlideProbeView()
        view.transition = self.transition
        return view
    }

    func updateNSView(_ view: PageSlideProbeView, context: Context) {
        view.transition = self.transition
    }

    final class PageSlideProbeView: NSView {
        weak var transition: PageSlideTransition?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard self.window != nil, let transition else { return }
            transition.attach(probe: self)
        }
    }
}

// MARK: - PageNavigationStack

/// A page's navigation stack, which publishes its back control to the window.
///
/// The stack itself is a plain `NavigationStack`: what this adds is the one thing a page cannot state on
/// its own — that it has somewhere to go back to — so the window's toolbar can draw the control that takes
/// it there. Replacing the pages' `NavigationStack` with this is the whole of a page's part; the path stays
/// the page's own `@State`, so everything that pushes into it keeps working unchanged.
///
/// `id` names the page for the window's register. It must be stable for as long as the page is on screen
/// and distinct per page, because it is what keeps one page's retraction from clearing another's.
@available(macOS 26.0, *)
struct PageNavigationStack<Content: View>: View {
    @Environment(PageNavigationModel.self) private var pageNavigation: PageNavigationModel?

    let id: String
    @Binding var path: NavigationPath
    /// The push/pop slide, installed on the pane's layer for each change of the path's depth.
    @State private var slide = PageSlideTransition()
    private let content: () -> Content

    init(id: String, path: Binding<NavigationPath>, @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self._path = path
        self.content = content
    }

    var body: some View {
        NavigationStack(path: self.$path) {
            self.content()
                // The back control is the app's (`PageNavigationModel`), so no screen in this stack asks
                // SwiftUI for one. Left to itself SwiftUI answers a push by replacing the window's toolbar
                // with its own one-item one, and a pop by taking the toolbar away entirely
                // (`window.toolbar = nil`). A window without a toolbar loses its 52pt top inset, so the
                // whole page jumps up until the shell re-takes the toolbar a turn later — the flash on
                // every push into, and pop out of, a page. Stated on the stack's content, which is what
                // the stack's screens read it from; a page view cannot state it for the stack.
                .navigationBarBackButtonHidden(true)
        }
        // The pane's layer, which the slide animates. Placed here rather than inside the stack so the
        // page's pushes do not re-create it.
        .background(PageSlideProbe(transition: self.slide))
        .onAppear { self.publish() }
        // The depth is the whole of the answer, and it changes for every push and pop — whether they came
        // from a link, a `navigationDestination`, or the page appending to the path itself. It is also
        // the one place every change passes through, which is why the slide is installed here: the
        // transition has to be on the layer before the content it shows swaps.
        .onChange(of: self.path.count) { oldDepth, newDepth in
            self.slide.perform(from: oldDepth, to: newDepth)
            self.publish()
        }
        .onDisappear { self.pageNavigation?.retract(id: self.id) }
    }

    /// Runs a path change with SwiftUI's own animation of the swap turned off.
    ///
    /// The stack would otherwise animate the swap itself (a fade, or nothing, depending on the context)
    /// underneath the layer transition — two motions for one navigation. The page moves because the
    /// transition moves it.
    private func withoutStackAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    private func publish() {
        guard let pageNavigation = self.pageNavigation else { return }
        let path = self.$path
        pageNavigation.publish(
            id: self.id,
            canGoBack: !self.path.isEmpty,
            goBack: {
                guard !path.wrappedValue.isEmpty else { return }
                self.withoutStackAnimation { path.wrappedValue.removeLast() }
            },
            // A route opened from outside this stack (the Now Playing column's album/artist credits) is
            // appended here, at the one place that holds the path. The values are the ones the stack's own
            // destinations are registered for, so the push resolves exactly as a link's would.
            open: { route in
                self.withoutStackAnimation {
                    switch route {
                    case let .album(playlist): path.wrappedValue.append(playlist)
                    case let .artist(artist): path.wrappedValue.append(artist)
                    }
                }
            }
        )
    }
}
