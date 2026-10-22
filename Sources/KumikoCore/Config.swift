import Foundation
import TOMLDecoder

/// The whole of `kumiko.toml`. Every key is optional in the file: a missing key takes its default,
/// so an empty file (or no file at all) is a valid configuration.
public struct Config: Equatable, Sendable {
	public var wm = WM()
	public var hotkeys = Module()
	public var bar = Module()
	public var borders = Module()

	public init() {}

	/// A `[section]` of a module that has no keys of its own yet: it only says whether the module runs.
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

	/// `[wm]`: which windows kumiko arranges.
	public struct WM: Equatable, Sendable, Decodable {
		public var enabled = true
		/// Whether a window no rule speaks about is managed.
		public var manage = true
		/// `[[wm.rule]]` entries, in file order; for a given window the last matching one wins.
		public var rules: [WindowRule] = []

		public init(enabled: Bool = true, manage: Bool = true, rules: [WindowRule] = []) {
			self.enabled = enabled
			self.manage = manage
			self.rules = rules
		}

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
			manage = try container.decodeIfPresent(Bool.self, forKey: .manage) ?? true
			rules = try container.decodeIfPresent([WindowRule].self, forKey: .rules) ?? []
		}

		private enum CodingKeys: String, CodingKey {
			case enabled, manage
			case rules = "rule"
		}
	}

	public static func parse(_ text: String) throws(ConfigError) -> Config {
		let config: Config

		do {
			config = try TOMLDecoder().decode(Config.self, from: text)
		} catch {
			throw ConfigError.invalid(describe(error))
		}

		// Patterns are checked here, not when a window shows up, so a typo in one is reported on save
		// instead of silently never matching.
		for (index, rule) in config.wm.rules.enumerated() {
			for pattern in [rule.app, rule.title].compactMap(\.self) {
				do {
					_ = try NSRegularExpression(pattern: pattern)
				} catch {
					throw ConfigError.invalid("wm.rule #\(index + 1): bad pattern \"\(pattern)\"")
				}
			}
		}

		return config
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

	/// Decoding errors come wrapped in `DecodingError`, whose own text is aimed at Swift developers.
	/// The TOML parser underneath already says what and where; dig that out.
	private static func describe(_ error: any Error) -> String {
		guard let error = error as? DecodingError else { return String(describing: error) }

		switch error {
		case let .dataCorrupted(context):
			return context.underlyingError.map { String(describing: $0) } ?? context.debugDescription
		case let .typeMismatch(type, context):
			return "\(keyPath(context.codingPath)): expected \(typeName(type))"
		case let .valueNotFound(type, context):
			return "\(keyPath(context.codingPath)): expected \(typeName(type))"
		case let .keyNotFound(key, context):
			return "\(keyPath(context.codingPath + [key])): missing"
		@unknown default:
			return String(describing: error)
		}
	}

	private static func keyPath(_ path: [any CodingKey]) -> String {
		path.map { $0.intValue.map { "#\($0 + 1)" } ?? $0.stringValue }.joined(separator: ".")
	}

	private static func typeName(_ type: Any.Type) -> String {
		switch type {
		case is Bool.Type: "true or false"
		case is String.Type: "a string"
		default: String(describing: type).lowercased()
		}
	}
}

/// One `[[wm.rule]]`. A rule matches a window when every pattern it has matches; a rule with no
/// patterns matches every window.
public struct WindowRule: Equatable, Sendable, Decodable {
	/// Regular expression for the whole app name: `Code` matches Code, not Xcode.
	public var app: String?
	/// Regular expression searched anywhere in the window title.
	public var title: String?
	public var manage: Bool

	public init(app: String? = nil, title: String? = nil, manage: Bool) {
		self.app = app
		self.title = title
		self.manage = manage
	}
}

extension Config: Decodable {
	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		wm = try container.decodeIfPresent(WM.self, forKey: .wm) ?? WM()
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
