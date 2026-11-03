import SwiftUI

// MARK: - OfflineBanner

/// A slim, non-blocking notice that the network is gone.
///
/// Pages keep whatever they last loaded underneath it, so a brief drop does not replace the reader's
/// library or feed with an error screen.
@available(macOS 26.0, *)
struct OfflineBanner: View {
    @State private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        Group {
            if !self.networkMonitor.isConnected {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 12, weight: .semibold))

                    Text("You're offline. Showing saved content.")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: self.networkMonitor.isConnected)
    }
}
