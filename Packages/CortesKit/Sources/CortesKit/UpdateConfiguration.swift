import Foundation

public enum UpdateConfiguration {
    public static let feedURL = "https://github.com/mrcat71/cortes/releases/latest/download/appcast.xml"

    public static func problem(bundleURL: URL, info: [String: Any]) -> String? {
        guard bundleURL.pathExtension == "app" else {
            return "Updates require a packaged Cortes.app."
        }
        guard info["SUFeedURL"] as? String == feedURL else {
            return "This build has no trusted Cortes update feed."
        }
        guard let text = info["SUPublicEDKey"] as? String, Data(base64Encoded: text)?.count == 32 else {
            return "Update signing is not configured for this build."
        }
        for flag in ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"] {
            guard info[flag] as? Bool == true else {
                return "This build does not enable \(flag)."
            }
        }
        guard (info["SUSignedFeedFailureExpirationInterval"] as? NSNumber)?.intValue == 0 else {
            return "This build allows unsigned update feeds after signature failures."
        }
        return nil
    }
}
