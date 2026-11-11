import Foundation
import Testing

@testable import Kaset

/// Source guards for how the podcast show page is pushed.
///
/// Opening a podcast show hung the app: the main thread sat in `NSHostingView.layout` for the 80 s
/// before the stack report sampled it (2026-11-11). The page registered two `navigationDestination`s of
/// its own while already being a destination of the stack that shows it, and it was registered a second
/// time as a `PodcastShow` destination by the stack itself — both shapes of the rule in ADR-0023: a
/// second destination on the same stack re-enters layout and freezes the app.
///
/// A hosted test does not reproduce it (ADR-0023), so these read the source.
@Suite(.tags(.model))
struct PodcastShowNavigationTests {
    private static let viewsURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // the file
        .deletingLastPathComponent() // KasetTests
        .deletingLastPathComponent() // Tests
        .appending(path: "Sources/Kaset/Views")

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: self.viewsURL.appending(path: path), encoding: .utf8)
    }

    private func showPageSource() throws -> String {
        let source = try Self.source("PodcastsView.swift")
        let start = try #require(source.range(of: "struct PodcastShowView: View"))
        let end = try #require(source.range(of: "// MARK: - PodcastEpisodeRow"))
        return String(source[start.lowerBound ..< end.lowerBound])
    }

    @Test("The podcast show page registers no destination of its own")
    func showPageRegistersNoDestination() throws {
        let page: String = try self.showPageSource()

        #expect(
            !page.contains("navigationDestination"),
            """
            PodcastShowView is a destination already. A navigationDestination on it registers a second \
            destination on the same stack, which re-enters layout and freezes the app (ADR-0023). Its \
            "Show All" pushes through `onShowAllEpisodes` onto the stack's path instead.
            """
        )

        #expect(page.contains("self.onShowAllEpisodes("))
    }

    @Test("The podcasts stack registers the show page once")
    func stackRegistersShowPageOnce() throws {
        let source = try Self.source("PodcastsView.swift")

        #expect(
            !source.contains("navigationDestination(for: PodcastShow.self)"),
            """
            PodcastsView gets its PodcastShow destination from navigationDestinations(client:artistPath:). \
            Registering it here as well put two of them on one stack, the shape that froze the app.
            """
        )
    }

    @Test("The shared destinations register the full episode list")
    func sharedDestinationsRegisterAllEpisodes() throws {
        let source = try Self.source("SharedViews/NavigationDestinationsModifier.swift")

        #expect(source.contains(".navigationDestination(for: AllEpisodesDestination.self)"))
        #expect(source.contains("onShowAllEpisodes:"))
    }
}
