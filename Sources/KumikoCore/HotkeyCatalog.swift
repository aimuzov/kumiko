import Foundation

/// Names a person reads for what kumiko's commands do, and the way macOS draws a shortcut. A
/// command the catalog does not know stays as it is written: nothing is lost by showing it.
public enum HotkeyCatalog {
	/// One line for a table: "Focus window · Left", "Press ↓", "Reload config, then Default".
	public static func title(of action: HotkeyAction) -> String {
		var parts: [String] = []
		if let run = action.run { parts.append(title(ofCommand: run)) }
		if let shell = action.shell { parts.append("Run \(shell)") }
		if let send = action.send { parts.append("Press \(symbols(send))") }
		if action.block { parts.append("Do nothing") }

		guard let mode = action.mode else { return parts.isEmpty ? "Nothing" : parts.joined(separator: ", ") }
		let switchTo = "Switch to \(modeTitle(mode))"
		return parts.isEmpty ? switchTo : parts.joined(separator: ", ") + ", then \(modeTitle(mode))"
	}

	/// A command the page offers, with the argument it takes picked from `options`.
	public struct Command: Equatable, Sendable {
		public struct Option: Equatable, Sendable {
			public var title: String
			public var word: String
		}

		public var group: String
		public var title: String
		/// What the command is in the file, before its argument.
		public var words: String
		public var options: [Option]
		/// Takes a workspace's number too, up to the number of workspaces.
		public var numbered = false

		/// "Focus window · Left".
		public func title(_ option: Option?) -> String {
			option.map { "\(title) · \($0.title)" } ?? title
		}

		public func run(_ option: Option?) -> String {
			option.map { "\(words) \($0.word)" } ?? words
		}

		/// Its options for a config with this many workspaces.
		public func options(workspaces: Int) -> [Option] {
			guard numbered else { return options }
			return options + (0..<max(workspaces, 1)).map { Option(title: "\($0 + 1)", word: "\($0 + 1)") }
		}
	}

	private static func sides(_ extra: [Command.Option] = []) -> [Command.Option] {
		[
			.init(title: "Left", word: "west"), .init(title: "Right", word: "east"), .init(title: "Up", word: "north"),
			.init(title: "Down", word: "south"),
		] + extra
	}

	/// In the order of the page's menu.
	public static let commands: [Command] = [
		Command(group: "Windows", title: "Focus window", words: "window focus", options: sides([
			.init(title: "Next", word: "next"), .init(title: "Previous", word: "prev"), .init(title: "Last used", word: "recent"),
			.init(title: "Next in stack", word: "stack-next"), .init(title: "Previous in stack", word: "stack-prev"),
		])),
		Command(group: "Windows", title: "Move window", words: "window warp", options: sides()),
		Command(group: "Windows", title: "Stack window", words: "window stack", options: sides()),
		Command(group: "Windows", title: "Unstack window", words: "window unstack", options: []),
		Command(group: "Windows", title: "Float window", words: "window float", options: []),
		Command(group: "Windows", title: "Zoom window", words: "window zoom", options: [
			.init(title: "Full screen", word: "fullscreen"), .init(title: "Parent", word: "parent"),
		]),
		Command(group: "Windows", title: "Close window", words: "window close", options: []),
		Command(group: "Workspaces", title: "Show workspace", words: "workspace focus", options: [
			.init(title: "Next", word: "next"), .init(title: "Previous", word: "prev"),
		], numbered: true),
		Command(group: "Workspaces", title: "Balance workspace", words: "workspace balance", options: []),
		Command(group: "Workspaces", title: "Rotate workspace", words: "workspace rotate", options: [
			.init(title: "90°", word: "90"), .init(title: "180°", word: "180"), .init(title: "270°", word: "270"),
		]),
		Command(group: "Workspaces", title: "Mirror workspace", words: "workspace mirror", options: [
			.init(title: "Vertically", word: "vertical"), .init(title: "Horizontally", word: "horizontal"),
		]),
		Command(group: "kumiko", title: "Reload config", words: "reload", options: []),
		Command(group: "kumiko", title: "Open settings", words: "settings", options: []),
	]

	/// The catalog's command and option a command is, nil for one it does not know.
	public static func command(for run: String) -> (command: Command, option: Command.Option?)? {
		let run = run.split(separator: " ").joined(separator: " ")
		for command in commands {
			if run == command.words, command.options.isEmpty, !command.numbered { return (command, nil) }
			guard run.hasPrefix(command.words + " ") else { continue }
			let word = String(run.dropFirst(command.words.count + 1))
			if let option = command.options.first(where: { $0.word == word }) { return (command, option) }
			if command.numbered, let number = Int(word), number > 0 { return (command, .init(title: word, word: word)) }
		}
		return nil
	}

	/// Whether the catalog has a name for the command, or shows it as written.
	public static func knows(_ command: String) -> Bool {
		self.command(for: command) != nil
	}

	public static func title(ofCommand command: String) -> String {
		self.command(for: command).map { $0.command.title($0.option) } ?? command
	}

	public static func modeTitle(_ mode: String) -> String {
		mode == "default" ? "Default" : mode.prefix(1).uppercased() + mode.dropFirst()
	}

	// MARK: - Shortcuts

	/// ⌃⌥⇧⌘ in the order macOS writes them, then the key: "⌃⌘J", "R⌘1" for a right-hand ⌘.
	public static func symbols(_ combo: KeyCombo) -> String {
		let order: [(String, [KeyCombo.Modifier])] = [
			("fn ", [.fn]), ("⌃", [.ctrl, .lctrl, .rctrl]), ("⌥", [.alt, .lalt, .ralt]),
			("⇧", [.shift, .lshift, .rshift]), ("⌘", [.cmd, .lcmd, .rcmd]),
		]
		var text = ""
		for (symbol, family) in order {
			guard let modifier = family.first(where: combo.modifiers.contains) else { continue }
			let side = modifier.rawValue.hasPrefix("r") ? "R" : modifier.rawValue.hasPrefix("l") ? "L" : ""
			text += side + symbol
		}
		return text + key(combo.keyCode)
	}

	private static let keySymbols: [String: String] = [
		"return": "↩", "tab": "⇥", "space": "Space", "backspace": "⌫", "escape": "⎋", "delete": "⌦",
		"home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟", "left": "←", "right": "→", "down": "↓", "up": "↑",
	]

	private static func key(_ code: UInt16) -> String {
		// The key left of 1 on an ISO keyboard has no name in the ANSI table.
		if code == 0x0A { return "§" }
		guard let name = KeyCombo.names.first(where: { $0.value == code })?.key else { return String(format: "0x%02X", code) }
		return keySymbols[name] ?? name.uppercased()
	}
}
