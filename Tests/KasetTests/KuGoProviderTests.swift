import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service))
struct KuGoProviderTests {
    // MARK: - Keyword generation

    @Test("generateKeyword normalizes title, artist, and album")
    func generatesKeyword() {
        let keyword = KuGoProvider.generateKeyword(
            title: "Blinding Lights (Official Video)",
            artist: "The Weeknd & Daft Punk",
            album: "After Hours"
        )
        #expect(keyword.title == "Blinding Lights")
        #expect(keyword.artist == "The Weeknd、Daft Punk")
        #expect(keyword.album == "After Hours")
    }

    @Test("normalizeTitle strips bracketed annotations in all styles")
    func normalizesTitle() {
        #expect(KuGoProvider.normalizeTitle("Song (Live)") == "Song")
        #expect(KuGoProvider.normalizeTitle("歌（现场版）") == "歌")
        #expect(KuGoProvider.normalizeTitle("Song「アニメ盤」") == "Song")
        #expect(KuGoProvider.normalizeTitle("Song『Special』") == "Song")
        #expect(KuGoProvider.normalizeTitle("Song《专辑》") == "Song")
        #expect(KuGoProvider.normalizeTitle("Song <Live>") == "Song")
        #expect(KuGoProvider.normalizeTitle("Plain Title") == "Plain Title")
    }

    @Test("normalizeArtist merges multiple artists and strips annotations")
    func normalizesArtist() {
        #expect(KuGoProvider.normalizeArtist("A & B") == "A、B")
        #expect(KuGoProvider.normalizeArtist("A, B") == "A、B")
        #expect(KuGoProvider.normalizeArtist("A和B") == "A、B")
        #expect(KuGoProvider.normalizeArtist("A.B") == "AB")
        #expect(KuGoProvider.normalizeArtist("Artist (Remix)") == "Artist")
        #expect(KuGoProvider.normalizeArtist("Solo Artist") == "Solo Artist")
    }

    // MARK: - LRC normalization

    @Test("normalize keeps timestamped lines and strips head metadata")
    func normalizesLRC() {
        let raw = """
        [ti:Blinding Lights]
        [ar:The Weeknd]
        [00:12.34]Hello world
        [00:16.50]Second line
        """
        #expect(KuGoProvider.normalize(raw) == "[00:12.34]Hello world\n[00:16.50]Second line")
    }

    @Test("normalize strips trailing metadata lines")
    func stripsTrailingMetadata() {
        let raw = """
        [00:12.34]Hello world
        [00:16.50]Second line
        [by:kuge]
        """
        #expect(KuGoProvider.normalize(raw) == "[00:12.34]Hello world\n[00:16.50]Second line")
    }

    @Test("normalize trims everything up to a colon annotation line")
    func stripsColonAnnotationLines() {
        // The reference implementation cuts the head up to the last banned line
        // inside the first 30 lines, so a mid-lyrics annotation line also
        // removes the earlier lines. Ported faithfully.
        let raw = """
        [00:12.34]Hello world
        [00:14.00]作词：林夕
        [00:16.50]Second line
        """
        #expect(KuGoProvider.normalize(raw) == "[00:16.50]Second line")
    }

    @Test("normalize drops non-LRC lines entirely")
    func dropsNonLRCLines() {
        let raw = "Not a timestamped line\n[00:12.34]Hello world"
        #expect(KuGoProvider.normalize(raw) == "[00:12.34]Hello world")
    }

    @Test("normalize returns empty when no timestamped lines exist")
    func emptyWhenNoTimestamps() {
        #expect(KuGoProvider.normalize("just some text") == "")
        #expect(KuGoProvider.normalize("") == "")
    }

    // MARK: - Base64 pipeline

    @Test("processContent decodes base64 LRC into synced lyrics")
    func processesBase64LRC() {
        let lrc = "[00:12.34]Hello world\n[00:16.50]Second line"
        let base64 = Data(lrc.utf8).base64EncodedString()
        let result = KuGoProvider.processContent(base64)
        guard case let .synced(lyrics) = result else {
            Issue.record("Expected synced result")
            return
        }
        #expect(lyrics.source == "KuGo")
        #expect(lyrics.hasWordTiming == false)
        // LRCParser inserts an empty 0ms line when the first timestamp is late.
        #expect(lyrics.lines.count == 3)
        #expect(lyrics.lines[0].text == "")
        #expect(lyrics.lines[1].text == "Hello world")
        #expect(lyrics.lines[1].timeInMs == 12340)
        #expect(lyrics.lines[2].timeInMs == 16500)
    }

    @Test("decodingEntities decodes named, decimal, and hex entities in one pass")
    func decodesEntities() {
        #expect(KuGoProvider.decodingEntities("This isn&apos;t home") == "This isn't home")
        #expect(KuGoProvider.decodingEntities("a &quot;b&quot; &amp; c") == #"a "b" & c"#)
        #expect(KuGoProvider.decodingEntities("1 &lt; 2 &gt; 0") == "1 < 2 > 0")
        #expect(KuGoProvider.decodingEntities("it&#39;s") == "it's")
        #expect(KuGoProvider.decodingEntities("it&#x27;s") == "it's")
        #expect(KuGoProvider.decodingEntities("a&nbsp;b") == "a b")
        // An escaped entity is literal text, so it must not be decoded twice.
        #expect(KuGoProvider.decodingEntities("&amp;apos;") == "&apos;")
        // Unknown or entity-free text is left untouched.
        #expect(KuGoProvider.decodingEntities("plain lyric") == "plain lyric")
        #expect(KuGoProvider.decodingEntities("&bogus;") == "&bogus;")
    }

    @Test("processContent decodes entities before parsing")
    func processesBase64WithEntities() {
        let lrc = "[00:12.34]This isn&apos;t home for me"
        let base64 = Data(lrc.utf8).base64EncodedString()
        let result = KuGoProvider.processContent(base64)
        guard case let .synced(lyrics) = result else {
            Issue.record("Expected synced result")
            return
        }
        #expect(lyrics.lines.map(\.text).contains("This isn't home for me"))
    }

    @Test("processContent handles base64 with embedded newlines")
    func processesBase64WithNewlines() {
        let lrc = "[00:01.00]Line"
        let raw = Data(lrc.utf8).base64EncodedString()
        let wrapped = String(raw.enumerated().map { $0.offset % 40 == 39 ? "\n" : $0.element })
        let result = KuGoProvider.processContent(wrapped)
        #expect(result.isAvailable)
    }

    @Test("processContent returns unavailable for invalid base64 or garbage")
    func unavailableForInvalidContent() {
        #expect(KuGoProvider.processContent("not-base64!!") == .unavailable)
        #expect(KuGoProvider.processContent("") == .unavailable)
        // Valid base64 but not LRC text.
        let garbage = Data("hello".utf8).base64EncodedString()
        #expect(KuGoProvider.processContent(garbage) == .unavailable)
    }

    // MARK: - Candidate decoding

    @Test("candidate decoding accepts an id sent as a JSON string")
    func decodesStringCandidateID() throws {
        // The lyrics search endpoint started quoting the id: decoding it as an
        // Int64-only field failed the whole response, so KuGo reported "no
        // lyrics" for every song.
        let json = #"[{"id":"209655425","accesskey":"test-access-key"}]"#
        let candidates = try JSONDecoder().decode([KuGoLyricsCandidate].self, from: Data(json.utf8))
        #expect(candidates.count == 1)
        #expect(candidates.first?.id == 209_655_425)
        #expect(candidates.first?.accesskey == "test-access-key")
    }

    @Test("candidate decoding accepts an id sent as a JSON number")
    func decodesNumericCandidateID() throws {
        let json = #"[{"id":209655425,"accesskey":"test-access-key"}]"#
        let candidates = try JSONDecoder().decode([KuGoLyricsCandidate].self, from: Data(json.utf8))
        #expect(candidates.first?.id == 209_655_425)
    }

    @Test("candidate decoding tolerates a missing or unusable id")
    func decodesCandidateWithoutID() throws {
        let json = #"[{"accesskey":"test-access-key"},{"id":"not-a-number"}]"#
        let candidates = try JSONDecoder().decode([KuGoLyricsCandidate].self, from: Data(json.utf8))
        #expect(candidates.count == 2)
        #expect(candidates[0].id == nil)
        #expect(candidates[0].accesskey == "test-access-key")
        #expect(candidates[1].id == nil)
    }

    // MARK: - Candidate matching

    private static func song(_ hash: String, title: String, artist: String, duration: Int?) -> KuGoSongInfo {
        KuGoSongInfo(hash: hash, duration: duration, songname: title, singername: artist)
    }

    /// The search behind Baby Jane's "Savior": KuGou has no lyrics for the
    /// requested track, so its length-only neighbours — songs that share the
    /// title with another artist, and one by the same artist with another title —
    /// were what the provider visited instead.
    @Test("lookupOrder keeps the requested track and drops same-title songs by other artists")
    func dropsOtherArtistsSongs() {
        let keyword = KuGoProvider.generateKeyword(title: "Savior", artist: "Baby Jane", album: nil)
        let songs = [
            Self.song("sped", title: "Savior", artist: "Baby Jane", duration: 170),
            Self.song("right", title: "Savior", artist: "Baby Jane", duration: 187),
            Self.song("deathwish", title: "Deathwish", artist: "akiaura、LONOWN、Baby Jane", duration: 288),
            Self.song("one-n-only", title: "SAVIOR", artist: "ONE N' ONLY", duration: 179),
            Self.song("green-day", title: "Fancy Sauce", artist: "Green Day", duration: 241),
            Self.song("onerepublic", title: "Savior", artist: "OneRepublic", duration: 181),
            Self.song("novulent", title: "savior", artist: "Novulent", duration: 132),
        ]

        let ordered = KuGoProvider.lookupOrder(songs, keyword: keyword, duration: 188)
        #expect(ordered.map(\.hash) == ["right", "sped"])
    }

    @Test("lookupOrder ranks the requested track's entries by nearest length")
    func ranksByNearestLength() {
        let keyword = KuGoProvider.generateKeyword(title: "Blinding Lights", artist: "The Weeknd", album: nil)
        let songs = [
            Self.song("live", title: "Blinding Lights (Live)", artist: "The Weeknd", duration: 260),
            Self.song("studio", title: "Blinding Lights", artist: "The Weeknd", duration: 202),
            Self.song("remix", title: "Blinding Lights (Remix)", artist: "The Weeknd", duration: 210),
        ]

        let ordered = KuGoProvider.lookupOrder(songs, keyword: keyword, duration: 200)
        #expect(ordered.map(\.hash) == ["studio", "remix", "live"])
    }

    @Test("lookupOrder keeps search order when the playing duration is unknown")
    func keepsOrderWithoutDuration() {
        let keyword = KuGoProvider.generateKeyword(title: "Savior", artist: "Baby Jane", album: nil)
        let songs = [
            Self.song("least", title: "Savior", artist: "Baby Jane", duration: 300),
            Self.song("nearest", title: "Savior", artist: "Baby Jane", duration: 187),
        ]

        #expect(KuGoProvider.lookupOrder(songs, keyword: keyword, duration: nil).map(\.hash) == ["least", "nearest"])
        #expect(KuGoProvider.lookupOrder(songs, keyword: keyword, duration: -1).map(\.hash) == ["least", "nearest"])
    }

    @Test("lookupOrder drops entries KuGou didn't name")
    func dropsUnnamedEntries() {
        let keyword = KuGoProvider.generateKeyword(title: "Savior", artist: "Baby Jane", album: nil)
        let songs = [KuGoSongInfo(hash: "h", duration: 187, songname: nil, singername: nil)]
        #expect(KuGoProvider.lookupOrder(songs, keyword: keyword, duration: 188).isEmpty)
    }

    @Test("titlesAgree ignores bracketed suffixes, case and punctuation")
    func titlesAgreeLoose() {
        #expect(KuGoProvider.titlesAgree("Savior (Sped Up)", "Savior"))
        #expect(KuGoProvider.titlesAgree("SAVIOR", "Savior"))
        #expect(KuGoProvider.titlesAgree("Don't Stop Me Now", "Dont Stop Me Now"))
        #expect(KuGoProvider.titlesAgree("歌（现场版）", "歌"))
        // A longer title is a different song.
        #expect(KuGoProvider.titlesAgree("Savior Complex", "Savior") == false)
        #expect(KuGoProvider.titlesAgree("", "Savior") == false)
    }

    @Test("artistsAgree matches a shared credit")
    func artistsAgreeLoose() {
        // KuGou adds the featured artist the YouTube credit omits.
        #expect(KuGoProvider.artistsAgree("akiaura、LONOWN、Baby Jane", "Baby Jane"))
        // KuGou credits only the lead of a duet.
        #expect(KuGoProvider.artistsAgree("The Weeknd", "The Weeknd、Daft Punk"))
        #expect(KuGoProvider.artistsAgree("Baby Jane", "Baby Jane"))
        #expect(KuGoProvider.artistsAgree("OneRepublic", "Baby Jane") == false)
        #expect(KuGoProvider.artistsAgree("Baby Jane Tribute Band", "Baby Jane") == false)
        #expect(KuGoProvider.artistsAgree("", "Baby Jane") == false)
    }

    @Test("bestKeywordCandidate skips hits that name another song")
    func keywordCandidateNeedsIdentity() throws {
        let keyword = KuGoProvider.generateKeyword(title: "Savior", artist: "Baby Jane", album: nil)
        let others = [
            try Self.candidate(id: 1, song: "Savior", singer: "OneRepublic"),
            try Self.candidate(id: 2, song: "SAVIOR", singer: "ONE N' ONLY"),
            try Self.candidate(id: 3, song: "Savior", singer: "Baby Jane"),
        ]
        #expect(KuGoProvider.bestKeywordCandidate(others, keyword: keyword)?.id == 3)
        #expect(KuGoProvider.bestKeywordCandidate(Array(others.prefix(2)), keyword: keyword) == nil)
    }

    @Test("bestKeywordCandidate accepts the two names in either order")
    func keywordCandidateToleratesSwap() throws {
        // This endpoint has served `song: The Weeknd, singer: Blinding Lights`.
        let keyword = KuGoProvider.generateKeyword(title: "Blinding Lights", artist: "The Weeknd", album: nil)
        let swapped = try Self.candidate(id: 7, song: "The Weeknd", singer: "Blinding Lights")
        #expect(KuGoProvider.bestKeywordCandidate([swapped], keyword: keyword)?.id == 7)
    }

    private static func candidate(id: Int64, song: String?, singer: String?) throws -> KuGoLyricsCandidate {
        func field(_ value: String?) -> String {
            guard let value else { return "null" }
            return "\"\(value)\""
        }
        let json = "{\"id\":\(id),\"accesskey\":\"test-access-key\","
            + "\"song\":\(field(song)),\"singer\":\(field(singer))}"
        return try JSONDecoder().decode(KuGoLyricsCandidate.self, from: Data(json.utf8))
    }
}