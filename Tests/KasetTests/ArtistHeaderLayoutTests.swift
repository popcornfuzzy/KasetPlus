import AppKit
import SwiftUI
import Testing

@testable import Kaset

/// What the artist page's header does with the content an artist actually has.
///
/// The header used to hold a fixed 64 pt slot for the Apple wordmark and a `Spacer()` above its actions,
/// so a niche artist — a name, no description, no monthly listeners — drew its name floating above an
/// empty box with the buttons at the artwork's opposite edge. These tests host the real header at the
/// widths the page can have and read the height it laid out to: a cluster that hugs its content stays
/// near the artwork's height, content that grows makes it taller, and a two-line name is taller than a
/// one-line name rather than being clipped to one.
@Suite("Artist header layout")
@MainActor
struct ArtistHeaderLayoutTests {
    @MainActor
    final class Probe {
        var size: CGSize = .zero
    }

    private struct Sized<Content: View>: View {
        let probe: Probe
        let content: Content

        init(probe: Probe, @ViewBuilder content: () -> Content) {
            self.probe = probe
            self.content = content()
        }

        var body: some View {
            self.content
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { self.probe.size = proxy.size }
                            .onChange(of: proxy.size) { _, newSize in self.probe.size = newSize }
                    }
                )
        }
    }

    /// Hosts the header offscreen at exactly `width` and reports the height it laid out to.
    ///
    /// The width is imposed on the header itself, not only on the hosting view's frame: the header picks
    /// its shape from the width it is drawn into, and a hosted view whose frame is wider than what SwiftUI
    /// proposes would otherwise measure the compact shape at every width.
    private func height(_ header: ArtistHeaderView, width: CGFloat) -> CGFloat {
        let probe = Probe()
        let hosting = NSHostingView(rootView: Sized(probe: probe) {
            header.frame(width: width, alignment: .leading)
        })
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        hosting.wantsLayer = true

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }

        return probe.size.height
    }

    private func header(
        name: String = "KINGS",
        monthlyListeners: String? = nil,
        description: String? = nil,
        subscriberCount: String? = "9.41K"
    ) -> ArtistHeaderView {
        ArtistHeaderView(
            name: name,
            monthlyListeners: monthlyListeners,
            description: description,
            subscriberCount: subscriberCount,
            avatarURL: nil,
            thumbnailURL: nil,
            logoImage: nil,
            logoIsMonochrome: false,
            isSubscribed: false,
            canSubscribe: true,
            isSubscribing: false,
            canShuffle: true,
            hasMix: true,
            onShuffle: {},
            onMix: {},
            onSubscribe: {}
        )
    }

    // The page pane is 765 pt at the app's narrowest window and around 1300 pt at a wide one.
    private static let pageWidths: [CGFloat] = [765, 1000, 1290]

    @Test("A niche artist's header is the portrait's height at every page width")
    func sparseHeaderHugsItsContent() {
        for width in Self.pageWidths {
            let measured = self.height(self.header(), width: width)
            // The portrait is 180 pt and the cluster is a name and a row of buttons, so the header is the
            // portrait's height — the same at the page's floor and at a wide window. The old fixed 64 pt
            // slot plus a `Spacer()` above the actions made the cluster fill that box with the name and the
            // buttons at opposite ends.
            #expect(measured > 170, "sparse header collapsed to \(measured) at \(width)pt")
            #expect(measured < 200, "sparse header grew to \(measured) at \(width)pt")
        }
    }

    @Test("A long biography stays inside a bounded header instead of becoming a wall of text")
    func richHeaderStaysBounded() {
        // The portrait is 180 pt at every width, so the text can only grow the header past it with a lot
        // of content; three (or two, on a compact page) lines must not turn it into a column of prose.
        for width in [CGFloat(765), 1290] {
            let rich = self.height(
                self.header(
                    monthlyListeners: "103M",
                    description: String(
                        repeating: "An artist with a biography long enough to need more than one line. ",
                        count: 8
                    )
                ),
                width: width
            )

            #expect(rich < 300, "rich header grew to \(rich) at \(width)pt")
            #expect(rich > 170, "rich header collapsed to \(rich) at \(width)pt")
        }
    }

    @Test("The header stays bounded at a width narrower than any page can be")
    func narrowHeaderStaysBounded() {
        // 480 pt is narrower than the page pane can be; it stands in for a locale whose button labels are
        // longer than English, which is what the actions' second-row shape exists for. The header must
        // still lay out within its artwork-and-two-rows budget rather than running away.
        let narrow = self.height(self.header(monthlyListeners: "103M"), width: 480)

        #expect(narrow < 340, "the folded header grew to \(narrow)")
        #expect(narrow > 110, "the folded header collapsed to \(narrow)")
    }
}
