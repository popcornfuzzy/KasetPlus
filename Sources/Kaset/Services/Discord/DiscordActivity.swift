import Foundation

// MARK: - DiscordActivity

/// One Discord Rich Presence activity — the card the Discord client shows under Kaset's name.
///
/// Built from the same player state the scrobbling pipeline reads, so it says what Last.fm's
/// now-playing says: the track, the artists, the album (on the artwork), the artwork itself and a
/// progress bar while it plays. Discord, not Kaset, draws it; Kaset only hands over the fields.
///
/// Field names are Discord's own (`large_image`, not `largeImage`), so they are spelled out in
/// `CodingKeys` rather than inferred by an encoder strategy.
struct DiscordActivity: Encodable, Equatable, Sendable {
    /// Discord's activity kinds. Music is `listening`; the raw values are the wire protocol's.
    enum Kind: Int, Encodable, Sendable {
        case playing = 0
        case listening = 2
    }

    /// The progress bar's anchors, in Unix milliseconds.
    ///
    /// Discord draws the timer from these, client-side, so they are sent once per playback session
    /// and never refreshed: `start` is where playback began, and `end` is where it will stop.
    struct Timestamps: Encodable, Equatable, Sendable {
        let start: Int64
        let end: Int64?
    }

    /// The artwork and its hover text. `large_text` carries the album, the way a Last.fm card
    /// names the album beside the cover rather than in the artist line; `small_image` is Kaset's
    /// own icon, in the corner where Discord puts the application that is reporting.
    struct Assets: Encodable, Equatable, Sendable {
        let largeImage: String?
        let largeText: String?
        let smallImage: String?
        let smallText: String?

        enum CodingKeys: String, CodingKey {
            case largeImage = "large_image"
            case largeText = "large_text"
            case smallImage = "small_image"
            case smallText = "small_text"
        }
    }

    /// A link under the card.
    struct Button: Encodable, Equatable, Sendable {
        let label: String
        let url: String
    }

    let type: Kind
    let details: String
    let state: String?
    let timestamps: Timestamps?
    let assets: Assets?
    let buttons: [Button]?
    let instance: Bool = false
}

// MARK: - Building the card

extension DiscordActivity {
    /// Discord rejects longer texts, and truncates silently rather than telling the app.
    static let textLimit = 128

    /// Discord's button label limit.
    static let buttonLabelLimit = 32

    /// The card for `song` at a point in its playback session.
    ///
    /// - Parameters:
    ///   - song: The track the player is on.
    ///   - duration: Its length in seconds; `0` while still unknown.
    ///   - isPlaying: Whether playback is running. A paused track gets no timestamps: Discord draws
    ///     a timer from fixed values and cannot freeze one, so a paused card would keep counting.
    ///   - startedAt: When this playback session began, which anchors the progress bar.
    static func nowPlaying(
        song: Song,
        duration: TimeInterval,
        isPlaying: Bool,
        startedAt: Date
    ) -> DiscordActivity? {
        let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let artists = song.artistsDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = song.album?.title.trimmingCharacters(in: .whitespacesAndNewlines)

        return DiscordActivity(
            type: .listening,
            details: Self.clipped(title, to: Self.textLimit),
            state: artists.isEmpty ? nil : Self.clipped(artists, to: Self.textLimit),
            timestamps: isPlaying
                ? Timestamps(
                    start: Self.milliseconds(since1970: startedAt),
                    end: duration > 0
                        ? Self.milliseconds(since1970: startedAt.addingTimeInterval(duration))
                        : nil
                )
                : nil,
            assets: Assets(
                largeImage: song.thumbnailURL?.absoluteString,
                largeText: album.flatMap { $0.isEmpty ? nil : Self.clipped($0, to: Self.textLimit) },
                smallImage: DiscordApplication.iconURL,
                smallText: DiscordApplication.name
            ),
            buttons: Self.buttons(for: song)
        )
    }

    /// The card's links: the record, and where Kaset comes from. Discord draws at most two buttons,
    /// which is exactly what these are.
    private static func buttons(for song: Song) -> [Button]? {
        var buttons: [Button] = []

        // Only songs that came from YouTube Music have a record to link to.
        if !song.videoId.isEmpty,
           let url = URL(string: "https://music.youtube.com/watch?v=\(song.videoId)")
        {
            buttons.append(
                Button(
                    label: Self.clipped("Listen on YouTube Music", to: Self.buttonLabelLimit),
                    url: url.absoluteString
                )
            )
        }

        if let url = URL(string: DiscordApplication.repositoryURL) {
            buttons.append(
                Button(
                    label: Self.clipped("Kaset on GitHub", to: Self.buttonLabelLimit),
                    url: url.absoluteString
                )
            )
        }

        return buttons.isEmpty ? nil : buttons
    }

    private static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    private static func milliseconds(since1970 date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
