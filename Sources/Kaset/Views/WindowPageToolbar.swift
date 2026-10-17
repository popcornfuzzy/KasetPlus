import AppKit
import SwiftUI

// MARK: - PageToolbarContribution

/// A page's contribution to the window's toolbar: the page's own controls (search, sort, refresh),
/// drawn in the titlebar.
///
/// A macOS window has **one** toolbar and a `ToolbarItem` is positioned against the *window*, so with a
/// sidebar in the middle of the window no placement keeps a page's controls off it. The platform's
/// answer is a tracking separator: an item that sits on a split view's divider and bounds the region to
/// its left — which is what the window shell installs
/// ([ADR-0030](../../docs/adr/0030-appkit-window-shell.md)), and what the item order in
/// `WindowToolbarItems.identifiers` uses. These controls are therefore real toolbar items, laid out
/// against the Now Playing column's divider and unable to land on the column at any width.
///
/// The contribution is a *view*, not a description of one: the page's controls read the page's model,
/// and a hosted view observes that model itself, so a search field in the titlebar and the list it
/// filters are looking at exactly the same state.
@available(macOS 26.0, *)
struct PageToolbarContribution {
    /// Identity of the page that published it. Two contributions with the same id are the same
    /// contribution; a different id means the reader is on a different page, and the toolbar rebuilds
    /// the item — which is also what keeps one page's half-typed query or focused field out of the next.
    let id: String
    /// The controls, drawn as one group in the toolbar's page region.
    let content: AnyView
}

// MARK: - PageToolbarModel

/// The window's register of what the page on screen wants in the toolbar.
///
/// A page publishes on appearance and retracts on disappearance, and both calls are keyed by the page's
/// id: a retraction from a page that is no longer the published one is ignored, so the order of the
/// outgoing page's `onDisappear` against the incoming page's `onAppear` cannot leave the window showing
/// the wrong page's controls.
@available(macOS 26.0, *)
@MainActor
@Observable
final class PageToolbarModel {
    /// Every page that published and has not retracted yet, oldest first. A stack rather than a slot:
    /// a navigation stack's root stays mounted while a destination is pushed over it, so the root never
    /// retracts — when the destination is popped and retracts, the root's entry underneath is what the
    /// window falls back to. Without this, popping back to a page left the toolbar showing nothing (or
    /// whatever the popped page last stated) instead of the page underneath.
    private var stack: [PageToolbarContribution] = []

    var contribution: PageToolbarContribution? {
        self.stack.last
    }

    func contribute(_ contribution: PageToolbarContribution) {
        // A re-publication (a detail reloading, a remount) moves the page back on top rather than
        // stacking a duplicate of it that a single retraction could never clear.
        self.stack.removeAll { $0.id == contribution.id }
        self.stack.append(contribution)
    }

    /// Takes this page's controls away, revealing whatever page underneath published its own.
    func retract(id: String) {
        self.stack.removeAll { $0.id == id }
    }
}

// MARK: - PageToolbarModifier

/// Publishes a page's controls to the window for as long as the page is on screen.
@available(macOS 26.0, *)
private struct PageToolbarModifier<Controls: View>: ViewModifier {
    @Environment(PageToolbarModel.self) private var pageToolbar: PageToolbarModel?

    let id: String
    @ViewBuilder var controls: Controls

    func body(content: Content) -> some View {
        content
            .onAppear {
                self.pageToolbar?.contribute(
                    PageToolbarContribution(
                        id: self.id,
                        // Identity by page: switching pages must not carry a search field's text or
                        // focus into the page that replaces it.
                        content: AnyView(self.controls.id(self.id))
                    )
                )
            }
            .onDisappear {
                self.pageToolbar?.retract(id: self.id)
            }
    }
}

@available(macOS 26.0, *)
extension View {
    /// Publishes this page's toolbar controls to the window's toolbar while the page is on screen.
    ///
    /// The window has one toolbar, so a page does not *declare* items — it states what they should be
    /// for as long as it is the page on screen (see `PageToolbarModel`).
    func pageToolbar<Controls: View>(
        id: String,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        self.modifier(PageToolbarModifier(id: id, controls: controls))
    }
}

// MARK: - PageTitleModel

/// The window's register of what the page on screen is called.
///
/// The pages used to state `.navigationTitle`, which is toolbar-managed content: SwiftUI's window
/// controller answered by installing its own one-item toolbar on every push into (and back out of) a
/// page, and the app's toolbar was taken away with it until the shell re-took it a runloop turn later
/// — the titlebar flashing empty, and the back control landing on the wrong side while the window's
/// own title held its slot. The pages state their title here instead, and the shell writes it to the
/// window itself, so SwiftUI has no reason to manage a toolbar at all.
///
/// A page publishes on appearance and retracts on disappearance, and both calls are keyed by the
/// page's id exactly as `PageToolbarModel`'s are, for the same reason: the order of the outgoing
/// page's `onDisappear` against the incoming page's `onAppear` must not leave the window titled by a
/// page that is gone.
@available(macOS 26.0, *)
@MainActor
@Observable
final class PageTitleModel {
    /// Every page that published a title and has not retracted yet, oldest first. A stack rather than a
    /// slot, for the same reason as `PageToolbarModel.stack`: a pushed destination retracts on pop while
    /// the root underneath never left, so the window falls back to the root's title instead of keeping
    /// the popped page's — which is what left the album's name in the titlebar after going back home.
    private var stack: [(id: String, title: String)] = []

    /// The title of the page on screen. The window starts with the app's name until a page states one.
    var title: String {
        self.stack.last?.title ?? "Kaset"
    }

    func publish(id: String, title: String) {
        // A re-publication (a detail's title arriving with its header, a remount) moves the page back
        // on top rather than stacking a duplicate of it that a single retraction could never clear.
        self.stack.removeAll { $0.id == id }
        self.stack.append((id: id, title: title))
    }

    /// Takes this page's title away, revealing whatever page underneath published its own.
    func retract(id: String) {
        self.stack.removeAll { $0.id == id }
    }
}

// MARK: - PageTitleModifier

/// Publishes a page's title to the window for as long as the page is on screen.
@available(macOS 26.0, *)
private struct PageTitleModifier: ViewModifier {
    @Environment(PageTitleModel.self) private var pageTitle: PageTitleModel?

    let id: String
    let title: String

    func body(content: Content) -> some View {
        content
            .onAppear {
                self.pageTitle?.publish(id: self.id, title: self.title)
            }
            // Detail titles arrive after the page does — an album's name comes with its header — so
            // the window follows the title rather than the snapshot from when the page appeared.
            .onChange(of: self.title) { _, newTitle in
                self.pageTitle?.publish(id: self.id, title: newTitle)
            }
            .onDisappear {
                self.pageTitle?.retract(id: self.id)
            }
    }
}

@available(macOS 26.0, *)
extension View {
    /// Publishes this page's title to the window's titlebar while the page is on screen.
    ///
    /// The window has one titlebar, so a page does not *declare* a title — it states what it should be
    /// for as long as it is the page on screen (see `PageTitleModel`). This replaces `.navigationTitle`
    /// for pages inside the window shell, which must not ask SwiftUI for toolbar-managed content.
    func pageTitle(id: String, title: String) -> some View {
        self.modifier(PageTitleModifier(id: id, title: title))
    }
}

// MARK: - PageRefreshButton

/// A page's refresh control, as a toolbar item.
///
/// A page's manual refresh is a *background* refresh: it keeps the list on screen and swaps it when the
/// new one arrives, so the page's own `LoadingState` cannot say whether one is running (it is `.loaded`
/// throughout). The page's model owns that flag instead (`isRefreshing`), which is what lets this control
/// in the titlebar and the page below it read the same state from two different view trees.
@available(macOS 26.0, *)
struct PageRefreshButton: View {
    let help: LocalizedStringKey
    /// Asked during this view's own render, not captured as a value: the answer lives on the page's
    /// model, and reading it here is what ties the toolbar item to that model — a value read when the
    /// page published its controls would be a snapshot, and the spinner would never start.
    let isRefreshing: () -> Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            // A spinner, not a spun glyph. The arrow used to rotate through a `repeatForever` animation
            // tied to the refreshing flag, and the toolbar's hosted view is re-rendered on every window
            // update while a page loads — each render restarted the animation mid-spin, which is what
            // made the control judder through every refresh. An indeterminate `ProgressView` has no
            // phase to restart, so re-renders are invisible. Both states share one fixed frame so the
            // swap never moves the controls beside it.
            Group {
                if self.isRefreshing() {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .frame(width: 16, height: 16)
        }
        .help(self.help)
        .disabled(self.isRefreshing())
    }
}
