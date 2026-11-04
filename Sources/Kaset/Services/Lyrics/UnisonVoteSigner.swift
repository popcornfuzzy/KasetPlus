import CryptoKit
import Foundation
import Security

// MARK: - UnisonVoteKeyStore

/// Where the Unison vote signing key is kept.
///
/// The private key *is* the listener's Unison identity — every vote is a signed
/// request and the server derives the voter from the key — so it belongs in the
/// Keychain, not in defaults or the lyrics cache.
protocol UnisonVoteKeyStore: Sendable {
    /// The stored 32-byte P-256 scalar, or `nil` before the first vote.
    func loadPrivateKey() -> Data?
    func savePrivateKey(_ rawRepresentation: Data)
}

// MARK: - KeychainUnisonVoteKeyStore

/// Keychain-backed store, following the same service/account convention as
/// `KeychainCredentialStore`.
struct KeychainUnisonVoteKeyStore: UnisonVoteKeyStore {
    private static let service = "com.sertacozercan.Kaset"
    private static let account = "com.sertacozercan.Kaset.unisonVoteKey"

    func loadPrivateKey() -> Data? {
        // UI tests must not touch the real Keychain: the freshly built app is
        // signed differently from the item's owner, so macOS would ask the user
        // to allow access. Same rule as `KeychainCredentialStore`.
        guard !UITestConfig.isUITestMode else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func savePrivateKey(_ rawRepresentation: Data) {
        guard !UITestConfig.isUITestMode else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}

// MARK: - UnisonJSONValue

/// The JSON value kinds a signed Unison payload uses.
///
/// Numbers stay integers: Unison hashes the canonical *text* of the payload, and
/// `1` and `1.0` are different text.
enum UnisonJSONValue: Equatable {
    case string(String)
    case integer(Int64)
    case object([String: UnisonJSONValue])

    /// Unison's canonical JSON: object keys sorted, no whitespace, and
    /// members whose value is `undefined` omitted (this type has no such case).
    var canonicalJSON: String {
        switch self {
        case let .string(value):
            return "\"\(Self.quotedContent(value))\""
        case let .integer(value):
            return String(value)
        case let .object(members):
            let body = members.keys.sorted().map { key in
                "\"\(Self.quotedContent(key))\":\(members[key]?.canonicalJSON ?? "null")"
            }
            return "{\(body.joined(separator: ","))}"
        }
    }

    /// The value as `JSONSerialization` takes it. Only the payload is signed, so
    /// the order the body is written in does not matter.
    var rawValue: Any {
        switch self {
        case let .string(value): value
        case let .integer(value): NSNumber(value: value)
        case let .object(members): members.mapValues(\.rawValue)
        }
    }

    private static func quotedContent(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
    }
}

// MARK: - UnisonVoteSigner

/// Builds the signed request bodies Unison requires for its write endpoints.
///
/// Kaset is not the Better Lyrics browser extension, so it owns its own ECDSA
/// P-256 key: the public key rides along with the first signed request and
/// Unison registers it, which makes that key the listener's stable Unison
/// identity. Only the payload (`keyId`, `timestamp`, `nonce`, and the action's
/// own fields) is signed, as canonical JSON; the signature is the raw 64-byte
/// `r‖s` pair Web Crypto verifies.
final class UnisonVoteSigner: @unchecked Sendable {
    private let store: any UnisonVoteKeyStore
    private let lock = NSLock()
    private var cachedKey: P256.Signing.PrivateKey?

    init(store: any UnisonVoteKeyStore = KeychainUnisonVoteKeyStore()) {
        self.store = store
    }

    /// SHA-256 of the key's canonical JWK, as 64 lowercase hex characters —
    /// Unison's `keyId`. Sent as `x-key-id` to have reads include the
    /// listener's own vote.
    var keyID: String {
        Self.keyID(for: self.privateKey().publicKey)
    }

    /// The signed body for a vote (`vote` present) or for removing one
    /// (`vote` omitted, sent with `DELETE`).
    func signedBody(vote: LyricsVoteDirection?) throws -> Data {
        let key = self.privateKey()
        var payload: [String: UnisonJSONValue] = [
            "keyId": .string(Self.keyID(for: key.publicKey)),
            "timestamp": .integer(Int64((Date().timeIntervalSince1970 * 1000).rounded())),
            // Hex UUID: 32 characters, unique per request, which is what the
            // server's replay cache needs (it requires at least 16).
            "nonce": .string(UUID().uuidString.replacingOccurrences(of: "-", with: "")),
        ]
        if let vote {
            payload["vote"] = .integer(Int64(vote.rawValue))
        }

        let canonical = UnisonJSONValue.object(payload).canonicalJSON
        let signature = try key.signature(for: Data(canonical.utf8))

        let body: [String: Any] = [
            "payload": payload.mapValues(\.rawValue),
            "signature": signature.rawRepresentation.base64EncodedString(),
            "publicKey": Self.jwk(for: key.publicKey),
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Key

    private func privateKey() -> P256.Signing.PrivateKey {
        self.lock.lock()
        defer { self.lock.unlock() }

        if let cachedKey { return cachedKey }

        if let raw = self.store.loadPrivateKey(),
           let stored = try? P256.Signing.PrivateKey(rawRepresentation: raw)
        {
            self.cachedKey = stored
            return stored
        }

        // A key that has never been registered: the next signed request carries
        // its public key, and the identity is stable from then on.
        let key = P256.Signing.PrivateKey()
        self.store.savePrivateKey(key.rawRepresentation)
        self.cachedKey = key
        return key
    }

    // MARK: - Encoding

    /// Unison's `keyId`: the SHA-256 of the canonical public-key JWK, in hex.
    static func keyID(for publicKey: P256.Signing.PublicKey) -> String {
        let canonical = UnisonJSONValue.object(
            self.jwk(for: publicKey).mapValues(UnisonJSONValue.string)
        ).canonicalJSON
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The members that define the key's identity, in JWK spelling.
    private static func jwk(for publicKey: P256.Signing.PublicKey) -> [String: String] {
        let coordinates = publicKey.x963Representation.dropFirst() // 0x04 ‖ X ‖ Y
        return [
            "crv": "P-256",
            "kty": "EC",
            "x": self.base64URL(Data(coordinates.prefix(32))),
            "y": self.base64URL(Data(coordinates.dropFirst(32))),
        ]
    }

    /// JWK coordinates are base64url without padding.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
