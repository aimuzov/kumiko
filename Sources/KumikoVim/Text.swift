/// Text as Accessibility has it, one string with offsets counted in UTF-16 units, and as Vim has
/// it, lines with columns counted in UTF-8 bytes; and the way between the two.
struct Text: Equatable {
	var lines: [String]

	init(_ string: String) {
		lines = string.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
	}

	init(lines: [String]) {
		self.lines = lines.isEmpty ? [""] : lines
	}

	var string: String { lines.joined(separator: "\n") }

	/// The UTF-16 offset of a Vim position (1-based line, byte column), clamped into the text.
	func offset(line: Int, byteColumn: Int) -> Int {
		let index = min(max(line, 1), lines.count) - 1
		let before = lines[..<index].reduce(0) { $0 + $1.utf16.count + 1 }
		let bytes = Array(lines[index].utf8)
		let prefix = String(decoding: bytes.prefix(max(0, byteColumn)), as: UTF8.self)
		return before + prefix.utf16.count
	}

	/// The Vim position (1-based line, byte column) of a UTF-16 offset, clamped into the text.
	func position(offset: Int) -> (line: Int, byteColumn: Int) {
		var remaining = max(0, offset)

		for (index, line) in lines.enumerated() {
			let length = line.utf16.count
			if remaining <= length || index == lines.count - 1 {
				let units = Array(line.utf16.prefix(min(remaining, length)))
				let prefix = String(decoding: units, as: UTF16.self)
				return (index + 1, prefix.utf8.count)
			}
			remaining -= length + 1
		}

		return (1, 0)
	}

	/// The UTF-16 length of a whole line, without its line break.
	func length(ofLine line: Int) -> Int {
		lines[min(max(line, 1), lines.count) - 1].utf16.count
	}

	/// The UTF-16 length of the character at a Vim position, 0 past the end of the line.
	func characterLength(line: Int, byteColumn: Int) -> Int {
		let text = lines[min(max(line, 1), lines.count) - 1]
		let bytes = Array(text.utf8)
		guard byteColumn < bytes.count else { return 0 }
		let rest = String(decoding: bytes[byteColumn...], as: UTF8.self)
		return rest.first.map { String($0).utf16.count } ?? 0
	}
}
