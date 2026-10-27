import Foundation

// MARK: - BridgePort

/// Where Kaset and its presence helper meet, with no channel to agree through.
///
/// Kaset starts the helper with `NSWorkspace`, and LaunchServices delivers neither arguments nor
/// environment to the launched app, and the helper cannot read anything Kaset writes (an app's
/// container belongs to that app). So both sides derive the same ports from the one thing they do
/// share: the host application's bundle identifier — Kaset knows it, and the helper reads it from
/// the bundle that contains it.
///
/// A short run of ports rather than one: the helper binds the first free port in the run and Kaset
/// tries them in order, so a port some other process holds only costs an attempt.
public enum BridgePort {
    /// How many ports the helper may use. Ten is enough to step over a chance collision.
    public static let rangeLength = 10

    /// The ports to try, in order, for an app with this identifier.
    public static func candidates(forBundleIdentifier bundleIdentifier: String) -> [UInt16] {
        let base = 49_160 + Int(self.hash(bundleIdentifier) % 8_000)
        return (0 ..< self.rangeLength).map { UInt16(base + $0) }
    }

    /// The identifier of the app whose bundle contains this helper.
    ///
    /// The helper lives at `<App>.app/Contents/Helpers/KasetPresenceBridge.app`, so the app's own
    /// `Info.plist` is three directories up from the helper's bundle.
    public static func hostBundleIdentifier(forHelperAt helperURL: URL) -> String? {
        let appInfo = helperURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Contents/Info.plist")

        guard let data = try? Data(contentsOf: appInfo),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }

    /// FNV-1a, so the same identifier yields the same ports in every process and every launch.
    private static func hash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
