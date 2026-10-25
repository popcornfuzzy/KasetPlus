import Foundation

// MARK: - KuGoKeyword

/// Normalized search keyword for the KuGou APIs.
struct KuGoKeyword: Sendable, Equatable {
    let title: String
    let artist: String
    let album: String?
}

// MARK: - KuGoProvider

/// Fetches lyrics from KuGou's lyrics library.
///
/// Flow: search the KuGou song API for a track that names the requested song
/// (title and artist, nearest length first), look up that song's lyrics by hash,
/// download the base64-encoded LRC payload, decode it, and strip metadata
/// lines. KuGou delivers line-synced LRC, so this provider is line-tier.
final class KuGoProvider: LyricsProvider {
    let name = "KuGo"
    let capability: LyricsCapability = .line

    private static let songSearchURL = URL(string: "https://mobileservice.kugou.com/api/v3/search/song")!
    private static let lyricsSearchURL = URL(string: "https://lyrics.kugou.com/search")!
    private static let lyricsDownloadURL = URL(string: "https://lyrics.kugou.com/download")!

    private static let pageSize = 8
    private static let headCutLimit = 30

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Public

    func search(info: LyricsSearchInfo) async -> LyricResult {
        do {
            return try await self.fetchLyrics(info: info)
        } catch is CancellationError {
            return .unavailable
        } catch {
            DiagnosticsLogger.api.warning("KuGo lyrics request failed: \(error.localizedDescription)")
            return .unavailable
        }
    }

    // MARK: - Flow

    private func fetchLyrics(info: LyricsSearchInfo) async throws -> LyricResult {
        let keyword = Self.generateKeyword(title: info.title, artist: info.artist, album: info.album)
        let duration = info.duration.map { Int($0) }

        guard let candidate = try await self.lyricsCandidate(keyword: keyword, duration: duration) else {
            return .unavailable
        }
        guard let id = candidate.id, let accessKey = candidate.accesskey else {
            return .unavailable
        }
        guard let content = try await self.downloadLyrics(id: id, accessKey: accessKey) else {
            return .unavailable
        }
        return Self.processContent(content, source: self.name)
    }

    /// Finds lyrics for the first search hit that is actually the requested
    /// track, falling back to a keyword lyrics search when no hash lookup
    /// succeeds.
    private func lyricsCandidate(keyword: KuGoKeyword, duration: Int?) async throws -> KuGoLyricsCandidate? {
        let songs = try await self.searchSongs(keyword: keyword)
        for song in Self.lookupOrder(songs, keyword: keyword, duration: duration) {
            guard let hash = song.hash, !hash.isEmpty else { continue }
            if let candidate = try await self.searchLyricsByHash(hash).first {
                return candidate
            }
        }
        let candidates = try await self.searchLyricsByKeyword(keyword: keyword, duration: duration)
        return Self.bestKeywordCandidate(candidates, keyword: keyword)
    }

    // MARK: - Requests

    private func searchSongs(keyword: KuGoKeyword) async throws -> [KuGoSongInfo] {
        var components = URLComponents(url: Self.songSearchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "version", value: "9108"),
            URLQueryItem(name: "plat", value: "0"),
            URLQueryItem(name: "pagesize", value: "\(Self.pageSize)"),
            URLQueryItem(name: "showtype", value: "0"),
            URLQueryItem(name: "keyword", value: Self.searchQuery(for: keyword)),
        ]
        let response: KuGoSongSearchResponse = try await self.get(components)
        return response.data?.info ?? []
    }

    private func searchLyricsByHash(_ hash: String) async throws -> [KuGoLyricsCandidate] {
        var components = URLComponents(url: Self.lyricsSearchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "hash", value: hash),
        ]
        let response: KuGoLyricsSearchResponse = try await self.get(components)
        return response.candidates ?? []
    }

    private func searchLyricsByKeyword(keyword: KuGoKeyword, duration: Int?) async throws -> [KuGoLyricsCandidate] {
        var components = URLComponents(url: Self.lyricsSearchURL, resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "keyword", value: Self.searchQuery(for: keyword)),
        ]
        if let duration, duration != -1 {
            queryItems.append(URLQueryItem(name: "duration", value: "\(duration * 1000)"))
        }
        components.queryItems = queryItems
        let response: KuGoLyricsSearchResponse = try await self.get(components)
        return response.candidates ?? []
    }

    private func downloadLyrics(id: Int64, accessKey: String) async throws -> String? {
        var components = URLComponents(url: Self.lyricsDownloadURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "fmt", value: "lrc"),
            URLQueryItem(name: "charset", value: "utf8"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "id", value: "\(id)"),
            URLQueryItem(name: "accesskey", value: accessKey),
        ]
        let response: KuGoDownloadResponse = try await self.get(components)
        guard let content = response.content, !content.isEmpty else { return nil }
        return content
    }

    private func get<T: Decodable>(_ components: URLComponents) async throws -> T {
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Kaset/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Keyword generation

    static func generateKeyword(title: String, artist: String, album: String?) -> KuGoKeyword {
        KuGoKeyword(
            title: Self.normalizeTitle(title),
            artist: Self.normalizeArtist(artist),
            album: album
        )
    }

    /// Strips bracketed annotations (parentheses, corner brackets, angle
    /// brackets, full-width variants) from a title.
    static func normalizeTitle(_ title: String) -> String {
        var result = title
        for pattern in [
            #"\(.*\)"#, #"（.*）"#, #"「.*」"#, #"『.*』"#,
            #"<.*>"#, #"《.*》"#, #"〈.*〉"#, #"＜.*＞"#,
        ] {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapses multiple artists into one using the full-width comma and
    /// strips annotations, matching KuGou's search normalization.
    static func normalizeArtist(_ artist: String) -> String {
        var result = artist
        result = result.replacingOccurrences(of: ", ", with: "、")
        result = result.replacingOccurrences(of: " & ", with: "、")
        result = result.replacingOccurrences(of: ".", with: "")
        result = result.replacingOccurrences(of: "和", with: "、")
        result = result.replacingOccurrences(of: #"\(.*\)"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"（.*）"#, with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func searchQuery(for keyword: KuGoKeyword) -> String {
        var query = "\(keyword.title) - \(keyword.artist)"
        if let album = keyword.album, !album.isEmpty {
            query += " \(album)"
        }
        return query
    }

    // MARK: - Candidate matching

    /// The search hits that name the requested track, nearest length first.
    ///
    /// Length is a ranking hint here, never the admission test. KuGou's song
    /// search answers with other artists' songs that only share the title, so
    /// admitting a hit because its length is a few seconds close — while the
    /// track that was actually asked for has no lyrics — is how a different
    /// song's lyrics end up on screen.
    static func lookupOrder(
        _ songs: [KuGoSongInfo],
        keyword: KuGoKeyword,
        duration: Int?
    ) -> [KuGoSongInfo] {
        let matched = songs.filter { Self.isSameTrack(song: $0, keyword: keyword) }
        guard let duration, duration != -1 else { return matched }

        func distance(_ song: KuGoSongInfo) -> Int {
            song.duration.map { abs($0 - duration) } ?? .max
        }

        return matched.enumerated()
            .sorted { lhs, rhs in
                let left = distance(lhs.element)
                let right = distance(rhs.element)
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    /// The keyword-search hit that names the requested track. KuGou lists its
    /// own best guess first, and that guess is not checked against the song
    /// that was asked for — so the order alone decides nothing.
    static func bestKeywordCandidate(
        _ candidates: [KuGoLyricsCandidate],
        keyword: KuGoKeyword
    ) -> KuGoLyricsCandidate? {
        candidates.first { candidate in
            // This endpoint has served the two names the other way round
            // (`song: The Weeknd`, `singer: Blinding Lights`), so either order
            // names the track.
            Self.isSameTrack(title: candidate.song, artist: candidate.singer, keyword: keyword)
                || Self.isSameTrack(title: candidate.singer, artist: candidate.song, keyword: keyword)
        }
    }

    /// Whether KuGou's name for a song is the track that was asked for.
    static func isSameTrack(song: KuGoSongInfo, keyword: KuGoKeyword) -> Bool {
        Self.isSameTrack(title: song.songname, artist: song.singername, keyword: keyword)
    }

    /// Whether a title/artist pair from KuGou names the requested track. A name
    /// KuGou didn't send can't be verified, so it is not a match.
    static func isSameTrack(title: String?, artist: String?, keyword: KuGoKeyword) -> Bool {
        guard let title, let artist else { return false }
        return Self.titlesAgree(title, keyword.title) && Self.artistsAgree(artist, keyword.artist)
    }

    /// Titles agree once bracketed annotations, case, accents and punctuation
    /// are gone: `Savior` and `Savior (Sped Up)` carry the same lyrics, while
    /// `Savior Complex` is another song. Nothing looser than equality belongs
    /// here — a shared prefix is not the same title.
    static func titlesAgree(_ candidate: String, _ requested: String) -> Bool {
        let candidateKey = Self.comparisonKey(candidate)
        let requestedKey = Self.comparisonKey(requested)
        guard !candidateKey.isEmpty, !requestedKey.isEmpty else { return false }
        return candidateKey == requestedKey
    }

    /// Artists agree when their credits share a name: KuGou adds a featured
    /// artist YouTube doesn't name, or credits only the lead of a duet.
    static func artistsAgree(_ candidate: String, _ requested: String) -> Bool {
        let candidateNames = Self.artistNames(candidate)
        let requestedNames = Self.artistNames(requested)
        guard !candidateNames.isEmpty, !requestedNames.isEmpty else { return false }
        return !candidateNames.isDisjoint(with: requestedNames)
    }

    /// Comparison form of a KuGou title or artist: bracketed annotations
    /// dropped, case and accents folded, punctuation and spacing collapsed to a
    /// single space between words.
    private static func comparisonKey(_ text: String) -> String {
        var key = Self.normalizeTitle(text)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        key = key.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
        return key.trimmingCharacters(in: .whitespaces)
    }

    /// The individual names in an artist credit, in comparison form.
    private static func artistNames(_ artist: String) -> Set<String> {
        let credit = artist
            .replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: "・", with: ",")
        return Set(
            LyricsArtistNormalizer.artistComponents(credit)
                .map(Self.comparisonKey)
                .filter { !$0.isEmpty }
        )
    }

    // MARK: - Content processing

    /// Decodes a base64-encoded LRC payload, strips metadata lines, and parses
    /// it into synced lyrics. Returns `.unavailable` on any failure.
    static func processContent(_ base64: String, source: String = "KuGo") -> LyricResult {
        let compact = base64
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let data = Data(base64Encoded: compact),
              let decoded = String(data: data, encoding: .utf8)
        else {
            return .unavailable
        }

        // KuGou occasionally serves its LRC payload with XML entities left in the
        // text (e.g. `This isn&apos;t home`), so decode them before parsing rather
        // than showing the raw entity in the lyrics display.
        let normalized = Self.normalize(Self.decodingEntities(decoded))
        guard !normalized.isEmpty, let parsed = LRCParser.parse(normalized) else {
            return .unavailable
        }
        return .synced(SyncedLyrics(lines: parsed.lines, source: source))
    }

    /// Decodes XML/HTML entities KuGou leaves in its LRC text.
    ///
    /// A single pass over the string keeps an escaped entity such as
    /// `&amp;apos;` decoding to the literal text `&apos;` (its correct meaning)
    /// instead of being decoded twice into `'`.
    static func decodingEntities(_ raw: String) -> String {
        let pattern = #"&(#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }

        let nsRaw = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: nsRaw.length))
        guard !matches.isEmpty else { return raw }

        var decoded = ""
        decoded.reserveCapacity(raw.count)
        var cursor = 0
        for match in matches {
            decoded += nsRaw.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let name = nsRaw.substring(with: match.range(at: 1))
            decoded += Self.entityValue(name) ?? nsRaw.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        decoded += nsRaw.substring(from: cursor)
        return decoded
    }

    /// Resolves the body of an entity (`amp`, `#39`, `#x27`, …) to its character,
    /// or `nil` when it is not a recognized entity.
    private static func entityValue(_ name: String) -> String? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            guard let value = UInt32(name.dropFirst(2), radix: 16),
                  let scalar = Unicode.Scalar(value)
            else { return nil }
            return String(Character(scalar))
        }
        if name.hasPrefix("#") {
            guard let value = UInt32(name.dropFirst()),
                  let scalar = Unicode.Scalar(value)
            else { return nil }
            return String(Character(scalar))
        }
        switch name.lowercased() {
        case "apos": return "'"
        case "quot": return "\""
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "nbsp": return " "
        default: return nil
        }
    }

    /// Keeps only LRC timestamped lines and trims metadata blocks (lines whose
    /// text contains a colon, e.g. `[00:12.34]作词：某某`) from the head and
    /// tail of the payload.
    static func normalize(_ raw: String) -> String {
        let acceptedRegex = try! NSRegularExpression(pattern: #"^\[(\d\d):(\d\d)\.(\d{2,3})\].*$"#)
        let bannedRegex = try! NSRegularExpression(pattern: #"^.+].+[:：].+$"#)

        let lines = raw
            .components(separatedBy: .newlines)
            .filter { Self.matches($0, regex: acceptedRegex) }

        guard !lines.isEmpty else { return "" }

        // Cut trailing metadata within the first 30 lines: the last banned line
        // in that window marks where real lyrics begin.
        var headCutLine = 0
        let headLimit = min(Self.headCutLimit, lines.count - 1)
        if headLimit >= 0 {
            for i in stride(from: headLimit, through: 0, by: -1) where Self.matches(lines[i], regex: bannedRegex) {
                headCutLine = i + 1
                break
            }
        }

        // Cut leading metadata within the last 30 lines: the first banned line
        // scanning upward from the end marks where real lyrics end.
        var tailCutLine = 0
        let tailLimit = min(lines.count - Self.headCutLimit, lines.count - 1)
        if tailLimit >= 0 {
            for i in stride(from: tailLimit, through: 0, by: -1)
                where Self.matches(lines[lines.count - 1 - i], regex: bannedRegex)
            {
                tailCutLine = i + 1
                break
            }
        }

        let kept = lines.dropFirst(headCutLine)
        let finalLines = tailCutLine > 0 ? kept.dropLast(tailCutLine) : kept
        return finalLines.joined(separator: "\n")
    }

    private static func matches(_ line: String, regex: NSRegularExpression) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return regex.rangeOfFirstMatch(in: line, range: range).location != NSNotFound
    }
}

// MARK: - Decoding types

struct KuGoSongInfo: Decodable, Sendable, Equatable {
    let hash: String?
    let duration: Int? // seconds
    let songname: String?
    let singername: String?
}

struct KuGoLyricsCandidate: Decodable, Sendable, Equatable {
    let id: Int64?
    let accesskey: String?
    let song: String?
    let singer: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case accesskey
        case song
        case singer
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // KuGou has served `id` both as a JSON number and as a quoted number.
        // Accept either: a type change on their side must not fail the whole
        // response, which would leave the provider reporting "no lyrics" for
        // every song.
        if let number = try? container.decode(Int64.self, forKey: .id) {
            self.id = number
        } else if let text = try? container.decode(String.self, forKey: .id) {
            self.id = Int64(text)
        } else {
            self.id = nil
        }
        self.accesskey = try? container.decode(String.self, forKey: .accesskey)
        self.song = try? container.decode(String.self, forKey: .song)
        self.singer = try? container.decode(String.self, forKey: .singer)
    }
}

private struct KuGoSongSearchResponse: Decodable {
    let data: Data?
    struct Data: Decodable {
        let info: [KuGoSongInfo]?
    }
}

private struct KuGoLyricsSearchResponse: Decodable {
    let candidates: [KuGoLyricsCandidate]?
}

private struct KuGoDownloadResponse: Decodable {
    let content: String?
}