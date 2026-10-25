import AppKit
import SwiftUI
import Testing

@testable import Kaset

/// The Now Playing column's divider, driven in an offscreen window.
///
/// The shell is AppKit's, so the arithmetic it applies on every layout pass can only be checked against a
/// real split view. Two cases broke here and both are about the divider having no usable range at the
/// app's own opening width: with the page's floor enforced as a hard `minimumThickness`, the column's cap
/// at 1280 was 313 at best, and 293 with the navigation sidebar at its usual 220 — under the column's own
/// 300pt minimum. So an outward drag did nothing and an inward one collapsed the column, which the app
/// read as the reader closing it.
@MainActor
@Suite(.tags(.model))
struct WindowShellDividerTests {
    /// What the shell reports back to the app, recorded instead of performed.
    private final class Recorder: @unchecked Sendable {
        var collapsedEvents: [Bool] = []
    }

    /// The shell hosted the way `MainWindow` hosts it, with the app's real numbers.
    @MainActor
    private final class Harness {
        let controller: WindowShellController
        let window: NSWindow
        let recorder: Recorder
        private let layout: WindowShellLayout

        init(width: CGFloat) {
            let recorder = Recorder()
            self.recorder = recorder
            let layout = WindowShellLayout(
                minSidebarWidth: 200,
                maxSidebarWidth: 300,
                minContentWidth: 765,
                contentSqueezeWidth: 500,
                minWindowWidth: 900,
                minInspectorWidth: 300,
                maxInspectorWidth: 560,
                autosaveName: "KasetTests.WindowShellDivider"
            )
            self.layout = layout

            let shell = WindowShell(
                sidebar: AnyView(ShellPane { size, _ in Color.red.frame(width: size.width, height: size.height) }),
                content: AnyView(ShellPane { size, _ in Color.green.frame(width: size.width, height: size.height) }),
                inspector: AnyView(ShellPane { size, _ in Color.blue.frame(width: size.width, height: size.height) }),
                layout: layout,
                showsInspector: true,
                seedInspectorWidth: 380,
                onInspectorCollapsedChange: { recorder.collapsedEvents.append($0) },
                toolbar: WindowToolbarItems(
                    tracksColumn: true,
                    showsAI: false,
                    showsNowPlayingToggle: true,
                    canGoBack: false,
                    pageTitle: "Test",
                    pageControls: nil,
                    sidebarHeader: nil,
                    onBack: {},
                    onAI: {}
                ),
                windowTitle: "Test"
            )
            let hosting = NSHostingController(
                rootView: AnyView(
                    shell.frame(minWidth: layout.minimumWindowWidth(tracksColumn: true), minHeight: 600)
                )
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 820),
                styleMask: [.titled, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            self.window = window
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: width, height: 820))
            window.orderBack(nil)
            window.layoutIfNeeded()
            Self.pump(0.4)
            window.setContentSize(NSSize(width: width, height: 820))
            Self.pump(0.3)

            // The controller the representable installed.
            if let found = Self.splitController(inView: hosting.view) {
                self.controller = found
            } else {
                Issue.record("the shell did not install a split view controller")
                self.controller = WindowShellController()
            }
        }

        var inspectorItem: NSSplitViewItem? {
            self.controller.splitViewItems.last
        }

        var columnWidth: CGFloat {
            self.controller.splitView.arrangedSubviews[2].frame.width
        }

        var pageWidth: CGFloat {
            self.controller.splitView.arrangedSubviews[1].frame.width
        }

        private static func splitController(inView view: NSView) -> WindowShellController? {
            var stack = [view]
            while let candidate = stack.popLast() {
                if candidate is NSSplitView {
                    var responder: NSResponder? = candidate
                    while let current = responder {
                        if let shell = current as? WindowShellController { return shell }
                        responder = current.nextResponder
                    }
                }
                stack.append(contentsOf: candidate.subviews)
            }
            return nil
        }

        /// What `WindowShell.updateNSViewController` does when the app's state changes.
        func apply(showsInspector: Bool) {
            let recorder = self.recorder
            self.controller.apply(
                sidebar: AnyView(ShellPane { size, _ in Color.red.frame(width: size.width, height: size.height) }),
                content: AnyView(ShellPane { size, _ in Color.green.frame(width: size.width, height: size.height) }),
                inspector: AnyView(ShellPane { size, _ in Color.blue.frame(width: size.width, height: size.height) }),
                layout: self.layout,
                state: WindowShellState(showsInspector: showsInspector, seedInspectorWidth: 380),
                toolbar: WindowToolbarItems(
                    tracksColumn: showsInspector,
                    showsAI: false,
                    showsNowPlayingToggle: true,
                    canGoBack: false,
                    pageTitle: "Test",
                    pageControls: nil,
                    sidebarHeader: nil,
                    onBack: {},
                    onAI: {}
                ),
                windowTitle: "Test",
                onInspectorCollapsedChange: { recorder.collapsedEvents.append($0) }
            )
            // The app's next layout pass is where the shell applies a state it was handed.
            self.controller.view.needsLayout = true
            self.window.layoutIfNeeded()
            Self.pump(0.3)
        }

        static func pump(_ seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.004))
            }
        }

        /// Lets the column's own animation run out and the split view lay itself out after it.
        /// Lets the column's own animation run out, so the next press starts from a settled pane.
        func settle() {
            self.window.layoutIfNeeded()
            Self.pump(0.5)
            self.window.layoutIfNeeded()
            self.controller.view.layoutSubtreeIfNeeded()
        }

        /// Moves the divider the way a drag does: in steps, laying the split view out between them.
        func drag(by delta: CGFloat) {
            let split = self.controller.splitView
            let current = split.bounds.width - self.columnWidth - split.dividerThickness
            let target = current + delta
            let step: CGFloat = delta < 0 ? -20 : 20
            var x = current
            while step < 0 ? x > target : x < target {
                x += step
                split.setPosition(x, ofDividerAt: 1)
                self.window.layoutIfNeeded()
                Self.pump(0.02)
            }
            split.setPosition(target, ofDividerAt: 1)
            self.window.layoutIfNeeded()
            Self.pump(0.05)
        }
    }

    @Test("The column can be dragged out to its maximum at the window's opening width")
    func columnReachesItsMaximumAtTheDefaultWindow() {
        let harness = Harness(width: 1280)
        defer { harness.window.orderOut(nil) }

        guard let item = harness.inspectorItem else { return }
        // The regression: with the page only inches from its floor at this width, the column used to be
        // capped at its own minimum, so its divider had nothing to drag.
        #expect(
            item.maximumThickness > item.minimumThickness + 1,
            "the column's divider has no range: [\(Int(item.minimumThickness)), \(Int(item.maximumThickness))]"
        )

        // All the way to the column's own maximum: the page gives way, it does not stop the drag.
        harness.drag(by: -600)
        #expect(
            abs(harness.columnWidth - item.maximumThickness) <= 1,
            "the column stopped at \(Int(harness.columnWidth)) against a maximum of \(Int(item.maximumThickness))"
        )
        #expect(
            harness.pageWidth >= 499,
            "the drag squeezed the page to \(Int(harness.pageWidth)), below its squeeze floor"
        )
        #expect(item.isCollapsed == false)
    }

    @Test("An inward drag narrows the column instead of collapsing it")
    func draggingInwardNarrowsTheColumn() {
        let harness = Harness(width: 1280)
        defer { harness.window.orderOut(nil) }

        harness.drag(by: -600)
        let widened = harness.columnWidth

        harness.drag(by: 200)
        #expect(
            abs(harness.columnWidth - (widened - 200)) <= 2,
            "the column went from \(Int(widened)) to \(Int(harness.columnWidth)) on a 200pt drag"
        )
        #expect(harness.inspectorItem?.isCollapsed == false, "the column collapsed inside its own bounds")
        #expect(harness.recorder.collapsedEvents.isEmpty, "the app was told the reader closed the column")
    }

    @Test("Dragging past the minimum stops there instead of collapsing the column")
    func draggingPastTheMinimumStopsThere() {
        let harness = Harness(width: 1280)
        defer { harness.window.orderOut(nil) }

        harness.drag(by: -600)
        // Well past the column's floor: AppKit's own rule for a collapsible item collapses it here.
        harness.drag(by: 900)

        #expect(
            abs(harness.columnWidth - 300) <= 1,
            "the column ended at \(Int(harness.columnWidth)) instead of stopping at its 300pt minimum"
        )
        #expect(
            harness.inspectorItem?.isCollapsed == false,
            "the column collapsed on a drag past its minimum"
        )
        #expect(harness.recorder.collapsedEvents.isEmpty, "the app was told the reader closed the column")
    }

    @Test("The toolbar toggle still collapses and reopens the column")
    func toolbarToggleStillCollapses() {
        let harness = Harness(width: 1280)
        defer { harness.window.orderOut(nil) }

        // The button's action, which is AppKit's own animated inspector toggle.
        harness.controller.toggleNowPlayingColumn()
        #expect(
            harness.inspectorItem?.isCollapsed == true,
            "the button no longer collapses the column — a drag is the only thing that must not"
        )
        #expect(
            harness.recorder.collapsedEvents == [true],
            "the app was not told the reader closed the column"
        )
        // Let the animation run out, then press it again: the column reopens from a settled collapse.
        harness.settle()

        harness.controller.toggleNowPlayingColumn()
        #expect(
            harness.inspectorItem?.isCollapsed == false,
            "the button no longer reopens the column"
        )
        #expect(harness.recorder.collapsedEvents == [true, false])
        harness.settle()
        // The pane's widths are not asserted here: an offscreen window lays its split view out a pass behind
        // the toggle, so the state above is the contract and the animation is AppKit's own.
    }
}
