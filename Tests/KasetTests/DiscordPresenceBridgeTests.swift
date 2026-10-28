import Foundation
import Testing
@testable import Kaset

/// The only part of the helper worth testing without launching anything is where Kaset looks for it.
/// `swift test` runs without Kaset.app, so a build with no helper must report none rather than
/// offering to start something that is not there.
@Suite(.serialized, .tags(.service))
struct DiscordPresenceBridgeTests {
    @Test("A build without a helper reports none, so the settings row can say it is unavailable")
    func reportsMissingHelper() throws {
        let app = try self.makeAppBundle(withHelper: false)
        defer { try? FileManager.default.removeItem(at: app) }

        #expect(DiscordPresenceBridge.helperURL(inAppBundle: app) == nil)
    }

    @Test("The bundled helper is found where Kaset launches it from")
    func findsBundledHelper() throws {
        let app = try self.makeAppBundle(withHelper: true)
        defer { try? FileManager.default.removeItem(at: app) }

        let helper = try #require(DiscordPresenceBridge.helperURL(inAppBundle: app))
        #expect(helper.lastPathComponent == "\(DiscordPresenceBridge.helperName).app")
        #expect(helper.deletingLastPathComponent().lastPathComponent == "Helpers")
    }

    // MARK: - Helpers

    private func makeAppBundle(withHelper: Bool) throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaset-launcher-\(UUID().uuidString.prefix(6))", isDirectory: true)
            .appendingPathComponent("Kaset.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        if withHelper {
            let helper = app.appendingPathComponent(
                "Contents/Helpers/\(DiscordPresenceBridge.helperName).app",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        }

        return app
    }
}
