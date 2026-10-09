import CryptoKit
import Foundation

/// Update logic that needs no UI: version comparison, release metadata and signature checks.
/// The app (SixAxis/Update) does the networking and the installation.
public enum Update {
    /// Semantic version "1.2.3" (a leading "v" and a pre-release suffix like "-beta.1" are allowed).
    public struct Version: Comparable, CustomStringConvertible, Sendable {
        public let parts: [Int]
        public let prerelease: String?

        public init?(_ text: String) {
            var s = text.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
            let split = s.split(separator: "-", maxSplits: 1)
            guard let core = split.first else { return nil }
            let nums = core.split(separator: ".").map { Int($0) }
            guard !nums.isEmpty, nums.allSatisfy({ $0 != nil }) else { return nil }
            parts = nums.map { $0! }
            prerelease = split.count > 1 ? String(split[1]) : nil
        }

        public var description: String {
            parts.map(String.init).joined(separator: ".") + (prerelease.map { "-" + $0 } ?? "")
        }

        public static func < (a: Version, b: Version) -> Bool {
            for i in 0..<max(a.parts.count, b.parts.count) {
                let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
                if x != y { return x < y }
            }
            // 1.0.0-beta < 1.0.0
            switch (a.prerelease, b.prerelease) {
            case (nil, nil): return false
            case (_?, nil): return true
            case (nil, _?): return false
            case let (p?, q?): return p.compare(q, options: .numeric) == .orderedAscending
            }
        }

        public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
    }

    /// The parts of a GitHub release that matter for updating.
    public struct Release: Sendable, Equatable {
        public var version: Version
        public var tag: String
        public var name: String
        public var notes: String
        public var page: URL
        /// The app as ZIP (6axis-<version>.zip) and its detached Ed25519 signature (…zip.sig).
        public var archive: URL?
        public var signature: URL?

        public static func == (a: Release, b: Release) -> Bool { a.tag == b.tag }

        /// Parses the JSON of `GET /repos/{owner}/{repo}/releases/latest`.
        public static func parse(_ data: Data) throws -> Release {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            struct JSONRelease: Decodable {
                let tag_name: String
                let name: String?
                let body: String?
                let html_url: URL
                let draft: Bool?
                let prerelease: Bool?
                let assets: [Asset]
            }
            let r = try JSONDecoder().decode(JSONRelease.self, from: data)
            guard let version = Version(r.tag_name) else { throw KernelError("Ungültige Versionsnummer im Release") }
            let zip = r.assets.first { $0.name.hasSuffix(".zip") }
            let sig = zip.flatMap { z in r.assets.first { $0.name == z.name + ".sig" } }
            return Release(version: version, tag: r.tag_name, name: r.name ?? r.tag_name, notes: r.body ?? "",
                           page: r.html_url, archive: zip?.browser_download_url, signature: sig?.browser_download_url)
        }
    }

    /// Checks a detached Ed25519 signature (base64) of `data` against the app's public key (base64, raw 32 bytes).
    public static func verify(_ data: Data, signature: String, publicKey: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    /// Signs `data` with a private key (base64, raw 32 bytes); used by the release workflow and tests.
    public static func sign(_ data: Data, privateKey: String) throws -> String {
        guard let raw = Data(base64Encoded: privateKey.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw KernelError("Ungültiger Signaturschlüssel")
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        return try key.signature(for: data).base64EncodedString()
    }
}
