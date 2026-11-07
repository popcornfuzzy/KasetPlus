import CryptoKit
import Foundation

// MARK: - ArtistLogoCache

/// Remembers artist wordmarks on disk for a month, so a page revisits instantly.
///
/// Only logos are stored: a miss is deliberately *not* remembered, here or in the service's memory, so an
/// artist whose wordmark Apple adds later picks it up on the next visit instead of never. Entries age out
/// on read — an artist's page art can change, and a month-old answer is worth asking for again.
actor ArtistLogoCache {
    static let shared = ArtistLogoCache()

    /// How long a stored wordmark is served before the artist is looked up again.
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    private struct Entry: Codable {
        let url: URL
        let aspectRatio: Double
        let savedAt: Date
    }

    private let directory: URL
    private let now: @Sendable () -> Date
    private let fileManager = FileManager.default

    /// - Parameters:
    ///   - directory: Where entries live. Injectable so tests do not touch the real cache.
    ///   - now: The clock entries are aged against. Injectable so a test can wait a month instantly.
    init(
        directory: URL = ArtistLogoCache.defaultDirectory,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.now = now
    }

    static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("com.kaset.artistlogos", isDirectory: true)
    }

    /// The stored wordmark for `artistId`, or nil when there is none — or it has expired.
    func logo(for artistId: String) -> ArtistLogo? {
        let file = self.fileURL(for: artistId)
        guard let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(Entry.self, from: data)
        else { return nil }

        let age = self.now().timeIntervalSince(entry.savedAt)
        guard age >= 0, age < Self.maxAge else {
            try? self.fileManager.removeItem(at: file)
            return nil
        }
        return ArtistLogo(url: entry.url, aspectRatio: CGFloat(entry.aspectRatio))
    }

    /// Stores a found wordmark. Failures are ignored: a cache that cannot write is not a broken page.
    func store(_ logo: ArtistLogo, for artistId: String) {
        try? self.fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let entry = Entry(url: logo.url, aspectRatio: Double(logo.aspectRatio), savedAt: self.now())
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: self.fileURL(for: artistId), options: .atomic)
    }

    /// Clears every stored wordmark.
    func clear() {
        try? self.fileManager.removeItem(at: self.directory)
    }

    /// One file per artist, named by a digest: the key is usually a channel id, but a name with spaces or
    /// slashes in it must not be able to escape the directory.
    private func fileURL(for artistId: String) -> URL {
        let digest = SHA256.hash(data: Data(artistId.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return self.directory.appendingPathComponent(name)
    }
}
