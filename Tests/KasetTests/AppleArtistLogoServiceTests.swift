import Foundation
import Testing
@testable import Kaset

/// Tests for reading artist wordmarks out of an Apple Music artist page.
@Suite("AppleArtistLogoService", .tags(.service))
struct AppleArtistLogoServiceTests {
    /// A page shaped like Apple's: hydration JSON in a `serialized-server-data` script, with the header
    /// node carrying the logo (or `null` for artists without one).
    private func makePage(logo: String) -> String {
        """
        <html><head></head><body>
        <script id="serialized-server-data" type="application/json">\
        [{"data":[{"artistHeader":{"artistName":"Test Artist","artistLogo":\(logo)}}]}]\
        </script>
        </body></html>
        """
    }

    private var logoNode: String {
        """
        {"dictionary":{"width":2000,"height":1000,"textColor1":"ffffff",\
        "url":"https://is1-ssl.mzstatic.com/image/thumb/Features/v4/ab/cd/{w}x{h}{c}.{f}"},\
        "cropStyle":"bb"}
        """
    }

    @Test("Reads the logo URL and aspect ratio")
    func parsesLogo() throws {
        let logo = try #require(AppleArtistLogoService.artistLogo(inHTML: self.makePage(logo: self.logoNode)))

        #expect(logo.url.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/Features/v4/ab/cd/1000x500bb.png")
        #expect(logo.aspectRatio == 2)
    }

    @Test("An artist without a logo has none")
    func nullLogo() {
        #expect(AppleArtistLogoService.artistLogo(inHTML: self.makePage(logo: "null")) == nil)
    }

    @Test("A page without hydration data has no logo")
    func missingHydrationData() {
        #expect(AppleArtistLogoService.artistLogo(inHTML: "<html><body>No script</body></html>") == nil)
    }

    @Test("Artwork templates need both size placeholders and an https scheme")
    func fillsArtworkTemplate() {
        #expect(
            AppleArtistLogoService.artworkURL(template: "https://example.com/{w}x{h}{c}.{f}", width: 10, height: 20)?
                .absoluteString == "https://example.com/10x20bb.png"
        )
        #expect(AppleArtistLogoService.artworkURL(template: "https://example.com/logo.png", width: 10, height: 20) == nil)
        #expect(AppleArtistLogoService.artworkURL(template: "http://example.com/{w}x{h}", width: 10, height: 20) == nil)
    }

    @Test("Shared release titles identify the same act")
    func matchesSharedTitles() {
        let pageTitles = Set(["currents", "the slow rush"])

        #expect(AppleArtistLogoService.sharesTitles(["Currents"], pageTitles))
        #expect(AppleArtistLogoService.sharesTitles(["The Slow Rush (Deluxe)"], pageTitles) == false)
        #expect(AppleArtistLogoService.sharesTitles(["Lover", "Midnights"], pageTitles) == false)
    }
}
