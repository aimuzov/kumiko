/// A key with modifiers, written the way skhd writes it: `cmd + ctrl - m`, `rcmd - 1`, `0x32`.
///
/// Keys are physical positions on an ANSI keyboard, not characters, so a hotkey stays where it is
/// whatever input source is active.
public struct KeyCombo: Hashable, Sendable, CustomStringConvertible {
	public var keyCode: UInt16
	public var modifiers: Set<Modifier>

	public init(keyCode: UInt16, modifiers: Set<Modifier> = []) {
		self.keyCode = keyCode
		self.modifiers = modifiers
	}

	/// `cmd`, `alt`, `ctrl` and `shift` accept either side; the `l`/`r` forms ask for one side.
	public enum Modifier: String, Hashable, Sendable, CaseIterable {
		case cmd, lcmd, rcmd
		case alt, lalt, ralt
		case ctrl, lctrl, rctrl
		case shift, lshift, rshift
		case fn

		/// The family a modifier belongs to; a combo names each family at most once.
		public var family: String {
			switch self {
			case .cmd, .lcmd, .rcmd: "cmd"
			case .alt, .lalt, .ralt: "alt"
			case .ctrl, .lctrl, .rctrl: "ctrl"
			case .shift, .lshift, .rshift: "shift"
			case .fn: "fn"
			}
		}
	}

	public var description: String {
		let names = modifiers.map(\.rawValue).sorted().joined(separator: " + ")
		let key = Self.names.first { $0.value == keyCode }?.key ?? String(format: "0x%02x", keyCode)
		return names.isEmpty ? key : "\(names) - \(key)"
	}

	public static func parse(_ text: String) throws(ConfigError) -> KeyCombo {
		let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
		let keyPart: Substring
		var modifiers = Set<Modifier>()

		// "-" alone is a valid key name; a lone dash part means there were no modifiers.
		if parts.count == 2, !parts[0].trimmingCharacters(in: .whitespaces).isEmpty {
			keyPart = parts[1]

			for name in parts[0].split(separator: "+") {
				let name = name.trimmingCharacters(in: .whitespaces).lowercased()
				guard let modifier = Modifier(rawValue: name) else {
					throw ConfigError.invalid("hotkey \"\(text)\": unknown modifier \"\(name)\"")
				}
				guard !modifiers.contains(where: { $0.family == modifier.family }) else {
					throw ConfigError.invalid("hotkey \"\(text)\": \(modifier.family) given twice")
				}
				modifiers.insert(modifier)
			}
		} else {
			keyPart = Substring(text)
		}

		let key = keyPart.trimmingCharacters(in: .whitespaces).lowercased()

		if key.hasPrefix("0x"), let code = UInt16(key.dropFirst(2), radix: 16), code < 0x80 {
			return KeyCombo(keyCode: code, modifiers: modifiers)
		}
		guard let code = names[key] else { throw ConfigError.invalid("hotkey \"\(text)\": unknown key \"\(key)\"") }
		return KeyCombo(keyCode: code, modifiers: modifiers)
	}

	/// Virtual key codes of an ANSI keyboard (Carbon's kVK_* values).
	public static let names: [String: UInt16] = [
		"a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
		"c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
		"t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
		"9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
		"[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
		"\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
		"return": 0x24, "tab": 0x30, "space": 0x31, "backspace": 0x33, "escape": 0x35, "delete": 0x75,
		"home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
		"left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
		"f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
		"f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B, "f15": 0x71,
		"f16": 0x6A, "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
	]
}

/// What a hotkey does. In the file either a kumiko command as a string — `"window focus west"`,
/// with `||` to try the next one when a command fails — or a table:
/// `{ run = "...", shell = "...", mode = "move", send = "shift - 0x32", block = true }`.
public struct HotkeyAction: Equatable, Sendable, Decodable {
	/// A kumiko command, the same words the CLI takes.
	public var run: String?
	/// A shell command, run with /bin/sh in the background.
	public var shell: String?
	/// The mode to switch to, after the commands.
	public var mode: String?
	/// Another key the press turns into, instead of doing anything itself.
	public var send: KeyCombo?
	/// Swallow the key and do nothing, to take a system shortcut away.
	public var block: Bool

	public init(run: String? = nil, shell: String? = nil, mode: String? = nil, send: KeyCombo? = nil, block: Bool = false) {
		self.run = run
		self.shell = shell
		self.mode = mode
		self.send = send
		self.block = block
	}

	public init(from decoder: any Decoder) throws {
		if let command = try? decoder.singleValueContainer().decode(String.self) {
			self.init(run: command)
			return
		}

		let container = try decoder.container(keyedBy: CodingKeys.self)
		let send = try container.decodeIfPresent(String.self, forKey: .send)

		self.init(
			run: try container.decodeIfPresent(String.self, forKey: .run),
			shell: try container.decodeIfPresent(String.self, forKey: .shell),
			mode: try container.decodeIfPresent(String.self, forKey: .mode),
			send: try send.map { text in
				do { return try KeyCombo.parse(text) } catch { throw error }
			},
			block: try container.decodeIfPresent(Bool.self, forKey: .block) ?? false
		)
	}

	private enum CodingKeys: String, CodingKey {
		case run, shell, mode, send, block
	}
}
