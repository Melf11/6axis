import CryptoKit
import XCTest
@testable import SixAxisCore

final class UpdateTests: XCTestCase {
    func testVersionOrder() {
        func v(_ s: String) -> Update.Version { Update.Version(s)! }
        XCTAssertLessThan(v("1.0.0"), v("1.0.1"))
        XCTAssertLessThan(v("v1.0.9"), v("1.0.10"))
        XCTAssertLessThan(v("0.9.0"), v("1.0"))
        XCTAssertLessThan(v("1.1.0-beta.2"), v("1.1.0"))
        XCTAssertLessThan(v("1.1.0-beta.2"), v("1.1.0-beta.10"))
        XCTAssertEqual(v("1.0"), v("1.0.0"))
        XCTAssertNil(Update.Version("dev"))
    }

    func testParseGitHubRelease() throws {
        let json = """
        {"tag_name":"v1.2.0","name":"6axis v1.2.0","body":"## Änderungen\\n- Neu","html_url":"https://github.com/Melf11/6axis/releases/tag/v1.2.0",
         "draft":false,"prerelease":false,"assets":[
           {"name":"6axis-1.2.0.dmg","browser_download_url":"https://example.org/6axis-1.2.0.dmg"},
           {"name":"6axis-1.2.0.zip","browser_download_url":"https://example.org/6axis-1.2.0.zip"},
           {"name":"6axis-1.2.0.zip.sig","browser_download_url":"https://example.org/6axis-1.2.0.zip.sig"}]}
        """
        let r = try Update.Release.parse(Data(json.utf8))
        XCTAssertEqual(r.version, Update.Version("1.2.0"))
        XCTAssertEqual(r.archive?.lastPathComponent, "6axis-1.2.0.zip")
        XCTAssertEqual(r.signature?.lastPathComponent, "6axis-1.2.0.zip.sig")
        XCTAssertTrue(r.notes.contains("Neu"))
    }

    func testReleaseWithoutSignatureHasNoSignatureURL() throws {
        let json = #"{"tag_name":"v1.0.1","html_url":"https://x.org","assets":[{"name":"6axis-1.0.1.zip","browser_download_url":"https://x.org/a.zip"}]}"#
        let r = try Update.Release.parse(Data(json.utf8))
        XCTAssertNotNil(r.archive)
        XCTAssertNil(r.signature)
    }

    func testSignatureRoundTripAndTampering() throws {
        let key = Curve25519.Signing.PrivateKey()
        let priv = key.rawRepresentation.base64EncodedString()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let data = Data("6axis update archive".utf8)
        let sig = try Update.sign(data, privateKey: priv)
        XCTAssertTrue(Update.verify(data, signature: sig, publicKey: pub))
        XCTAssertFalse(Update.verify(Data("tampered".utf8), signature: sig, publicKey: pub))
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(Update.verify(data, signature: sig, publicKey: other))
        XCTAssertFalse(Update.verify(data, signature: "kaputt", publicKey: pub))
    }
}
