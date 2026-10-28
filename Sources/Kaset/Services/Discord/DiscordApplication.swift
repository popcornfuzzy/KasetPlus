import Foundation

// MARK: - DiscordApplication

/// The Discord application Kaset's card is published under.
///
/// There is one Kaset and one application, so the id is compiled in rather than asked for: it is
/// public metadata — the same for every reader, not a secret — and nothing is gained by making
/// someone register an application of their own before their music can show up. See
/// `docs/adr/0039-discord-rich-presence.md`.
enum DiscordApplication {
    /// The Application ID from the Discord Developer Portal.
    static let id = "1564749596431880303"

    /// The application's name, which the card wears as the small image's hover text.
    static let name = "Kaset"

    /// Discord offers no "use the application's own icon" asset key, so the icon the portal holds is
    /// referenced by its CDN URL — `small_image` accepts an external URL, and Discord fetches it.
    ///
    /// The hash changes when the icon is replaced in the portal, which is the only thing that has to
    /// follow here.
    static let iconHash = "ad79145b99f3d637a47c502de0c891f9"

    static var iconURL: String {
        "https://cdn.discordapp.com/app-icons/\(self.id)/\(self.iconHash).png?size=512"
    }

    /// Where Kaset's code lives. The card's second button links here.
    static let repositoryURL = "https://github.com/popcornfuzzy/KasetPlus"
}
