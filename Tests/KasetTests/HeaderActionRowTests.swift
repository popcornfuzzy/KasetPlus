import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Kaset

/// What the header's action row is built from: the size its controls come out at, and how it gives itself
/// up as its width shrinks.
///
/// All of it is invisible to a build and to every test that does not launch the app:
///
/// - **The row's controls are not one size.** `.controlSize(.large)` glass controls do not share a height
///   on macOS 26: measured here, a labelled glass button is 28 pt tall while a glyph-only one is 26, so
///   the row pins every control's layout height to the labelled one (`actionRowControlHeight`).
/// - **A `Menu` cannot be given the row's look by a style.** Left alone, macOS draws its own pull-down
///   chrome over the row's glass — a flat pill, measured 61.5 pt wide, with a chevron; under
///   `.menuStyle(.button)` the chevron costs 27.5 pt (74.5 against 47 without) and the row's glass style
///   still does not reach the control. So the overflow control is plain, has no indicator, and states its
///   own size and Liquid Glass capsule — 46 by 26 pt, the size the glyph buttons it sits beside come out
///   at. Its label then carries a `contentShape`, because a plain-styled menu hit-tests its label's ink
///   rather than its frame: without it the capsule is drawn but dead, and only the three dots open the
///   menu. Both sizes are measured here, and all three of those facts are guarded in the row's source.
/// - **The row has to fold.** The row draws the widest shape of a ladder that fits the width the header
///   offers it. A ladder whose glyph shapes all fit at the app's narrowest window would never change shape
///   at all, so the two widest shapes name their actions and the ladder is measured here at a spread of
///   widths: nothing may overflow its row, and each shape must be narrower than the one above it, because
///   `PlaylistDetailView.fittingShapeIndex` reads the ladder widest-first and stops at the first shape
///   that fits.
///
/// The last test guards the shipped source, because none of the measurements say anything about the row
/// that is actually built: the controls below mirror the row's own modifier stack and the shape list they
/// are measured as is held against `PlaylistDetailView.shapeLadder`.
@Suite("Header action row")
@MainActor
struct HeaderActionRowTests {
    /// Mirrors `PlaylistDetailView.actionRowControlHeight`; the source guard fails if they part.
    private static let rowControlHeight: CGFloat = 28

    /// Mirrors `PlaylistDetailView.overflowControlSize`.
    private static let overflowControlSize = CGSize(width: 46, height: 26)

    /// `PlaylistDetailView`'s source, from the test file's own location.
    private static let playlistDetailViewSource: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // the file
        .deletingLastPathComponent() // KasetTests
        .deletingLastPathComponent() // Tests
        .appending(path: "Sources/Kaset/Views/PlaylistDetailView.swift")

    /// The actions a playlist can offer the row, in the row's order, with the glyph each one carries — the
    /// row's `availableHeaderActions(for:)` set, which is what its widest shapes render.
    private static let secondaryActions: [(title: String, systemImage: String)] = [
        ("Start Radio", "dot.radiowaves.left.and.right"),
        ("Play Next", "text.insert"),
        ("Add to Queue", "text.append"),
        ("Add to Library", "plus.circle"),
        ("Refine Playlist", "sparkles"),
    ]

    /// The action names as the row's source spells them, in `secondaryActions`' order. The shape list is
    /// read out of the source through these, so a shape naming an action this table does not know is a
    /// failure rather than a shape that quietly goes unmeasured.
    private static let actionNames = [".radio", ".playNext", ".addToQueue", ".library", ".refine"]

    /// The ladder as `PlaylistDetailView.shapeLadder` lists it, widest first: names while there is room
    /// for names, then the same actions as glyphs, then fewer of them.
    private static let ladder: [(showsTitles: Bool, actions: [Int])] = [
        (true, [0, 1, 2, 3]),
        (true, [0, 1, 2]),
        (false, [0, 1, 2, 3, 4]),
        (false, [0, 1, 2, 3]),
        (false, [0, 1, 2]),
        (false, [0, 1]),
        (false, [0]),
        (false, []),
    ]

    // MARK: - The row's controls

    private var playButton: some View {
        Button {} label: { Label("Play", systemImage: "play.fill") }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .frame(height: Self.rowControlHeight)
    }

    /// A glyph control as the row builds it, without the row's layout height: this is the size the
    /// overflow menu has to match, and the height difference the row's pinning exists for.
    private var glyphControl: some View {
        Button {} label: { Image(systemName: "shuffle") }
            .buttonStyle(.glass)
            .controlSize(.large)
    }

    private var glyphButton: some View {
        Button {} label: { Image(systemName: "shuffle") }
            .buttonStyle(.glass)
            .controlSize(.large)
            .frame(height: Self.rowControlHeight)
    }

    /// The row's overflow control as it ships: plain, no indicator, its own Liquid Glass capsule, and a
    /// label whose whole 46 × 26 pt frame is the hit shape.
    private var overflowControl: some View {
        Menu {} label: {
            Image(systemName: "ellipsis")
                .frame(width: Self.overflowControlSize.width, height: Self.overflowControlSize.height)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    /// The same control with the row's layout height around it, as the row builds it.
    private var overflowMenu: some View {
        self.overflowControl
            .frame(height: Self.rowControlHeight)
    }

    /// The same menu left to macOS: the pull-down chrome the row must not fall back to.
    private var unstyledMenu: some View {
        Menu {} label: { Image(systemName: "ellipsis") }
            .buttonStyle(.glass)
            .controlSize(.large)
            .frame(height: Self.rowControlHeight)
    }

    /// The button-style menu the row used to carry: the chevron it pays 27.5 pt for.
    private var buttonStyledMenuIncludingIndicator: some View {
        Menu {} label: { Image(systemName: "ellipsis") }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .controlSize(.large)
            .frame(height: Self.rowControlHeight)
    }

    private func action(_ index: Int, showsTitle: Bool) -> some View {
        let action = Self.secondaryActions[index]
        return Button {} label: {
            if showsTitle {
                Label(action.title, systemImage: action.systemImage)
            } else {
                Image(systemName: action.systemImage)
            }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .frame(height: Self.rowControlHeight)
    }

    /// One shape of the ladder: Play, Shuffle, the shape's secondary actions, then the overflow menu.
    private func row(showsTitles: Bool, actions: [Int]) -> some View {
        HStack(spacing: 10) {
            self.playButton
            self.glyphButton
            ForEach(actions, id: \.self) { index in
                self.action(index, showsTitle: showsTitles)
            }
            self.overflowMenu
        }
    }

    // MARK: - Measuring

    /// Hosts `content` offscreen in a real window and lets the run loop deliver a layout pass, then
    /// reports the size it settled on.
    ///
    /// The control is hosted bare — a `frame` around it would be measured instead of the control.
    private func settledSize(of content: some View) -> CGSize {
        let (host, window) = self.host(content)
        defer { window.orderOut(nil) }
        return host.fittingSize
    }

    private func host(_ content: some View) -> (NSHostingView<some View>, NSWindow) {
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)

        // The style resolves its metrics during a layout pass, so let the run loop deliver one.
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }

        return (hosting, window)
    }

    // MARK: - The controls

    @Test("Every control in the row is the row's height, and the menu is the size of a glyph control")
    func rowControlsShareTheRowHeight() {
        let play = self.settledSize(of: self.playButton)
        let glyph = self.settledSize(of: self.glyphButton)
        let menu = self.settledSize(of: self.overflowMenu)

        #expect(
            abs(play.height - Self.rowControlHeight) < 0.5,
            "The labelled Play button measured \(play), which is not the row's \(Self.rowControlHeight) pt height."
        )
        for (name, size) in [("glyph button", glyph), ("overflow menu", menu)] {
            #expect(
                abs(size.height - Self.rowControlHeight) < 0.5,
                """
                The row's \(name) measured \(size) rather than the row's \(Self.rowControlHeight) pt. \
                Without that height the glyph controls come out 2 pt shorter than the Play button beside them.
                """
            )
        }

        // The controls the row's readers compare, without the row's layout height wrapped around either:
        // the menu has to read as the glyph button beside it.
        let glyphControl = self.settledSize(of: self.glyphControl)
        let menuControl = self.settledSize(of: self.overflowControl)
        #expect(
            abs(menuControl.width - glyphControl.width) < 1.5 && abs(menuControl.height - glyphControl.height) < 1.5,
            """
            The overflow menu's control is \(menuControl) against the \(glyphControl) of the glyph control \
            it sits beside, so it does not read as one of them. `overflowControlSize` \
            (\(Self.overflowControlSize)) is what states that size; this test holds the two together and \
            the source guard holds the constant.
            """
        )
    }

    @Test("The overflow menu has to state its own size, its own glass and no indicator")
    func theMenuCannotBeStyledIntoAButton() {
        let menu = self.settledSize(of: self.overflowMenu)
        let unstyled = self.settledSize(of: self.unstyledMenu)
        let withIndicator = self.settledSize(of: self.buttonStyledMenuIncludingIndicator)

        #expect(
            unstyled.width > menu.width + 10,
            """
            Left to macOS the menu measured \(unstyled) against the row's \(menu). That chrome — the \
            pull-down pill — is what made the "…" read as a flat capsule beside the glass buttons rather \
            than as one of them; if it is gone, the row's own plain control is no longer earning its keep.
            """
        )
        #expect(
            withIndicator.width > menu.width + 10,
            """
            A button-style menu with its indicator measured \(withIndicator) against the row's \(menu): the \
            chevron and the label box macOS reserves for it are what the row's plain control avoids. The \
            row states the size itself because no menu or button style gives it this control.
            """
        )
    }

    // MARK: - Choosing the shape

    @Test("The shape that is drawn is the widest one that fits the row")
    func theWidestShapeThatFitsIsChosen() {
        // The ladder's measured widths, widest first (see `theLadderFoldsAsTheRowNarrows`).
        let widths: [CGFloat] = [735, 588, 465, 408, 355, 300, 245, 188]

        #expect(PlaylistDetailView.fittingShapeIndex(for: 2000, widths: widths) == 0)
        #expect(PlaylistDetailView.fittingShapeIndex(for: 735, widths: widths) == 0, "a shape exactly as wide as the row still fits it")
        #expect(PlaylistDetailView.fittingShapeIndex(for: 734, widths: widths) == 1)
        #expect(PlaylistDetailView.fittingShapeIndex(for: 465, widths: widths) == 2)
        #expect(PlaylistDetailView.fittingShapeIndex(for: 188, widths: widths) == 7)
        #expect(
            PlaylistDetailView.fittingShapeIndex(for: 100, widths: widths) == 7,
            "A row narrower than every shape has to fall back to the narrowest one, not to a shape that overflows it."
        )
        #expect(
            PlaylistDetailView.fittingShapeIndex(for: 900, widths: [0, 0, 0, 0, 0, 0, 0, 0]) == 7,
            """
            With nothing measured yet the row has to draw its narrowest shape: the first layout pass has no \
            widths, and any other choice would draw a shape that may not fit.
            """
        )

        // Every shape fits the row it was chosen for, and the next wider one does not. The walk starts at
        // the narrowest shape: below that there is no shape that fits, which is the fallback asserted above.
        for width in stride(from: CGFloat(188), through: 900, by: 17) {
            let index = PlaylistDetailView.fittingShapeIndex(for: width, widths: widths)
            #expect(widths[index] <= width, "Shape \(index) is \(widths[index]) pt wide in a \(width) pt row.")
            if index > 0 {
                #expect(widths[index - 1] > width, "Shape \(index - 1) fits too, so it was the shape to draw.")
            }
        }
    }

    @Test("The ladder folds as its row narrows, and no shape overflows it")
    func theLadderFoldsAsTheRowNarrows() throws {
        #expect(Self.ladder.count == 8, "The ladder has more shapes than this test walks.")

        let widths = Self.ladder.map { self.settledSize(of: self.row(showsTitles: $0.showsTitles, actions: $0.actions)).width }

        for (index, width) in widths.enumerated().dropFirst() {
            #expect(
                width < widths[index - 1],
                """
                Shape \(index) measured \(width) pt against shape \(index - 1)'s \(widths[index - 1]) pt: the \
                ladder is not widest-first, so `fittingShapeIndex` stops at the wrong shape.
                """
            )
        }

        let widest = try #require(widths.first)
        let narrowest = try #require(widths.last)
        #expect(
            widest > 700,
            "The widest shape measured \(widest) pt: its widest shapes are no longer the named ones."
        )
        #expect(
            narrowest < 200,
            "The narrowest shape measured \(narrowest) pt: it no longer folds down to Play, Shuffle and the menu."
        )

        // The rungs the ladder has to move through to be worth having at all: a row that is already 650 pt
        // at the app's narrowest window, and a ladder whose shapes run from 735 pt to 188 pt.
        #expect(
            widths.filter { $0 <= 650 }.count >= 5,
            """
            Only \(widths.filter { $0 <= 650 }.count) shapes fit a 650 pt row (measured: \(widths.map { Int($0) })). \
            A ladder that is already narrow enough at the app's narrowest window never changes shape while the \
            window is resized.
            """
        )
    }

    // MARK: - The shipped row

    /// A slice of the row's source with its comments removed.
    ///
    /// These guards are about what the row's code does, and the row's comments name the very modifiers
    /// they explain — a guard that read the prose would fail on the explanation of the thing it is
    /// guarding against.
    private func code(of source: Substring) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("The row's source keeps the shared height, the plain glass menu and the ladder")
    func rowSourceKeepsTheRow() throws {
        let source = try String(contentsOf: Self.playlistDetailViewSource, encoding: .utf8)
        let start = try #require(source.range(of: "// MARK: - Header Actions"))
        let end = try #require(source.range(of: "private func metadataText("))
        let row = source[start.lowerBound ..< end.lowerBound]
        let rowCode = self.code(of: row)

        #expect(
            source.contains("private static let actionRowControlHeight: CGFloat = \(Int(Self.rowControlHeight))\n"),
            "The row's control height moved: this test mirrors it as \(Self.rowControlHeight) pt."
        )
        #expect(
            source.contains(
                "private static let overflowControlSize = CGSize(width: \(Int(Self.overflowControlSize.width)), height: \(Int(Self.overflowControlSize.height)))\n"
            ),
            """
            The overflow control's size moved: this test mirrors it as \(Self.overflowControlSize). It is the \
            size the glyph controls beside it come out at, and the row draws it because no menu or button \
            style gives a `Menu` that control.
            """
        )

        let sized = rowCode.components(separatedBy: ".frame(height: Self.actionRowControlHeight)").count - 1
        #expect(
            sized == 4,
            """
            \(sized) of the row's four controls (play, shuffle, the secondary actions, the menu) pin \
            themselves to the row's height. The ones that do not come out 2 pt short of the others.
            """
        )

        for modifier in [
            "\n        .buttonStyle(.plain)\n",
            "\n        .menuIndicator(.hidden)\n",
            "\n        .glassEffect(.regular.interactive(), in: .capsule)\n",
        ] {
            #expect(
                rowCode.contains(modifier),
                """
                The row's overflow menu is missing \(modifier.trimmingCharacters(in: .whitespacesAndNewlines)): \
                without the plain style macOS draws its own pull-down chrome over the row, without \
                `.menuIndicator(.hidden)` the control keeps a chevron, and the glass capsule is the only \
                thing drawing the control the way the buttons beside it are drawn.
                """
            )
        }
        #expect(
            !rowCode.contains(".menuStyle(.button)"),
            """
            The row styles its overflow menu again. `.menuStyle(.button)` was measured at 74.5 pt against the \
            47 pt of the same menu with its indicator hidden and 46 pt for the glyph controls beside it — the \
            control it produces is not the one the row's neighbours are.
            """
        )

        // The menu's label is the control's body, so its three statements have to stay together and in order:
        // the 46 × 26 pt the glyph controls beside it come out at, and the whole-frame hit shape a
        // plain-styled menu has no chrome to give it. Without the `contentShape` the capsule is drawn but
        // dead — only a click on the three dots themselves opens the menu, which is exactly the bug the
        // running app showed.
        let lines = rowCode
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let ellipsis = try #require(
            lines.firstIndex(of: "Image(systemName: \"ellipsis\")"),
            "The row's overflow control no longer draws an `ellipsis`."
        )
        let label = Array(lines[ellipsis...].prefix(3))
        #expect(
            label == [
                "Image(systemName: \"ellipsis\")",
                ".frame(width: Self.overflowControlSize.width, height: Self.overflowControlSize.height)",
                ".contentShape(.rect)",
            ],
            """
            The overflow control's label is stated as \(label) as it ships — the frame is the 46 × 26 pt \
            the glyph controls beside it come out at, and `contentShape` is what makes that frame the \
            button rather than the three dots' ink.
            """
        )

        #expect(
            !rowCode.contains("withAnimation") && !rowCode.contains(".transition("),
            """
            The row animates its change of shape again. It is deliberately stated in one step: a window dragged \
            across the ladder resizes continuously, and interpolating the rungs made every resize a moving \
            picture of the row's controls growing and shrinking under the pointer.
            """
        )
        #expect(
            !rowCode.contains("ViewThatFits"),
            """
            The row is back on `ViewThatFits`, which picks a shape by laying all of them out and keeps the \
            choice to itself: it cannot say what it picked, and every shape it holds stays in the layout and \
            in the accessibility tree.
            """
        )

        #expect(
            rowCode.contains("self.availableHeaderActions(for: detail).intersection(requested)")
                && rowCode.contains("self.availableHeaderActions(for: detail).subtracting(inline)"),
            """
            The row and its menu split one set of actions: the row renders what fits of `available`, and \
            the menu renders the rest. Any other arrangement can show an action twice or drop it.
            """
        )

        // The shapes the ladder is measured as above, read out of the row's own source: the same actions,
        // the same order. A shape added, removed or reordered in the view without being measured here shows
        // up as a mismatch instead of silently going unmeasured.
        let shipped = self.code(of: source[...])
            .split(separator: "\n")
            .compactMap { line -> (showsTitles: Bool, actions: [Int])? in
                // The actions between the shape's own brackets — not `split`, which drops the empty
                // subsequence an empty action set leaves and reads the next bracket group instead.
                guard line.contains("HeaderRowShape(actions: ["),
                      let open = line.firstIndex(of: "["),
                      let close = line[line.index(after: open)...].firstIndex(of: "]")
                else { return nil }
                let inline = line[line.index(after: open) ..< close]
                let names = inline.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard names.allSatisfy(Self.actionNames.contains) else { return nil }
                return (line.contains("showsTitles: true"), names.compactMap(Self.actionNames.firstIndex(of:)))
            }
        #expect(
            shipped.count == Self.ladder.count,
            "The row lists \(shipped.count) shapes and this test measures \(Self.ladder.count): see `Self.ladder`."
        )
        #expect(
            zip(shipped, Self.ladder).allSatisfy { pair in pair.0 == pair.1 },
            """
            The row's shapes are \(shipped) where this test measures \(Self.ladder). The shapes are measured \
            widest-first — names while there is room for names, then glyphs — and the row draws the first one \
            that fits.
            """
        )
        #expect(
            rowCode.contains("Self.shapeLadder[self.rowShapeIndex]"),
            "The row is not drawing the shape it chose."
        )
    }

    @Test("The row draws its overflow menu only when something is behind it")
    func overflowMenuIsDrawnOnlyWhenItHoldsSomething() throws {
        let everyAction: PlaylistDetailView.HeaderAction = [.radio, .playNext, .addToQueue, .library]

        // An album that fits whole: the row renders every action the page has, and an album has no
        // playlist to rename or delete, so the menu has nothing in it. That is the state the running app
        // shipped — a menu that opened onto nothing, so the three dots read as a dead control.
        #expect(
            !PlaylistDetailView.showsOverflowMenu(
                available: everyAction,
                inline: everyAction,
                showsManagement: false
            ),
            "An album's row would draw an empty overflow menu again."
        )

        // Anything the row had no room for belongs in the menu, and a playlist can always be managed.
        #expect(
            PlaylistDetailView.showsOverflowMenu(
                available: everyAction,
                inline: [.radio, .playNext, .addToQueue],
                showsManagement: false
            ),
            "An action the row could not render would be unreachable."
        )
        #expect(
            PlaylistDetailView.showsOverflowMenu(available: everyAction, inline: everyAction, showsManagement: true),
            "A playlist the reader owns lost its own management actions."
        )
        #expect(
            !PlaylistDetailView.showsOverflowMenu(available: [], inline: [], showsManagement: false),
            "A menu with no actions and no management behind it is a control that opens nothing."
        )

        // Liked Music is the page the two halves of the gate disagree about, and where the disagreement is
        // visible: it offers the queue actions (and its radio) and nothing to manage — the library action is
        // refused on it, and Rename and Delete are not its to offer — so a shape that renders everything it
        // has leaves the menu nothing and the "…" goes with it. The page used to draw one whose only items
        // were Rename and Delete, at the window widths where the row had something left over to put in it.
        let likedMusic: PlaylistDetailView.HeaderAction = [.playNext, .addToQueue]
        #expect(
            !PlaylistDetailView.showsOverflowMenu(
                available: likedMusic,
                inline: likedMusic,
                showsManagement: false
            ),
            """
            Liked Music's row draws a "…" for a menu with nothing behind it: Rename and Delete are not that \
            page's to offer, and every action it has is in the row.
            """
        )
        #expect(
            PlaylistDetailView.showsOverflowMenu(
                available: likedMusic,
                inline: [.playNext],
                showsManagement: false
            ),
            "An action the row could not render would be unreachable on Liked Music."
        )

        // The gate is what the row draws through, and both the row and the ladder's measurement passes go
        // through `headerActionRow`: a menu left outside the gate is drawn on the album page above.
        let source = try String(contentsOf: Self.playlistDetailViewSource, encoding: .utf8)
        let start = try #require(source.range(of: "// MARK: - Header Actions"))
        let end = try #require(source.range(of: "private func metadataText("))
        let rowCode = self.code(of: source[start.lowerBound ..< end.lowerBound])
        #expect(
            rowCode.contains("if self.hasOverflowItems(for: detail, inline: inline) {"),
            """
            The row draws its overflow menu unconditionally again, so a page whose actions all fit — every \
            album — shows a menu that opens onto nothing.
            """
        )
        #expect(
            rowCode.contains("showsManagement: detail.supportsPlaylistManagement")
                && rowCode.contains("available: self.availableHeaderActions(for: detail)"),
            """
            The row's menu gate no longer asks the same question the menu's contents answer: which actions the \
            page offers, which of them the row rendered, and whether the page has management actions at all.
            """
        )

        // The management half of the gate: `!detail.isAlbum` drew Rename and Delete on every page that is
        // not an album, which is how Liked Music — the library's own list of liked songs, neither renameable
        // nor deletable — was offered both. The two actions have to sit inside the page's own rule.
        let management = try #require(
            rowCode.range(of: "if detail.supportsPlaylistManagement {"),
            "The menu's Rename and Delete are no longer drawn through the page's own rule."
        )
        let menuLabel = try #require(
            rowCode.range(
                of: "} label: {\n            Image(systemName: \"ellipsis\")",
                range: management.upperBound ..< rowCode.endIndex
            ),
            "The menu's own label no longer follows the management section."
        )
        let managementCode = rowCode[management.upperBound ..< menuLabel.lowerBound]
        for action in ["Label(\"Rename Playlist\"", "Label(\"Delete Playlist\""] {
            #expect(
                managementCode.contains(action),
                """
                \(action)… is drawn outside the management gate again, so a page the reader cannot write to is \
                offered a write the server answers with an error.
                """
            )
        }
    }

    @Test("The row offers its library action only where the library can be written to")
    func rowSourceGatesTheLibraryAction() throws {
        let source = try String(contentsOf: Self.playlistDetailViewSource, encoding: .utf8)
        let start = try #require(source.range(of: "// MARK: - Header Actions"))
        let end = try #require(source.range(of: "private func metadataText("))
        let rowCode = self.code(of: source[start.lowerBound ..< end.lowerBound])

        // `PlaylistLibraryActionTests` holds which pages have a writable library ID and which do not; what it
        // cannot hold is whether the row asks at all — `availableHeaderActions` is private.
        #expect(
            rowCode.contains("if self.offersLibraryAction(for: detail) {")
                && rowCode.contains("return self.libraryWriteId != nil"),
            """
            The row is back to offering "Add to Library" on every page. The write behind it is `like/like` \
            with an ID as a `playlistId`, so an album browsed by its `MPREb_…` page ID, a generated mix \
            (`RD…`) and Liked Music have no membership it could toggle: the control read the same whatever \
            the reader did with it.
            """
        )
        #expect(
            !rowCode.contains("HeaderAction = [.playNext, .addToQueue, .library]"),
            """
            The row's action set names `.library` outright again, which is what put an inert control on albums, \
            mixes and Liked Music.
            """
        )
        // Liked Music has to be refused *before* the library is consulted: its ID can sit in the library's own
        // listing without a membership behind it, and "Remove from Library" beside the library's list of liked
        // songs reads as a way to empty it.
        let likedMusic = try #require(
            rowCode.range(of: "if detail.isLikedMusic {"),
            "The library action no longer excludes Liked Music at all."
        )
        let membership = try #require(
            rowCode.range(of: "return self.libraryWriteId != nil"),
            "The library action no longer asks whether the page has an ID the library accepts."
        )
        #expect(
            likedMusic.lowerBound < membership.lowerBound,
            """
            Liked Music is checked only after the library snapshot, so the Liked Music page reaches the action \
            through being listed in the library and offers to remove the library's own liked songs.
            """
        )
        // Nor may a write go to a page ID: `like/like` answers `MPREb_…` with `HTTP 404`, which is how an \
        // album's control failed silently.
        let writeId = try #require(
            source.range(of: "private var libraryWriteId: String?"),
            "The page no longer resolves the ID a library write goes to."
        )
        let writeIdCode = self.code(of: source[writeId.lowerBound ..< source.endIndex])
        #expect(
            writeIdCode.contains("!Playlist.isAlbumPageId(storedId)"),
            """
            A stored album page ID is used as a write target again, so removing an album the library lists by \
            its page asks `like/removelike` about a page and gets an error back.
            """
        )
    }
}
