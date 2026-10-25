import Foundation
import Testing
@testable import CortesKit

struct UpdateConfigurationTests {
    private var valid: [String: Any] {
        [
            "SUFeedURL": UpdateConfiguration.feedURL,
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "SUVerifyUpdateBeforeExtraction": true,
            "SURequireSignedFeed": true,
            "SUSignedFeedFailureExpirationInterval": 0,
        ]
    }

    @Test func acceptsConfiguredApp() {
        #expect(UpdateConfiguration.problem(bundleURL: URL(fileURLWithPath: "/Applications/Cortes.app"), info: valid) == nil)
    }

    @Test(arguments: ["SUFeedURL", "SUPublicEDKey", "SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed", "SUSignedFeedFailureExpirationInterval"])
    func rejectsMissingConfiguration(key: String) {
        var info = valid
        info.removeValue(forKey: key)
        #expect(UpdateConfiguration.problem(bundleURL: URL(fileURLWithPath: "/Applications/Cortes.app"), info: info) != nil)
    }

    @Test(arguments: ["", "invalid", Data(repeating: 1, count: 31).base64EncodedString()])
    func rejectsInvalidKeys(key: String) {
        var info = valid
        info["SUPublicEDKey"] = key
        #expect(UpdateConfiguration.problem(bundleURL: URL(fileURLWithPath: "/Applications/Cortes.app"), info: info) != nil)
    }

    @Test func rejectsUntrustedFeedAndDisabledVerification() {
        for (key, value) in [
            ("SUFeedURL", "https://example.com/appcast.xml" as Any),
            ("SURequireSignedFeed", false),
            ("SUVerifyUpdateBeforeExtraction", false),
            ("SUSignedFeedFailureExpirationInterval", 1728000),
        ] {
            var info = valid
            info[key] = value
            #expect(UpdateConfiguration.problem(bundleURL: URL(fileURLWithPath: "/Applications/Cortes.app"), info: info) != nil)
        }
        #expect(UpdateConfiguration.problem(bundleURL: URL(fileURLWithPath: "/tmp/cortes-cli"), info: valid) != nil)
    }
}
