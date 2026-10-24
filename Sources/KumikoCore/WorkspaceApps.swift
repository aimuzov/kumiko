import Foundation
import os

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
		if let cached = matchers.withLock({ $0[pattern] }) { return cached }
		let matcher = try? NSRegularExpression(pattern: "^(?:\(pattern))$")
		matchers.withLock { $0[pattern] = matcher }
		return matcher
	}

	/// The settings window asks for every row on every draw. A pattern that does not compile is
	/// kept too, as nil, so it is not tried again.
	private static let matchers = OSAllocatedUnfairLock<[String: NSRegularExpression?]>(initialState: [:])

	public func opens(_ app: String) -> Bool {
		let range = NSRange(app.startIndex..., in: app)
		return apps.contains { Self.matcher(for: $0)?.firstMatch(in: app, range: range) != nil }
	}

	/// The `apps` entries in the order their windows are laid out: as written, except the ones
	/// an older file pins with `last`, which go after the rest.
	public var orderedApps: [String] {
		apps.filter { !isPinnedLast($0) } + apps.filter(isPinnedLast)
	}

	private func isPinnedLast(_ entry: String) -> Bool { last.contains(Self.name(of: entry) ?? entry) }

	/// Where a window of `app` goes in the layout, lower first: the place of the first entry
	/// that matches it, then the apps no entry matches, then the ones `last` pins.
	public func layoutRank(of app: String) -> Int {
		if last.contains(app) { return apps.count + 1 }
		let range = NSRange(app.startIndex..., in: app)
		return orderedApps.firstIndex { Self.matcher(for: $0)?.firstMatch(in: app, range: range) != nil } ?? apps.count
	}

	/// The windows in layout order. Stable: windows of one app, and windows no entry ranks,
	/// keep the order they had, so a reorder moves only what the ranks say must move.
	public func layoutOrder<ID>(_ windows: [(id: ID, app: String)]) -> [ID] {
		windows.enumerated()
			.map { (rank: layoutRank(of: $0.element.app), place: $0.offset, id: $0.element.id) }
			.sorted { ($0.rank, $0.place) < ($1.rank, $1.place) }
			.map(\.id)
	}

	/// What a settings row calls an `apps` entry: the name it spells, else the pattern as written.
	/// In layout order, which the rows are dragged to change.
	public var appRows: [String] {
		var seen: [String] = []
		let named = orderedApps.map { Self.name(of: $0) ?? $0 }
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
