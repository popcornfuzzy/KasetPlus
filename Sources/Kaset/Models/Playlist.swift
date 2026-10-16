import Foundation

// MARK: - Playlist

/// Represents a playlist from YouTube Music.
struct Playlist: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let description: String?
    let thumbnailURL: URL?
    let trackCount: Int?
    let author: String?

    /// Whether this is an album (vs a playlist).
    /// Albums have IDs starting with "OLAK" or "MPRE".
    var isAlbum: Bool {
        self.id.hasPrefix("OLAK") || self.id.hasPrefix("MPRE")
    }

    /// Whether the library can hold this item — whether "Add to Library" is an action that means
    /// anything for it.
    var supportsLibraryMembership: Bool {
        Self.isLibraryHoldable(id: self.id)
    }

    /// The ID without the `VL` browse alias YouTube Music wraps a playlist ID in.
    var normalizedId: String {
        self.id.hasPrefix("VL") ? String(self.id.dropFirst(2)) : self.id
    }

    /// Every ID the library could list this item under, normalized.
    ///
    /// The library's own listing answers by one spelling and a page can be opened by another — an
    /// album is browsed by `MPREb_…` while its library entry may name the `OLAK5uy_…` audio
    /// playlist — so membership is asked with the whole set rather than with one guess.
    var libraryMatchIds: Set<String> {
        [self.id, self.normalizedId]
    }

    /// Whether an ID names an album's *page* (`MPREb_…`) rather than a playlist the library stores.
    ///
    /// A page ID is a browse target: `like/like` answers it with `HTTP 404 NOT_FOUND`, which is how an
    /// album's "Add to Library" used to fail silently (see ADR-0033).
    static func isAlbumPageId(_ id: String) -> Bool {
        let normalizedId = id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
        return normalizedId.hasPrefix("MPRE")
    }

    /// Whether the library can hold the item with this ID.
    ///
    /// The write behind "Add to Library" is `like/like` with `target.playlistId`
    /// (`YTMusicClient.subscribeToPlaylist`), so the ID has to be a *playlist* ID the library can store.
    /// Three of the items the app draws are not, and each was offered the action anyway — an "Add to
    /// Library" that read the same whether or not the item was saved and changed nothing when clicked:
    ///
    /// - **An album browsed by its page ID (`MPREb_…`).** That ID is a page, not a playlist: YouTube
    ///   Music saves an album under its `OLAK5uy_…` audio playlist, which is also the only ID the
    ///   library lists it by. This predicate sees the ID alone and so cannot derive one — a page that has
    ///   the album's header uses `PlaylistDetail.libraryId`, which can.
    /// - **A mix or radio (`RD…`: `RDCLAK…`, `RDEM…`, `RDTMAK…`, `RDAMVM…`).** These are generated on
    ///   request; nothing stores one.
    /// - **Liked Music (`LM`).** It *is* the library's list of liked songs, rather than a member of it.
    ///
    /// An item the library *already* holds keeps its action whatever its ID looks like (see
    /// `PlaylistDetailView.offersLibraryAction(for:)`): that is how the library offers to drop an item,
    /// including the radio playlists its own listing can carry.
    static func isLibraryHoldable(id: String) -> Bool {
        let normalizedId = id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
        if normalizedId == "LM" {
            return false
        }
        if normalizedId.hasPrefix("MPRE") {
            return false
        }
        return !normalizedId.hasPrefix("RD")
    }

    /// Display string for track count.
    var trackCountDisplay: String {
        guard let count = trackCount else { return "" }
        return count == 1 ? "1 song" : "\(count) songs"
    }
}

extension Playlist {
    /// Creates a Playlist from YouTube Music API response data.
    init?(from data: [String: Any]) {
        guard let playlistId = data["playlistId"] as? String ?? data["browseId"] as? String else {
            return nil
        }

        self.id = playlistId
        self.title = (data["title"] as? String) ?? "Unknown Playlist"
        self.description = data["description"] as? String

        // Parse thumbnail
        if let thumbnails = data["thumbnails"] as? [[String: Any]],
           let lastThumbnail = thumbnails.last,
           let urlString = lastThumbnail["url"] as? String
        {
            self.thumbnailURL = URL(string: urlString)
        } else {
            self.thumbnailURL = nil
        }

        // Parse track count
        if let count = data["trackCount"] as? Int {
            self.trackCount = count
        } else if let countString = data["trackCount"] as? String,
                  let count = Int(countString.replacingOccurrences(of: ",", with: ""))
        {
            self.trackCount = count
        } else {
            self.trackCount = nil
        }

        // Parse author
        if let authors = data["authors"] as? [[String: Any]],
           let firstAuthor = authors.first
        {
            self.author = firstAuthor["name"] as? String
        } else {
            self.author = data["author"] as? String
        }
    }
}

// MARK: - PlaylistDetail

/// Detailed playlist information including tracks.
struct PlaylistDetail: Identifiable {
    let id: String
    let title: String
    let description: String?
    let thumbnailURL: URL?
    let author: String?
    let trackCount: Int?
    let tracks: [Song]
    let duration: String?
    /// Artists credited on the album, or the playlist's creators. Carries channel IDs when the
    /// response exposed them, which is what makes the names navigable to artist pages.
    let artists: [Artist]
    /// The server's stored track ordering. `nil` when the playlist is not owned by the signed-in
    /// user, or the header did not expose a sort menu.
    let sortOrder: PlaylistSortOrder?
    /// Sort options the header advertised, in menu order. Empty when the playlist is not sortable.
    let availableSortOrders: [PlaylistSortOrder]
    /// Whether the signed-in user can edit this playlist — and therefore reorder it.
    let isEditable: Bool
    /// Mix playlist the header's "Start mix" action would play — YouTube Music's radio for this
    /// playlist or album. `nil` when the header advertised no such action.
    let mixPlaylistId: String?
    /// The playlist the page's own save/remove action names, when the header carried one.
    ///
    /// This is the target YouTube Music itself writes for the item, which is what makes it more
    /// trustworthy than anything derived here: for an album it is the `OLAK5uy_…` audio playlist the
    /// library stores the album under, never the `MPREb_…` page the album is browsed by.
    let libraryPlaylistId: String?

    /// Whether this is an album (vs a playlist).
    /// Albums have IDs starting with "OLAK" or "MPRE".
    var isAlbum: Bool {
        self.id.hasPrefix("OLAK") || self.id.hasPrefix("MPRE")
    }

    /// The ID without the `VL` browse alias YouTube Music wraps a playlist ID in. Both forms name the
    /// same list, and the library stores whichever form the response served, so anything comparing
    /// playlist IDs compares these.
    var normalizedId: String {
        self.id.hasPrefix("VL") ? String(self.id.dropFirst(2)) : self.id
    }

    /// Whether this is the Liked Music auto-playlist. Its browse response does not carry the
    /// editable header a normal playlist has, but the account can still sort it.
    var isLikedMusic: Bool {
        self.normalizedId == "LM"
    }

    /// The ID the library holds this page's item under, or `nil` when it cannot hold it at all.
    ///
    /// Three sources, in order of how much they are trusted:
    /// 1. The page's own save/remove target (`libraryPlaylistId`): the ID YouTube Music would write.
    /// 2. For a playlist, its own ID. For an album opened by its `MPREb_…` page ID, the audio playlist
    ///    its radio target names (`RDAMPL` + that playlist, see `PlaylistParser.parseRadioPlaylistId`),
    ///    because a page ID is not a target and `like/like` answers it with `HTTP 404`.
    /// 3. `nil` — an album page whose header named neither an action nor a radio target has nothing to
    ///    save under.
    ///
    /// Liked Music is refused first, because it *is* the library's list of liked songs, and a mix or
    /// radio (`RD…`) after it, because those are generated on request.
    var libraryId: String? {
        let normalizedId = self.normalizedId
        if normalizedId == "LM" {
            return nil
        }
        if normalizedId.hasPrefix("RD") {
            return nil
        }
        if normalizedId.hasPrefix("OLAK5uy_") {
            return normalizedId
        }
        if let target = self.libraryPlaylistId,
           !Playlist.isAlbumPageId(target),
           !target.hasPrefix("RD"),
           !target.hasPrefix("VL")
        {
            return target
        }
        if normalizedId.hasPrefix("MPRE") {
            guard let mixPlaylistId, mixPlaylistId.hasPrefix(Self.radioPrefix) else { return nil }
            let audioPlaylistId = String(mixPlaylistId.dropFirst(Self.radioPrefix.count))
            return audioPlaylistId.hasPrefix("OLAK5uy_") ? audioPlaylistId : nil
        }
        return normalizedId.hasPrefix("PL") ? normalizedId : nil
    }

    /// Every ID the library could list this page under, normalized — the page's own ID and the
    /// library's ID for it, which differ for an album (`MPREb_…` vs `OLAK5uy_…`).
    var libraryMatchIds: Set<String> {
        var ids: Set<String> = [self.id, self.normalizedId]
        if let libraryId = self.libraryId {
            ids.insert(libraryId)
        }
        return ids
    }

    /// What YouTube Music prefixes a mix target with: `RDAMPL` + the item's audio playlist ID.
    private static let radioPrefix = "RDAMPL"

    /// Whether the library can hold this page's item — whether "Add to Library" is an action that means
    /// anything here.
    var supportsLibraryMembership: Bool {
        self.libraryId != nil
    }

    /// Sort options to offer. Prefers the header's own menu and falls back to the standard set for
    /// Liked Music, which is sortable even though its header does not advertise a menu.
    var sortOptions: [PlaylistSortOrder] {
        if !self.availableSortOrders.isEmpty {
            return self.availableSortOrders
        }
        return self.isLikedMusic ? PlaylistSortOrder.standard : []
    }

    /// Whether the track list can be sorted in place.
    ///
    /// Albums cannot, and the server only accepts a reorder for a playlist the signed-in user can
    /// edit — the same `musicEditablePlaylistDetailHeaderRenderer` marker that gates every other
    /// playlist write. A menu advertised for a playlist we do not own is therefore not actionable,
    /// and offering it produced an `HTTP 400` when the write was sent. Liked Music is the exception:
    /// the account can reorder it although its header carries no editable marker.
    var isSortable: Bool {
        !self.isAlbum && !self.sortOptions.isEmpty && (self.isEditable || self.isLikedMusic)
    }

    /// Whether the page's own management — Rename and Delete — means anything here.
    ///
    /// Both are owner-only writes: Rename sends `browse/edit_playlist` with `ACTION_SET_PLAYLIST_NAME`
    /// and Delete sends `playlist/delete`, and the header marker that says the signed-in user owns a
    /// playlist (`musicEditablePlaylistDetailHeaderRenderer`, `isEditable`) is the same one that gates
    /// every other playlist write. A playlist the account does not own is therefore not offered them,
    /// because the server would answer with an error and the menu would be offering a write that cannot
    /// happen.
    ///
    /// Three kinds of page are refused by name as well as by the marker, because none of them is a playlist
    /// the account manages:
    ///
    /// - **Liked Music.** It *is* the library's list of liked songs, which the account can reorder
    ///   (`isSortable`) but can neither rename nor delete.
    /// - **A mix or radio (`RD…`: `RDCLAK…`, `RDEM…`, `RDTMAK…`, `RDAMVM…`).** These are generated on
    ///   request and stored nowhere — the same refusal `libraryId` makes — so there is nothing to rename or
    ///   delete.
    /// - **An album.** There is no playlist behind the page to write to.
    var supportsPlaylistManagement: Bool {
        if self.isAlbum || self.isLikedMusic || self.normalizedId.hasPrefix("RD") {
            return false
        }
        return self.isEditable
    }

    /// The option to mark as selected. Falls back to Manual — the documented server default — when
    /// the header did not name its current order.
    var effectiveSortOrder: PlaylistSortOrder {
        self.sortOrder ?? .manual
    }

    init(
        playlist: Playlist,
        tracks: [Song],
        duration: String? = nil,
        artists: [Artist] = [],
        sortOrder: PlaylistSortOrder? = nil,
        availableSortOrders: [PlaylistSortOrder] = [],
        isEditable: Bool = false,
        mixPlaylistId: String? = nil,
        libraryPlaylistId: String? = nil
    ) {
        self.id = playlist.id
        self.title = playlist.title
        self.description = playlist.description
        self.thumbnailURL = playlist.thumbnailURL
        self.author = playlist.author
        self.trackCount = playlist.trackCount
        self.tracks = tracks
        self.duration = duration
        self.artists = artists
        self.sortOrder = sortOrder
        self.availableSortOrders = availableSortOrders
        self.isEditable = isEditable
        self.mixPlaylistId = mixPlaylistId
        self.libraryPlaylistId = libraryPlaylistId
    }

    /// Track count to show in the UI, preferring the API-reported total over the loaded row count.
    var resolvedTrackCount: Int {
        self.trackCount ?? self.tracks.count
    }

    /// Display string for the resolved track count.
    var trackCountDisplay: String {
        let count = self.resolvedTrackCount
        return count == 1 ? "1 song" : "\(count.formatted()) songs"
    }
}

// MARK: - LikedSongsResponse

/// Response from the liked songs API, including pagination support.
struct LikedSongsResponse {
    /// The liked songs returned in this response.
    let songs: [Song]

    /// Continuation token for fetching more songs, if available.
    let continuationToken: String?

    /// Whether more songs are available to load.
    var hasMore: Bool {
        self.continuationToken != nil
    }
}

// MARK: - PlaylistTracksResponse

/// Response from the playlist tracks API, including pagination support.
struct PlaylistTracksResponse {
    /// The playlist detail with header info and initial tracks.
    let detail: PlaylistDetail

    /// Continuation token for fetching more tracks, if available.
    let continuationToken: String?

    /// Whether more tracks are available to load.
    var hasMore: Bool {
        self.continuationToken != nil
    }
}

// MARK: - PlaylistContinuationResponse

/// Response from a playlist continuation request.
struct PlaylistContinuationResponse {
    /// The additional tracks from this continuation.
    let tracks: [Song]

    /// Continuation token for fetching more tracks, if available.
    let continuationToken: String?

    /// Whether more tracks are available to load.
    var hasMore: Bool {
        self.continuationToken != nil
    }
}

// MARK: - Playlist Management

/// Privacy options supported by YouTube Music playlist creation/editing.
enum PlaylistPrivacy: String, CaseIterable, Codable, Sendable {
    case `private` = "PRIVATE"
    case unlisted = "UNLISTED"
    case `public` = "PUBLIC"

    var displayName: String {
        switch self {
        case .private:
            String(localized: "Private")
        case .unlisted:
            String(localized: "Unlisted")
        case .public:
            String(localized: "Public")
        }
    }
}

/// A playlist entry returned by the Add-to-Playlist API for a specific song.
struct AddToPlaylistEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let thumbnailURL: URL?
    let canAddVideo: Bool
    let canRemoveVideoById: Bool
    let containsVideo: Bool
}

/// Result metadata from adding a song to a playlist.
struct PlaylistVideoAddResult: Sendable {
    let setVideoId: String?
    let status: String?
}
