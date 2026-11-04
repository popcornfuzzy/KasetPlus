import CryptoKit
import Foundation
import Testing
@testable import Kaset

// MARK: - UnisonVotingTests

@Suite(.tags(.service), .serialized)
struct UnisonVotingTests {
    // MARK: - Signing

    @Test("canonical JSON sorts keys and keeps numbers integral")
    func canonicalJSON() {
        let value = UnisonJSONValue.object([
            "vote": .integer(1),
            "nonce": .string("0123456789abcdef"),
            "keyId": .string("key"),
            "timestamp": .integer(1_700_000_000_000),
        ])

        #expect(
            value.canonicalJSON
                == #"{"keyId":"key","nonce":"0123456789abcdef","timestamp":1700000000000,"vote":1}"#
        )
    }

    @Test("a key id is the stable SHA-256 of the key, in 64 hex characters")
    func keyID() {
        let key = P256.Signing.PrivateKey()

        let first = UnisonVoteSigner.keyID(for: key.publicKey)
        #expect(first == UnisonVoteSigner.keyID(for: key.publicKey))
        #expect(first.count == 64)
        #expect(first.allSatisfy { $0.isHexDigit })
        #expect(first != UnisonVoteSigner.keyID(for: P256.Signing.PrivateKey().publicKey))
    }

    // MARK: - Vote writes

    @Test("an upvote is a signed envelope posted to the record")
    func postsSignedUpvote() async throws {
        defer { UnisonVoteURLProtocol.handler = nil }
        let log = UnisonVoteRequestLog()
        UnisonVoteURLProtocol.handler = { request in
            log.append(request)
            return Self.response(for: request, status: 200, body: #"{"success":true,"data":{"message":"Vote recorded"}}"#)
        }

        let provider = UnisonProvider(
            session: UnisonVoteURLProtocol.makeSession(),
            voteKeyStore: InMemoryVoteKeyStore()
        )
        try await provider.vote(.up, lyricsID: 4_821)

        let request = try #require(log.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/lyrics/4821/vote")

        let body = try Self.jsonBody(of: request)
        let payload = try #require(body["payload"] as? [String: Any])
        #expect((payload["vote"] as? NSNumber)?.intValue == 1)
        #expect((payload["keyId"] as? String)?.count == 64)
        let nonce = try #require(payload["nonce"] as? String)
        #expect(nonce.count >= 16)
        #expect((payload["timestamp"] as? NSNumber)?.int64Value ?? 0 > 0)

        let publicKey = try #require(body["publicKey"] as? [String: Any])
        #expect(publicKey["kty"] as? String == "EC")
        #expect(publicKey["crv"] as? String == "P-256")

        let signature = try #require(body["signature"] as? String)
        try Self.verify(payload: payload, signature: signature, jwk: publicKey)
    }

    @Test("removing a vote deletes the record's vote and signs no vote field")
    func removesVote() async throws {
        defer { UnisonVoteURLProtocol.handler = nil }
        let log = UnisonVoteRequestLog()
        UnisonVoteURLProtocol.handler = { request in
            log.append(request)
            return Self.response(for: request, status: 200, body: #"{"success":true,"data":{"message":"Vote removed"}}"#)
        }

        let provider = UnisonProvider(
            session: UnisonVoteURLProtocol.makeSession(),
            voteKeyStore: InMemoryVoteKeyStore()
        )
        try await provider.vote(nil, lyricsID: 7)

        let request = try #require(log.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/lyrics/7/vote")

        let body = try Self.jsonBody(of: request)
        let payload = try #require(body["payload"] as? [String: Any])
        #expect(payload["vote"] == nil)
    }

    @Test("a rejected vote carries Unison's own message")
    func rejectedVoteSurfacesMessage() async throws {
        defer { UnisonVoteURLProtocol.handler = nil }
        UnisonVoteURLProtocol.handler = { request in
            Self.response(
                for: request,
                status: 429,
                body: #"{"success":false,"error":"Too many requests","code":"RATE_LIMITED"}"#
            )
        }

        let provider = UnisonProvider(
            session: UnisonVoteURLProtocol.makeSession(),
            voteKeyStore: InMemoryVoteKeyStore()
        )

        do {
            try await provider.vote(.up, lyricsID: 7)
            Issue.record("Expected the rejected vote to throw")
        } catch let error as UnisonRequestError {
            #expect(error.statusCode == 429)
            #expect(error.message == "Too many requests")
        }
    }

    // MARK: - Vote reads

    @Test("reading the record with the listener's key yields count and their vote")
    func readsVoteState() async throws {
        defer { UnisonVoteURLProtocol.handler = nil }
        let log = UnisonVoteRequestLog()
        UnisonVoteURLProtocol.handler = { request in
            log.append(request)
            return Self.response(
                for: request,
                status: 200,
                body: #"{"success":true,"data":{"id":4821,"voteCount":12,"userVote":-1}}"#
            )
        }

        let provider = UnisonProvider(
            session: UnisonVoteURLProtocol.makeSession(),
            voteKeyStore: InMemoryVoteKeyStore()
        )
        let state = try await provider.voteState(lyricsID: 4_821)

        #expect(state == LyricsVoteState(lyricsID: 4_821, count: 12, direction: .down))

        let request = try #require(log.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/lyrics/4821")
        #expect(request.value(forHTTPHeaderField: "x-key-id")?.count == 64)
    }

    @Test("variants carry the community vote counts")
    func variantsCarryVotes() async throws {
        defer { UnisonVoteURLProtocol.handler = nil }
        UnisonVoteURLProtocol.handler = { request in
            Self.response(
                for: request,
                status: 200,
                body: #"{"success":true,"data":[{"id":10,"videoId":"v","format":"lrc","syncType":"linesync","voteCount":12,"lyrics":"[00:01.00]Line"}]}"#
            )
        }

        let provider = UnisonProvider(
            session: UnisonVoteURLProtocol.makeSession(),
            voteKeyStore: InMemoryVoteKeyStore()
        )
        let variants = await provider.variants(for: Self.searchInfo(videoId: "v"))

        #expect(variants.first?.voteCount == 12)
        #expect(variants.first?.userVote == nil)
    }

    // MARK: - Service

    @Test("the service toggles a vote and settles on the provider's count")
    @MainActor
    func serviceTogglesVote() async {
        let lyrics = Self.votableLyrics(recordID: "42")
        let variant = LyricsVariant(
            id: "42",
            label: "Line-synced · Maker",
            result: .synced(lyrics),
            voteCount: 10
        )
        let provider = VoteServiceProvider(
            result: .synced(lyrics),
            variants: [variant],
            initial: LyricsVoteState(lyricsID: 42, count: 10, direction: nil)
        )
        let service = SyncedLyricsService(providers: [provider])

        await service.fetchLyrics(for: Self.searchInfo(videoId: "video-vote"))
        #expect(service.currentVote == LyricsVoteState(lyricsID: 42, count: 10, direction: nil))

        await service.toggleVote(.up)
        #expect(service.currentVote?.direction == .up)
        #expect(service.currentVote?.count == 11)

        // Pressing the direction already chosen takes the vote back.
        await service.toggleVote(.up)
        #expect(service.currentVote?.direction == nil)
        #expect(service.currentVote?.count == 10)
        #expect(await provider.sentDirections() == [.up, nil])
    }

    @Test("a failed vote puts the count back and reports itself")
    @MainActor
    func serviceRestoresStateAfterFailure() async {
        let lyrics = Self.votableLyrics(recordID: "42")
        let variant = LyricsVariant(id: "42", label: "Line-synced · Maker", result: .synced(lyrics), voteCount: 10)
        let provider = VoteServiceProvider(
            result: .synced(lyrics),
            variants: [variant],
            initial: LyricsVoteState(lyricsID: 42, count: 10, direction: nil),
            fails: true
        )
        let service = SyncedLyricsService(providers: [provider])

        await service.fetchLyrics(for: Self.searchInfo(videoId: "video-vote-failure"))
        await service.toggleVote(.down)

        #expect(service.currentVote == LyricsVoteState(lyricsID: 42, count: 10, direction: nil))
        #expect(service.voteErrorMessage != nil)
        #expect(service.isVoting == false)
    }

    // MARK: - Helpers

    private static func searchInfo(videoId: String) -> LyricsSearchInfo {
        LyricsSearchInfo(title: "Song", artist: "Artist", album: nil, duration: nil, videoId: videoId)
    }

    private static func votableLyrics(recordID: String) -> SyncedLyrics {
        SyncedLyrics(
            lines: [SyncedLyricLine(timeInMs: 0, duration: 4_000, text: "Line", words: nil)],
            source: "Unison",
            attribution: LyricsAttribution(
                providerName: "Unison",
                submitterName: "Maker",
                submitterProfileURL: nil,
                submitterAvatarURL: nil,
                recordID: recordID
            )
        )
    }

    private static func response(
        for request: URLRequest,
        status: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    /// URLSession hands the body to a `URLProtocol` as a stream, not as `httpBody`.
    private static func jsonBody(of request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }

            var collected = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            data = collected
        } else {
            return [:]
        }

        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Checks the envelope the way Unison does: canonical JSON of the payload,
    /// verified with the public key the body carries.
    private static func verify(payload: [String: Any], signature: String, jwk: [String: Any]) throws {
        let x = try #require((jwk["x"] as? String)?.base64URLDecoded())
        let y = try #require((jwk["y"] as? String)?.base64URLDecoded())
        let publicKey = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y)
        let rawSignature = try #require(Data(base64Encoded: signature))
        let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: rawSignature)

        let canonical = UnisonJSONValue.object(payload.mapValues { value in
            if let number = value as? NSNumber {
                return .integer(number.int64Value)
            }
            return .string(String(describing: value))
        }).canonicalJSON

        #expect(publicKey.isValidSignature(ecdsa, for: Data(canonical.utf8)))
    }
}

// MARK: - InMemoryVoteKeyStore

private final class InMemoryVoteKeyStore: UnisonVoteKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    func loadPrivateKey() -> Data? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stored
    }

    func savePrivateKey(_ rawRepresentation: Data) {
        self.lock.lock()
        self.stored = rawRepresentation
        self.lock.unlock()
    }
}

// MARK: - VoteServiceProvider

/// A Unison-shaped provider for the service tests: one result, one variant,
/// and a vote box that answers reads with the vote it last recorded.
private final class VoteServiceProvider: LyricsProvider, LyricsVariantProvider, LyricsVoteProvider, @unchecked Sendable {
    let name = "Unison"
    let capability: LyricsCapability

    private let result: LyricResult
    private let variantList: [LyricsVariant]
    private let box: VoteBox
    private let fails: Bool

    init(result: LyricResult, variants: [LyricsVariant], initial: LyricsVoteState, fails: Bool = false) {
        self.capability = result.capability
        self.result = result
        self.variantList = variants
        self.box = VoteBox(initial)
        self.fails = fails
    }

    func search(info: LyricsSearchInfo) async -> LyricResult {
        self.result
    }

    func variants(for info: LyricsSearchInfo) async -> [LyricsVariant] {
        self.variantList
    }

    func voteState(lyricsID: Int) async throws -> LyricsVoteState? {
        await self.box.snapshot()
    }

    func vote(_ direction: LyricsVoteDirection?, lyricsID: Int) async throws {
        if self.fails {
            throw UnisonRequestError(statusCode: 429, message: "Too many requests")
        }
        await self.box.apply(direction)
    }

    func sentDirections() async -> [LyricsVoteDirection?] {
        await self.box.sent()
    }
}

// MARK: - VoteBox

private actor VoteBox {
    private var state: LyricsVoteState
    private var sentDirections: [LyricsVoteDirection?] = []

    init(_ state: LyricsVoteState) {
        self.state = state
    }

    func snapshot() -> LyricsVoteState {
        self.state
    }

    func apply(_ direction: LyricsVoteDirection?) {
        self.sentDirections.append(direction)
        self.state = self.state.applying(direction)
    }

    func sent() -> [LyricsVoteDirection?] {
        self.sentDirections
    }
}

// MARK: - UnisonVoteURLProtocol

/// A file-private protocol so these tests never race with other suites on the
/// shared `MockURLProtocol` handler.
private final class UnisonVoteURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }
}

// MARK: - UnisonVoteRequestLog

private final class UnisonVoteRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []

    func append(_ request: URLRequest) {
        self.lock.lock()
        self.stored.append(request)
        self.lock.unlock()
    }

    var requests: [URLRequest] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stored
    }
}

// MARK: - base64url

private extension String {
    func base64URLDecoded() -> Data? {
        var value = self
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 {
            value += "="
        }
        return Data(base64Encoded: value)
    }
}
