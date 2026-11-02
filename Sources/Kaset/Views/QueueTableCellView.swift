import AppKit
import SwiftUI

// MARK: - QueueCellActions

@available(macOS 26.0, *)
struct QueueCellActions {
    let onPlay: () -> Void
}

// MARK: - Queue Row Colours

extension NSAppearance {
    /// Whether this appearance draws on a dark background, whichever of the four it is.
    ///
    /// `bestMatch(from:)` is the question AppKit asks a dynamic colour's own provider, so a vibrant
    /// appearance answers with the scheme underneath it rather than falling through to `.aqua`.
    var isDark: Bool {
        self.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// The queue row's greys, in colours no appearance can re-resolve.
///
/// The rows are drawn inside the Now Playing sidebar's material, and its content lives in a **vibrant**
/// appearance. The vibrant appearances re-resolve the system's label colours to lower-alpha ones — on this
/// Mac `secondaryLabelColor` comes back as black @ 0.50 and `tertiaryLabelColor` as black @ 0.30 under
/// `VibrantLight` — so the track number, the artist and the duration landed as greys near the panel's own
/// colour (the system's tertiary grey at 0.70 of the way to white, where the row wants 0.29), which is the
/// washed-out row they read as. Dark mode is the same story mirrored: 0.20 for the system's tertiary grey
/// against the 0.73 the row wants.
///
/// A colour that carries its own literals is not re-resolved: the appearance picks *which* of the two
/// stated values is drawn, and nothing dims them. This is the same escape `Sidebar.rowForeground(for:)`
/// takes with literal colours, stated for the queue's own text (`EmphasizedMaterialView` has the measured
/// table of what the system colours are worth in each appearance).
///
/// The literal each appearance draws, and what it lands as on the panel (measured on this Mac; asserted
/// in `QueueRowTextColorTests`):
///
/// | element                            | light          | lands at | dark           | lands at |
/// |------------------------------------|----------------|----------|----------------|----------|
/// | artist (was `secondaryLabelColor`) | white 0.25     | 0.19     | white 0.85     | 0.82     |
/// | number, duration, waveform at rest | white 0.36     | 0.29     | white 0.78     | 0.73     |
@available(macOS 26.0, *)
enum QueueRowTextColor {
    /// The artist line — the row's most-read secondary text.
    static let artist = NSColor(name: "QueueRowArtistText", dynamicProvider: { appearance in
        appearance.isDark
            ? NSColor(white: 0.85, alpha: 1)
            : NSColor(white: 0.25, alpha: 1)
    })

    /// The track number, the duration, and the waveform when it is not animating: quieter than the
    /// artist line, and still a colour rather than a haze.
    static let detail = NSColor(name: "QueueRowDetailText", dynamicProvider: { appearance in
        appearance.isDark
            ? NSColor(white: 0.78, alpha: 1)
            : NSColor(white: 0.36, alpha: 1)
    })
}

// MARK: - QueueTableCellView

@available(macOS 26.0, *)
class QueueTableCellView: NSView {
    /// Height of a song row.
    static let rowHeight: CGFloat = 56

    private var onPlay: (() -> Void)?
    private var isCurrentTrack: Bool = false
    private var isPlaying: Bool = false
    private var stackView: NSStackView?
    private var indicatorLabel = NSTextField()
    private var waveformView: NSView?
    private let thumbnailImageView = NSImageView()
    private var imageLoadTask: Task<Void, Never>?
    private var currentSongId: String?
    private let titleLabel = NSTextField()
    private let artistLabel = NSTextField()
    private let durationLabel = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupView()
    }

    private func setupView() {
        wantsLayer = true
        // Fill the row view so layout is consistent when the table reuses row views (fixes misaligned rows).
        autoresizingMask = [.width, .height]

        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 12
        stackView.alignment = .centerY
        // Do NOT use edgeInsets — use explicit constraints for predictable, consistent padding on all rows.
        stackView.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 8)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        self.stackView = stackView

        // Indicator container (for number or waveform) — keep fixed so long text doesn't shift row layout
        let indicatorContainer = NSView()
        indicatorContainer.translatesAutoresizingMaskIntoConstraints = false
        let indicatorWidth = indicatorContainer.widthAnchor.constraint(equalToConstant: 24)
        indicatorWidth.priority = .required
        indicatorWidth.isActive = true
        indicatorContainer.heightAnchor.constraint(equalToConstant: 20).isActive = true
        indicatorContainer.setContentHuggingPriority(.required, for: .horizontal)
        indicatorContainer.setContentCompressionResistancePriority(.required, for: .horizontal)

        self.indicatorLabel.isEditable = false
        self.indicatorLabel.isBordered = false
        self.indicatorLabel.backgroundColor = .clear
        self.indicatorLabel.alignment = .center
        self.indicatorLabel.font = NSFont.systemFont(ofSize: 12)
        self.indicatorLabel.translatesAutoresizingMaskIntoConstraints = false
        indicatorContainer.addSubview(self.indicatorLabel)
        NSLayoutConstraint.activate([
            self.indicatorLabel.centerXAnchor.constraint(equalTo: indicatorContainer.centerXAnchor),
            self.indicatorLabel.centerYAnchor.constraint(equalTo: indicatorContainer.centerYAnchor),
        ])

        self.thumbnailImageView.wantsLayer = true
        self.thumbnailImageView.layer?.cornerRadius = 4
        self.thumbnailImageView.layer?.masksToBounds = true
        self.thumbnailImageView.widthAnchor.constraint(equalToConstant: 40).isActive = true
        self.thumbnailImageView.heightAnchor.constraint(equalToConstant: 40).isActive = true
        self.thumbnailImageView.setContentHuggingPriority(.required, for: .horizontal)
        self.thumbnailImageView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let infoStackView = NSStackView()
        infoStackView.orientation = .vertical
        infoStackView.spacing = 2
        infoStackView.alignment = .leading

        self.titleLabel.isEditable = false
        self.titleLabel.isBordered = false
        self.titleLabel.backgroundColor = .clear
        self.titleLabel.lineBreakMode = .byTruncatingTail

        self.artistLabel.isEditable = false
        self.artistLabel.isBordered = false
        self.artistLabel.backgroundColor = .clear
        self.artistLabel.lineBreakMode = .byTruncatingTail
        self.artistLabel.font = NSFont.systemFont(ofSize: 11)
        self.artistLabel.textColor = QueueRowTextColor.artist

        infoStackView.addArrangedSubview(self.titleLabel)
        infoStackView.addArrangedSubview(self.artistLabel)

        self.durationLabel.isEditable = false
        self.durationLabel.isBordered = false
        self.durationLabel.backgroundColor = .clear
        self.durationLabel.alignment = .right
        self.durationLabel.font = NSFont.systemFont(ofSize: 11)
        self.durationLabel.textColor = QueueRowTextColor.detail
        self.durationLabel.setContentCompressionResistancePriority(.required, for: .horizontal) // Don't compress duration

        // Spacer takes all flexible space so title/artist and duration stay consistently aligned across rows
        let spacerView = NSView()
        spacerView.translatesAutoresizingMaskIntoConstraints = false
        spacerView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacerView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        infoStackView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) // Truncate before spacer grows

        stackView.addArrangedSubview(indicatorContainer)
        stackView.addArrangedSubview(self.thumbnailImageView)
        stackView.addArrangedSubview(infoStackView)
        stackView.addArrangedSubview(spacerView)
        stackView.addArrangedSubview(self.durationLabel)

        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(self.handleRowClick))
        addGestureRecognizer(clickGesture)

    }

    override func layout() {
        super.layout()
        // Ensure we always fill the row view so reused rows don't keep a stale frame (fixes misaligned rows).
        if let sv = superview, !sv.bounds.isEmpty, frame != sv.bounds {
            frame = sv.bounds
        }
        // Force stackView to recalculate layout based on consistent constraints — prevents
        // off-by-one padding from table view reuse when constraints were set up incorrectly.
        self.stackView?.needsLayout = true
    }

    func configure(
        song: Song,
        index: Int,
        isCurrentTrack: Bool,
        isPlaying: Bool,
        actions: QueueCellActions
    ) {
        self.onPlay = actions.onPlay
        self.isCurrentTrack = isCurrentTrack
        self.isPlaying = isPlaying
        
        // Reset frame to match superview — fixes misaligned rows from constraint drift on reuse
        if let sv = superview, !sv.bounds.isEmpty {
            self.frame = sv.bounds
        }
        
        self.updateAppearance(isCurrentTrack: isCurrentTrack, isPlaying: isPlaying, index: index)

        self.titleLabel.stringValue = song.title
        self.titleLabel.font = NSFont.systemFont(ofSize: 13, weight: isCurrentTrack ? .semibold : .regular)
        self.titleLabel.textColor = isCurrentTrack ? NSColor.systemRed : NSColor.labelColor

        self.artistLabel.stringValue = song.artistsDisplay.isEmpty ? "Unknown Artist" : song.artistsDisplay

        if let duration = song.duration {
            let mins = Int(duration) / 60
            let secs = Int(duration) % 60
            self.durationLabel.stringValue = String(format: "%d:%02d", mins, secs)
        } else {
            self.durationLabel.stringValue = ""
        }

        let songId = song.id
        self.currentSongId = songId
        self.imageLoadTask?.cancel()
        let candidates = Self.thumbnailCandidates(for: song)
        if candidates.isEmpty {
            self.thumbnailImageView.image = nil
        } else {
            // The row starts with the picture the app already holds, when it holds one: the load below
            // answers a hop later, and a row that draws before it does shows an empty slot. Rebuilding
            // the list — a reload after a drop, a row scrolled back into view — would otherwise flash
            // every thumbnail it re-creates.
            self.thumbnailImageView.image = Self.cachedThumbnail(from: candidates)
            self.imageLoadTask = Task { [weak self] in
                var image: NSImage?
                for candidate in candidates {
                    image = await ImageCache.shared.image(for: candidate, targetSize: Self.thumbnailSize)
                    if image != nil {
                        break
                    }
                }

                guard !Task.isCancelled, self?.currentSongId == songId else { return }
                self?.thumbnailImageView.image = image
            }
        }
    }

    private static let thumbnailSize = CGSize(width: 40, height: 40)

    /// The artwork URLs a row tries, in order: the high-quality size, the other high-quality sizes,
    /// and the URL the song was parsed with last.
    private static func thumbnailCandidates(for song: Song) -> [URL] {
        guard let primaryURL = song.thumbnailURL?.highQualityThumbnailURL,
              let fallbackURL = song.thumbnailURL
        else { return [] }
        var candidates: [URL] = [primaryURL]
        candidates.append(contentsOf: fallbackURL.highQualityThumbnailCandidates.filter { $0 != fallbackURL })
        candidates.append(fallbackURL)
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.absoluteString).inserted }
    }

    /// The first candidate already decoded in memory at this row's size.
    ///
    /// `configure` runs while the table draws, so a picture has to be there *now* rather than a hop
    /// later: a row that starts empty and fills in is a flash when a whole list is rebuilt at once.
    private static func cachedThumbnail(from candidates: [URL]) -> NSImage? {
        for candidate in candidates {
            guard let image = ImageCache.shared.cachedImage(for: candidate) else { continue }
            if ImageCache.isSufficientResolution(image, for: Self.thumbnailSize) {
                return image
            }
        }
        return nil
    }

    func updateAppearance(isCurrentTrack: Bool, isPlaying: Bool, index: Int) {
        self.isCurrentTrack = isCurrentTrack
        self.isPlaying = isPlaying

        if isCurrentTrack {
            // Show animated waveform for current track
            self.indicatorLabel.stringValue = ""
            self.indicatorLabel.isHidden = true

            // Create or update waveform view
            if self.waveformView == nil {
                let waveView = WaveformView(frame: NSRect(x: 0, y: 0, width: 24, height: 16))
                waveView.translatesAutoresizingMaskIntoConstraints = false
                self.waveformView = waveView

                // Find indicator container and add waveform
                if let indicatorContainer = indicatorLabel.superview {
                    indicatorContainer.addSubview(waveView)
                    NSLayoutConstraint.activate([
                        waveView.centerXAnchor.constraint(equalTo: indicatorContainer.centerXAnchor),
                        waveView.centerYAnchor.constraint(equalTo: indicatorContainer.centerYAnchor),
                        waveView.widthAnchor.constraint(equalToConstant: 24),
                        waveView.heightAnchor.constraint(equalToConstant: 16),
                    ])
                }
            }

            if let waveView = waveformView as? WaveformView {
                waveView.isHidden = false
                waveView.isAnimating = isPlaying
            }
        } else {
            // Show number for non-current tracks
            self.indicatorLabel.isHidden = false
            self.indicatorLabel.stringValue = "\(index + 1)"
            self.indicatorLabel.textColor = QueueRowTextColor.detail

            // Hide waveform
            self.waveformView?.isHidden = true
        }

        self.applyLayerColours()
    }

    /// Paints the parts of the row that are not text fields: the row's own tint and the waveform's bars.
    ///
    /// Both live as `CGColor`s in layers, and a layer holds a *resolved* colour — so each is handed a
    /// fresh one whenever the row's state changes, and handed it inside the appearance the row actually
    /// draws in, since `NSAppearance.current` is the drawing context's and not this view's. The text
    /// fields need none of this: each re-resolves its own dynamic colour when the appearance changes.
    private func applyLayerColours() {
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = self.isCurrentTrack
                ? NSColor.systemRed.withAlphaComponent(0.1).cgColor
                : NSColor.clear.cgColor
            if let waveView = self.waveformView as? WaveformView {
                waveView.tintColor = self.isPlaying ? NSColor.systemRed : QueueRowTextColor.detail
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.applyLayerColours()
    }

    @objc private func handleRowClick() {
        self.onPlay?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.imageLoadTask?.cancel()
        self.imageLoadTask = nil
        self.currentSongId = nil
        self.thumbnailImageView.image = nil
        self.waveformView?.removeFromSuperview()
        self.waveformView = nil
    }
}

// MARK: - QueueSectionHeaderCellView

/// A queue section's caption row: "Next in queue" and "Rest of the queue".
///
/// It is a real table row (`isGroupRow`), not a strip inside the first song's row, so it is not
/// draggable, not selectable, and cannot appear in a drag image. "Next in queue" carries the button
/// that empties that section.
@available(macOS 26.0, *)
class QueueSectionHeaderCellView: NSView {
    /// Height of a caption row. The caption is centred, so the row itself is the air above and below it.
    static let rowHeight: CGFloat = 34

    private let titleLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private var onClear: (() -> Void)?
    private var titleTrailingWithButton: NSLayoutConstraint?
    private var titleTrailingToEdge: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupView()
    }

    private func setupView() {
        wantsLayer = true
        autoresizingMask = [.width, .height]

        self.titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        self.titleLabel.textColor = QueueRowTextColor.artist
        self.titleLabel.lineBreakMode = .byTruncatingTail
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(self.titleLabel)

        self.clearButton.title = ""
        self.clearButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear Next in Queue")
        self.clearButton.isBordered = false
        self.clearButton.bezelStyle = .regularSquare
        self.clearButton.controlSize = .mini
        self.clearButton.contentTintColor = QueueRowTextColor.detail
        self.clearButton.target = self
        self.clearButton.action = #selector(self.handleClearClick)
        self.clearButton.toolTip = String(localized: "Clear Next in Queue")
        self.clearButton.setAccessibilityLabel(String(localized: "Clear Next in Queue"))
        self.clearButton.isHidden = true
        self.clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(self.clearButton)

        let titleTrailingWithButton = self.titleLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: self.clearButton.leadingAnchor,
            constant: -8
        )
        let titleTrailingToEdge = self.titleLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor,
            constant: -12
        )
        self.titleTrailingWithButton = titleTrailingWithButton
        self.titleTrailingToEdge = titleTrailingToEdge
        titleTrailingToEdge.isActive = true

        NSLayoutConstraint.activate([
            self.titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            self.titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            self.clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            self.clearButton.centerYAnchor.constraint(equalTo: self.titleLabel.centerYAnchor),
            self.clearButton.widthAnchor.constraint(equalToConstant: 18),
            self.clearButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    /// - Parameters:
    ///   - title: The section's name.
    ///   - clearsHandQueuedSongs: Whether this section's caption carries the clear button.
    ///   - onClear: The action that empties the section.
    func configure(title: String, clearsHandQueuedSongs: Bool, onClear: (() -> Void)?) {
        self.titleLabel.stringValue = title
        self.onClear = clearsHandQueuedSongs ? onClear : nil
        self.clearButton.isHidden = !clearsHandQueuedSongs

        self.titleTrailingWithButton?.isActive = clearsHandQueuedSongs
        self.titleTrailingToEdge?.isActive = !clearsHandQueuedSongs
    }

    @objc private func handleClearClick() {
        self.onClear?()
    }
}

// MARK: - WaveformView

@available(macOS 26.0, *)
class WaveformView: NSView {
    var isAnimating: Bool = false {
        didSet {
            self.updateAnimation()
        }
    }

    var tintColor: NSColor = .systemRed {
        didSet {
            layer?.sublayers?.forEach { $0.backgroundColor = self.tintColor.cgColor }
        }
    }

    private var timer: Timer?
    private var bars: [CALayer] = []
    private var startTime: CFTimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.setupBars()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupBars()
    }

    private func setupBars() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // Create 3 bars for the waveform
        let barWidth: CGFloat = 3
        let barSpacing: CGFloat = 2
        let totalWidth = CGFloat(3) * barWidth + CGFloat(2) * barSpacing
        let startX = (bounds.width - totalWidth) / 2

        for i in 0 ..< 3 {
            let bar = CALayer()
            bar.backgroundColor = self.tintColor.cgColor
            bar.cornerRadius = 1
            bar.frame = NSRect(
                x: startX + CGFloat(i) * (barWidth + barSpacing),
                y: bounds.height / 2 - 4,
                width: barWidth,
                height: 8
            )
            layer?.addSublayer(bar)
            self.bars.append(bar)
        }
    }

    private func updateAnimation() {
        if self.isAnimating {
            self.startAnimation()
        } else {
            self.stopAnimation()
            // Reset to static middle position
            for bar in self.bars {
                bar.frame.size.height = 8
                bar.frame.origin.y = (bounds.height - 8) / 2
            }
        }
    }

    private func startAnimation() {
        guard timer == nil else { return }

        self.startTime = CACurrentMediaTime()

        // Use Timer for 30fps animation - simpler and safer than CVDisplayLink
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateBars()
            }
        }
        // Add to common run loop modes to ensure it runs during tracking/dragging
        if let timer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    private func stopAnimation() {
        self.timer?.invalidate()
        self.timer = nil
    }

    private func updateBars() {
        guard self.isAnimating else { return }

        let elapsed = CACurrentMediaTime() - self.startTime
        let barHeights: [CGFloat] = [
            4 + 8 * CGFloat(abs(sin(elapsed * 4))),
            4 + 10 * CGFloat(abs(sin(elapsed * 3 + 1))),
            4 + 6 * CGFloat(abs(sin(elapsed * 5 + 2))),
        ]

        CATransaction.begin()
        CATransaction.setDisableActions(true) // Disable implicit animations
        for (i, bar) in self.bars.enumerated() {
            let height = min(barHeights[i], bounds.height)
            bar.frame.size.height = height
            bar.frame.origin.y = (bounds.height - height) / 2
        }
        CATransaction.commit()
    }

    deinit {
        self.stopAnimation()
    }
}
