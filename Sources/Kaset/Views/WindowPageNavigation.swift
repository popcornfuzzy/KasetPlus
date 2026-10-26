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
    private let content: () -> Content

    init(id: String, path: Binding<NavigationPath>, @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self._path = path
        self.content = content
    }

    var body: some View {
        NavigationStack(path: self.$path) {
            self.content()
        }
        .onAppear { self.publish() }
        // The depth is the whole of the answer, and it changes for every push and pop — whether they came
        // from a link, a `navigationDestination`, or the page appending to the path itself.
        .onChange(of: self.path.count) { _, _ in self.publish() }
        .onDisappear { self.pageNavigation?.retract(id: self.id) }
    }

    private func publish() {
        guard let pageNavigation = self.pageNavigation else { return }
        let path = self.$path
        pageNavigation.publish(
            id: self.id,
            canGoBack: !self.path.isEmpty,
            goBack: {
                guard !path.wrappedValue.isEmpty else { return }
                path.wrappedValue.removeLast()
            },
            // A route opened from outside this stack (the Now Playing column's album/artist credits) is
            // appended here, at the one place that holds the path. The values are the ones the stack's own
            // destinations are registered for, so the push resolves exactly as a link's would.
            open: { route in
                switch route {
                case let .album(playlist): path.wrappedValue.append(playlist)
                case let .artist(artist): path.wrappedValue.append(artist)
                }
            }
        )
    }
}
