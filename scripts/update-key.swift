// Ed25519 keys for signed updates (CryptoKit).
//   swift scripts/update-key.swift generate <private-key-file>   → writes the private key (mode 600), prints the public key
//   swift scripts/update-key.swift sign <file>                   → reads UPDATE_SIGNING_KEY, writes <file>.sig (base64)
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
default:
    fail("usage: update-key.swift generate <file> | sign <file>")
}
