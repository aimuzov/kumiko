import Foundation

/// A value the settings window writes: what TOML writes on one line.
public enum TOMLValue: Equatable, Sendable {
	case bool(Bool)
	case int(Int)
	case double(Double)
	case string(String)
	/// An inline table, `{ top = 4, bottom = 40 }`, its keys in the order given.
	indirect case table([Field])
	/// `["Code", "Zed"]`, on one line.
	indirect case array([TOMLValue])

	public struct Field: Equatable, Sendable {
		public var key: String
		public var value: TOMLValue

		public init(_ key: String, _ value: TOMLValue) {
			self.key = key
			self.value = value
		}
	}

	/// How the value is spelled in the file.
	var literal: String {
		switch self {
		case let .bool(value): value ? "true" : "false"
		case let .int(value): String(value)
		// `36`, not `36.0`: that is what people write, and it still decodes as a Double.
		case let .double(value): value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
		case let .string(value): Self.quote(value)
		case let .array(values): "[" + values.map(\.literal).joined(separator: ", ") + "]"
		case let .table(fields) where fields.isEmpty: "{}"
		case let .table(fields):
			"{ " + fields.map { "\(ConfigWriter.bare($0.key)) = \($0.value.literal)" }.joined(separator: ", ") + " }"
		}
	}

	private static func quote(_ text: String) -> String {
		var result = "\""
		for scalar in text.unicodeScalars {
			switch scalar {
			case "\"": result += "\\\""
			case "\\": result += "\\\\"
			case "\n": result += "\\n"
			case "\t": result += "\\t"
			case "\r": result += "\\r"
			case _ where scalar.value < 0x20 || scalar.value == 0x7F: result += String(format: "\\u%04X", scalar.value)
			default: result.unicodeScalars.append(scalar)
			}
		}
		return result + "\""
	}
}

/// Where a key lives: a `[table]`, or one entry of an array of tables like `[[workspace]]`.
public enum ConfigTarget: Equatable, Sendable {
	case table(String)
	/// The entry at that index, 0-based, counting the array's entries in file order.
	case entry(String, Int)

	var name: String {
		switch self {
		case let .table(name), let .entry(name, _): name
		}
	}

	/// How errors name it: `wm`, `workspace #3`.
	var description: String {
		switch self {
		case let .table(name): name
		case let .entry(name, index): "\(name) #\(index + 1)"
		}
	}
}

/// One key of a `[table]` or of an array's entry set to a value, or taken out of the file.
public struct ConfigEdit: Equatable, Sendable {
	public var target: ConfigTarget
	/// The key as the file spells it: `hide_apps`, not `hideApps`.
	public var key: String
	/// nil takes the key out, and with it back to its default.
	public var value: TOMLValue?

	public init(target: ConfigTarget, key: String, value: TOMLValue?) {
		self.target = target
		self.key = key
		self.value = value
	}

	public init(table: String, key: String, value: TOMLValue?) {
		self.init(target: .table(table), key: key, value: value)
	}
}

/// A whole entry of an array of tables added, taken out or moved, its sub-tables with it. Comments
/// and blank lines between entries are no entry's: they stay where they are in the file.
public enum EntryEdit: Equatable, Sendable {
	/// After the array's last entry, or at the end of a file that has none.
	case insert(String, fields: [TOMLValue.Field])
	case remove(String, Int)
	/// `to` is the entry's index once it has moved.
	case move(String, from: Int, to: Int)
}

/// One change to kumiko.toml, text in and text out, so a single write can carry several.
public protocol ConfigChange: Sendable {
	func apply(to text: String) throws(ConfigError) -> String
}

extension ConfigEdit: ConfigChange {
	public func apply(to text: String) throws(ConfigError) -> String { try ConfigWriter.apply(self, to: text) }
}

extension EntryEdit: ConfigChange {
	public func apply(to text: String) throws(ConfigError) -> String { try ConfigWriter.apply(self, to: text) }
}

/// Changes kumiko.toml the way a person would: the line of the key gets a new value and every
/// other byte, comments and blank lines included, stays where the user put it.
///
/// It reads lines, not a TOML tree, so it knows only `[table]` sections, the entries of an array
/// of tables (`[[workspace]]`) and `key = value` lines in them. A key written any other way (dotted,
/// or inside an inline table) is refused rather than guessed at.
public enum ConfigWriter {
	public static func apply(_ changes: [any ConfigChange], to text: String) throws(ConfigError) -> String {
		var text = text
		for change in changes {
			text = try change.apply(to: text)
		}
		return text
	}

	public static func apply(_ edit: ConfigEdit, to text: String) throws(ConfigError) -> String {
		let target = [edit.target.name, edit.key]
		let place = switch edit.target {
		case .table: "\(edit.target.description).\(edit.key)"
		case .entry: "\(edit.key) of \(edit.target.description)"
		}
		let unchangeable = ConfigError.invalid(
			"\(place) is written in a way the settings window cannot change; change it in kumiko.toml"
		)
		let missing = ConfigError.invalid("there is no \(edit.target.description)")

		var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		var state = ScanState()
		var table: [String] = []
		var inSection = false
		// Entries of the array seen so far, and whether the lines now are another entry of it, whose
		// keys are as much the array's as the target's and say nothing against changing it.
		var entries = 0
		var inOtherEntry = false
		// The section's last line that belongs to a key: a new key goes after it, before any
		// comment that introduces the next section.
		var insertAfter: Int?
		var indent = ""

		for index in lines.indices {
			var line = Array(lines[index])
			let ending = line.last == "\r" ? "\r" : ""
			if !ending.isEmpty { line.removeLast() }

			// The rest of a value an earlier line opened.
			guard state.atRest else {
				_ = scan(line, from: 0, &state)
				if inSection { insertAfter = index }
				continue
			}

			guard let first = line.firstIndex(where: { $0 != " " && $0 != "\t" }), line[first] != "#" else { continue }

			if line[first] == "[" {
				let array = first + 1 < line.count && line[first + 1] == "["
				table = key(in: line, from: first + (array ? 2 : 1))?.parts ?? []

				// A sub-table, `[workspace.share]`, belongs to the last entry the file opened.
				var ofTarget = true

				switch edit.target {
				case let .table(name):
					inSection = !array && table == [name]
					inOtherEntry = false
				case let .entry(name, position):
					let isEntry = array && table == [name]
					let isSub = table.count > 1 && table[0] == name
					if isEntry { entries += 1 }
					ofTarget = !isSub || entries == position + 1
					inSection = isEntry && entries == position + 1
					inOtherEntry = isEntry ? !inSection : isSub && !ofTarget
				}

				if inSection { insertAfter = index }
				if ofTarget && table.starts(with: target) { throw unchangeable }
				continue
			}

			guard let (parts, end) = key(in: line, from: first), end < line.count, line[end] == "=" else { continue }

			let comment = scan(line, from: end + 1, &state)
			if inOtherEntry { continue }
			let path = table + parts

			if path == target && inSection {
				guard let value = edit.value else {
					// The key's line goes, and the lines of a value it spreads over with it.
					var last = index
					while !state.atRest && last + 1 < lines.count {
						last += 1
						_ = scan(Array(lines[last]), from: 0, &state)
					}
					lines.removeSubrange(index...last)
					return lines.joined(separator: "\n")
				}
				guard state.atRest else { throw unchangeable }
				let valueEnd = comment ?? line.count
				let old = line[(end + 1)..<valueEnd]
				let leading = old.prefix { $0 == " " || $0 == "\t" }
				let trailing = comment == nil ? [] : Array(old.reversed().prefix { $0 == " " || $0 == "\t" })
				lines[index] = String(line[...end]) + String(leading) + value.literal + String(trailing.reversed())
					+ String(line[valueEnd...]) + ending
				return lines.joined(separator: "\n")
			}

			// `wm = { gap = 4 }`, `wm.gap = 4` or `gap.x = 1` under `[wm]`: the key exists, just not as a line of its own.
			if path.starts(with: target) || target.starts(with: path) { throw unchangeable }

			if inSection {
				insertAfter = index
				indent = String(line[..<first])
			}
		}

		let entryIsMissing = if case let .entry(_, position) = edit.target { entries <= position } else { false }
		if entryIsMissing { throw missing }

		// A key that is not in the file already has its default.
		guard let value = edit.value else { return text }

		let entry = "\(bare(edit.key)) = \(value.literal)"

		if let insertAfter {
			lines.insert(indent + entry, at: insertAfter + 1)
			return lines.joined(separator: "\n")
		}

		return appending("[\(bare(edit.target.name))]\n\(entry)", to: text)
	}

	public static func apply(_ edit: EntryEdit, to text: String) throws(ConfigError) -> String {
		var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

		func missing(_ name: String, _ index: Int) -> ConfigError {
			ConfigError.invalid("there is no \(ConfigTarget.entry(name, index).description)")
		}

		switch edit {
		case let .insert(name, fields):
			let entry = ["[[\(bare(name))]]"] + fields.map { "\(bare($0.key)) = \($0.value.literal)" }

			if let last = try entries(of: name, in: lines).last {
				lines.insert(contentsOf: [""] + entry, at: last.upperBound + 1)
				return lines.joined(separator: "\n")
			}

			return appending(entry.joined(separator: "\n"), to: text)

		case let .remove(name, index):
			let spans = try entries(of: name, in: lines)
			guard spans.indices.contains(index) else { throw missing(name, index) }

			let start = spans[index].lowerBound
			lines.removeSubrange(spans[index])
			// One blank line next to it goes too, or every removal would leave one more. Not the
			// file's last line, though: that blank is its final newline.
			if start < lines.count - 1, isBlank(lines[start]) {
				lines.remove(at: start)
			} else if start > 0, isBlank(lines[start - 1]) {
				lines.remove(at: start - 1)
			}
			return lines.joined(separator: "\n")

		case let .move(name, from, to):
			let spans = try entries(of: name, in: lines)
			guard spans.indices.contains(from) else { throw missing(name, from) }
			guard spans.indices.contains(to) else { throw missing(name, to) }

			var blocks = spans.map { Array(lines[$0]) }
			blocks.insert(blocks.remove(at: from), at: to)
			// Each place in the file keeps its lines around it; only what stands there changes. The
			// last place goes first, so the line numbers of the earlier ones still hold.
			for (span, block) in zip(spans, blocks).reversed() {
				lines.replaceSubrange(span, with: block)
			}
			return lines.joined(separator: "\n")
		}
	}

	/// `block` after the text, one blank line between them, and a newline after it.
	private static func appending(_ block: String, to text: String) -> String {
		var result = text.allSatisfy(\.isWhitespace) ? "" : text
		if !result.isEmpty {
			result += result.hasSuffix("\n") ? "\n" : "\n\n"
		}
		return result + block + "\n"
	}

	/// Each entry of the array `name`: the lines from its header to its last key line, a value
	/// spread over several lines and comments between its keys included. Its sub-tables,
	/// `[workspace.share]`, go with it. An array written inline at the top is refused.
	private static func entries(of name: String, in lines: [String]) throws(ConfigError) -> [ClosedRange<Int>] {
		var spans: [ClosedRange<Int>] = []
		var current: ClosedRange<Int>?
		var inSection = false
		var state = ScanState()
		let unchangeable = ConfigError.invalid(
			"\(name) is written in a way the settings window cannot change; change it in kumiko.toml"
		)

		for index in lines.indices {
			var line = Array(lines[index])
			if line.last == "\r" { line.removeLast() }

			guard state.atRest else {
				_ = scan(line, from: 0, &state)
				if let start = current?.lowerBound { current = start...index }
				continue
			}

			guard let first = line.firstIndex(where: { $0 != " " && $0 != "\t" }), line[first] != "#" else { continue }

			if line[first] == "[" {
				inSection = true
				let array = first + 1 < line.count && line[first + 1] == "["
				let table = key(in: line, from: first + (array ? 2 : 1))?.parts ?? []
				if table.count > 1, table[0] == name {
					// A sub-table that is not right behind its entry cannot be told from the
					// entry's own without reading the whole file as TOML.
					guard let start = current?.lowerBound else { throw unchangeable }
					current = start...index
					continue
				}
				if !array && table == [name] { throw unchangeable }
				if let previous = current { spans.append(previous) }
				current = array && table == [name] ? index...index : nil
				continue
			}

			if let (parts, end) = key(in: line, from: first), end < line.count, line[end] == "=" {
				if !inSection && parts[0] == name {
					throw unchangeable
				}
				_ = scan(line, from: end + 1, &state)
			}
			if let start = current?.lowerBound { current = start...index }
		}

		if let current { spans.append(current) }
		return spans
	}

	private static func isBlank(_ line: String) -> Bool {
		line.allSatisfy(\.isWhitespace)
	}

	/// One edit, written like a batch of one.
	public static func write(_ edit: ConfigEdit, to url: URL) throws(ConfigError) -> Config {
		try write([edit], to: url)
	}

	/// Applies the changes in order and writes the result once: all of them land or none does.
	/// Nothing is written unless the result is a valid config, so a file that is already broken
	/// stays as it is.
	public static func write(_ changes: [any ConfigChange], to url: URL) throws(ConfigError) -> Config {
		// A config linked in from a dotfiles repository stays a link: the write goes to its target.
		let url = url.resolvingSymlinksInPath()
		let path = url.path(percentEncoded: false)
		let text: String

		do {
			text = try String(contentsOf: url, encoding: .utf8)
		} catch let error as CocoaError where error.code == .fileReadNoSuchFile {
			text = ""
		} catch {
			throw ConfigError.unreadable(path, error.localizedDescription)
		}

		let changed = try apply(changes, to: text)
		let config = try Config.parse(changed)
		if changed == text { return config }

		do {
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try changed.write(to: url, atomically: true, encoding: .utf8)
		} catch {
			throw ConfigError.unwritable(path, error.localizedDescription)
		}

		return config
	}

	/// Where a line leaves the text after it: inside a multi-line string, or inside brackets a
	/// value opened.
	private struct ScanState {
		/// The delimiter that closes the open multi-line string.
		var string: [Character]?
		var depth = 0

		var atRest: Bool { string == nil && depth == 0 }
	}

	/// Follows strings and brackets through `line` and returns where a comment starts, if one does.
	private static func scan(_ line: [Character], from start: Int, _ state: inout ScanState) -> Int? {
		var i = start

		while i < line.count {
			if let delimiter = state.string {
				if delimiter.first == "\"" && line[i] == "\\" {
					i += 2
				} else if line[i...].starts(with: delimiter) {
					state.string = nil
					i += delimiter.count
				} else {
					i += 1
				}
				continue
			}

			switch line[i] {
			case "#":
				return i
			case "\"", "'":
				let quote = line[i]
				let triple = [quote, quote, quote]
				if line[i...].starts(with: triple) {
					state.string = triple
					i += 3
					continue
				}
				i += 1
				while i < line.count && line[i] != quote {
					if quote == "\"" && line[i] == "\\" { i += 1 }
					i += 1
				}
				i += 1
			case "[", "{":
				state.depth += 1
				i += 1
			case "]", "}":
				state.depth -= 1
				i += 1
			default:
				i += 1
			}
		}

		return nil
	}

	/// The dotted key starting at `start`, unquoted part by part, and the index just past it.
	private static func key(in line: [Character], from start: Int) -> (parts: [String], end: Int)? {
		var parts: [String] = []
		var i = start

		func skipSpaces() {
			while i < line.count && (line[i] == " " || line[i] == "\t") { i += 1 }
		}

		while true {
			skipSpaces()
			guard i < line.count else { return nil }
			var part = ""

			if line[i] == "\"" || line[i] == "'" {
				let quote = line[i]
				i += 1
				while i < line.count && line[i] != quote {
					if quote == "\"" && line[i] == "\\" && i + 1 < line.count { i += 1 }
					part.append(line[i])
					i += 1
				}
				guard i < line.count else { return nil }
				i += 1
			} else {
				while i < line.count && isBare(line[i]) {
					part.append(line[i])
					i += 1
				}
				guard !part.isEmpty else { return nil }
			}

			parts.append(part)
			skipSpaces()
			guard i < line.count && line[i] == "." else { return (parts, i) }
			i += 1
		}
	}

	private static func isBare(_ character: Character) -> Bool {
		character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
	}

	/// A key as written: bare when TOML allows it, quoted otherwise.
	fileprivate static func bare(_ key: String) -> String {
		!key.isEmpty && key.allSatisfy(isBare) ? key : TOMLValue.string(key).literal
	}
}

extension Insets {
	/// The padding as people write it: one number when every side is the same, otherwise a table
	/// that names all four, so no side is left to the zero a missing key means.
	public var tomlValue: TOMLValue {
		if Set([top, bottom, left, right]).count == 1 { return .int(top) }
		return .table([
			.init("top", .int(top)), .init("bottom", .int(bottom)), .init("left", .int(left)), .init("right", .int(right)),
		])
	}
}

extension Config.Workspace {
	/// The entry as the settings window writes it. `display` is always there, so the file
	/// shows which screen the workspace lives on. The other keys are left out while they
	/// keep their default, so a new workspace is two lines, the way a person would start one.
	public var tomlFields: [TOMLValue.Field] {
		var fields: [TOMLValue.Field] = [.init("name", .string(name)), .init("display", .string(display))]
		if !apps.isEmpty { fields.append(.init("apps", .array(apps.map(TOMLValue.string)))) }
		if isDefault { fields.append(.init("default", .bool(true))) }
		if !stack.isEmpty { fields.append(.init("stack", .array(stack.map(TOMLValue.string)))) }
		if !last.isEmpty { fields.append(.init("last", .array(last.map(TOMLValue.string)))) }
		if !share.isEmpty { fields.append(.init("share", Self.shareValue(share, order: apps))) }
		return fields
	}

	/// `share` as an inline table. A dictionary has no order of its own; the apps go
	/// in the order `order` names them, the rest after them by name, so the line
	/// reads the same on every write.
	public static func shareValue(_ share: [String: Double], order: [String]) -> TOMLValue {
		var seen = Set<String>()
		let keys =
			order.filter { share[$0] != nil && seen.insert($0).inserted } + share.keys.filter { !seen.contains($0) }.sorted()
		return .table(keys.map { .init($0, .double(share[$0]!)) })
	}
}
