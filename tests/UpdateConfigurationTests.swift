import Foundation

@main
struct UpdateConfigurationTests {
    static func main() {
        let valid: [String: Any] = [
            "SUFeedURL": "https://github.com/quentinsteinke/DockShift/releases/latest/download/appcast.xml",
            "SUPublicEDKey": Data(repeating: 17, count: 32).base64EncodedString(),
            "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true
        ]
        var passed = 0
        func check(_ name: String, _ info: [String: Any], valid expected: Bool) {
            precondition((UpdateConfiguration.problem(in: info) == nil) == expected, name)
            print("PASS: \(name)")
            passed += 1
        }
        check("valid signed HTTPS configuration", valid, valid: true)
        for (name, field, value) in [
            ("HTTP rejected", "SUFeedURL", "http://example.com/appcast.xml"),
            ("file URL rejected", "SUFeedURL", "file:///tmp/appcast.xml"),
            ("credentials in feed rejected", "SUFeedURL", "https://user:password@example.com/appcast.xml"),
            ("empty key rejected", "SUPublicEDKey", ""),
            ("malformed key rejected", "SUPublicEDKey", "invalid"),
            ("short key rejected", "SUPublicEDKey", Data(repeating: 1, count: 31).base64EncodedString()),
            ("zero key rejected", "SUPublicEDKey", Data(repeating: 0, count: 32).base64EncodedString())
        ] {
            var changed = valid; changed[field] = value
            check(name, changed, valid: false)
        }
        for field in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
            var changed = valid; changed[field] = false
            check("\(field) required", changed, valid: false)
        }
        check("missing configuration rejected", [:], valid: false)
        var fixture = valid
        fixture["CFBundleIdentifier"] = "com.quentinsteinke.DockShift.UpdaterTest"
        fixture["SUFeedURL"] = "http://127.0.0.1:8765/appcast.xml"
        #if DEBUG
        check("Debug fixture permits loopback feed", fixture, valid: true)
        #else
        check("Release fixture rejects loopback feed", fixture, valid: false)
        #endif
        fixture["SUFeedURL"] = "http://example.com/appcast.xml"
        check("fixture never permits remote HTTP", fixture, valid: false)
        print("\(passed) configuration checks passed")
    }
}
