import Foundation

// MARK: - UnisonEnvelope

/// Every Unison response is wrapped in `{ success, data }`. `success` must be
/// checked before `data` is read — a failed lookup keeps the envelope and adds
/// `code`/`error`/`hint` instead.
struct UnisonEnvelope: Decodable {
    let success: Bool
    let data: UnisonLyricsEntry?
}

/// `/lyrics/variants/:videoId` returns the same records as a list.
struct UnisonVariantsEnvelope: Decodable {
    let success: Bool
    let data: [UnisonLyricsEntry]?
}

/// A single Unison lyrics record. `format` says how to read `lyrics` (`ttml`,
/// `lrc`, or `plain`) and `syncType` how precise the timing is (`richsync`,
/// `linesync`, or `plain`).
struct UnisonLyricsEntry: Decodable, Sendable, Equatable {
    let id: Int?
    let videoId: String?
    let song: String?
    let artist: String?
    let album: String?
    let duration: TimeInterval?
    let format: String?
    let syncType: String?
    let language: String?
    let score: Int?
    let voteCount: Int?
    /// This listener's own vote on the record, when the read carried their
    /// `x-key-id`.
    let userVote: Int?
    let confidence: String?
    let lyrics: String?
    let submitter: UnisonSubmitter?
}

/// The member who submitted a lyrics version. `keyId` is a public key-derived
/// identifier; Unison serves a profile for it at `/curator/<keyId>`.
struct UnisonSubmitter: Decodable, Sendable, Equatable {
    let keyId: String?
    let displayName: String?
    let avatarUrl: String?
}

// MARK: - UnisonProvider

/// Fetches lyrics from Unison (`unison.boidu.dev`), a public community-synced
/// lyrics database. No key and no sign-in are required.
///
/// Lookup order: the track's `videoId` first, since Unison is keyed on it and
/// the result is exact. When that misses, the title/artist (plus optional album
/// and duration) fall back. Entries declare their own `format`, so TTML becomes
/// word-synced lyrics, LRC line-synced lyrics, and plain text stays plain.
///
/// Every record credits its submitter, so the lyrics carry a
/// `LyricsAttribution`. Because a video can have several community versions,
/// the provider is also a `LyricsVariantProvider`: the service asks for the
/// rest of the list once Unison's result is displayed.
///
/// Unison rate limits reads to 120 requests per minute per IP, so a search
/// makes at most two requests (plus one variant list when Unison wins).
final class UnisonProvider: LyricsProvider {
    static let displayName = "Unison"

    let name = UnisonProvider.displayName
    let capability: LyricsCapability = .word

    static let baseURL = URL(string: "https://unison.boidu.dev")!

    /// Unison lists up to 50 versions; only the best-ranked few are useful as a
    /// switcher, and every record carries a full lyrics body.
    static let variantLimit = 25

    private let session: URLSession
    private let voteSigner: UnisonVoteSigner

    init(session: URLSession? = nil, voteKeyStore: (any UnisonVoteKeyStore)? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: configuration)
        }
        self.voteSigner = UnisonVoteSigner(store: voteKeyStore ?? KeychainUnisonVoteKeyStore())
    }

    // MARK: - Public

    func search(info: LyricsSearchInfo) async -> LyricResult {
        do {
            if let entry = try await self.fetch(videoId: info.videoId),
               let result = Self.parse(entry, source: self.name),
               result.isAvailable
            {
                return result
            }
            if let entry = try await self.fetch(info: info),
               let result = Self.parse(entry, source: self.name),
               result.isAvailable
            {
                return result
            }
            return .unavailable
        } catch is CancellationError {
            return .unavailable
        } catch {
            DiagnosticsLogger.api.warning("Unison lyrics request failed: \(error.localizedDescription)")
            return .unavailable
        }
    }

    // MARK: - Requests

    private func fetch(videoId: String) async throws -> UnisonLyricsEntry? {
        guard let url = Self.lyricsURL(queryItems: [URLQueryItem(name: "v", value: videoId)]) else {
            throw URLError(.badURL)
        }
        guard let data = try await self.performRequest(url) else { return nil }
        let envelope = try JSONDecoder().decode(UnisonEnvelope.self, from: data)
        guard envelope.success else { return nil }
        return envelope.data
    }

    private func fetch(info: LyricsSearchInfo) async throws -> UnisonLyricsEntry? {
        var queryItems = [
            URLQueryItem(name: "song", value: info.title),
            URLQueryItem(name: "artist", value: info.artist),
        ]
        if let album = info.album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            queryItems.append(URLQueryItem(name: "album", value: album))
        }
        if let duration = info.duration, duration > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        guard let url = Self.lyricsURL(queryItems: queryItems) else { throw URLError(.badURL) }
        guard let data = try await self.performRequest(url) else { return nil }
        let envelope = try JSONDecoder().decode(UnisonEnvelope.self, from: data)
        guard envelope.success else { return nil }
        return envelope.data
    }

    /// Runs a request and returns its body. A `404` means no lyrics matched,
    /// not an error.
    private func performRequest(_ url: URL) async throws -> Data? {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return nil }
        guard (200 ..< 300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    // MARK: - Parsing

    /// Converts a Unison record into the highest-fidelity result its `format`
    /// supports, carrying the submitter's attribution. Returns `nil` when the
    /// payload carries no usable lyrics.
    static func parse(_ entry: UnisonLyricsEntry, source: String = "Unison") -> LyricResult? {
        guard let raw = entry.lyrics,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let attribution = Self.attribution(for: entry, providerName: source)

        switch entry.format?.lowercased() {
        case "ttml":
            guard let parsed = TTMLParser.parse(raw, source: source), !parsed.isEmpty else { return nil }
            return .synced(SyncedLyrics(lines: parsed.lines, source: source, attribution: attribution))
        case "lrc":
            guard let parsed = LRCParser.parse(raw), !parsed.isEmpty else { return nil }
            return .synced(SyncedLyrics(lines: parsed.lines, source: source, attribution: attribution))
        default:
            return .plain(Lyrics(text: raw, source: source, attribution: attribution))
        }
    }

    /// Credits the member who submitted the lyrics, with a link to their public
    /// Unison profile, and names the record itself. Returns `nil` only when the
    /// record has neither a submitter nor an id.
    static func attribution(for entry: UnisonLyricsEntry, providerName: String = "Unison") -> LyricsAttribution? {
        let name = entry.submitter?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (name?.isEmpty == false) ? name : nil
        let profileURL = entry.submitter?.keyId.flatMap { keyId in
            URL(string: "https://unison.boidu.dev/curator/\(keyId)")
        }
        let avatarURL = entry.submitter?.avatarUrl.flatMap(URL.init(string:))
        // An anonymous record still has an id, and the id is what a vote names.
        let recordID = entry.id.map(String.init)

        guard displayName != nil || profileURL != nil || avatarURL != nil || recordID != nil else { return nil }
        return LyricsAttribution(
            providerName: providerName,
            submitterName: displayName,
            submitterProfileURL: profileURL,
            submitterAvatarURL: avatarURL,
            recordID: recordID
        )
    }

    // MARK: - Variants

    private func fetchVariants(videoId: String) async throws -> [UnisonLyricsEntry] {
        let url = Self.baseURL
            .appendingPathComponent("lyrics")
            .appendingPathComponent("variants")
            .appendingPathComponent(videoId)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "limit", value: "\(Self.variantLimit)")]
        guard let finalURL = components.url else { throw URLError(.badURL) }
        guard let data = try await self.performRequest(finalURL) else { return [] }
        let envelope = try JSONDecoder().decode(UnisonVariantsEnvelope.self, from: data)
        guard envelope.success else { return [] }
        return envelope.data ?? []
    }

    /// Stable picker identifier: Unison's numeric record id when present.
    static func variantID(for entry: UnisonLyricsEntry, index: Int) -> String {
        if let id = entry.id { return String(id) }
        return "\(entry.videoId ?? "variant")-\(index)"
    }

    /// Short label shown in the variant picker: how precise the timing is, then
    /// who submitted it (falling back to the vetting level when unnamed).
    static func variantLabel(for entry: UnisonLyricsEntry) -> String {
        var parts = [Self.syncDescription(for: entry)]
        if let name = entry.submitter?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            parts.append(name)
        } else if let confidence = entry.confidence?.trimmingCharacters(in: .whitespacesAndNewlines), !confidence.isEmpty {
            parts.append(confidence.capitalized)
        }
        return parts.joined(separator: " · ")
    }

    private static func syncDescription(for entry: UnisonLyricsEntry) -> String {
        switch entry.syncType?.lowercased() {
        case "richsync": String(localized: "Word-synced")
        case "linesync": String(localized: "Line-synced")
        case "plain": String(localized: "Plain text")
        default:
            switch entry.format?.lowercased() {
            case "ttml": String(localized: "Synced")
            case "lrc": String(localized: "Line-synced")
            default: String(localized: "Plain text")
            }
        }
    }

    // MARK: - Constants

    /// The song's public page: its community versions, their submitters and
    /// their votes. Unison keys the pages on the YouTube video id.
    static func songURL(videoId: String) -> URL {
        Self.baseURL
            .appendingPathComponent("song")
            .appendingPathComponent(videoId)
    }

    private static func lyricsURL(queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent("lyrics"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems
        return components?.url
    }

    private static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Kaset/\(version)"
    }
}

// MARK: - LyricsVariantProvider

extension UnisonProvider: LyricsVariantProvider {
    /// Lists the community versions for a video, best-ranked first. Records that
    /// carry no usable lyrics are dropped.
    func variants(for info: LyricsSearchInfo) async -> [LyricsVariant] {
        do {
            let entries = try await self.fetchVariants(videoId: info.videoId)
            return entries.enumerated().compactMap { index, entry -> LyricsVariant? in
                guard let result = Self.parse(entry, source: self.name), result.isAvailable else { return nil }
                return LyricsVariant(
                    id: Self.variantID(for: entry, index: index),
                    label: Self.variantLabel(for: entry),
                    result: result,
                    voteCount: entry.voteCount,
                    userVote: entry.userVote.flatMap(LyricsVoteDirection.init(rawValue:))
                )
            }
        } catch is CancellationError {
            return []
        } catch {
            DiagnosticsLogger.api.warning("Unison variants request failed: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - LyricsVoteProvider

extension UnisonProvider: LyricsVoteProvider {
    /// Reads the record back with this listener's key, which is what makes the
    /// response carry `userVote` as well as `voteCount`.
    func voteState(lyricsID: Int) async throws -> LyricsVoteState? {
        var request = URLRequest(url: Self.recordURL(lyricsID: lyricsID))
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(self.voteSigner.keyID, forHTTPHeaderField: "x-key-id")

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return nil }
        guard (200 ..< 300).contains(http.statusCode) else { throw URLError(.badServerResponse) }

        let envelope = try JSONDecoder().decode(UnisonEnvelope.self, from: data)
        guard envelope.success, let entry = envelope.data else { return nil }
        return Self.voteState(from: entry, lyricsID: lyricsID)
    }

    /// Casts or removes a vote. Unison names the voter by the signing key, so
    /// the signed body is the whole authentication — there is no token to
    /// carry.
    func vote(_ direction: LyricsVoteDirection?, lyricsID: Int) async throws {
        var request = URLRequest(url: Self.voteURL(lyricsID: lyricsID))
        request.httpMethod = direction == nil ? "DELETE" : "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try self.voteSigner.signedBody(vote: direction)

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200 ..< 300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder().decode(UnisonErrorEnvelope.self, from: data)
            throw UnisonRequestError(
                statusCode: http.statusCode,
                message: envelope?.error ?? "Unison rejected the vote."
            )
        }
    }

    /// The record's standing as the API spelled it: `voteCount` is the net
    /// count, and `userVote` is `1`/`-1` once the read carried this listener's
    /// key.
    static func voteState(from entry: UnisonLyricsEntry, lyricsID: Int? = nil) -> LyricsVoteState? {
        guard let id = lyricsID ?? entry.id else { return nil }
        return LyricsVoteState(
            lyricsID: id,
            count: entry.voteCount,
            direction: entry.userVote.flatMap(LyricsVoteDirection.init(rawValue:))
        )
    }

    private static func recordURL(lyricsID: Int) -> URL {
        Self.baseURL
            .appendingPathComponent("lyrics")
            .appendingPathComponent(String(lyricsID))
    }

    private static func voteURL(lyricsID: Int) -> URL {
        Self.recordURL(lyricsID: lyricsID).appendingPathComponent("vote")
    }
}

// MARK: - UnisonRequestError

/// A write Unison answered with a non-2xx status, carrying the API's own
/// message so a failed vote can say why.
struct UnisonRequestError: LocalizedError, Equatable {
    let statusCode: Int
    let message: String

    var errorDescription: String? { self.message }
}

// MARK: - UnisonErrorEnvelope

/// A failed response's body (`success: false` plus `error`/`code`/`hint`).
private struct UnisonErrorEnvelope: Decodable {
    let success: Bool?
    let error: String?
    let code: String?
}
