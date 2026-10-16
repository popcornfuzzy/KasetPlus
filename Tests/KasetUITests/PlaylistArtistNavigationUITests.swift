import CoreGraphics
import XCTest

/// Regression tests for the header's artist credit.
///
/// The credit in a playlist/album header pushes `ArtistDetailView`. Pressing Back used to leave the
/// app unresponsive — the window kept painting the previous page but stopped answering events, and
/// the main thread never returned. These tests drive the path a user takes (open a playlist, click
/// the credited artist, press Back) and assert afterwards that the page is back *and* the app still
/// answers accessibility queries, which is what fails when the main thread is stuck.
///
/// Albums and playlists share the same header, so covering Liked Music covers both routes.
///
/// They need UI test mode, which is what `Scripts/run-ui-tests.sh` sets up: the app must be built
/// and installed at `/Applications/Kaset.app`, and mock mode is switched on through a marker file,
/// because macOS drops the launch arguments a sandboxed runner passes on (see `docs/testing.md`).
///
/// ```bash
/// Scripts/run-ui-tests.sh KasetUITests/PlaylistArtistNavigationUITests
/// ```
@MainActor
final class PlaylistArtistNavigationUITests: KasetUITestCase {
    /// Identifiers of the credited-artist links in the header. The artist ID is part of the
    /// identifier, so the tests match the prefix and stay independent of the account's data.
    private static let artistCreditPrefix = "playlistDetailView.artistCredit."

    /// Mirrors `PlaylistDetailView.artworkSize`.
    private static let artworkSize: CGFloat = 180

    func testLikedMusicArtistCreditThenBackLeavesAppResponsive() {
        // A frozen app can stall an accessibility query past its timeout, so bound the whole test.
        self.executionTimeAllowance = 240

        self.launchDefault()

        // A debug build can spend a while on launch work before the sidebar is up.
        let likedMusicItem = self.app.buttons[TestAccessibilityID.Sidebar.likedMusicItem].firstMatch
        XCTAssertTrue(self.waitQuietly(likedMusicItem, timeout: 90), "the sidebar should appear after launch")

        self.navigateToLikedMusic()

        let credit = self.artistCredit
        XCTAssertTrue(
            self.waitQuietly(credit, timeout: 30),
            "Liked Music should show a clickable artist credit in its header.\n\(self.app.debugDescription)"
        )

        // The backdrop behind the header, sampled before the trip. Coming back must leave it
        // unchanged: the list used to keep its row decoration painted over the whole header row,
        // which showed up as a full-width accent-coloured band (see ADR-0014).
        let before = self.headerBackdropPixel(near: credit)

        // The window can sit behind another app's, and a click XCUITest cannot hit-test silently
        // lands nowhere (`Falling back to element center point`). Front the app, and fail loudly on
        // the frame instead of waiting out the navigation timeout.
        self.app.activate()
        XCTAssertTrue(
            self.waitUntilHittable(credit, timeout: 15),
            "The artist credit is not clickable: \(credit.frame) in window \(self.app.windows.firstMatch.frame)."
        )

        credit.click()

        // The playlist page is replaced by the artist page; the credit's disappearance is the push.
        XCTAssertTrue(
            self.waitForElementToDisappear(credit, timeout: 25),
            "Clicking the credit should open the artist page.\n\(self.app.debugDescription)"
        )

        self.pressBack()

        // The regression: after the pop the playlist must be back *and* the app must still respond.
        // When the main thread spins, this query never resolves and the test fails here.
        XCTAssertTrue(
            self.waitQuietly(credit, timeout: 25),
            "The Liked Music header should be back after pressing Back, and the app must still answer accessibility queries.\n\(self.app.debugDescription)"
        )

        // A second round trip. The header used to keep its row activation after the first push, and
        // a repeat click on the credit was ignored until some *other* row was clicked.
        Thread.sleep(forTimeInterval: 1)
        credit.click()
        XCTAssertTrue(
            self.waitForElementToDisappear(credit, timeout: 25),
            "the artist page should open again after returning.\n\(self.app.debugDescription)"
        )

        self.pressBack()
        XCTAssertTrue(
            self.waitQuietly(credit, timeout: 25),
            "The Liked Music header should be back after a second round trip.\n\(self.app.debugDescription)"
        )

        let after = self.headerBackdropPixel(near: credit)
        guard let before, let after else {
            XCTFail("Could not sample the header backdrop (before: \(String(describing: before)), after: \(String(describing: after)))")
            return
        }

        let delta = max(
            abs(before.red - after.red),
            max(abs(before.green - after.green), abs(before.blue - after.blue))
        )
        XCTContext.runActivity(named: "header backdrop before: \(before), after: \(after), delta: \(delta)") { _ in }
        XCTAssertLessThan(
            delta,
            24,
            "The header backdrop changed after returning from the artist page (before: \(before), after: \(after)). The list is painting a decoration over the header."
        )

        // And it must not be tinted in the first place: the table used to paint its row highlight
        // over the whole header — accent red while the window was key, gray while it was not.
        let spread = before.red - min(before.green, before.blue)
        XCTAssertLessThan(
            spread,
            40,
            "The header is tinted (sampled \(before)), which is the table's row highlight over the header."
        )
    }

    // MARK: - Header layout

    /// The header's action row is pinned to the thumbnail's bottom edge, its controls share one
    /// height, and the actions that fit beside Play and Shuffle are in the row instead of the "…" menu.
    ///
    /// The header used to be the list's first row, so the table fixed its height. Above the list it
    /// became a flexible child of the page's stack, and the stack shared the space the tracks list
    /// left over with it: the buttons drifted ~140 pt down and the header grew to ~310 pt. Forcing
    /// the header to its ideal height then made the list claim the container's full height, so the
    /// page measured 961 pt in a 734 pt window, and the stack centred the overflow — the header slid
    /// up until its top half, and the toolbar's controls over it, was clipped off the window.
    ///
    /// The row is *aligned* to the thumbnail's bottom edge — nothing in the header is a `Spacer`, so
    /// the header stays its own height — and this test pins that down: the row starts at or below the
    /// metadata line, ends on the artwork's bottom edge, and never leaves the window. It also covers
    /// the two things the row itself got wrong: the "…" menu sits on the glass buttons' centre line, and
    /// the actions with room in the row are drawn there rather than only in that menu (one set of actions
    /// split between a row of shapes and the menu — see ADR-0033). Since the actions appear in one shape of
    /// the row at a time, each is asserted once: a duplicate would mean a shape the row is not drawing is
    /// in the accessibility tree, and VoiceOver reads the same action several times.
    func testHeaderActionRowSitsOnTheArtworkBottomEdge() {
        self.executionTimeAllowance = 240

        self.launchDefault()

        let likedMusicItem = self.app.buttons[TestAccessibilityID.Sidebar.likedMusicItem].firstMatch
        XCTAssertTrue(self.waitQuietly(likedMusicItem, timeout: 90), "the sidebar should appear after launch")

        self.navigateToLikedMusic()

        let artwork = self.app.descendants(matching: .any)[TestAccessibilityID.PlaylistDetail.artwork].firstMatch
        XCTAssertTrue(
            self.waitQuietly(artwork, timeout: 30),
            "the header thumbnail should be visible.\n\(self.app.debugDescription)"
        )

        let play = self.app.buttons[TestAccessibilityID.PlaylistDetail.playButton].firstMatch
        XCTAssertTrue(self.waitQuietly(play, timeout: 15), "the header should show the play button")

        let shuffle = self.app.buttons[TestAccessibilityID.PlaylistDetail.shuffleButton].firstMatch
        XCTAssertTrue(self.waitQuietly(shuffle, timeout: 15), "the header should show the shuffle button")

        // Addressed by identifier rather than as a button: the "…" is an `AXMenuButton`, which
        // `app.buttons` does not match — the same reason the artwork above is looked up this way.
        let more = self.app.descendants(matching: .any)[TestAccessibilityID.PlaylistDetail.moreButton].firstMatch
        XCTAssertTrue(self.waitQuietly(more, timeout: 15), "the header should show the actions menu")

        let credit = self.artistCredit
        XCTAssertTrue(self.waitQuietly(credit, timeout: 15), "the header should show the artist credit")

        let metadata = self.app.staticTexts[TestAccessibilityID.PlaylistDetail.metadata].firstMatch
        XCTAssertTrue(self.waitQuietly(metadata, timeout: 15), "the header should show the track count and duration")

        let window = self.app.windows.firstMatch
        XCTContext.runActivity(
            named: """
            window=\(window.frame) artwork=\(artwork.frame) play=\(play.frame) \
            shuffle=\(shuffle.frame) more=\(more.frame) credit=\(credit.frame) metadata=\(metadata.frame)
            """
        ) { _ in }

        // The header has to be *inside* the window. When the header+list need more height than the
        // window offers, the stack centres the overflow and the page slides up until the header's top
        // half — and the toolbar's controls with it — is clipped off the window.
        XCTAssertTrue(
            window.frame.contains(artwork.frame),
            "The header thumbnail \(artwork.frame) is outside the window \(window.frame)."
        )

        // The thumbnail is 180 pt; the header is this plus its 24 pt insets. Stretching shows up as a
        // far taller thumbnail container.
        XCTAssertLessThan(
            artwork.frame.height,
            Self.artworkSize + 24,
            "The header is \(artwork.frame.height) pt tall for a \(Self.artworkSize) pt thumbnail, so it is absorbing the tracks list's leftover height."
        )

        // Below the text it belongs with: the row comes after the metadata line, and a large gap is
        // the dead space a stretched header leaves behind.
        XCTAssertGreaterThanOrEqual(
            play.frame.minY,
            metadata.frame.maxY - 2,
            "The action row (\(play.frame)) should start below the metadata line (\(metadata.frame))."
        )
        XCTAssertLessThan(
            play.frame.minY - metadata.frame.maxY,
            60,
            "\(play.frame.minY - metadata.frame.maxY) pt of empty space between the metadata and the buttons: the header is stretching."
        )

        // But at the thumbnail's bottom edge: the row is aligned there, so the buttons line up with
        // the artwork's trailing corner instead of floating in the header's middle.
        XCTAssertLessThanOrEqual(
            abs(play.frame.maxY - artwork.frame.maxY),
            6,
            "The action row (\(play.frame)) should sit on the thumbnail's bottom edge (\(artwork.frame))."
        )

        // One row, one control size, one centre line. The "…" is drawn by the row itself — a plain `Menu`
        // with no indicator whose label states its own 46 × 26 pt and makes that whole frame its hit shape.
        // Measured in the running app, the label's `contentShape` is what accessibility reports: before it,
        // the menu's frame was the ellipsis' ink (12 × 2 pt) and only a click on the dots opened the menu;
        // now the control reports its full 46 × 26 pt like the glyph buttons beside it.
        XCTAssertLessThanOrEqual(
            abs(more.frame.midY - shuffle.frame.midY),
            2,
            "The actions menu's centre (\(more.frame.midY)) is not on the shuffle button's (\(shuffle.frame.midY))."
        )
        XCTAssertLessThanOrEqual(
            abs(more.frame.width - shuffle.frame.width),
            1.5,
            "The actions menu is \(more.frame.width) pt wide against the \(shuffle.frame.width) pt glyph button beside it."
        )
        XCTAssertLessThanOrEqual(
            abs(more.frame.height - shuffle.frame.height),
            1.5,
            "The actions menu is \(more.frame.height) pt tall against the \(shuffle.frame.height) pt glyph button beside it."
        )

        // The row ends inside the window: an over-wide row is clipped rather than folded into the menu.
        XCTAssertLessThanOrEqual(
            more.frame.maxX,
            window.frame.maxX,
            "The action row runs past the window edge: the menu ends at \(more.frame.maxX) in a window \(window.frame)."
        )

        // What has room in the row is in the row. Liked Music is not an album, so it can offer all
        // five secondary actions; the default window is wide enough for some of them, and each shows
        // as one glass button beside Shuffle. They appear in one shape of the row at a time, so a
        // count above one means a shape the row is not drawing is in the accessibility tree.
        let secondaryActions = [
            TestAccessibilityID.PlaylistDetail.radioButton: "Start Radio",
            TestAccessibilityID.PlaylistDetail.playNextButton: "Play Next",
            TestAccessibilityID.PlaylistDetail.addToQueueButton: "Add to Queue",
            TestAccessibilityID.PlaylistDetail.libraryButton: "Add to Library",
            TestAccessibilityID.PlaylistDetail.refineButton: "Refine Playlist",
        ]
        var inline = [String]()
        var inlineButtons = [XCUIElement]()
        var duplicated = [String]()
        for (identifier, title) in secondaryActions.sorted(by: { $0.key < $1.key }) {
            let matches = self.app.buttons.matching(identifier: identifier)
            if matches.count > 1 {
                duplicated.append("\(title) (\(matches.count)×)")
            }
            let button = matches.firstMatch
            guard button.exists else { continue }
            inline.append(title)
            inlineButtons.append(button)
            XCTAssertTrue(
                window.frame.intersects(button.frame),
                "\(title) is in the row but outside the window: \(button.frame) in \(window.frame)."
            )
        }

        // And it is spaced like one of them: the row spaces its controls 10 pt apart, so the control starts
        // 10 pt after the one in front of it ends. A menu left to macOS is 61.5 pt of pull-down chrome and
        // would run wider than its neighbours as well as leaving a gap in front of it.
        let preceding = ([shuffle] + inlineButtons)
            .filter { $0.frame.maxX <= more.frame.minX }
            .max { $0.frame.maxX < $1.frame.maxX }
        if let preceding {
            let gap = more.frame.minX - preceding.frame.maxX
            XCTAssertEqual(
                gap,
                10,
                accuracy: 1.5,
                """
                The actions menu starts \(gap) pt after the control in front of it ends (\(preceding.frame)) \
                where the row spaces its controls 10 pt apart.
                """
            )
        }

        XCTAssertTrue(
            duplicated.isEmpty,
            "These header actions are drawn more than once because more than one shape of the action row is in the tree: \(duplicated.joined(separator: ", "))."
        )
        XCTAssertFalse(
            inline.isEmpty,
            "No header action is shown beside Play and Shuffle in a \(window.frame.width) pt window, so the row is not filling up with the actions that fit."
        )
        XCTContext.runActivity(named: "inline header actions: \(inline.joined(separator: ", "))") { _ in }

        // The header belongs to the scrolling content. It spent a while pinned above the list, which
        // is what this pins down: swiping the list has to carry the thumbnail with it.
        let artworkTop = artwork.frame.minY
        artwork.swipeUp()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(
            !artwork.exists || artwork.frame.minY < artworkTop - 40,
            "The header is pinned: after swiping, the thumbnail is at \(artwork.frame) and was at \(artworkTop)."
        )
    }

    // MARK: - Toolbar

    /// The search field and the refresh button sit next to each other in the playlist toolbar.
    /// They used to be laid out on top of each other (the search pill covering the refresh
    /// control), which is what this pins down.
    func testPlaylistToolbarControlsDoNotOverlap() {
        self.executionTimeAllowance = 240

        self.launchDefault()

        let likedMusicItem = self.app.buttons[TestAccessibilityID.Sidebar.likedMusicItem].firstMatch
        XCTAssertTrue(self.waitQuietly(likedMusicItem, timeout: 90), "the sidebar should appear after launch")

        self.navigateToLikedMusic()

        self.assertToolbarControlsAreSeparate(in: "Liked Music, which has a sort menu")
    }

    /// The same toolbar without a sort menu.
    ///
    /// The sort item is only added for a playlist that can be sorted. With just the search field and
    /// the refresh button left, the toolbar drew them inside one shared glass capsule and the refresh
    /// glyph ended up on the search pill's trailing edge — the two read as a single control. The
    /// capsule is a rendering detail the accessibility tree does not expose, so this checks the
    /// layout the capsule is built from: the controls keep a gap between them and the refresh button
    /// is not inside the search field.
    func testToolbarControlsStaySeparateWithoutASortMenu() {
        self.executionTimeAllowance = 240

        self.launchDefault()

        let libraryItem = self.app.buttons[TestAccessibilityID.Sidebar.libraryItem].firstMatch
        XCTAssertTrue(self.waitQuietly(libraryItem, timeout: 90), "the sidebar should appear after launch")
        XCTAssertTrue(
            self.clickWhenHittable(libraryItem),
            "the Library sidebar item never became clickable: \(libraryItem.frame)."
        )

        // A library playlist carries no sort menu (only Liked Music and owned playlists do). The
        // library's playlist card is a plain button around its title, so the title is what can be
        // matched here. (The sidebar's disclosure button is not in the accessibility tree, which is
        // why the sidebar route is not used.)
        let playlistCardTitle = self.app.staticTexts["My Playlist 1"].firstMatch
        if !self.waitQuietly(playlistCardTitle, timeout: 45) {
            // The library page can come up without its content on a loaded machine; re-selecting it
            // is harmless and gives the fetch a second chance.
            XCTAssertTrue(self.clickWhenHittable(libraryItem), "the Library sidebar item never became clickable")
        }

        XCTAssertTrue(
            self.waitQuietly(playlistCardTitle, timeout: 30),
            "the library should list its playlists.\n\(self.app.debugDescription)"
        )
        XCTAssertTrue(
            self.clickWhenHittable(playlistCardTitle),
            "the library's first playlist never became clickable: \(playlistCardTitle.frame)."
        )

        XCTAssertFalse(
            self.app.buttons["Sort"].firstMatch.exists,
            "this playlist should not offer a sort menu"
        )

        self.assertToolbarControlsAreSeparate(in: "a library playlist, which has no sort menu")
    }

    /// Asserts the toolbar's search field and refresh button are laid out as two separate controls.
    private func assertToolbarControlsAreSeparate(in context: String) {
        let searchField = self.app.textFields
            .matching(NSPredicate(format: "placeholderValue == %@", "Search in playlist"))
            .firstMatch
        XCTAssertTrue(self.waitQuietly(searchField, timeout: 30), "the playlist search field should be in the toolbar (\(context))")

        let refreshButton = self.app.buttons["arrow.clockwise"].firstMatch
        XCTAssertTrue(self.waitQuietly(refreshButton, timeout: 15), "the refresh button should be in the toolbar (\(context))")

        let search = searchField.frame
        let refresh = refreshButton.frame
        XCTContext.runActivity(named: "\(context): search=\(search) refresh=\(refresh)") { _ in }

        // The shared capsule both controls used to be drawn in is not part of the accessibility
        // tree, so keep a screenshot: whether the two items share one background is a rendering
        // detail that only the pixels show (`xcrun xcresulttool export attachments`).
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "playlist toolbar"
        screenshot.lifetime = .keepAlways
        self.add(screenshot)

        XCTAssertFalse(
            search.intersects(refresh),
            "The search field \(search) overlaps the refresh button \(refresh) (\(context))."
        )

        // `contains` also catches a refresh glyph that was merged into the search pill's frame.
        XCTAssertFalse(
            search.contains(refresh),
            "The refresh button \(refresh) sits inside the search field \(search) (\(context))."
        )

        XCTAssertGreaterThanOrEqual(
            refresh.minX - search.maxX,
            4,
            "Only \(refresh.minX - search.maxX) pt between the search field and the refresh button (\(context)): they are sharing one control."
        )
    }

    // MARK: - Header backdrop

    private struct RGB: CustomStringConvertible {
        let red: Int
        let green: Int
        let blue: Int

        var description: String { "rgb(\(self.red), \(self.green), \(self.blue))" }
    }

    /// Samples the backdrop in the header row's empty area, to the right of the credits.
    private func headerBackdropPixel(near element: XCUIElement) -> RGB? {
        let frame = element.frame
        guard frame != .zero else { return nil }
        return self.pixelColor(at: CGPoint(x: frame.midX + 250, y: frame.midY))
    }

    /// Reads one pixel from the current screen at the given point.
    private func pixelColor(at point: CGPoint) -> RGB? {
        let screenshot = XCUIScreen.main.screenshot()
        guard let cgImage = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let scale = CGFloat(cgImage.width) / screenshot.image.size.width
        let x = Int((point.x * scale).rounded())
        let y = Int((point.y * scale).rounded())
        guard x >= 0, y >= 0, x < cgImage.width, y < cgImage.height else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Place the requested pixel at the origin of the 1×1 context.
        context.draw(
            cgImage,
            in: CGRect(x: -x, y: -(cgImage.height - 1 - y), width: cgImage.width, height: cgImage.height)
        )

        return RGB(red: Int(pixel[0]), green: Int(pixel[1]), blue: Int(pixel[2]))
    }

    // MARK: - Steps

    /// The credited artist link in the current page's header.
    private var artistCredit: XCUIElement {
        self.app.buttons.matching(identifierPrefix: Self.artistCreditPrefix).firstMatch
    }

    /// Presses the navigation stack's Back button, falling back to the standard ⌘[ shortcut.
    private func pressBack() {
        let backButton = self.app.buttons["chevron.backward"].firstMatch
        if self.waitQuietly(backButton, timeout: 5), backButton.isHittable {
            backButton.click()
            return
        }

        let labeledBack = self.app.buttons["Back"].firstMatch
        if self.waitQuietly(labeledBack, timeout: 3), labeledBack.isHittable {
            labeledBack.click()
            return
        }

        self.app.typeKey("[", modifierFlags: .command)
    }

    /// Waits for an element without failing the test, so callers can try one marker then another.
    private func waitQuietly(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Clicks an element once it is clickable, fronting the app in between attempts. The window can
    /// sit behind another app's, and a click XCUITest cannot hit-test silently lands nowhere.
    private func clickWhenHittable(_ element: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            self.app.activate()
            if element.exists, element.isHittable {
                element.click()
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        return false
    }

    /// Waits for an element to become clickable. A false `isHittable` means something is over it —
    /// another window, or a view that swallowed the click.
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

private extension XCUIElementQuery {
    /// Matches elements whose accessibility identifier starts with `prefix`.
    func matching(identifierPrefix prefix: String) -> XCUIElementQuery {
        self.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }
}
