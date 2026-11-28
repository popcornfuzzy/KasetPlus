import Foundation
import Testing
@testable import Kaset

/// Tests that parsers carry the song/video counterpart and `musicVideoType`.
@Suite(.serialized, .tags(.parser))
struct SongVariantParsingTests {
    // MARK: - Fixtures

    private func makeRenderer(
        videoId: String,
        title: String,
        musicVideoType: String?,
        byline: String = "Test Artist",
        length: String = "3:20"
    ) -> [String: Any] {
        var renderer: [String: Any] = [
            "videoId": videoId,
            "title": ["runs": [["text": title]]],
            "longBylineText": ["runs": [["text": byline]]],
            "lengthText": ["runs": [["text": length]]],
        ]

        if let musicVideoType {
            renderer["navigationEndpoint"] = [
                "watchEndpoint": [
                    "videoId": videoId,
                    "watchEndpointMusicSupportedConfigs": [
                        "watchEndpointMusicConfig": ["musicVideoType": musicVideoType],
                    ],
                ],
            ]
        }

        return renderer
    }

    private func makeWrapperItem(primary: [String: Any], counterpart: [String: Any]) -> [String: Any] {
        [
            "playlistPanelVideoWrapperRenderer": [
                "primaryRenderer": ["playlistPanelVideoRenderer": primary],
                "counterpart": [
                    ["counterpartRenderer": ["playlistPanelVideoRenderer": counterpart]],
                ],
            ],
        ]
    }

    /// A track row as a playlist, artist or home shelf delivers it: the video type sits on the
    /// row's own watch endpoint.
    private func makeRow(videoId: String, title: String, musicVideoType: String) -> [String: Any] {
        [
            "musicResponsiveListItemRenderer": [
                "playlistItemData": ["videoId": videoId],
                "navigationEndpoint": [
                    "watchEndpoint": [
                        "videoId": videoId,
                        "watchEndpointMusicSupportedConfigs": [
                            "watchEndpointMusicConfig": ["musicVideoType": musicVideoType],
                        ],
                    ],
                ],
                "flexColumns": [
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": ["runs": [["text": title]]],
                        ],
                    ],
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": [
                                "runs": [
                                    [
                                        "text": "Test Artist",
                                        "navigationEndpoint": [
                                            "browseEndpoint": ["browseId": "UC-test-artist"],
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

    private func makeShelfPage(row: [String: Any]) -> [String: Any] {
        [
            "header": ["musicImmersiveHeaderRenderer": ["title": ["runs": [["text": "Page"]]]]],
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [
                        [
                            "tabRenderer": [
                                "content": [
                                    "sectionListRenderer": [
                                        "contents": [
                                            ["musicShelfRenderer": ["contents": [row]]],
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

    private func makeWatchNextResponse(item: [String: Any]) -> [String: Any] {
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

    // MARK: - Tests

    @Test("SongMetadataParser attaches the counterpart and video type")
    func songMetadataParsesCounterpart() throws {
        let primary = self.makeRenderer(
            videoId: "video-id", title: "Song", musicVideoType: "MUSIC_VIDEO_TYPE_OMV"
        )
        let counterpart = self.makeRenderer(
            videoId: "audio-id", title: "Song", musicVideoType: "MUSIC_VIDEO_TYPE_ATV"
        )
        let data = self.makeWatchNextResponse(item: self.makeWrapperItem(primary: primary, counterpart: counterpart))

        let song = try SongMetadataParser.parse(data, videoId: "video-id")

        #expect(song.videoId == "video-id")
        #expect(song.musicVideoType == .omv)
        #expect(song.isVideoVariant)
        #expect(song.counterpart?.videoId == "audio-id")
        #expect(song.counterpart?.musicVideoType == .atv)
    }

    @Test("RadioQueueParser carries music video type and counterpart")
    func radioQueueParsesVariant() {
        let primary = self.makeRenderer(
            videoId: "video-id", title: "Song", musicVideoType: "MUSIC_VIDEO_TYPE_OMV"
        )
        let counterpart = self.makeRenderer(
            videoId: "audio-id", title: "Song", musicVideoType: "MUSIC_VIDEO_TYPE_ATV"
        )
        let data = self.makeWatchNextResponse(item: self.makeWrapperItem(primary: primary, counterpart: counterpart))

        let result = RadioQueueParser.parse(from: data)

        #expect(result.songs.count == 1)
        #expect(result.songs[0].videoId == "video-id")
        #expect(result.songs[0].musicVideoType == .omv)
        #expect(result.songs[0].counterpart?.videoId == "audio-id")
    }

    @Test("PlaylistParser queue tracks carry music video type and counterpart")
    func playlistQueueParsesVariant() {
        let primary = self.makeRenderer(
            videoId: "video-id", title: "Song", musicVideoType: "MUSIC_VIDEO_TYPE_OMV"
        )
        let counterpart = self.makeRenderer(
            videoId: "audio-id", title: "Song", musicVideoType: "MUSIC_VIDEO_TYPE_ATV"
        )
        let data: [String: Any] = [
            "queueDatas": [
                ["content": self.makeWrapperItem(primary: primary, counterpart: counterpart)],
            ],
        ]

        let tracks = PlaylistParser.parseQueueTracks(data)

        #expect(tracks.count == 1)
        #expect(tracks[0].videoId == "video-id")
        #expect(tracks[0].musicVideoType == .omv)
        #expect(tracks[0].counterpart?.videoId == "audio-id")
    }

    @Test("A row's video type is read from its navigation endpoint, play button or flex column")
    func rowVideoTypeShapes() {
        let endpointRow: [String: Any] = [
            "navigationEndpoint": [
                "watchEndpoint": [
                    "watchEndpointMusicSupportedConfigs": [
                        "watchEndpointMusicConfig": ["musicVideoType": "MUSIC_VIDEO_TYPE_OMV"],
                    ],
                ],
            ],
        ]
        #expect(ParsingHelpers.extractMusicVideoType(fromRow: endpointRow) == .omv)

        let playButtonRow: [String: Any] = [
            "overlay": [
                "musicItemThumbnailOverlayRenderer": [
                    "content": [
                        "musicPlayButtonRenderer": [
                            "playNavigationEndpoint": [
                                "watchEndpoint": [
                                    "watchEndpointMusicSupportedConfigs": [
                                        "watchEndpointMusicConfig": ["musicVideoType": "MUSIC_VIDEO_TYPE_UGC"],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
        #expect(ParsingHelpers.extractMusicVideoType(fromRow: playButtonRow) == .ugc)

        let flexRow: [String: Any] = [
            "flexColumns": [
                [
                    "musicResponsiveListItemFlexColumnRenderer": [
                        "text": [
                            "runs": [
                                [
                                    "text": "Song",
                                    "navigationEndpoint": [
                                        "watchEndpoint": [
                                            "watchEndpointMusicSupportedConfigs": [
                                                "watchEndpointMusicConfig": ["musicVideoType": "MUSIC_VIDEO_TYPE_ATV"],
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
        #expect(ParsingHelpers.extractMusicVideoType(fromRow: flexRow) == .atv)
        #expect(ParsingHelpers.extractMusicVideoType(fromRow: [:]) == nil)
    }

    @Test("A playlist row keeps the video type so its song version plays")
    func playlistDetailRowCarriesVideoType() {
        let data = self.makeShelfPage(
            row: self.makeRow(videoId: "video-id", title: "Song", musicVideoType: "MUSIC_VIDEO_TYPE_OMV")
        )

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "VL-test")

        #expect(detail.tracks.map(\.videoId) == ["video-id"])
        #expect(detail.tracks.first?.musicVideoType == .omv)
        #expect(detail.tracks.first?.isVideoVariant == true)
    }

    @Test("An artist page's songs keep the video type")
    func artistSongsCarryVideoType() {
        let data = self.makeShelfPage(
            row: self.makeRow(videoId: "video-id", title: "Song", musicVideoType: "MUSIC_VIDEO_TYPE_OMV")
        )

        let detail = ArtistParser.parseArtistDetail(data, artistId: "UC-test-artist")

        #expect(detail.songs.first?.videoId == "video-id")
        #expect(detail.songs.first?.musicVideoType == .omv)
    }

    @Test("A home row keeps the video type")
    func homeRowCarriesVideoType() throws {
        let sectionData: [String: Any] = [
            "musicShelfRenderer": [
                "title": ["runs": [["text": "Songs"]]],
                "contents": [
                    self.makeRow(videoId: "video-id", title: "Song", musicVideoType: "MUSIC_VIDEO_TYPE_OMV"),
                ],
            ],
        ]

        let section = try #require(HomeResponseParser.parseHomeSection(sectionData))
        guard case let .song(song)? = section.items.first else {
            Issue.record("Expected a song row")
            return
        }

        #expect(song.videoId == "video-id")
        #expect(song.musicVideoType == .omv)
        #expect(song.isVideoVariant == true)
    }

    @Test("A song counterpairs with its video")
    func songCounterpartRoundTrips() {
        let video = Song(
            id: "video-id", title: "Song", artists: [],
            videoId: "video-id", musicVideoType: .omv
        )
        let audio = Song(
            id: "audio-id", title: "Song", artists: [],
            videoId: "audio-id", musicVideoType: .atv
        ).paired(with: video)

        #expect(audio.counterpart?.videoId == "video-id")
        #expect(audio.counterpart?.isVideoVariant == true)
        #expect(audio.counterpart?.asSong.isVideoVariant == true)
    }
}
