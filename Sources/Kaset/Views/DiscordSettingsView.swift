import AppKit
import SwiftUI

// MARK: - DiscordSettingsView

/// Settings for Discord Rich Presence.
///
/// Laid out like the scrobbling rows — an on switch, a connection status and one action — because
/// it answers the same question ("is my listening being reported, and to whom?"). There is no
/// account to sign into: Discord's card is set on the client running on this Mac, so the
/// "connection" is to that client.
///
/// Every state says what to do next: Discord closed offers to open it, a missing helper names the
/// fix, and a connected row that has nothing to share says so instead of looking broken.
@available(macOS 26.0, *)
struct DiscordSettingsView: View {
    @Environment(DiscordPresenceService.self) private var presence
    @State private var settings = SettingsManager.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show what I'm listening to on Discord", isOn: self.enabledBinding)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            self.statusDot
                            Text("Discord")
                                .font(.headline)
                        }
                        Text(self.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                            .padding(.leading, Self.dotInset)
                        if let hint = self.statusHint {
                            Text(hint)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, Self.dotInset)
                        }
                    }
                    Spacer()
                    self.connectionButton
                }
                .padding(.vertical, 4)
                .animation(.easeInOut(duration: 0.2), value: self.presence.status)
            } footer: {
                Text("Your profile shows the track you're playing, its artists and artwork while the Discord app is running on this Mac. No Discord account is needed, and nothing is sent anywhere else.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 320)
        .navigationTitle("Discord")
        .onChange(of: self.presence.status) { _, status in
            switch status {
            case .connected: HapticService.success()
            case .failed: HapticService.error()
            default: break
            }
        }
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.discordRichPresenceEnabled },
            set: { isEnabled in
                HapticService.toggle()
                self.settings.discordRichPresenceEnabled = isEnabled
                Task {
                    if isEnabled {
                        await self.presence.ensureConnected()
                    } else {
                        await self.presence.shutdown()
                    }
                }
            }
        )
    }

    // MARK: - Status

    private var statusText: String {
        switch self.presence.status {
        case .off:
            String(localized: "Off")
        case .waitingForDiscord:
            String(localized: "Waiting for Discord")
        case .bridgeUnavailable:
            String(localized: "Presence helper missing")
        case .connecting:
            String(localized: "Connecting…")
        case .connected:
            if let track = self.presence.activity?.details {
                String(localized: "Sharing “\(track)”")
            } else {
                String(localized: "Connected")
            }
        case let .failed(message):
            String(localized: "Error: \(message)")
        }
    }

    /// What the user should do about the state above, when there is something to do.
    private var statusHint: String? {
        switch self.presence.status {
        case .off:
            String(localized: "Turn this on to show what you're playing on your Discord profile.")
        case .waitingForDiscord:
            String(localized: "Open the Discord app on this Mac to start sharing.")
        case .bridgeUnavailable:
            String(localized: "This copy of Kaset is missing the helper that reaches Discord. Reinstalling Kaset restores it.")
        case .connected where self.presence.activity == nil:
            String(localized: "Play a song and your Discord profile will show it.")
        case .connecting, .connected, .failed:
            nil
        }
    }

    /// Width of the status dot plus its gap, so the lines under the name start where it does.
    private static let dotInset: CGFloat = 13

    private var statusDot: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 7))
            .foregroundStyle(self.statusColor)
            .accessibilityHidden(true)
    }

    private var statusColor: Color {
        switch self.presence.status {
        case .off: .secondary
        case .waitingForDiscord, .bridgeUnavailable: .orange
        case .connecting: .blue
        case .connected: .green
        case .failed: .red
        }
    }

    // MARK: - Discord client

    private static let discordBundleIdentifiers = [
        "com.hnc.Discord",
        "com.hnc.DiscordPTB",
        "com.hnc.DiscordCanary",
    ]

    /// The installed desktop client, if this Mac has one. Its absence turns the button into a
    /// pointer at the download, rather than an action that silently does nothing.
    private var installedDiscord: URL? {
        Self.discordBundleIdentifiers.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    /// Brings up the client so the next connection pass finds it, or offers the download when it is
    /// not installed at all.
    private func openDiscord() {
        if let app = self.installedDiscord {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    DiagnosticsLogger.discord.error("Could not open Discord: \(error.localizedDescription, privacy: .public)")
                }
            }
            HapticService.success()
        } else if let download = URL(string: "https://discord.com/download") {
            NSWorkspace.shared.open(download)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var connectionButton: some View {
        switch self.presence.status {
        case .off:
            // The switch is the entry point; a second way to turn the same thing on would only
            // make the row look like two features.
            if self.settings.discordRichPresenceEnabled {
                Button("Connect") {
                    Task { await self.presence.ensureConnected() }
                }
            }

        case .waitingForDiscord:
            Button(self.installedDiscord == nil ? "Get Discord" : "Open Discord") {
                self.openDiscord()
            }

        case .bridgeUnavailable:
            EmptyView()

        case .failed:
            Button("Try Again") {
                HapticService.toggle()
                Task { await self.presence.ensureConnected() }
            }

        case .connecting:
            ProgressView()
                .controlSize(.small)

        case .connected:
            // Turns the feature off rather than dropping just the socket: the switch is what keeps
            // it connected, so a bare disconnect would be undone by the next connection pass.
            Button("Turn Off") {
                HapticService.toggle()
                self.settings.discordRichPresenceEnabled = false
                Task { await self.presence.shutdown() }
            }
        }
    }
}
