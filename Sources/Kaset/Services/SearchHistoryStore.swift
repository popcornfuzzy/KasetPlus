import Foundation
import Observation

// MARK: - SearchHistoryStore

/// Persisted list of the queries the reader has run, newest first.
///
/// Stored beside the app's other small state files (`favorites.json`) as one JSON array of strings,
/// so the search page can offer a way back into a query instead of opening on an empty placeholder.
@MainActor
@Observable
final class SearchHistoryStore {
    static let shared = SearchHistoryStore()

    /// How many queries are kept; older ones fall off the end.
    private static let limit = 8

    /// The recorded queries, newest first.
    private(set) var queries: [String] = []

    private let fileURL: URL?
    private let logger = DiagnosticsLogger.api

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.queries = Self.load(from: self.fileURL)
    }

    /// Records a completed search, moving a repeated query back to the front.
    func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }

        self.queries.removeAll { $0.compare(trimmed, options: .caseInsensitive) == .orderedSame }
        self.queries.insert(trimmed, at: 0)
        if self.queries.count > Self.limit {
            self.queries.removeLast(self.queries.count - Self.limit)
        }
        self.persist()
    }

    func remove(_ query: String) {
        self.queries.removeAll { $0 == query }
        self.persist()
    }

    func clear() {
        self.queries = []
        self.persist()
    }

    // MARK: - Persistence

    private static func defaultFileURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("Kaset", isDirectory: true)
            .appendingPathComponent("search-history.json")
    }

    private static func load(from url: URL?) -> [String] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        guard let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Array(decoded.prefix(Self.limit))
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(self.queries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            self.logger.warning("Failed to save search history: \(error.localizedDescription)")
        }
    }
}
