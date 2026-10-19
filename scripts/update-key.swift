// Ed25519 keys for signed updates (CryptoKit).
//   swift scripts/update-key.swift generate <private-key-file>   → writes the private key (mode 600), prints the public key
//   swift scripts/update-key.swift sign <file>                   → reads UPDATE_SIGNING_KEY, writes <file>.sig (base64)
//   swift scripts/update-key.swift verify <file> [public-key]    → checks <file>.sig (key default: Resources/update-public-key.txt)
import CryptoKit
import Foundation

let args = CommandLine.arguments
func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

switch args.count > 1 ? args[1] : "" {
case "generate":
    guard args.count > 2 else { fail("usage: update-key.swift generate <private-key-file>") }
    let key = Curve25519.Signing.PrivateKey()
    let path = args[2]
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) exists – refusing to overwrite a signing key") }
    FileManager.default.createFile(atPath: path, contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
                                   attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count > 2 else { fail("usage: update-key.swift sign <file>") }
    guard let b64 = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"],
          let raw = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("UPDATE_SIGNING_KEY missing or invalid") }
    guard let data = FileManager.default.contents(atPath: args[2]) else { fail("cannot read \(args[2])") }
    let sig = try key.signature(for: data).base64EncodedString()
    try (sig + "\n").write(toFile: args[2] + ".sig", atomically: true, encoding: .utf8)
    print("signed \(args[2])")
case "verify":
    guard args.count > 2 else { fail("usage: update-key.swift verify <file> [public-key]") }
    let keyB64 = args.count > 3 ? args[3]
        : (try? String(contentsOfFile: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Resources/update-public-key.txt").path, encoding: .utf8)) ?? ""
    guard let raw = Data(base64Encoded: keyB64.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { fail("public key missing or invalid") }
    guard let data = FileManager.default.contents(atPath: args[2]),
          let sigText = try? String(contentsOfFile: args[2] + ".sig", encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("cannot read \(args[2]) or its .sig") }
    guard key.isValidSignature(sig, for: data) else { fail("signature INVALID: \(args[2])") }
    print("signature valid")
default:
    fail("usage: update-key.swift generate <file> | sign <file> | verify <file> [public-key]")
}
