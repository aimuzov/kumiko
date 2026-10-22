import Foundation
import TOMLDecoder

/// The whole of `kumiko.toml`. Every key is optional in the file: a missing key takes its default,
/// so an empty file (or no file at all) is a valid configuration.
public struct Config: Equatable, Sendable {
	public var wm = Module()
	public var hotkeys = Module()
	public var bar = Module()
	public var borders = Module()

	public init() {}

	/// One `[section]`. For now a section only says whether its module runs; the modules add their
	/// own keys as they arrive.
	public struct Module: Equatable, Sendable, Decodable {
		public var enabled = true

		public init(enabled: Bool = true) {
			self.enabled = enabled
		}

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
		}

		private enum CodingKeys: String, CodingKey {
			case enabled
		}
	}

	public static func parse(_ text: String) throws(ConfigError) -> Config {
		do {
			return try TOMLDecoder().decode(Config.self, from: text)
		} catch {
			throw ConfigError.invalid(String(describing: error))
		}
	}

	/// A missing file is the default configuration, not an error: kumiko must start on a machine
	/// that has never seen it.
	public static func load(from url: URL) throws(ConfigError) -> Config {
		let text: String

		do {
			text = try String(contentsOf: url, encoding: .utf8)
		} catch let error as CocoaError where error.code == .fileReadNoSuchFile {
			return Config()
		} catch {
			throw ConfigError.unreadable(url.path(percentEncoded: false), error.localizedDescription)
		}

		return try parse(text)
	}
}

extension Config: Decodable {
	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		wm = try container.decodeIfPresent(Module.self, forKey: .wm) ?? Module()
		hotkeys = try container.decodeIfPresent(Module.self, forKey: .hotkeys) ?? Module()
		bar = try container.decodeIfPresent(Module.self, forKey: .bar) ?? Module()
		borders = try container.decodeIfPresent(Module.self, forKey: .borders) ?? Module()
	}

	private enum CodingKeys: String, CodingKey {
		case wm, hotkeys, bar, borders
	}
}

public enum ConfigError: Error, Equatable, CustomStringConvertible {
	case unreadable(String, String)
	case invalid(String)

	public var description: String {
		switch self {
		case let .unreadable(path, reason): "cannot read \(path): \(reason)"
		case let .invalid(reason): "invalid config: \(reason)"
		}
	}
}
