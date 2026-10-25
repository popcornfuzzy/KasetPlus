import SwiftUI

// MARK: - RichLyricsWordView

/// One word of a lyric line in the Better Lyrics style: a crisp highlight that sweeps the word, a
/// small pop of the whole word, and a wave through its letters as they are lit.
///
/// A letter is drawn as its own layer here, unlike `KaraokeWordView`, because the wave puts every
/// letter at a different height at the same moment, which no single text layer can do. The cost is
/// bounded by drawing a word with nothing in flight as the one `Text` it was before: on a line that
/// is every word but the one or two being sung, and on a settled line it is every word of it.
@available(macOS 26.0, *)
struct RichLyricsWordView: View {
    /// The word: its text and the window it is sung over.
    let word: KaraokeWord
    /// The word's characters, in reading order.
    let characters: [KaraokeCharacter]
    /// Measured advance width of each character, in the same order as `characters`.
    let characterWidths: [CGFloat]
    /// Whether the word reads right-to-left: such a word is laid out, and so sweeps, from its
    /// trailing edge.
    let isRightToLeft: Bool
    /// Playback position to render at, in milliseconds.
    let displayTimeMs: Double
    var color: Color = .primary
    /// Opacity of the not-yet-sung text.
    var dimOpacity: Double = 0.32
    var fontSize: CGFloat
    /// Strength of the bloom, and the switch for everything that moves: `0` renders a plain sweep,
    /// which is what Reduce Motion uses.
    ///
    /// The motion itself is not scaled by it. A letter's float is a share of the font size (Better
    /// Lyrics' `0.05em`), so the narrow panel's smaller text already moves less than the player's;
    /// halving that again for the panel's lighter emphasis would take the wave below the point at
    /// which it can be seen, which is the whole of what this style is for.
    var emphasis: Double = 1.0
    /// When each of the word's letters floats, from the line's layout. Scheduling it there is what
    /// keeps a frame's work arithmetic: a word does not rebuild its wave every time it is drawn.
    let waves: [RichLyricsLetterWave]
    /// Whether the line is no longer being sung: every letter is on the baseline, however far its
    /// own float would still be from finished.
    var isSettled: Bool = false
    var timing: RichLyricsTiming = .standard

    /// The width of the word's box: the cells its characters are drawn in, which is the width the
    /// flow layout reserved for it.
    private var width: CGFloat {
        self.characterWidths.reduce(0, +)
    }

    var body: some View {
        let band = RichLyricsAnimation.band(for: self.word, at: self.displayTimeMs, timing: self.timing)
        let floats = self.floats
        // Letters only need layers while they are at *different* heights. Before a word's wave starts
        // and after it has settled, every letter is at the same one, and the word draws as the one
        // text layer it was. Neither is the usual case on a line timed per syllable — its units are
        // short, so their floats are still running long after the units themselves are sung — so a
        // word whose letters differ by less than a quarter point shares one layer too: that is a
        // movement no display can show, and it is most of the line's cost.
        let uniformFloat = RichLyricsAnimation.sharedFloat(of: floats, fontSize: self.fontSize)
        let wobble = self.popped
        // A settled line carries no bloom — its words finished glowing before it left the clock —
        // and a word that is not lit yet has nothing for the bloom to spread from.
        let glow = self.emphasis > 0 && !self.isSettled && !band.isUnlit
            ? RichLyricsAnimation.glow(for: self.word, at: self.displayTimeMs, timing: self.timing)
            : 0

        ZStack(alignment: .leading) {
            if let uniform = uniformFloat {
                self.uniformText(band: band)
                    .scaleEffect(CGFloat(uniform.scale), anchor: .center)
                    .offset(y: -self.fontSize * CGFloat(uniform.liftEm))
            } else {
                ForEach(self.characters.indices, id: \.self) { index in
                    self.letter(at: index, band: band, float: floats[index])
                }
            }

            if glow > 0 {
                self.bloom(band: band, strength: glow)
            }
        }
        .frame(width: max(0, self.width), alignment: .leading)
        .scaleEffect(x: CGFloat(wobble.scale), y: 1, anchor: .center)
        .offset(x: self.fontSize * CGFloat(wobble.travelEm))
    }

    // MARK: Layers

    /// The word as one text layer, for the frames where every letter is at the same height.
    ///
    /// A word the highlight is crossing is cut with the same gradient the per-letter path cuts each
    /// cell with, so the edge lands in exactly the same place: two letters at one height are one
    /// word, and drawing them separately would only cost layers.
    @ViewBuilder
    private func uniformText(band: RichLyricsBand) -> some View {
        if band.isUnlit {
            self.text(isSung: false)
        } else if band.isFullyLit {
            self.text(isSung: true)
        } else {
            ZStack(alignment: .leading) {
                self.text(isSung: false)
                self.text(isSung: true)
                    .mask(alignment: .leading) { self.mask(band) }
            }
        }
    }

    /// The whole word as the one text layer a settled word needs.
    private func text(isSung: Bool) -> some View {
        Text(self.word.text)
            .foregroundStyle(isSung ? self.color : self.color.opacity(self.dimOpacity))
            .fixedSize()
            .frame(width: max(0, self.width), alignment: .leading)
    }

    /// One letter, with its own slice of the highlight and its own place in the wave.
    private func letter(at index: Int, band: RichLyricsBand, float: RichLyricsLetterFloat) -> some View {
        let cell = self.cell(at: index)
        let fill = self.fill(of: cell, in: band)
        let alignment: Alignment = self.isRightToLeft ? .trailing : .leading
        let glyph = Text(self.characters[index].text).fixedSize()

        return Group {
            switch fill {
            case .unlit:
                glyph
                    .foregroundStyle(self.color.opacity(self.dimOpacity))
            case .lit:
                // A lit letter is one opaque layer: keeping the dim base underneath it would only
                // add a layer to every sung letter of every frame, and a line mostly shows those.
                glyph
                    .foregroundStyle(self.color)
            case let .partial(from, to):
                ZStack(alignment: alignment) {
                    glyph
                        .foregroundStyle(self.color.opacity(self.dimOpacity))
                    glyph
                        .foregroundStyle(self.color)
                        .frame(width: cell.width, alignment: alignment)
                        .mask(alignment: alignment) { self.cellMask(from: from, to: to) }
                }
            }
        }
        .frame(width: cell.width, alignment: alignment)
        .scaleEffect(CGFloat(float.scale), anchor: .center)
        .offset(y: -self.fontSize * CGFloat(float.liftEm))
        .offset(x: cell.x)
    }

    /// The bloom behind the highlight: one blurred, masked copy of the whole word, drawn only while
    /// the glow lasts and only when the decorations are on.
    private func bloom(band: RichLyricsBand, strength: Double) -> some View {
        let layer = Text(self.word.text)
            .foregroundStyle(self.color)
            .fixedSize()
            .frame(width: max(0, self.width), alignment: .leading)
        let radius = self.fontSize * CGFloat(self.timing.glowRadiusEm)
        let opacity = self.timing.glowOpacity * self.emphasis * strength

        return Group {
            if band.isFullyLit {
                layer
            } else {
                layer.mask(alignment: .leading) { self.mask(band) }
            }
        }
        // Blurring after masking lets the bloom spread past the word's box the way a bloom does,
        // so it tapers into the line instead of ending on the edge of the text box.
        .blur(radius: radius)
        .opacity(opacity)
    }

    // MARK: Masks

    /// The highlight's gradient over the word's whole box.
    private func mask(_ band: RichLyricsBand) -> some View {
        let lit = min(max(band.lit, 0), 1)
        let tail = max(min(max(band.tail, 0), 1), lit)
        return Rectangle().fill(
            LinearGradient(
                stops: [
                    .init(color: .white, location: lit),
                    .init(color: .white.opacity(0), location: tail),
                ],
                startPoint: self.leadingEdge,
                endPoint: self.trailingEdge
            )
        )
    }

    /// A letter's slice of that gradient, measured inside its own cell.
    private func cellMask(from: Double, to: Double) -> some View {
        let lit = min(max(from, 0), 1)
        let tail = max(min(max(to, 0), 1), lit)
        return Rectangle().fill(
            LinearGradient(
                stops: [
                    .init(color: .white, location: lit),
                    .init(color: .white.opacity(0), location: tail),
                ],
                startPoint: self.leadingEdge,
                endPoint: self.trailingEdge
            )
        )
    }

    private var leadingEdge: UnitPoint {
        self.isRightToLeft ? .trailing : .leading
    }

    private var trailingEdge: UnitPoint {
        self.isRightToLeft ? .leading : .trailing
    }

    // MARK: Geometry

    /// One letter's cell in the word's box: where it is drawn, and the share of the box it takes.
    private struct LetterCell {
        /// Left edge of the cell in the word's box, in points.
        let x: CGFloat
        let width: CGFloat
        /// Where the cell starts and how wide it is as shares of the box, in reading order.
        let start: Double
        let share: Double
    }

    /// How much of one letter's cell the highlight has reached.
    private enum LetterFill {
        case unlit
        case lit
        case partial(from: Double, to: Double)
    }

    /// Where a letter's cell sits in the word's box, counted from the edge the word is drawn from:
    /// a right-to-left word draws its first letter at the right of the box.
    private func cell(at index: Int) -> LetterCell {
        let widths = self.characterWidths
        guard widths.indices.contains(index) else {
            return LetterCell(x: 0, width: 0, start: 0, share: 0)
        }
        let width = widths[index]
        let pen = widths.prefix(index).reduce(0, +)
        let box = max(1, self.width)
        return LetterCell(
            x: self.isRightToLeft ? box - pen - width : pen,
            width: width,
            start: Double(pen / box),
            share: Double(width / box)
        )
    }

    /// Split a letter's cell against the highlight's band, so a letter the band is crossing carries
    /// a gradient and every other letter is drawn as one plain layer.
    private func fill(of cell: LetterCell, in band: RichLyricsBand) -> LetterFill {
        let end = cell.start + cell.share
        if band.tail <= cell.start { return .unlit }
        if band.lit >= end { return .lit }

        let share = max(0.0001, cell.share)
        let from = min(max((band.lit - cell.start) / share, 0), 1)
        let to = min(max((band.tail - cell.start) / share, 0), 1)
        return .partial(from: from, to: max(to, from))
    }

    // MARK: Animation values

    /// Where every letter of the word sits at this playback position.
    ///
    /// With the decorations off nothing floats, and the word is drawn as one layer however far its
    /// sweep has got — which is what Reduce Motion gets.
    private var floats: [RichLyricsLetterFloat] {
        let count = self.characters.count
        guard !self.isSettled, self.emphasis > 0, count > 0 else {
            return Array(repeating: .rest, count: count)
        }
        let waves = self.waves
        return (0 ..< count).map { index in
            guard waves.indices.contains(index) else { return .rest }
            return RichLyricsAnimation.letterFloat(
                of: waves[index],
                word: self.word,
                at: self.displayTimeMs,
                timing: self.timing
            )
        }
    }

    /// How far the whole word has popped at this playback position.
    private var popped: RichLyricsWobble {
        guard !self.isSettled, self.emphasis > 0 else { return .identity }
        return RichLyricsAnimation.wobble(for: self.word, at: self.displayTimeMs, timing: self.timing)
    }
}
