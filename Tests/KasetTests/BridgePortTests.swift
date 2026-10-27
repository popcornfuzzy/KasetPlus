import DiscordBridge
import Foundation
import Testing

@Suite(.tags(.service))
struct BridgePortTests {
    @Test("The two sides agree on a stable, distinct run of ports inside the fixed range")
    func portsAreStableAndDistinct() {
        let kaset = BridgePort.candidates(forBundleIdentifier: "com.popcornfuzzy.Kaset")
        let other = BridgePort.candidates(forBundleIdentifier: "com.popcornfuzzy.Kaset.Dev")

        // Stable across processes and launches: this is the whole agreement.
        #expect(kaset == BridgePort.candidates(forBundleIdentifier: "com.popcornfuzzy.Kaset"))
        #expect(kaset.count == BridgePort.rangeLength)
        #expect(kaset == kaset.sorted())
        #expect(Set(kaset).count == kaset.count)
        #expect(kaset.allSatisfy { (49_160 ... 57_168).contains($0) })

        // Two apps must not fight over one run.
        #expect(Set(kaset).isDisjoint(with: Set(other)))
    }

    @Test("The helper finds the app that contains it, and reports nothing when there is none")
    func findsHostBundleIdentifier() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-port-\(UUID().uuidString.prefix(6))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root.appendingPathComponent("Kaset.app", isDirectory: true)
        let helper = app.appendingPathComponent("Contents/Helpers/KasetPresenceBridge.app", isDirectory: true)
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)

        let info: [String: Any] = ["CFBundleIdentifier": "com.example.Host"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))

        #expect(BridgePort.hostBundleIdentifier(forHelperAt: helper) == "com.example.Host")

        let orphan = root.appendingPathComponent("Loose/Helper.app", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        #expect(BridgePort.hostBundleIdentifier(forHelperAt: orphan) == nil)
    }
}
