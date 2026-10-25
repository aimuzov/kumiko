import Foundation

/// `[[wm.rule]]` the way the Window Rules page shows them: per app, whether its windows are tiled,
/// and the window titles that go the other way. A rule that says something else, a real pattern or
/// one about titles alone, stays a pattern of its own.
///
/// The edits come back as changes to kumiko.toml that touch as little of it as they can: an app
/// in a rule shared with others leaves that rule's list and gets one of its own right after it.
public struct AppRules: Equatable, Sendable {
	public struct App: Equatable, Sendable {
		public var name: String
		public var tiles: Bool
		/// Windows whose title has one of these in it go the other way.
		public var exceptions: [String]
		/// Windows whose identifier has one of these in it go the other way: those with no title.
		public var idExceptions: [String]
		/// The rule that names the app, alone or with others.
		var rule: Int
		/// Its rules with titles, in file order.
		var exceptionRules: [Int]
		/// Its rules with identifiers, in file order.
		var idExceptionRules: [Int]
	}

	public struct Pattern: Equatable, Sendable {
		/// The rule's place among `[[wm.rule]]`, 0-based.
		public var index: Int
		public var rule: WindowRule
	}

	/// By name, as people look for them.
	public private(set) var apps: [App] = []
	/// In file order.
	public private(set) var patterns: [Pattern] = []
	private let rules: [WindowRule]

	private static let array = "wm.rule"
	/// What a regular expression reads as more than itself, so a name with one is not a plain name.
	private static let special = Set(#"\^$.|?*+()[]{}"#)

	public init(_ rules: [WindowRule]) {
		self.rules = rules

		// The last rule that names an app decides for it, as when the rules are applied.
		var owners: [String: Int] = [:]
		var names: [String] = []
		for (index, rule) in rules.enumerated() where rule.title == nil && rule.id == nil {
			for name in rule.app.flatMap(Self.names) ?? [] {
				if owners[name] == nil { names.append(name) }
				owners[name] = index
			}
		}

		// By title or by identifier, never both: a rule that asks for both is a pattern.
		var exceptions: [String: (titles: [String], rules: [Int])] = [:]
		var idExceptions: [String: (ids: [String], rules: [Int])] = [:]
		var used = Set(owners.values)

		for (index, rule) in rules.enumerated() where (rule.title == nil) != (rule.id == nil) {
			guard
				let names = rule.app.flatMap(Self.names), names.count == 1, let name = names.first,
				let owner = owners[name], owner < index, rules[owner].manage != rule.manage,
				let values = (rule.title ?? rule.id).flatMap(Self.names)
			else { continue }
			if rule.title != nil {
				exceptions[name, default: ([], [])].titles += values
				exceptions[name, default: ([], [])].rules.append(index)
			} else {
				idExceptions[name, default: ([], [])].ids += values
				idExceptions[name, default: ([], [])].rules.append(index)
			}
			used.insert(index)
		}

		apps = names.map { name in
			let owner = owners[name]!
			return App(
				name: name, tiles: rules[owner].manage, exceptions: exceptions[name]?.titles ?? [],
				idExceptions: idExceptions[name]?.ids ?? [], rule: owner, exceptionRules: exceptions[name]?.rules ?? [],
				idExceptionRules: idExceptions[name]?.rules ?? []
			)
		}
		.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

		patterns = rules.enumerated().filter { !used.contains($0.offset) }.map { Pattern(index: $0.offset, rule: $0.element) }
	}

	public func app(named name: String) -> App? {
		apps.first { $0.name == name }
	}

	// MARK: - Edits

	/// Its exceptions turn with it, so they keep going the other way.
	public func setTiles(_ name: String, _ tiles: Bool) -> [any ConfigChange] {
		guard let app = app(named: name), app.tiles != tiles else { return [] }

		var changes: [any ConfigChange] = (app.exceptionRules + app.idExceptionRules).map { edit($0, "manage", .bool(!tiles)) }
		let shared = Self.names(in: rules[app.rule].app ?? "") ?? []

		if shared == [name] {
			changes.append(edit(app.rule, "manage", .bool(tiles)))
		} else {
			changes.append(edit(app.rule, "app", .string(Self.pattern(shared.filter { $0 != name }))))
			changes += insert([.init("app", .string(Self.pattern([name]))), .init("manage", .bool(tiles))], after: app.rule)
		}
		return changes
	}

	/// At the end of the rules. An app only matters when it goes the other way than the apps no
	/// rule names, so the page adds it that way.
	public func addApp(_ name: String, tiles: Bool) -> [any ConfigChange] {
		guard app(named: name) == nil else { return [] }
		return [EntryEdit.insert(Self.array, fields: [.init("app", .string(Self.pattern([name]))), .init("manage", .bool(tiles))])]
	}

	public func removeApp(_ name: String) -> [any ConfigChange] {
		guard let app = app(named: name) else { return [] }

		// The exceptions come after the app's rule: taken out first, from the end, they leave its place as it is.
		var changes: [any ConfigChange] = (app.exceptionRules + app.idExceptionRules).sorted(by: >).map {
			EntryEdit.remove(Self.array, $0)
		}
		let shared = Self.names(in: rules[app.rule].app ?? "") ?? []

		if shared == [name] {
			changes.append(EntryEdit.remove(Self.array, app.rule))
		} else {
			changes.append(edit(app.rule, "app", .string(Self.pattern(shared.filter { $0 != name }))))
		}
		return changes
	}

	/// The titles go into the app's first rule with titles, and the others go. None left, no rule.
	public func setExceptions(_ name: String, _ titles: [String]) -> [any ConfigChange] {
		guard let app = app(named: name) else { return [] }
		return setExceptions(of: app, "title", titles, current: app.exceptions, rules: app.exceptionRules)
	}

	/// As `setExceptions`, for windows told apart by their identifier.
	public func setIDExceptions(_ name: String, _ ids: [String]) -> [any ConfigChange] {
		guard let app = app(named: name) else { return [] }
		return setExceptions(of: app, "id", ids, current: app.idExceptions, rules: app.idExceptionRules)
	}

	private func setExceptions(
		of app: App, _ key: String, _ values: [String], current: [String], rules indices: [Int]
	) -> [any ConfigChange] {
		var seen = Set<String>()
		let values = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
		guard values != current else { return [] }

		guard let first = indices.first else {
			guard !values.isEmpty else { return [] }
			return insert([
				.init("app", .string(Self.pattern([app.name]))), .init(key, .string(Self.pattern(values))),
				.init("manage", .bool(!app.tiles)),
			], after: app.rule)
		}

		let others: [any ConfigChange] = indices.dropFirst().reversed().map { EntryEdit.remove(Self.array, $0) }
		guard !values.isEmpty else { return others + [EntryEdit.remove(Self.array, first)] }
		return others + [edit(first, key, .string(Self.pattern(values)))]
	}

	/// A pattern as written: nil takes the key out.
	public func setPattern(_ index: Int, app: String?, title: String?, id: String? = nil, tiles: Bool) -> [any ConfigChange] {
		guard rules.indices.contains(index) else { return [] }
		let rule = rules[index]
		var changes: [any ConfigChange] = []
		if app != rule.app { changes.append(edit(index, "app", app.map(TOMLValue.string))) }
		if title != rule.title { changes.append(edit(index, "title", title.map(TOMLValue.string))) }
		if id != rule.id { changes.append(edit(index, "id", id.map(TOMLValue.string))) }
		if tiles != rule.manage { changes.append(edit(index, "manage", .bool(tiles))) }
		return changes
	}

	public func removePattern(_ index: Int) -> [any ConfigChange] {
		rules.indices.contains(index) ? [EntryEdit.remove(Self.array, index)] : []
	}

	private func edit(_ index: Int, _ key: String, _ value: TOMLValue?) -> ConfigEdit {
		ConfigEdit(target: .entry(Self.array, index), key: key, value: value)
	}

	/// A new rule goes after the last one, then up to its place.
	private func insert(_ fields: [TOMLValue.Field], after index: Int) -> [any ConfigChange] {
		[EntryEdit.insert(Self.array, fields: fields), EntryEdit.move(Self.array, from: rules.count, to: index + 1)]
	}

	// MARK: - Patterns as lists

	/// The plain names a pattern is a list of, `Code|Zed`, or nil when it is more than a list.
	static func names(in pattern: String) -> [String]? {
		var names: [String] = []
		var name = ""
		var escaped = false

		for character in pattern {
			if escaped {
				name.append(character)
				escaped = false
			} else if character == "\\" {
				escaped = true
			} else if character == "|" {
				guard !name.isEmpty else { return nil }
				names.append(name)
				name = ""
			} else if special.contains(character) {
				return nil
			} else {
				name.append(character)
			}
		}

		guard !escaped, !name.isEmpty else { return nil }
		return names + [name]
	}

	/// Names as the one pattern that matches each of them as it is.
	static func pattern(_ names: [String]) -> String {
		names.map { name in
			String(name.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
		}
		.joined(separator: "|")
	}
}
