import AppKit

// MARK: - ArtistLogoRendering

/// How the artist header draws a wordmark.
///
/// Apple's wordmarks come in two shapes: a coloured signature, and a single-colour drawing that is often
/// white. The coloured ones are drawn as delivered; the single-colour ones are tinted with the label
/// colour, because white ink on a light page (or black ink on a dark one) is invisible — the logo is
/// there and the reader cannot see it.
enum ArtistLogoRendering {
    /// How far apart the channels of a pixel have to be before the picture counts as coloured.
    private static let colourThreshold: CGFloat = 0.08

    /// Alpha above which a pixel is ink rather than the transparent margin around it.
    private static let inkThreshold: UInt8 = 12

    /// The wordmark with its transparent margins removed.
    ///
    /// Apple's logos arrive with different amounts of empty space around the ink — one is mostly
    /// padding, the next is edge to edge — so drawing them at a fixed frame made some look half the size
    /// of others. Cropping to the ink lets one box size every logo by what is actually visible.
    static func trimmed(_ image: NSImage) -> NSImage {
        guard let tiff = image.tiffRepresentation,
              let source = NSBitmapImageRep(data: tiff),
              source.samplesPerPixel == 4,
              source.bitsPerSample == 8,
              let sourceData = source.bitmapData,
              source.pixelsWide > 0, source.pixelsHigh > 0
        else { return image }

        let width = source.pixelsWide
        let height = source.pixelsHigh
        let rowBytes = source.bytesPerRow
        let alphaOffset = source.bitmapFormat.contains(.alphaFirst) ? 0 : 3

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0 ..< height {
            let row = sourceData.advanced(by: y * rowBytes)
            for x in 0 ..< width where row[x * 4 + alphaOffset] > Self.inkThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }

        let cropWidth = maxX - minX + 1
        let cropHeight = maxY - minY + 1
        guard cropWidth < width || cropHeight < height else { return image }

        guard let target = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: cropWidth,
            pixelsHigh: cropHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: source.colorSpaceName,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let targetData = target.bitmapData else { return image }

        for y in 0 ..< cropHeight {
            memcpy(
                targetData.advanced(by: y * target.bytesPerRow),
                sourceData.advanced(by: (y + minY) * rowBytes + minX * 4),
                cropWidth * 4
            )
        }

        let result = NSImage(size: NSSize(width: cropWidth, height: cropHeight))
        result.addRepresentation(target)
        return result
    }

    /// Whether `image` is a single-colour drawing rather than artwork with its own colours.
    ///
    /// Sampled on a coarse grid: a wordmark is flat ink, so a sprinkling of pixels decides it, and a
    /// full pass over a 1000 px logo would cost more than the answer is worth.
    static func isMonochrome(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0
        else { return false }

        let step = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 32)
        var sampledVisiblePixel = false
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                // Transparent pixels are the wordmark's background, and say nothing about its ink.
                guard colour.alphaComponent > 0.2 else { continue }
                sampledVisiblePixel = true

                let channels = [colour.redComponent, colour.greenComponent, colour.blueComponent]
                guard let high = channels.max(), let low = channels.min() else { continue }
                if high - low > Self.colourThreshold {
                    return false
                }
            }
        }
        return sampledVisiblePixel
    }
}
