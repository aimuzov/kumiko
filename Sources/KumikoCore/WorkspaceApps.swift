import Foundation

/// `apps` holds patterns while `stack`, `last` and `share` hold exact app names, so the same app
/// is written two ways. These helpers carry a name between the two.
extension Config.Workspace {
	/// The pattern that matches exactly this name, so `Foo (Beta)` is not read as a group.
	public static func pattern(for name: String) -> String {
		NSRegularExpression.escapedPattern(for: name)
	}

	/// The name a pattern spells out, or nil when it is a real pattern like `Arc|Dia`: one that
	/// matches more than the one name has no name to show. A dot matches itself, so `zoom.us` is
	/// a name even unescaped.
	public static func name(of pattern: String) -> String? {
		var name = ""
		var characters = pattern.makeIterator()
		while let character = characters.next() {
			if character == "\\" {
				guard let escaped = characters.next() else { return nil }
				name.append(escaped)
			} else {
				name.append(character)
			}
		}
		if Self.pattern(for: name) == pattern { return name }
		let dotsOnly = Self.pattern(for: pattern) == pattern.replacingOccurrences(of: ".", with: "\\.")
		return dotsOnly ? pattern : nil
	}

	/// Whether an `apps` pattern matches the whole app name, like `[[wm.rule]]` patterns do: "Code" is
	/// not "Xcode".
	public static func matcher(for pattern: String) -> NSRegularExpression? {
		try? NSRegularExpression(pattern: "^(?:\(pattern))$")
	}

	public func opens(_ app: String) -> Bool {
		let range = NSRange(app.startIndex..., in: app)
		return apps.contains { Self.matcher(for: $0)?.firstMatch(in: app, range: range) != nil }
	}

	/// What a settings row calls an `apps` entry: the name it spells, else the pattern as written.
	public var appRows: [String] {
		var seen: [String] = []
		let named = apps.map { Self.name(of: $0) ?? $0 }
		for app in named + stack + last + share.keys.sorted() where !seen.contains(app) {
			seen.append(app)
		}
		return seen
	}

	/// Whether `row` is in `apps` as a real pattern. Such a row only says where windows open: the
	/// other lists compare exact names, which a pattern never equals. A string already in one of
	/// them is a name there, whatever `apps` makes of it.
	public func isPattern(_ row: String) -> Bool {
		apps.contains { $0 == row && Self.name(of: $0) == nil }
			&& !stack.contains(row) && !last.contains(row) && share[row] == nil
	}

	/// Whether `row` is in `apps`, as its name or as the pattern it is.
	public func listsInApps(_ row: String) -> Bool {
		apps.contains { (Self.name(of: $0) ?? $0) == row }
	}
}
