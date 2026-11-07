import Foundation
import Testing
@testable import Kaset

/// Tests for the on-disk wordmark cache: it stores only found logos, and forgets them after a month.
@Suite("ArtistLogoCache", .tags(.service))
struct ArtistLogoCacheTests {
    /// A clock the test moves by hand, so "a month later" costs nothing.
    private final class MutableClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private let logo = ArtistLogo(
        url: URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Features/1000x500bb.png")!,
        aspectRatio: 2
    )

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistLogoCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("A stored wordmark is served from disk")
    func storesLogo() async {
        let cache = ArtistLogoCache(directory: self.makeDirectory())

        await cache.store(self.logo, for: "UC-some-channel")

        #expect(await cache.logo(for: "UC-some-channel") == self.logo)
    }

    @Test("A different artist does not get this artist's wordmark")
    func separateArtists() async {
        let cache = ArtistLogoCache(directory: self.makeDirectory())
        await cache.store(self.logo, for: "UC-one")

        #expect(await cache.logo(for: "UC-two") == nil)
    }

    @Test("A wordmark older than a month is dropped")
    func expiresAfterAMonth() async {
        let clock = MutableClock()
        let cache = ArtistLogoCache(directory: self.makeDirectory(), now: { clock.now })
        await cache.store(self.logo, for: "UC-old")

        clock.now = clock.now.addingTimeInterval(ArtistLogoCache.maxAge - 1)
        #expect(await cache.logo(for: "UC-old") == self.logo)

        clock.now = clock.now.addingTimeInterval(2)
        #expect(await cache.logo(for: "UC-old") == nil)
    }

    @Test("A miss is not written, so a later visit looks the artist up again")
    func missesAreNotStored() async {
        let cache = ArtistLogoCache(directory: self.makeDirectory())

        #expect(await cache.logo(for: "UC-never-stored") == nil)
        #expect(await cache.logo(for: "UC-never-stored") == nil)
    }

    @Test("An artist id that could escape the cache directory stays inside it")
    func keyIsDigested() async {
        let directory = self.makeDirectory()
        let cache = ArtistLogoCache(directory: directory)
        let hostile = "../../../etc/passwd"

        await cache.store(self.logo, for: hostile)

        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(files.count == 1)
        #expect(files.first?.contains("..") == false)
        #expect(await cache.logo(for: hostile) == self.logo)
    }
}
