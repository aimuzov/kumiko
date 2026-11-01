import Foundation

public struct UpdateConfiguration {
	public let feedURL: URL
	public let publicKey: Data

	public init?(bundleURL: URL, info: [String: Any]) {
		guard bundleURL.pathExtension == "app",
			let feed = info["SUFeedURL"] as? String,
			let feedURL = URL(string: feed), feedURL.scheme == "https",
			let host = feedURL.host, !host.isEmpty,
			let key = info["SUPublicEDKey"] as? String,
			let publicKey = Data(base64Encoded: key), publicKey.count == 32
		else { return nil }
		self.feedURL = feedURL
		self.publicKey = publicKey
	}
}
