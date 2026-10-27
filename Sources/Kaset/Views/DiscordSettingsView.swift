import SwiftUI

// MARK: - DiscordSettingsView

/// Settings for Discord Rich Presence.
///
/// Laid out like the scrobbling rows — an on switch, a connection status and one action — because
/// it answers the same question ("is my listening being reported, and to whom?"). There is no
/// account to sign into: Discord's card is set on the client running on this Mac, so the
/// "connection" is to that client.
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
                        Text("Discord")
                            .font(.headline)
                        Text(self.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    self.connectionButton
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Kaset hands the card to the Discord app running on this Mac, and Discord publishes it like any other activity. Kaset itself sends nothing and needs no Discord account or password.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 320)
        .navigationTitle("Discord")
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.discordRichPresenceEnabled },
            set: { isEnabled in
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
            String(localized: "Discord isn't running")
        case .bridgeUnavailable:
            String(localized: "The presence helper isn't available")
        case .connecting:
            String(localized: "Connecting…")
        case .connected:
            String(localized: "Connected")
        case let .failed(message):
            String(localized: "Error: \(message)")
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        switch self.presence.status {
        case .off:
            Button("Connect") {
                self.settings.discordRichPresenceEnabled = true
                Task { await self.presence.ensureConnected() }
            }

        case .bridgeUnavailable:
            EmptyView()

        case .waitingForDiscord, .failed:
            Button("Try Again") {
                Task { await self.presence.ensureConnected() }
            }

        case .connecting:
            ProgressView()
                .controlSize(.small)

        case .connected:
            Button("Disconnect") {
                Task { await self.presence.shutdown() }
            }
        }
    }
}
