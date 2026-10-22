/// A key press as Vim takes it: typed text, or a key in Vim's `<...>` notation.
enum VimInput: Equatable {
	case text(String)
	case key(String)
}

enum Keys {
	/// Keys with a name in Vim's notation, by ANSI virtual key code.
	private static let named: [UInt16: String] = [
		0x35: "<Esc>", 0x24: "<CR>", 0x4C: "<CR>", 0x30: "<Tab>", 0x33: "<BS>", 0x75: "<Del>",
		0x7B: "<Left>", 0x7C: "<Right>", 0x7D: "<Down>", 0x7E: "<Up>",
		0x73: "<Home>", 0x77: "<End>", 0x74: "<PageUp>", 0x79: "<PageDown>",
	]

	/// Letters and the few punctuation keys Vim has control chords for, by key code, so that
	/// ctrl-r is <C-r> whatever input source is active.
	private static let controllable: [UInt16: String] = [
		0x00: "a", 0x0B: "b", 0x08: "c", 0x02: "d", 0x0E: "e", 0x03: "f", 0x05: "g", 0x04: "h", 0x22: "i",
		0x26: "j", 0x28: "k", 0x25: "l", 0x2E: "m", 0x2D: "n", 0x1F: "o", 0x23: "p", 0x0C: "q", 0x0F: "r",
		0x01: "s", 0x11: "t", 0x20: "u", 0x09: "v", 0x0D: "w", 0x07: "x", 0x10: "y", 0x06: "z",
		0x21: "[", 0x1E: "]",
	]

	/// What a key press means to Vim. `characters` is what the press types in the current input
	/// source, shift included; Vim's langmap turns other alphabets into commands. Returns nil for a
	/// press Vim has no use for.
	static func translate(keyCode: UInt16, characters: String?, control: Bool) -> VimInput? {
		if control {
			guard let letter = controllable[keyCode] else { return nil }
			// ctrl-[ is how a lot of people type escape.
			return letter == "[" ? .key("<Esc>") : .key("<C-\(letter)>")
		}

		if let name = named[keyCode] { return .key(name) }

		guard let characters, !characters.isEmpty, characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else {
			return nil
		}
		return .text(characters)
	}
}
