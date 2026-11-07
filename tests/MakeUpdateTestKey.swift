import CryptoKit
import Foundation

@main
struct MakeUpdateTestKey {
    static func main() throws {
        let privateURL = URL(filePath: CommandLine.arguments[1])
        let publicURL = URL(filePath: CommandLine.arguments[2])
        let key: Curve25519.Signing.PrivateKey
        if FileManager.default.fileExists(atPath: privateURL.path) {
            let raw = try Data(contentsOf: privateURL)
            key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: raw)!)
        } else {
            key = Curve25519.Signing.PrivateKey()
            try key.rawRepresentation.base64EncodedData().write(to: privateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateURL.path)
        }
        try key.publicKey.rawRepresentation.base64EncodedData().write(to: publicURL, options: .atomic)
        print("Disposable update-test key ready; private bytes were not printed")
    }
}
