import Foundation

/// Where kumiko keeps its files. Everything is derived from the home directory so that tests
/// and a second instance can point the whole set elsewhere with one argument.
public struct Paths: Sendable {
	public let configDirectory: URL
	public let socket: URL

	public var configFile: URL {
		configDirectory.appending(path: "kumiko.toml")
	}

	public init(configDirectory: URL, socket: URL) {
		self.configDirectory = configDirectory
		self.socket = socket
	}

	/// `$XDG_CONFIG_HOME/kumiko`, falling back to `~/.config/kumiko`; the socket lives in `~/.cache`.
	public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
		let home = FileManager.default.homeDirectoryForCurrentUser
		let configHome = environment["XDG_CONFIG_HOME"].map { URL(filePath: $0) } ?? home.appending(path: ".config")

		return Paths(
			configDirectory: configHome.appending(path: "kumiko"),
			socket: home.appending(path: ".cache/kumiko.sock")
		)
	}
}
