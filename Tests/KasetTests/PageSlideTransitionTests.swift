import AppKit
import QuartzCore
import SwiftUI
import Testing

@testable import Kaset

/// The slide a page has when it is pushed or popped.
///
/// The motion itself is a `CATransition` on the pane's layer, which an offscreen render cannot be asked to
/// show. What can be stated is everything that decides what the reader sees — which layer it lands on,
/// which way it goes, and when it is not added at all — and the layer is the one that matters: a slide
/// wired to a layer that is not the page's is a page that still swaps in place.
@MainActor
@Suite(.serialized)
struct PageSlideTransitionTests {
    @Observable
    final class PathBox {
        var path = NavigationPath()
    }

    private struct Harness: View {
        let model: PageNavigationModel
        @Bindable var box: PathBox

        var body: some View {
            PageNavigationStack(id: "slide-test", path: self.$box.path) {
                Text("HOME")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationDestination(for: Artist.self) { artist in
                        Text("ARTIST \(artist.name)")
                    }
            }
            .environment(self.model)
        }
    }

    /// Advances the run loop so the hosted view lays out and draws.
    private func pump(_ seconds: Double = 0.2) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
    }

    private func host(_ content: some View) -> (window: NSWindow, hosting: NSHostingView<AnyView>) {
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        hosting.wantsLayer = true
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.orderBack(nil)
        self.pump()
        return (window, hosting)
    }

    /// Waits for the slide of one direction to be on the layer. It is removed when it finishes, so the
    /// page's own update is pumped in short steps rather than run past it.
    private func waitForSlide(
        on layer: CALayer?,
        subtype: CATransitionSubtype,
        timeout: Double = 1
    ) -> CATransition? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let slide = layer?.animation(forKey: PageSlideTransition.animationKey) as? CATransition,
               slide.subtype == subtype
            {
                return slide
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
        return nil
    }

    @Test("A push comes in from the trailing edge and a pop from the leading edge")
    func theSlideGoesTheWayThePageMoved() {
        let transition = PageSlideTransition()
        let (_, hosting) = self.host(
            Color.clear
                .frame(width: 200, height: 120)
                .background(PageSlideProbe(transition: transition))
        )

        // The layer found is the pane the page is drawn into, not the page's own SwiftUI subtree.
        #expect(transition.hostDescription.contains("HostingView"), "\(transition.hostDescription)")

        let push = transition.perform(from: 0, to: 1)
        #expect(push?.type == .push)
        #expect(push?.subtype == .fromRight)
        #expect(push?.duration == PageSlideTransition.duration)
        #expect(
            hosting.layer?.animation(forKey: PageSlideTransition.animationKey) != nil,
            "the transition was added to the pane's layer"
        )

        let pop = transition.perform(from: 1, to: 0)
        #expect(pop?.type == .push)
        #expect(pop?.subtype == .fromLeft)
    }

    @Test("A change at the same depth does not slide")
    func theSameDepthDoesNotSlide() {
        let transition = PageSlideTransition()
        let (_, hosting) = self.host(
            Color.clear
                .frame(width: 200, height: 120)
                .background(PageSlideProbe(transition: transition))
        )

        #expect(transition.perform(from: 1, to: 1) == nil)
        #expect(hosting.layer?.animation(forKey: PageSlideTransition.animationKey) == nil)
    }

    @Test("Reduce Motion leaves the page to swap with no motion")
    func reduceMotionDoesNotSlide() {
        let transition = PageSlideTransition()
        let (_, hosting) = self.host(
            Color.clear
                .frame(width: 200, height: 120)
                .background(PageSlideProbe(transition: transition))
        )

        #expect(transition.perform(from: 0, to: 1, reduceMotion: true) == nil)
        #expect(hosting.layer?.animation(forKey: PageSlideTransition.animationKey) == nil)
    }

    @Test("The page's own stack slides on the push and pop the window asks for")
    func thePageStackSlidesOnPushAndPop() {
        let model = PageNavigationModel()
        let box = PathBox()
        let (_, hosting) = self.host(Harness(model: model, box: box))

        model.open(.artist(Artist(id: "UCslideprobe", name: "Slide Probe")))
        #expect(self.waitForSlide(on: hosting.layer, subtype: .fromRight) != nil, "the push slid")
        #expect(box.path.count == 1)

        model.goBack()
        #expect(self.waitForSlide(on: hosting.layer, subtype: .fromLeft) != nil, "the pop slid")
        #expect(box.path.isEmpty)
    }
}
