import Foundation
import TOMLDecoder

/// The whole of `kumiko.toml`. Every key is optional in the file: a missing key takes its default,
/// so an empty file (or no file at all) is a valid configuration.
public struct Config: Equatable, Sendable {
	public var wm = WM()
	public var hotkeys = Hotkeys()
	public var bar = Bar()
	public var borders = Borders()
	public var vim = Vim()
	public var menuBar = MenuBar()
	/// `[[workspace]]` entries in file order. Empty means the default set: "1"…"9" on the main display.
	public var workspaces: [Workspace] = []

	public init() {}

	/// One `[[workspace]]`: a virtual desktop with its own layout, shown on one display at a time.
	public struct Workspace: Equatable, Sendable, Decodable {
		public var name: String
		/// Which screen it lives on: `main`, `builtin`, `external`, or part of a screen's name.
		/// A screen that is not attached falls back to the main one.
		public var display: String
		/// Patterns for app names (whole name, like `[[wm.rule]]`) whose windows open here. When
		/// several workspaces match an app, the first one in the file wins. Their order is the
		/// order of their windows in the layout, among the places those windows hold: windows of
		/// apps not listed keep theirs. It is put back when a window new to the workspace joins it
		/// and when the list changes, not when a window comes back from being minimized or hidden.
		public var apps: [String]
		/// Windows of apps no workspace names open here. Without a default workspace they open on
		/// the workspace shown where they appear.
		public var isDefault: Bool
		/// Apps whose windows on this workspace are always kept in one stack.
		public var stack: [String]
		/// Apps whose windows go after the listed apps' windows and take the very last place of
		/// the layout. Still read from older files. Reordering the apps in the settings window
		/// moves such an app to the end of `apps` and out of here: from then on it takes the last
		/// of the listed apps' places, which need not be the last place.
		public var last: [String]
		/// The share of its split a window of the app gets when it joins the layout, or when this
		/// changes. An app without one splits evenly.
		public var share: [String: Double]

		/// What a file with no `[[workspace]]` gets: "1"…"9" on the main display.
		public static let builtIn = (1...9).map { Workspace(name: String($0)) }

		public init(
			name: String, display: String = "main", apps: [String] = [], isDefault: Bool = false, stack: [String] = [],
			last: [String] = [], share: [String: Double] = [:]
		) {
			self.name = name
			self.display = display
			self.apps = apps
			self.isDefault = isDefault
			self.stack = stack
			self.last = last
			self.share = share
		}

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			name = try container.decode(String.self, forKey: .name)
			display = try container.decodeIfPresent(String.self, forKey: .display) ?? "main"
			apps = try container.decodeIfPresent([String].self, forKey: .apps) ?? []
			isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
			stack = try container.decodeIfPresent([String].self, forKey: .stack) ?? []
			last = try container.decodeIfPresent([String].self, forKey: .last) ?? []
			share = try container.decodeIfPresent([String: Double].self, forKey: .share) ?? [:]
		}

		private enum CodingKeys: String, CodingKey {
			case name, display, apps, stack, last, share
			case isDefault = "default"
		}
	}

	/// `[bar]`: the status bar, one per display.
	public struct Bar: Equatable, Sendable, Decodable {
		/// `dock` magnifies the app icons exactly when the Dock is set to magnify its own.
		public enum Magnification: String, Sendable, Decodable { case dock, on, off }

		/// The bar's height at scale 1: what its items need.
		public static let baseHeight = 36.0

		public var enabled = true
		/// Height of the bar; the window manager keeps this much of the screen free for it. Never less
		/// than the scaled items need, whatever the file says, so a larger scale cannot push the bar
		/// over the windows.
		public var height: Double {
			get { max(fileHeight, minimumHeight) }
			set { fileHeight = newValue }
		}
		private var fileHeight = baseHeight
		/// How large the items are drawn: their text, icons and the space between them.
		public var scale = 1.0
		/// In whole points. A scale written short of its fraction, like 1.1667 for 7/6, is 42.0012 and
		/// makes 42; anything further from a whole point is rounded up, so the items still fit.
		public var minimumHeight: Double {
			let exact = Self.baseHeight * scale
			return abs(exact - exact.rounded()) < 0.01 ? exact.rounded() : exact.rounded(.up)
		}
		/// Space between the screen edges and the outermost items.
		public var padding = 4.0
		/// Empty means the font of the macOS menu bar, which is what the bar looks like by default.
		public var font = ""
		/// 0 means the size of the menu bar font.
		public var fontSize = 0.0
		/// App icons grow under the pointer, the way the Dock's do.
		public var magnification = Magnification.dock
		/// How tall an icon right under the pointer grows, in points. 0 grows it as much as the Dock
		/// grows its own; either way no taller than 128, the Dock's largest. It grows over the windows.
		public var magnificationSize = 0.0
		/// Items from the left edge inward.
		public var left = ["workspaces", "mode", "window"]
		/// Items from the right edge inward.
		public var right = ["datetime", "caffeinate", "battery", "input"]
		/// Leave out the time, battery and input items while the macOS menu bar shows them itself.
		public var followMenuBar = true
		/// Turn the battery and the input menu off in the macOS menu bar and make its clock analog, so
		/// the bar shows them; off puts back what was there before. On unless turned off: the bar is
		/// where kumiko shows them.
		public var takeFromMenuBar = true
		/// `[bar.colors]`: the palette items draw with, Catppuccin Macchiato unless overridden.
		public var colors = Palette()
		/// `[bar.input]`: text to show for an input source id instead of the system badge.
		public var input: [String: String] = [:]
		/// `[[bar.shell]]`: items that show what a shell command prints.
		public var shell: [ShellItem] = []

		public init() {}

		public struct Palette: Equatable, Sendable, Decodable {
			public var black = try! Color.parse("0xff181926")
			public var white = try! Color.parse("0xeeffffff")
			public var red = try! Color.parse("0xffed8796")
			public var green = try! Color.parse("0xffa6da95")
			public var blue = try! Color.parse("0xff8aadf4")
			public var yellow = try! Color.parse("0xffeed49f")
			public var orange = try! Color.parse("0xfff5a97f")
			public var magenta = try! Color.parse("0xffc6a0f6")
			public var grey = try! Color.parse("0xddc6d0f5")
			/// Background of the workspace shown on the display.
			public var active = try! Color.parse("0x50c6d0f5")
			/// Background of the bar itself.
			public var background = try! Color.parse("0x00000000")
			/// Text colour; nil follows the menu bar, light or dark with the system.
			public var text: Color?

			public init() {}

			public init(from decoder: any Decoder) throws {
				let container = try decoder.container(keyedBy: CodingKeys.self)
				func color(_ key: CodingKeys, _ fallback: Color) throws -> Color {
					guard let text = try container.decodeIfPresent(String.self, forKey: key) else { return fallback }
					do { return try Color.parse(text) } catch { throw error }
				}
				let defaults = Palette()
				black = try color(.black, defaults.black)
				white = try color(.white, defaults.white)
				red = try color(.red, defaults.red)
				green = try color(.green, defaults.green)
				blue = try color(.blue, defaults.blue)
				yellow = try color(.yellow, defaults.yellow)
				orange = try color(.orange, defaults.orange)
				magenta = try color(.magenta, defaults.magenta)
				grey = try color(.grey, defaults.grey)
				active = try color(.active, defaults.active)
				background = try color(.background, defaults.background)
				if let value = try container.decodeIfPresent(String.self, forKey: .text) {
					do { text = try Color.parse(value) } catch { throw error }
				}
			}

			private enum CodingKeys: String, CodingKey {
				case black, white, red, green, blue, yellow, orange, magenta, grey, active, background, text
			}
		}

		/// One `[[bar.shell]]`: runs `command` every `interval` seconds and shows its first line.
		public struct ShellItem: Equatable, Sendable, Decodable {
			public var name: String
			public var command: String
			public var interval: Double

			public init(name: String, command: String, interval: Double = 30) {
				self.name = name
				self.command = command
				self.interval = interval
			}

			public init(from decoder: any Decoder) throws {
				let container = try decoder.container(keyedBy: CodingKeys.self)
				name = try container.decode(String.self, forKey: .name)
				command = try container.decode(String.self, forKey: .command)
				interval = try container.decodeIfPresent(Double.self, forKey: .interval) ?? 30
			}

			private enum CodingKeys: String, CodingKey { case name, command, interval }
		}

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			let defaults = Bar()
			enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
			height = try container.decodeIfPresent(Double.self, forKey: .height) ?? defaults.height
			scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? defaults.scale
			padding = try container.decodeIfPresent(Double.self, forKey: .padding) ?? defaults.padding
			font = try container.decodeIfPresent(String.self, forKey: .font) ?? defaults.font
			fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? defaults.fontSize
			magnification = try container.decodeIfPresent(Magnification.self, forKey: .magnification)
				?? defaults.magnification
			magnificationSize = try container.decodeIfPresent(Double.self, forKey: .magnificationSize)
				?? defaults.magnificationSize
			left = try container.decodeIfPresent([String].self, forKey: .left) ?? defaults.left
			right = try container.decodeIfPresent([String].self, forKey: .right) ?? defaults.right
			followMenuBar = try container.decodeIfPresent(Bool.self, forKey: .followMenuBar) ?? defaults.followMenuBar
			takeFromMenuBar = try container.decodeIfPresent(Bool.self, forKey: .takeFromMenuBar)
				?? defaults.takeFromMenuBar
			colors = try container.decodeIfPresent(Palette.self, forKey: .colors) ?? defaults.colors
			input = try container.decodeIfPresent([String: String].self, forKey: .input) ?? defaults.input
			shell = try container.decodeIfPresent([ShellItem].self, forKey: .shell) ?? []
		}

		private enum CodingKeys: String, CodingKey {
			case enabled, height, scale, padding, font, left, right, colors, input, shell, magnification
			case fontSize = "font_size"
			case magnificationSize = "magnification_size"
			case followMenuBar = "follow_menu_bar"
			case takeFromMenuBar = "take_from_menu_bar"
		}
	}

	/// `[vim]`: Vim modes in any text field, the way SketchyVim does them.
	public struct Vim: Equatable, Sendable, Decodable {
		/// Off unless asked for: it changes what escape does in every text field.
		public var enabled = false
		/// Apps where Vim stays out of the way: terminals and editors with their own Vim.
		public var blacklist: [String] = []
		/// Vim commands run at start, svimrc style: `["set langmap=..."]`.
		public var commands: [String] = []

		public init() {}

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
			blacklist = try container.decodeIfPresent([String].self, forKey: .blacklist) ?? []
			commands = try container.decodeIfPresent([String].self, forKey: .commands) ?? []
		}

		private enum CodingKeys: String, CodingKey {
			case enabled, blacklist, commands
		}
	}

	/// `[menubar]`: hiding status items of the macOS menu bar, the way Ice does it.
	public struct MenuBar: Equatable, Sendable, Decodable {
		/// Off unless asked for: it adds two items to the menu bar and would fight another menu
		/// bar manager over them.
		public var enabled = false
		/// Seconds after which shown items hide again; 0 leaves them shown.
		public var rehide = 0.0

		public init() {}

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
			rehide = try container.decodeIfPresent(Double.self, forKey: .rehide) ?? 0
		}

		private enum CodingKeys: String, CodingKey {
			case enabled, rehide
		}
	}

	/// `[borders]`: a frame around the focused window.
	public struct Borders: Equatable, Sendable, Decodable {
		public var enabled = true
		/// Thickness in points, drawn outside the window.
		public var width = 4.0
		/// nil follows the accent colour of System Settings: no key, or `color = "accent"`, which is
		/// how the settings window gives the accent back without removing the key.
		public var color: Color?
		/// The colour of a frame that is not in the accent and has none picked for it: the blue of
		/// the bar's palette, which kumiko's frames were before they followed the accent.
		public static let ownColor = try! Color.parse("#8aadf4")
		/// Apps whose windows get no frame: games, mirroring.
		public var blacklist: [String] = []

		public init() {}

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
			width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 4
			blacklist = try container.decodeIfPresent([String].self, forKey: .blacklist) ?? []

			if let text = try container.decodeIfPresent(String.self, forKey: .color), text.lowercased() != "accent" {
				do { color = try Color.parse(text) } catch { throw error }
			}
		}

		private enum CodingKeys: String, CodingKey {
			case enabled, width, color, blacklist
		}
	}

	/// `[hotkeys]`: key bindings, modes and key remaps.
	public struct Hotkeys: Equatable, Sendable, Decodable {
		public var enabled = true
		/// Apps in front of which no hotkey or remap works: a remote desktop, a game.
		public var blacklist: [String] = []
		/// A shell command run on every mode change, with the new mode in `$KUMIKO_MODE`.
		public var onModeChange: String?
		/// `[hotkeys.bind]`: the bindings of the default mode.
		public var bindings: [KeyCombo: HotkeyAction] = [:]
		/// `[hotkeys.global]`: bindings that work in every mode, after the mode's own.
		public var global: [KeyCombo: HotkeyAction] = [:]
		/// `[hotkeys.mode.<name>]`: the other modes. Keys a mode does not bind are swallowed while
		/// it is on, and escape leaves a mode that binds no way out.
		public var modes: [String: [KeyCombo: HotkeyAction]] = [:]

		public init() {}

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
			blacklist = try container.decodeIfPresent([String].self, forKey: .blacklist) ?? []
			onModeChange = try container.decodeIfPresent(String.self, forKey: .onModeChange)
			bindings = try Self.combos(container.decodeIfPresent([String: HotkeyAction].self, forKey: .bindings) ?? [:])
			global = try Self.combos(container.decodeIfPresent([String: HotkeyAction].self, forKey: .global) ?? [:])

			let modes = try container.decodeIfPresent([String: [String: HotkeyAction]].self, forKey: .modes) ?? [:]
			self.modes = try modes.mapValues(Self.combos)
		}

		private static func combos(_ table: [String: HotkeyAction]) throws -> [KeyCombo: HotkeyAction] {
			var result: [KeyCombo: HotkeyAction] = [:]
			for (text, action) in table {
				let combo = try KeyCombo.parse(text)
				guard result[combo] == nil else { throw ConfigError.invalid("hotkey \"\(text)\" is bound twice") }
				result[combo] = action
			}
			return result
		}

		private enum CodingKeys: String, CodingKey {
			case enabled, blacklist, global
			case onModeChange = "on_mode_change"
			case bindings = "bind"
			case modes = "mode"
		}
	}

	/// `[wm]`: which windows kumiko arranges.
	public struct WM: Equatable, Sendable, Decodable {
		public var enabled = true
		/// Whether a window no rule speaks about is managed.
		public var manage = true
		/// Space between neighbouring windows, in points.
		public var gap = 8
		/// Space between the windows and the edges of the screen.
		public var padding = Insets(all: 4)
		/// Hide an app (like cmd-h) while none of its windows is on a shown workspace. Its windows
		/// then leave the screen corner and Mission Control instead of waiting there.
		public var hideApps = true
		/// Window shadows. Off needs the scripting addition in Dock (`kumiko sa load`), since only
		/// Dock may change other apps' windows; without it windows keep the shadow macOS gives them.
		public var shadows = true
		/// `[[workspace]]` in use. Off, every display has a single workspace of its own and all its
		/// windows are tiled there together.
		public var useWorkspaces = true
		/// `[[wm.rule]]` in use. Off, `manage` alone decides for every window.
		public var useRules = true
		/// `[[wm.rule]]` entries, in file order; for a given window the last matching one wins.
		public var rules: [WindowRule] = []

		public init(
			enabled: Bool = true, manage: Bool = true, gap: Int = 8, padding: Insets = Insets(all: 4),
			rules: [WindowRule] = []
		) {
			self.enabled = enabled
			self.manage = manage
			self.gap = gap
			self.padding = padding
			self.rules = rules
		}

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
			manage = try container.decodeIfPresent(Bool.self, forKey: .manage) ?? true
			gap = try container.decodeIfPresent(Int.self, forKey: .gap) ?? 8
			padding = try container.decodeIfPresent(Insets.self, forKey: .padding) ?? Insets(all: 4)
			hideApps = try container.decodeIfPresent(Bool.self, forKey: .hideApps) ?? true
			shadows = try container.decodeIfPresent(Bool.self, forKey: .shadows) ?? true
			useWorkspaces = try container.decodeIfPresent(Bool.self, forKey: .useWorkspaces) ?? true
			useRules = try container.decodeIfPresent(Bool.self, forKey: .useRules) ?? true
			rules = try container.decodeIfPresent([WindowRule].self, forKey: .rules) ?? []
		}

		private enum CodingKeys: String, CodingKey {
			case enabled, manage, gap, padding, shadows
			case hideApps = "hide_apps"
			case useWorkspaces = "workspaces"
			case useRules = "rules"
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
			try checkPatterns([rule.app, rule.title].compactMap(\.self), in: "wm.rule #\(index + 1)")
		}

		let modes = Set(config.hotkeys.modes.keys).union(["default"])
		let actions = [config.hotkeys.bindings, config.hotkeys.global].flatMap(\.values)
			+ config.hotkeys.modes.values.flatMap(\.values)

		for action in actions {
			if let mode = action.mode, !modes.contains(mode) {
				throw ConfigError.invalid("hotkeys: no mode \"\(mode)\"")
			}
		}

		let shellNames = config.bar.shell.map(\.name)
		let barItems = Set(["workspaces", "mode", "window", "datetime", "caffeinate", "battery", "input"] + shellNames)

		for item in config.bar.left + config.bar.right where !barItems.contains(item) {
			throw ConfigError.invalid("bar: no item \"\(item)\"")
		}

		if !(config.bar.scale > 0) {
			throw ConfigError.invalid("bar: scale must be greater than 0")
		}

		if config.bar.magnificationSize < 0 {
			throw ConfigError.invalid("bar: magnification_size must not be negative")
		}

		if config.menuBar.rehide < 0 {
			throw ConfigError.invalid("menubar: rehide must not be negative")
		}

		var names = Set<String>()

		for workspace in config.workspaces {
			guard !workspace.name.isEmpty else { throw ConfigError.invalid("workspace: empty name") }
			guard names.insert(workspace.name).inserted else {
				throw ConfigError.invalid("workspace \"\(workspace.name)\" is defined twice")
			}
			try checkPatterns(workspace.apps, in: "workspace \"\(workspace.name)\"")
		}

		return config
	}

	private static func checkPatterns(_ patterns: [String], in place: String) throws(ConfigError) {
		for pattern in patterns {
			do {
				_ = try NSRegularExpression(pattern: pattern)
			} catch {
				throw ConfigError.invalid("\(place): bad pattern \"\(pattern)\"")
			}
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

/// Space on each side of an area. In the file either one number for all sides
/// (`padding = 8`) or a table (`padding = { top = 4, bottom = 40 }`, missing sides are 0).
public struct Insets: Equatable, Sendable, Decodable {
	public var top: Int
	public var bottom: Int
	public var left: Int
	public var right: Int

	public init(top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) {
		self.top = top
		self.bottom = bottom
		self.left = left
		self.right = right
	}

	public init(all value: Int) {
		self.init(top: value, bottom: value, left: value, right: value)
	}

	public init(from decoder: any Decoder) throws {
		if let value = try? decoder.singleValueContainer().decode(Int.self) {
			self.init(all: value)
			return
		}

		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.init(
			top: try container.decodeIfPresent(Int.self, forKey: .top) ?? 0,
			bottom: try container.decodeIfPresent(Int.self, forKey: .bottom) ?? 0,
			left: try container.decodeIfPresent(Int.self, forKey: .left) ?? 0,
			right: try container.decodeIfPresent(Int.self, forKey: .right) ?? 0
		)
	}

	private enum CodingKeys: String, CodingKey {
		case top, bottom, left, right
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
		hotkeys = try container.decodeIfPresent(Hotkeys.self, forKey: .hotkeys) ?? Hotkeys()
		bar = try container.decodeIfPresent(Bar.self, forKey: .bar) ?? Bar()
		borders = try container.decodeIfPresent(Borders.self, forKey: .borders) ?? Borders()
		workspaces = try container.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
		vim = try container.decodeIfPresent(Vim.self, forKey: .vim) ?? Vim()
		menuBar = try container.decodeIfPresent(MenuBar.self, forKey: .menuBar) ?? MenuBar()
	}

	private enum CodingKeys: String, CodingKey {
		case wm, hotkeys, bar, borders, vim
		case menuBar = "menubar"
		case workspaces = "workspace"
	}
}

public enum ConfigError: Error, Equatable, CustomStringConvertible {
	case unreadable(String, String)
	case unwritable(String, String)
	case invalid(String)

	public var description: String {
		switch self {
		case let .unreadable(path, reason): "cannot read \(path): \(reason)"
		case let .unwritable(path, reason): "cannot write \(path): \(reason)"
		case let .invalid(reason): "invalid config: \(reason)"
		}
	}
}
