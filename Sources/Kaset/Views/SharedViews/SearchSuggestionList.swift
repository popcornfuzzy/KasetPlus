import SwiftUI

// MARK: - SearchSuggestionList

/// The completions a search field draws under itself.
///
/// It is part of the field's surface, not a panel of its own: the card that holds the field holds
/// this list too, divided by a hairline (ADR-0054). The first row is the text in the field, so the
/// list always has something to run; the rest is the provider's order.
@available(macOS 26.0, *)
struct SearchSuggestionList: View {
    /// The rows to draw, the typed query's own row first. That first row is also what a completion's
    /// matching prefix is emphasised against.
    let rows: [String]

    /// The row the pointer or the arrow keys are on; `-1` is the field itself.
    let highlightedIndex: Int

    /// Called when the pointer moves onto a row, so hover and the arrow keys share one highlight.
    let onHighlight: (Int) -> Void

    /// Called with the row's text when it is clicked.
    let onRun: (String) -> Void

    private static let rowCornerRadius: CGFloat = 9

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(self.rows.enumerated()), id: \.element) { index, row in
                self.row(row, index: index)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(AccessibilityID.Search.suggestionsContainer)
    }

    private func row(_ text: String, index: Int) -> some View {
        let isHighlighted = index == self.highlightedIndex

        return Button {
            self.onRun(text)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: index == 0 ? "magnifyingglass" : "arrow.up.left")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHighlighted ? Color.accentColor : Color.secondary)
                    .frame(width: 16)

                self.label(text, index: index)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // The typed query's own row always says what Return does; a completion says it only
                // while it is the row Return would run. The slot is always there, so the text does
                // not re-truncate as the highlight moves.
                Image(systemName: "return")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isHighlighted ? Color.accentColor : Color.secondary.opacity(0.5))
                    .opacity(isHighlighted || index == 0 ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Self.rowCornerRadius, style: .continuous)
                    .fill(isHighlighted ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            .contentShape(.rect(cornerRadius: Self.rowCornerRadius))
            // The highlight hands off between rows instead of jumping: both fades run on the same
            // curve, so the fill reads as one light moving under the pointer.
            .animation(AppAnimation.snappy, value: isHighlighted)
        }
        .buttonStyle(.interactiveRow(
            cornerRadius: Self.rowCornerRadius,
            hapticFeedback: .navigation,
            drawsBackground: false
        ))
        .onHover { hovering in
            if hovering {
                self.onHighlight(index)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Search.suggestion(index: index))
        .accessibilityLabel(text)
    }

    /// The row's text with the part the reader already typed set in bold, the way a completion is
    /// marked everywhere else: the suggestion is the difference, not the whole word.
    private func label(_ text: String, index: Int) -> Text {
        let term = self.rows.first ?? ""

        guard index > 0,
              let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .anchored])
        else {
            return Text(verbatim: text)
        }

        return Text(verbatim: String(text[..<range.upperBound])).bold()
            + Text(verbatim: String(text[range.upperBound...]))
    }
}
