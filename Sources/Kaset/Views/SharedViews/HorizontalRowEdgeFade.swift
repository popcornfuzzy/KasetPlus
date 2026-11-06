import SwiftUI

// MARK: - HorizontalRowEdgeFade

/// Softens a horizontal row's edges where cards run under them, so a shelf that continues past the row
/// dissolves into the page instead of ending in a hard cut against the window's side panes.
///
/// The trailing fade is always the row's own: it is drawn where a card would otherwise be sliced off
/// by the Now Playing column. The leading fade only exists once the reader has scrolled the row — at
/// rest the first card is whole, so fading its edge would be a lie about content that is not there.
///
/// The row is widened by the padding its page lays it out inside (`pageInset`), so it runs out to the
/// page's own edge and the trailing fade covers the space between the last visible card and the
/// column. Left inside the page padding it produced a band of bare page past a hard cut instead — the
/// card the row was cut off in stopped short, and the fade washed out only the empty padding.
/// `.contentMargins` hands the row's *end* its inset back, so a row scrolled all the way keeps its last
/// card clear of the column exactly as before.
///
/// It is a **mask**, not a gradient painted in the page's colour: pages do not share one surface — the
/// detail pages draw an artwork-derived accent gradient — and a mask lets whatever is behind the row
/// show through.
///
/// The fade is the last stretch of the row's *remaining* content, so it is absent when there is
/// nothing past the edge: a short shelf (three favorites, a couple of albums) keeps its cards crisp,
/// and a row scrolled to its end stops fading because there is no longer a card being cut off. It
/// therefore also tapers as the reader approaches the end, rather than switching off.
@available(macOS 26.0, *)
struct HorizontalRowEdgeFade: ViewModifier {
    /// The horizontal padding the row's page lays it out inside. The row is widened by it so the
    /// trailing fade reaches the page's edge, where the column starts.
    var pageInset: CGFloat = 24

    /// The fade's full width, in points.
    var width: CGFloat = 32

    /// Headroom the mask is given on each side of the row, so a card's hover scale and shadow are not
    /// the mask's to crop. A mask clips to its own bounds, and a row's bounds are exactly its cards:
    /// without this the shadow of every hovered card was cut off along the row's top and bottom edges,
    /// and the first card's was cut off at the leading edge — the page's own leading padding is the
    /// only room it has to grow into. The vertical headroom is taken back outside the mask (see
    /// `body`), so rows still lay out at the height their page gave them; the leading one stays outside
    /// the row's frame, in the page padding it belongs to.
    private static let hoverBleed: CGFloat = 20

    @State private var fades = EdgeFades()

    /// How much of each edge is currently hiding content (see `edgeFades`).
    private struct EdgeFades: Equatable {
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
    }

    func body(content: Content) -> some View {
        content
            // The row's own end inset, so its last card stops clear of the column.
            .contentMargins(.trailing, self.pageInset, for: .scrollContent)
            // Only the widths that are actually hiding content are published, so a row scrolled in the
            // middle reports the same clamped values every frame instead of re-rendering.
            .onScrollGeometryChange(for: EdgeFades.self) { geometry in
                Self.edgeFades(in: geometry, limit: self.width)
            } action: { _, fades in
                self.fades = fades
            }
            .padding(.vertical, Self.hoverBleed)
            // Also a leading edge, which lands in the page's padding once the outer padding is removed.
            .padding(.leading, Self.hoverBleed)
            .modifier(RowEdgeMask(leading: self.fades.leading, trailing: self.fades.trailing, bleed: Self.hoverBleed))
            // Taken back outside the mask: the row still reports the size the page gave it, and only its
            // drawing — the hover bleed included — extends past its slot. The leading bleed is offset
            // back out of the row entirely, so the cards stay where the page put them and only the
            // mask's edge reaches into the padding.
            .padding(.vertical, -Self.hoverBleed)
            .padding(.leading, -Self.hoverBleed)
            // Widened *outside* the mask, so the mask spans the row out to the page's edge while the row
            // still reports the width the page gave it.
            .padding(.trailing, -self.pageInset)
    }

    /// How far each edge is hiding content, capped at the fade's own width.
    ///
    /// The offset is taken relative to the content's leading inset, which is what makes the arithmetic
    /// agree with `contentSize` in a scroll view that insets its content. Overscroll — a bounce past
    /// either end — clamps to zero rather than fading an edge with nothing under it.
    private static func edgeFades(in geometry: ScrollGeometry, limit: CGFloat) -> EdgeFades {
        let offset = geometry.contentOffset.x - geometry.contentInsets.leading
        let remaining = geometry.contentSize.width - geometry.containerSize.width - offset
        return EdgeFades(
            leading: min(limit, max(0, offset)),
            trailing: min(limit, max(0, remaining))
        )
    }

    /// The fade itself: mostly opaque, so a card stays readable right up to the last few points and
    /// only its very edge dissolves. A straight `black`→`clear` ramp over this width read as a wash.
    static let trailingRamp = LinearGradient(
        stops: [
            .init(color: .black, location: 0),
            .init(color: .black.opacity(0.97), location: 0.25),
            .init(color: .black.opacity(0.88), location: 0.5),
            .init(color: .black.opacity(0.66), location: 0.72),
            .init(color: .black.opacity(0.32), location: 0.9),
            .init(color: .clear, location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// The same ramp, mirrored for the leading edge.
    static let leadingRamp = LinearGradient(
        stops: [
            .init(color: .clear, location: 0),
            .init(color: .black.opacity(0.32), location: 0.1),
            .init(color: .black.opacity(0.66), location: 0.28),
            .init(color: .black.opacity(0.88), location: 0.5),
            .init(color: .black.opacity(0.97), location: 0.75),
            .init(color: .black, location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
}

// MARK: - RowEdgeMask

/// The fade mask itself, applied only while an edge is actually hiding content.
///
/// A mask draws the row — its cards, their hover scales, their shadows — through an offscreen pass, and
/// the pass covers the whole row even when both fade widths are zero. Home stacks a dozen shelves, most
/// of them narrower than the page, and those rows used to pay that pass to draw an opaque rectangle over
/// themselves. A row is masked only when the mask would fade something.
@available(macOS 26.0, *)
private struct RowEdgeMask: ViewModifier {
    let leading: CGFloat
    let trailing: CGFloat
    let bleed: CGFloat

    func body(content: Content) -> some View {
        if self.leading > 0.5 || self.trailing > 0.5 {
            content.mask {
                HStack(spacing: 0) {
                    if self.leading > 0.5 {
                        // Longer by the bleed, so the fade still ends the same distance into the card
                        // even though its clear end now starts in the page's padding.
                        HorizontalRowEdgeFade.leadingRamp
                            .frame(width: self.leading + self.bleed)
                    }
                    Rectangle()
                        .fill(.black)
                    if self.trailing > 0.5 {
                        HorizontalRowEdgeFade.trailingRamp
                            .frame(width: self.trailing)
                    }
                }
            }
        } else {
            content
        }
    }
}

@available(macOS 26.0, *)
extension View {
    /// Softens a horizontal row's edges where it still has content past them (see
    /// `HorizontalRowEdgeFade`).
    /// - Parameter pageInset: the padding the row's page lays it out inside.
    func horizontalRowEdgeFade(pageInset: CGFloat = 24, width: CGFloat = 32) -> some View {
        modifier(HorizontalRowEdgeFade(pageInset: pageInset, width: width))
    }
}
