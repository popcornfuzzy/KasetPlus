import SwiftUI

// MARK: - StartRadioContextMenu

/// Shared controls for starting radio: from a song, or from a playlist or album.
@available(macOS 26.0, *)
@MainActor
enum StartRadioContextMenu {
    /// The system image every radio control uses, so a page button and a context menu item read
    /// as the same action.
    static let systemImage = "dot.radiowaves.left.and.right"

    /// Creates a context menu button for starting radio based on a song.
    /// Starts playing the song immediately and loads similar songs in the background.
    static func menuItem(for song: Song, playerService: PlayerService) -> some View {
        Button {
            Task {
                await playerService.playWithRadio(song: song)
            }
        } label: {
            Label("Start Radio", systemImage: Self.systemImage)
        }
    }

    /// Starts the radio for a playlist or album — the header's "Start mix" action, which names a
    /// separate mix playlist rather than pointing at the item itself.
    /// - Parameter mixPlaylistId: The mix playlist the item's header named (`RDAMPL…`).
    static func startMix(mixPlaylistId: String, playerService: PlayerService) {
        Task {
            await playerService.playWithMix(playlistId: mixPlaylistId, startVideoId: nil)
        }
    }
}
