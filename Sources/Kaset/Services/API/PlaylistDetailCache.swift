import CryptoKit
import Darwin
import Foundation

// MARK: - PlaylistDetailCache

/// Persists the last copy of each playlist page, so a playlist opens on the rows and artwork it held
/// last time while the fresh copy loads behind it.
///
/// One file per account and playlist under `~/Library/Application Support/Kaset/PlaylistCache`, as a
/// small versioned envelope around ``PlaylistDetail``. A page is written every time it grows — after the
/// first page, after each appended page, and after the recommendation section — so reopening a playlist
/// shows it as deep as it was left.
struct PlaylistDetailCache: Sendable {
    static let shared = PlaylistDetailCache()

    /// Bumped whenever a stored page must not be shown any more — a change to the models or to the
    /// parser leaves an old file decoding cleanly, so the version is the only signal that it is stale.
    static let schemaVersion = 1

    /// How many playlist pages are kept on disk. A reader moves through far fewer playlists than this
    /// in a session, and the entries are evicted least recently opened first.
    private static let maxEntries = 120

    /// How old a stored page may be before it is discarded rather than shown.
    private static let staleAge: TimeInterval = 30 * 24 * 60 * 60

    /// Decoded pages, keyed exactly like the files.
    ///
    /// A playlist page model is constructed whenever its window's body is evaluated, and each one seeds
    /// itself, so decoding the same JSON again for every construction would put that work on the main
    /// thread for nothing. Held per instance, so a store with its own directory never sees another's
    /// pages.
    private let memory = PageMemory()

    /// Directory holding one JSON file per account and playlist.
    let directoryURL: URL

    private let logger = DiagnosticsLogger.api

    /// - Parameter directory: Directory for the stored pages. Defaults to
    ///   Application Support/Kaset/PlaylistCache; injectable so tests never touch the real cache.
    init(directory: URL? = nil) {
        self.directoryURL = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(
            at: self.directoryURL,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Reads and writes

    /// The page stored for this playlist under this account, or `nil` when nothing usable is stored.
    ///
    /// The account is part of the key, not a filter applied afterwards: a playlist is the account's own
    /// copy, so one account's stored rows must never open under another.
    func load(playlistId: String, accountID: String?) -> PlaylistDetail? {
        let cacheKey = Self.cacheKey(playlistId: playlistId, accountID: accountID)
        if let decoded = self.memory.pages.object(forKey: cacheKey as NSString) {
            return decoded.detail
        }

        let fileURL = self.fileURL(for: cacheKey)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        do {
            let file = try JSONDecoder().decode(StoredPlaylist.self, from: data)
            guard file.version == Self.schemaVersion,
                  file.playlistId == Self.normalizedPlaylistId(playlistId),
                  file.accountID == Self.normalizedAccount(accountID)
            else {
                return nil
            }

            guard Date().timeIntervalSince(file.savedAt) < Self.staleAge else {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }

            // A page opened now is a page in use, so it is the last of the entries to be evicted.
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: fileURL.path
            )
            self.memory.pages.setObject(DecodedPage(file.detail), forKey: cacheKey as NSString)
            return file.detail
        } catch {
            self.logger.debug("Playlist cache: could not read a stored page: \(error.localizedDescription)")
            return nil
        }
    }

    /// Stores a page for the next open, replacing anything stored for the same playlist and account.
    func save(_ detail: PlaylistDetail, playlistId: String, accountID: String?) {
        let cacheKey = Self.cacheKey(playlistId: playlistId, accountID: accountID)
        let file = StoredPlaylist(
            version: Self.schemaVersion,
            playlistId: Self.normalizedPlaylistId(playlistId),
            accountID: Self.normalizedAccount(accountID),
            savedAt: Date(),
            detail: detail
        )

        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: self.fileURL(for: cacheKey), options: .atomic)
            self.memory.pages.setObject(DecodedPage(detail), forKey: cacheKey as NSString)
            self.prune()
        } catch {
            self.logger.debug("Playlist cache: could not store a page: \(error.localizedDescription)")
        }
    }

    /// Drops the page stored for this playlist under this account, for a playlist that no longer exists.
    func remove(playlistId: String, accountID: String?) {
        let cacheKey = Self.cacheKey(playlistId: playlistId, accountID: accountID)
        self.memory.pages.removeObject(forKey: cacheKey as NSString)
        try? FileManager.default.removeItem(at: self.fileURL(for: cacheKey))
    }

    // MARK: - Keys

    /// The account a page is stored under. A page opened before an account is known shares one bucket
    /// rather than every account's.
    private static func normalizedAccount(_ accountID: String?) -> String {
        accountID ?? ""
    }

    /// The ID a page is filed under.
    ///
    /// YouTube Music wraps a playlist ID in `VL` on some surfaces and serves it bare on others — Liked
    /// Music is `LM` in the sidebar and `VLLM` from a browse response — and both name the same list. The
    /// alias is dropped from the key so a playlist opened from one place is found from every other.
    static func normalizedPlaylistId(_ playlistId: String) -> String {
        playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
    }

    private static func cacheKey(playlistId: String, accountID: String?) -> String {
        "\(self.normalizedAccount(accountID))\u{0}\(self.normalizedPlaylistId(playlistId))"
    }

    private func fileURL(for cacheKey: String) -> URL {
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
        let name = digest.compactMap { String(format: "%02x", $0) }.joined()
        return self.directoryURL.appendingPathComponent(name).appendingPathExtension("json")
    }

    // MARK: - Eviction

    /// Drops expired pages and keeps only the most recently opened ones.
    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: self.directoryURL,
            includingPropertiesForKeys: keys
        ) else { return }

        let now = Date()
        var kept: [(url: URL, modified: Date)] = []
        for file in files where file.pathExtension == "json" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            if now.timeIntervalSince(modified) >= Self.staleAge {
                try? FileManager.default.removeItem(at: file)
            } else {
                kept.append((file, modified))
            }
        }

        guard kept.count > Self.maxEntries else { return }
        for entry in kept.sorted(by: { $0.modified < $1.modified }).prefix(kept.count - Self.maxEntries) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    // MARK: - Locations

    /// Real `~/Library/Application Support/Kaset/PlaylistCache` directory.
    ///
    /// Resolved from the actual home directory (`getpwuid`) rather than `.applicationSupportDirectory`
    /// because a sandboxed app gets redirected to its container. The app sandbox grants access to this
    /// real path via a home-relative temporary exception in `Kaset.entitlements` — the same resolution
    /// `LyricsCacheStore` uses.
    private static func defaultDirectory() -> URL {
        let home = self.realHomeDirectory() ?? FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/Kaset", isDirectory: true)
            .appendingPathComponent("PlaylistCache", isDirectory: true)
    }

    private static func realHomeDirectory() -> URL? {
        guard let passwd = getpwuid(getuid()),
              let home = passwd.pointee.pw_dir
        else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
    }
}

// MARK: - Decoded page

/// The pages a store has decoded, for the life of its process.
///
/// `NSCache` is thread-safe and drops entries under memory pressure; the wrapper exists so the value
/// type can carry one without making it global.
private final class PageMemory: @unchecked Sendable {
    let pages = NSCache<NSString, DecodedPage>()
}

/// A decoded page, held only for the process's lifetime so repeated constructions of the same page do
/// not decode the JSON again. `NSCache` needs class values.
private final class DecodedPage: @unchecked Sendable {
    let detail: PlaylistDetail

    init(_ detail: PlaylistDetail) {
        self.detail = detail
    }
}

// MARK: - Stored page

/// One stored playlist page: the schema that wrote it, what it belongs to, and when it was written.
///
/// The playlist and account IDs are repeated inside the file so a stored page is self-describing: a
/// copied file or a hand-edited cache cannot hand another playlist's rows to a page.
private struct StoredPlaylist: Codable {
    let version: Int
    let playlistId: String
    let accountID: String
    let savedAt: Date
    let detail: PlaylistDetail
}
