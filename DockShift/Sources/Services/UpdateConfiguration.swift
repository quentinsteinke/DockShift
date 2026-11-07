import Foundation

enum UpdateConfiguration {
    static func problem(in info: [String: Any]) -> String? {
        var allowedSchemes: Set<String> = ["https"]
        #if DEBUG
        // Only the disposable UI fixture can reach a loopback HTTP test server. Shipped
        // Release builds have no feed override or transport-security exception.
        if info["CFBundleIdentifier"] as? String == "com.quentinsteinke.DockShift.UpdaterTest",
           let value = info["SUFeedURL"] as? String,
           URL(string: value)?.host == "127.0.0.1" {
            allowedSchemes.insert("http")
        }
        #endif
        guard let value = info["SUFeedURL"] as? String,
              let url = URL(string: value), allowedSchemes.contains(url.scheme ?? ""), url.host != nil,
              url.user == nil, url.password == nil else {
            return "This build has no secure update feed configured."
        }
        guard let value = info["SUPublicEDKey"] as? String,
              let key = Data(base64Encoded: value), key.count == 32,
              key.contains(where: { $0 != 0 }) else {
            return "Updates aren’t configured for this build yet."
        }
        guard info["SURequireSignedFeed"] as? Bool == true,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true else {
            return "This build is missing update signature checks."
        }
        return nil
    }
}
