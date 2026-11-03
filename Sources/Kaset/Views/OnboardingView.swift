import SwiftUI

// MARK: - OnboardingView

/// Onboarding view shown to users before they sign in.
@available(macOS 26.0, *)
struct OnboardingView: View {
    @Environment(AuthService.self) private var authService
    @State private var showLoginSheet = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // App icon and title
            VStack(spacing: 16) {
                CassetteIcon(size: 80)
                    .foregroundStyle(.tint)

                Text("Welcome to Kaset")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("A native YouTube Music experience for macOS")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()
                .frame(height: 48)

            // Features
            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(
                    icon: "text.line.last.and.arrowtriangle.forward",
                    title: "Lyrics That Keep Up",
                    description: "Synced, word-by-word lyrics in the sidebar or fullscreen"
                )

                FeatureRow(
                    icon: "text.badge.plus",
                    title: "One Click to a Playlist",
                    description: "Save any song to a playlist right from the player bar"
                )

                FeatureRow(
                    icon: "list.bullet.rectangle",
                    title: "Your Queue, Your Rules",
                    description: "Reorder, shuffle, and tune what plays next"
                )

                FeatureRow(
                    icon: "airplayaudio",
                    title: "Everywhere You Listen",
                    description: "Cast to a speaker, share with Discord, keep playing when the window closes"
                )

                FeatureRow(
                    icon: "keyboard.fill",
                    title: "Built for the Keyboard",
                    description: "Space to play, ⌘→ to skip, ⌘K to ask for anything"
                )
            }
            .padding(.horizontal, 60)

            Spacer()

            // Sign in button
            VStack(spacing: 12) {
                Button {
                    self.showLoginSheet = true
                } label: {
                    Text("Sign in with Google")
                        .font(.headline)
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Sign in to access your YouTube Music library")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
                .frame(height: 40)
        }
        .frame(minWidth: 500, minHeight: 500)
        .sheet(isPresented: self.$showLoginSheet) {
            LoginSheet()
        }
    }
}

// MARK: - FeatureRow

/// A row displaying a feature with icon, title, and description.
@available(macOS 26.0, *)
private struct FeatureRow: View {
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: self.icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                    .font(.headline)

                Text(self.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@available(macOS 26.0, *)
#Preview {
    OnboardingView()
        .environment(AuthService())
        .environment(WebKitManager.shared)
}
