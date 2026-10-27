import AppKit
import SwiftUI
import Testing

@testable import Kaset

/// The window's toolbar through a page push and pop.
///
/// The shell's toolbar is an `NSToolbar` the app owns (`WindowToolbarController`), but SwiftUI still
/// manages a toolbar of its own for a `NavigationStack`'s back button. Left to itself, a push replaces
/// the window's toolbar with SwiftUI's one-item one, and a pop takes the toolbar away entirely
/// (`window.toolbar = nil`). A window with no toolbar loses its 52pt top inset for a turn, so the page
/// jumps up and settles back down when the shell re-takes the toolbar — the flicker the reader sees on
/// every push into, and pop out of, an artist or album page. The app draws its own back control
/// (`PageNavigationModel`), so the pages hide SwiftUI's and nothing replaces the window's toolbar.
///
/// This drives the real shell in a real window, because the takeover is SwiftUI's and only its real
/// hosting in a real window has any of it.
@MainActor
@Suite(.tags(.model))
struct WindowToolbarTakeoverTests {
    @Observable
    final class PathBox {
        var path = NavigationPath()
    }

    /// Every toolbar the window had while the test ran, with the inset it left the page.
    private final class ToolbarChanges: @unchecked Sendable {
        var records: [(toolbar: String, contentHeight: CGFloat)] = []
        var observation: NSKeyValueObservation?
    }

    /// The window's root, stated the way `MainWindow` states it: the shell is rebuilt with whatever the
    /// page on screen published, so a push changes its toolbar inputs.
    private struct ShellRoot: View {
        let pageNavigation: PageNavigationModel
        let page: AnyView

        private var layout: WindowShellLayout {
            WindowShellLayout(
                minSidebarWidth: 200,
                maxSidebarWidth: 300,
                minContentWidth: 765,
                contentSqueezeWidth: 500,
                minWindowWidth: 900,
                minInspectorWidth: 300,
                maxInspectorWidth: 560,
                autosaveName: "KasetTests.WindowToolbarTakeover"
            )
        }

        var body: some View {
            WindowShell(
                sidebar: AnyView(Color.clear),
                content: self.page,
                inspector: AnyView(Color.clear),
                layout: self.layout,
                showsInspector: false,
                seedInspectorWidth: 380,
                onInspectorCollapsedChange: { _ in },
                toolbar: WindowToolbarItems(
                    tracksColumn: false,
                    showsAI: false,
                    showsNowPlayingToggle: true,
                    canGoBack: self.pageNavigation.canGoBack,
                    pageTitle: self.pageNavigation.canGoBack ? "Artist" : "Home",
                    pageControls: nil,
                    sidebarHeader: nil,
                    onBack: {},
                    onAI: {}
                ),
                windowTitle: self.pageNavigation.canGoBack ? "Artist" : "Home"
            )
        }
    }

    /// The shell hosted the way `MainWindow` hosts it, with a page that has a stack.
    @MainActor
    private final class Harness {
        let window: NSWindow
        let changes = ToolbarChanges()
        let pageNavigation = PageNavigationModel()
        private let box = PathBox()

        init() {
            let pageNavigation = self.pageNavigation
            let box = self.box
            let path = Binding(get: { box.path }, set: { box.path = $0 })

            let page = PageNavigationStack(id: "takeover-test", path: path) {
                Text("ROOT")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationDestination(for: Artist.self) { artist in
                        Text("ARTIST \(artist.name)")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
            }
            .environment(pageNavigation)

            let hosting = NSHostingController(
                rootView: ShellRoot(pageNavigation: pageNavigation, page: AnyView(page))
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            self.window = window
            window.contentViewController = hosting
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            // Not on the desktop: the window only has to exist for AppKit to lay it out and for SwiftUI
            // to reach it.
            window.alphaValue = 0
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.transient, .ignoresCycle]
            window.orderBack(nil)
        }

        /// Lets the shell install its toolbar (deferred a main-actor turn) and lets SwiftUI lay the
        /// window out. A real turn of the main actor is what the deferred install waits for.
        func settle(_ milliseconds: Int = 400) async {
            try? await Task.sleep(for: .milliseconds(milliseconds))
            self.window.layoutIfNeeded()
        }

        /// Watches the window's toolbar from here on: a navigation must not replace it at all.
        func watchToolbar() {
            let changes = self.changes
            changes.observation = self.window.observe(\.toolbar, options: [.new]) { window, _ in
                MainActor.assumeIsolated {
                    changes.records.append((
                        toolbar: window.toolbar?.identifier ?? (window.toolbar == nil ? "nil" : "other"),
                        contentHeight: window.contentLayoutRect.height
                    ))
                }
            }
        }

        var toolbarIsTheShells: Bool {
            self.window.toolbar?.identifier == WindowToolbarController.toolbarIdentifier
        }
    }

    private func artist() -> Artist {
        Artist(id: "UCtakeover", name: "Takeover Artist")
    }

    @Test("A push and a pop leave the window's toolbar alone")
    func navigationDoesNotReplaceTheToolbar() async {
        let harness = Harness()
        defer {
            harness.changes.observation = nil
            harness.window.orderOut(nil)
        }

        await harness.settle(600)
        #expect(harness.toolbarIsTheShells, "the shell did not install the app's toolbar")
        harness.watchToolbar()

        harness.pageNavigation.open(.artist(self.artist()))
        await harness.settle(600)
        #expect(harness.pageNavigation.canGoBack, "the page was pushed onto the stack")

        harness.pageNavigation.goBack()
        await harness.settle(600)
        #expect(!harness.pageNavigation.canGoBack, "the page was popped off the stack")

        let takeovers = harness.changes.records
            .map { "\($0.toolbar)@\(Int($0.contentHeight))" }
            .joined(separator: ", ")
        #expect(
            takeovers.isEmpty,
            "SwiftUI replaced the window's toolbar during navigation, which drops the page's top inset for a turn: \(takeovers)"
        )
        #expect(harness.toolbarIsTheShells, "the window is left without the app's toolbar")
    }
}
