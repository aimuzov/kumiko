import Foundation
import KumikoCore
import Testing

struct UpdateConfigurationTests {
	private let key = Data(repeating: 1, count: 32).base64EncodedString()

	@Test func bundledAppWithHTTPSFeedAndSigningKeyCanUpdate() {
		#expect(configuration(path: "/Applications/Kumiko.app") != nil)
	}

	@Test func commandLineBuildCannotStartTheUpdater() {
		#expect(configuration(path: "/tmp/debug") == nil)
	}

	@Test func unsignedOrMalformedConfigurationCannotStartTheUpdater() {
		for key in ["", "not-base64", Data(repeating: 1, count: 31).base64EncodedString()] {
			#expect(configuration(path: "/Applications/Kumiko.app", key: key) == nil)
		}
		for feed in ["", "http://example.com/appcast.xml", "file:///tmp/appcast.xml", "https://"] {
			#expect(configuration(path: "/Applications/Kumiko.app", feed: feed) == nil)
		}
		#expect(UpdateConfiguration(bundleURL: URL(fileURLWithPath: "/Applications/Kumiko.app"), info: [:]) == nil)
	}

	private func configuration(path: String, key: String? = nil, feed: String = "https://example.com/appcast.xml") -> UpdateConfiguration? {
		UpdateConfiguration(bundleURL: URL(fileURLWithPath: path), info: ["SUFeedURL": feed, "SUPublicEDKey": key ?? self.key])
	}
}
