import AppKit
import Testing
@testable import Kaset

/// Tests for deciding whether an artist wordmark should keep its colours or be tinted, and for cropping
/// the padding Apple leaves around it.
@Suite("ArtistLogoRendering", .tags(.service))
struct ArtistLogoRenderingTests {
    /// Device colours rather than the named palette: a named colour has no components a bitmap can encode,
    /// and `setColor` logs a colour-space error for it instead of writing ink.
    private let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
    private let black = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
    private let red = NSColor(deviceRed: 0.9, green: 0.1, blue: 0.2, alpha: 1)
    private let blue = NSColor(deviceRed: 0.1, green: 0.3, blue: 0.9, alpha: 1)
    private let clear = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0)

    /// A one-pixel-tall picture of `colours`, pixel by pixel.
    private func makeImage(_ colours: [NSColor]) -> NSImage {
        let width = max(1, colours.count)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return NSImage(size: NSSize(width: width, height: 1)) }

        for (x, colour) in colours.enumerated() {
            rep.setColor(colour, atX: x, y: 0)
        }
        let image = NSImage(size: NSSize(width: width, height: 1))
        image.addRepresentation(rep)
        return image
    }

    /// A square picture with `colour` painted inside `ink` and transparent margins everywhere else.
    private func makeImage(width: Int, height: Int, ink: NSRect, colour: NSColor) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return NSImage(size: NSSize(width: width, height: height)) }

        for y in Int(ink.minY) ..< Int(ink.maxY) {
            for x in Int(ink.minX) ..< Int(ink.maxX) {
                rep.setColor(colour, atX: x, y: y)
            }
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    @Test("A white wordmark is monochrome, so it can be tinted")
    func whiteLogo() {
        #expect(ArtistLogoRendering.isMonochrome(self.makeImage([self.white, self.white, self.white])))
    }

    @Test("A black wordmark is monochrome too")
    func blackLogo() {
        #expect(ArtistLogoRendering.isMonochrome(self.makeImage([self.black, self.black])))
    }

    @Test("A coloured logo keeps its colours")
    func colouredLogo() {
        #expect(ArtistLogoRendering.isMonochrome(self.makeImage([self.red, self.blue])) == false)
    }

    @Test("One coloured pixel is enough to keep the whole logo in colour")
    func mixedLogo() {
        #expect(ArtistLogoRendering.isMonochrome(self.makeImage([self.white, self.white, self.blue])) == false)
    }

    @Test("Fully transparent artwork proves nothing")
    func transparentImage() {
        #expect(ArtistLogoRendering.isMonochrome(self.makeImage([self.clear, self.clear])) == false)
    }

    @Test("The transparent margin around the wordmark is cropped away")
    func trimsPadding() {
        let image = self.makeImage(width: 10, height: 10, ink: NSRect(x: 2, y: 3, width: 4, height: 5), colour: self.white)

        let trimmed = ArtistLogoRendering.trimmed(image)

        #expect(trimmed.size == NSSize(width: 4, height: 5))
    }

    @Test("A wordmark that already fills its picture is left alone")
    func keepsFullImage() {
        let image = self.makeImage(width: 10, height: 10, ink: NSRect(x: 0, y: 0, width: 10, height: 10), colour: self.red)

        #expect(ArtistLogoRendering.trimmed(image).size == NSSize(width: 10, height: 10))
    }

    @Test("A picture with no ink at all is left alone")
    func keepsEmptyImage() {
        let image = self.makeImage(width: 10, height: 10, ink: .zero, colour: self.white)

        #expect(ArtistLogoRendering.trimmed(image).size == NSSize(width: 10, height: 10))
    }
}
