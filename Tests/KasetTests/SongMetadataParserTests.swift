import Foundation
import Testing
@testable import Kaset

/// Tests for SongMetadataParser.
@Suite(.tags(.parser))
struct SongMetadataParserTests {
    // MARK: - Parse Title Tests

    @Test("parseTitle extracts title from renderer")
    func parseTitleExtractsTitle() {
        let renderer: [String: Any] = [
            "title": [
                "runs": [
                    ["text": "Test Song Title"],
                ],
            ],
        ]

        let result = SongMetadataParser.parseTitle(from: renderer)

        #expect(result == "Test Song Title")
    }

    @Test("parseTitle returns Unknown when no title")
    func parseTitleReturnsUnknown() {
        let renderer: [String: Any] = [:]

        let result = SongMetadataParser.parseTitle(from: renderer)

        #expect(result == "Unknown")
    }

    @Test("parseTitle returns Unknown when runs empty")
    func parseTitleReturnsUnknownWhenRunsEmpty() {
        let renderer: [String: Any] = [
            "title": [
                "runs": [] as [[String: Any]],
            ],
        ]

        let result = SongMetadataParser.parseTitle(from: renderer)

        #expect(result == "Unknown")
    }

    // MARK: - Parse Artists Tests

    @Test("parseArtists extracts single artist")
    func parseArtistsSingleArtist() {
        let renderer = Self.makeRendererWithArtists([
            ("Taylor Swift", "UC-artist-1"),
        ])

        let artists = SongMetadataParser.parseArtists(from: renderer)

        #expect(artists.count == 1)
        #expect(artists[0].name == "Taylor Swift")
        #expect(artists[0].id == "UC-artist-1")
    }

    @Test("parseArtists extracts multiple artists")
    func parseArtistsMultipleArtists() {
        let renderer = Self.makeRendererWithArtists([
            ("Artist One", "UC-1"),
            ("Artist Two", "UC-2"),
        ])

        let artists = SongMetadataParser.parseArtists(from: renderer)

        #expect(artists.count == 2)
        #expect(artists[0].name == "Artist One")
        #expect(artists[1].name == "Artist Two")
    }

    @Test("parseArtists filters out separators")
    func parseArtistsFiltersSeparators() {
        let renderer: [String: Any] = [
            "longBylineText": [
                "runs": [
                    ["text": "Artist One"],
                    ["text": " • "],
                    ["text": "Artist Two"],
                    ["text": " & "],
                    ["text": "Artist Three"],
                ],
            ],
        ]

        let artists = SongMetadataParser.parseArtists(from: renderer)

        #expect(artists.count == 3)
        #expect(artists.map(\.name) == ["Artist One", "Artist Two", "Artist Three"])
    }

    @Test("A song's byline names the album and the year, and neither is an artist")
    func parseArtistsDropsAlbumAndYear() throws {
        // The shape YouTube sends for an art track, captured from the `next` endpoint: the artist is a
        // link to an artist page, the album is a link to an album page, and the year is plain text.
        let renderer: [String: Any] = [
            "title": ["runs": [["text": "Staender"]]],
            "longBylineText": [
                "runs": [
                    [
                        "text": "SXTN",
                        "navigationEndpoint": [
                            "browseEndpoint": ["browseId": "UCFNSyezyK_1_f0nOrNaCdHQ"],
                        ],
                    ],
                    ["text": " • "],
                    [
                        "text": "Leben am Limit",
                        "navigationEndpoint": [
                            "browseEndpoint": ["browseId": "MPREb_v1BJdlN5p5X"],
                        ],
                    ],
                    ["text": " • "],
                    ["text": "2017"],
                ],
            ],
        ]

        let album = SongMetadataParser.parseAlbum(from: renderer)
        let artists = SongMetadataParser.parseArtists(from: renderer, albumTitle: album?.title)

        #expect(artists.map(\.name) == ["SXTN"])
        #expect(artists.map(\.id) == ["UCFNSyezyK_1_f0nOrNaCdHQ"], "the artist's page is what the credit opens")
        #expect(album?.title == "Leben am Limit")
        #expect(album?.id == "MPREb_v1BJdlN5p5X")
        #expect(album?.year == "2017")
    }

    @Test("A video's byline names the audience, which is not an artist")
    func parseArtistsDropsAudienceCounts() {
        // The same endpoint, for a video: "Rick Astley • 1.8B views • 19M likes".
        let renderer: [String: Any] = [
            "longBylineText": [
                "runs": [
                    [
                        "text": "Rick Astley",
                        "navigationEndpoint": [
                            "browseEndpoint": ["browseId": "UCwZEU0wAwIyZb4x5G_KJp2w"],
                        ],
                    ],
                    ["text": " • "],
                    ["text": "1.8B views"],
                    ["text": " • "],
                    ["text": "19M likes"],
                ],
            ],
        ]

        let artists = SongMetadataParser.parseArtists(from: renderer)

        #expect(artists.map(\.name) == ["Rick Astley"])
        #expect(artists.map(\.id) == ["UCwZEU0wAwIyZb4x5G_KJp2w"])
    }

    @Test("parseArtists generates UUID for artist without ID")
    func parseArtistsGeneratesUUID() {
        let renderer: [String: Any] = [
            "longBylineText": [
                "runs": [
                    ["text": "Unknown Artist"],
                ],
            ],
        ]

        let artists = SongMetadataParser.parseArtists(from: renderer)

        #expect(artists.count == 1)
        #expect(artists[0].name == "Unknown Artist")
        #expect(!artists[0].id.isEmpty)
    }

    @Test("parseArtists returns empty when no byline")
    func parseArtistsReturnsEmptyWhenNoByline() {
        let renderer: [String: Any] = [:]

        let artists = SongMetadataParser.parseArtists(from: renderer)

        #expect(artists.isEmpty)
    }

    // MARK: - Parse Thumbnail Tests

    @Test("parseThumbnail extracts URL")
    func parseThumbnailExtractsURL() {
        let renderer: [String: Any] = [
            "thumbnail": [
                "thumbnails": [
                    ["url": "https://example.com/small.jpg", "width": 60, "height": 60],
                    ["url": "https://example.com/large.jpg", "width": 226, "height": 226],
                ],
            ],
        ]

        let url = SongMetadataParser.parseThumbnail(from: renderer)

        #expect(url?.absoluteString == "https://example.com/large.jpg")
    }

    @Test("parseThumbnail handles protocol-relative URL")
    func parseThumbnailHandlesProtocolRelative() {
        let renderer: [String: Any] = [
            "thumbnail": [
                "thumbnails": [
                    ["url": "//example.com/thumb.jpg"],
                ],
            ],
        ]

        let url = SongMetadataParser.parseThumbnail(from: renderer)

        #expect(url?.absoluteString == "https://example.com/thumb.jpg")
    }

    @Test("parseThumbnail returns nil when no thumbnails")
    func parseThumbnailReturnsNilWhenNoThumbnails() {
        let renderer: [String: Any] = [:]

        let url = SongMetadataParser.parseThumbnail(from: renderer)

        #expect(url == nil)
    }

    // MARK: - Parse Duration Tests

    @Test("parseDuration extracts duration")
    func parseDurationExtractsDuration() {
        let renderer: [String: Any] = [
            "lengthText": [
                "runs": [
                    ["text": "3:45"],
                ],
            ],
        ]

        let duration = SongMetadataParser.parseDuration(from: renderer)

        #expect(duration == 225) // 3 * 60 + 45
    }

    @Test("parseDuration handles hour format")
    func parseDurationHandlesHourFormat() {
        let renderer: [String: Any] = [
            "lengthText": [
                "runs": [
                    ["text": "1:02:30"],
                ],
            ],
        ]

        let duration = SongMetadataParser.parseDuration(from: renderer)

        #expect(duration == 3750) // 1 * 3600 + 2 * 60 + 30
    }

    @Test("parseDuration returns nil when no length text")
    func parseDurationReturnsNilWhenNoLengthText() {
        let renderer: [String: Any] = [:]

        let duration = SongMetadataParser.parseDuration(from: renderer)

        #expect(duration == nil)
    }

    // MARK: - Parse Menu Data Tests

    /// The like button of the video the player holds, exactly where a real `next` response keeps it:
    /// `playerOverlays.playerOverlayRenderer.actions[].likeButtonRenderer.likeStatus`.
    private static func overlayPayload(likeStatus: String?) -> [String: Any] {
        guard let likeStatus else { return [:] }
        return [
            "playerOverlays": [
                "playerOverlayRenderer": [
                    "actions": [
                        ["likeButtonRenderer": ["likeStatus": likeStatus, "target": ["videoId": "video-id"]]],
                    ],
                ],
            ],
        ]
    }

    @Test("The like status comes from the player overlay, as a real `next` response states it")
    func likeStatusComesFromPlayerOverlays() {
        #expect(SongMetadataParser.parseLikeStatus(from: Self.overlayPayload(likeStatus: "LIKE")) == .like)
        #expect(SongMetadataParser.parseLikeStatus(from: Self.overlayPayload(likeStatus: "DISLIKE")) == .dislike)
        #expect(SongMetadataParser.parseLikeStatus(from: Self.overlayPayload(likeStatus: "INDIFFERENT")) == .indifferent)
    }

    @Test("No player overlay leaves the like status unknown")
    func missingOverlayLeavesLikeStatusUnknown() {
        #expect(SongMetadataParser.parseLikeStatus(from: [:]) == nil)
    }

    @Test("The record of a liked song carries its rating")
    func recordCarriesTheRating() throws {
        var data = Self.makeNextResponseWithRenderer([
            "playlistPanelVideoRenderer": [
                "videoId": "video-id",
                "title": ["runs": [["text": "A Song"]]],
                "longBylineText": [
                    "runs": [
                        ["text": "SXTN", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCsxtn"]]],
                    ],
                ],
            ],
        ])
        for (key, value) in Self.overlayPayload(likeStatus: "LIKE") { data[key] = value }

        let song = try SongMetadataParser.parse(data, videoId: "video-id")

        #expect(song.likeStatus == .like, "a liked track's thumb comes from the record")
    }

    @Test("parseMenuData extracts library add token")
    func parseMenuDataExtractsLibraryAddToken() {
        let renderer = Self.makeRendererWithLibraryMenu(
            iconType: "LIBRARY_ADD",
            feedbackToken: "add-to-library-token"
        )

        let result = SongMetadataParser.parseMenuData(from: renderer)

        #expect(result.feedbackTokens?.add == "add-to-library-token")
        #expect(result.isInLibrary == false)
    }

    @Test("parseMenuData extracts library remove token and sets in library")
    func parseMenuDataExtractsLibraryRemoveToken() {
        let renderer = Self.makeRendererWithLibraryMenu(
            iconType: "LIBRARY_REMOVE",
            feedbackToken: "remove-from-library-token"
        )

        let result = SongMetadataParser.parseMenuData(from: renderer)

        #expect(result.feedbackTokens?.remove == "remove-from-library-token")
        #expect(result.isInLibrary == true)
    }

    @Test("parseMenuData handles empty menu")
    func parseMenuDataHandlesEmptyMenu() {
        let renderer: [String: Any] = [:]

        let result = SongMetadataParser.parseMenuData(from: renderer)

        #expect(result.isInLibrary == false)
        #expect(result.feedbackTokens == nil)
    }

    // MARK: - Extract Panel Video Renderer Tests

    @Test("extractPanelVideoRenderer extracts direct renderer")
    func extractPanelVideoRendererDirect() throws {
        let data = Self.makeNextResponseWithRenderer([
            "playlistPanelVideoRenderer": [
                "videoId": "test-video",
                "title": ["runs": [["text": "Test"]]],
            ],
        ])

        let renderer = try SongMetadataParser.extractPanelVideoRenderer(from: data, videoId: "test-video")

        #expect(renderer["videoId"] as? String == "test-video")
    }

    @Test("extractPanelVideoRenderer extracts wrapped renderer")
    func extractPanelVideoRendererWrapped() throws {
        let data = Self.makeNextResponseWithRenderer([
            "playlistPanelVideoWrapperRenderer": [
                "primaryRenderer": [
                    "playlistPanelVideoRenderer": [
                        "videoId": "wrapped-video",
                        "title": ["runs": [["text": "Wrapped"]]],
                    ],
                ],
            ],
        ])

        let renderer = try SongMetadataParser.extractPanelVideoRenderer(from: data, videoId: "wrapped-video")

        #expect(renderer["videoId"] as? String == "wrapped-video")
    }

    @Test("extractPanelVideoRenderer throws on invalid structure")
    func extractPanelVideoRendererThrows() {
        let data: [String: Any] = [:]

        #expect(throws: YTMusicError.self) {
            _ = try SongMetadataParser.extractPanelVideoRenderer(from: data, videoId: "test")
        }
    }

    // MARK: - Test Helpers

    private static func makeRendererWithArtists(_ artists: [(name: String, id: String)]) -> [String: Any] {
        let runs: [[String: Any]] = artists.map { artist in
            [
                "text": artist.name,
                "navigationEndpoint": [
                    "browseEndpoint": [
                        "browseId": artist.id,
                    ],
                ],
            ]
        }

        return [
            "longBylineText": [
                "runs": runs,
            ],
        ]
    }

    private static func makeRendererWithLibraryMenu(iconType: String, feedbackToken: String) -> [String: Any] {
        [
            "menu": [
                "menuRenderer": [
                    "items": [
                        [
                            "menuServiceItemRenderer": [
                                "icon": [
                                    "iconType": iconType,
                                ],
                                "serviceEndpoint": [
                                    "feedbackEndpoint": [
                                        "feedbackToken": feedbackToken,
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    private static func makeNextResponseWithRenderer(_ item: [String: Any]) -> [String: Any] {
        [
            "contents": [
                "singleColumnMusicWatchNextResultsRenderer": [
                    "tabbedRenderer": [
                        "watchNextTabbedResultsRenderer": [
                            "tabs": [
                                [
                                    "tabRenderer": [
                                        "content": [
                                            "musicQueueRenderer": [
                                                "content": [
                                                    "playlistPanelRenderer": [
                                                        "contents": [item],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }
}
