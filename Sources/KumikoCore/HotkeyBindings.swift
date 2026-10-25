import Foundation

/// The hotkeys the way the Hotkeys page shows them: the modes, each with its bindings in the order
/// of the file, and every key as the file spells it, so an edit can find its line again.
public struct HotkeyBindings: Equatable, Sendable {
	public enum ModeID: Hashable, Sendable {
		/// `[hotkeys.bind]`.
		case `default`
		/// `[hotkeys.global]`, the bindings of every mode.
		case every
		/// `[hotkeys.mode.<name>]`.
		case named(String)
	}

	public struct Binding: Equatable, Sendable {
		/// The key as written in the file: `cmd + ctrl - j`.
		public var key: String
		public var combo: KeyCombo
		public var action: HotkeyAction
	}

	public struct Mode: Equatable, Sendable {
		public var id: ModeID
		public var bindings: [Binding]

		public var title: String {
			switch id {
			case .default: "Default"
			case .every: "Every mode"
			case let .named(name): name.prefix(1).uppercased() + name.dropFirst()
			}
		}

		/// The table of kumiko.toml the mode's bindings live in.
		public var table: String {
			switch id {
			case .default: "hotkeys.bind"
			case .every: "hotkeys.global"
			case let .named(name): "hotkeys.mode.\(name)"
			}
		}
	}

	/// Default, every mode, then the named modes in file order.
	public private(set) var modes: [Mode]

	/// `text` is kumiko.toml itself: the config knows the bindings, only the file knows their order.
	public init(_ hotkeys: Config.Hotkeys, text: String) {
		let keys = Self.keys(in: text)
		var modes = [
			Mode(id: .default, bindings: Self.bindings(hotkeys.bindings, keys["hotkeys.bind"] ?? [])),
			Mode(id: .every, bindings: Self.bindings(hotkeys.global, keys["hotkeys.global"] ?? [])),
		]

		let named = keys.order.compactMap { $0.hasPrefix("hotkeys.mode.") ? String($0.dropFirst(13)) : nil }
		let names = named.filter { hotkeys.modes[$0] != nil }
			+ hotkeys.modes.keys.filter { !named.contains($0) }.sorted()
		for name in names {
			modes.append(Mode(
				id: .named(name), bindings: Self.bindings(hotkeys.modes[name] ?? [:], keys["hotkeys.mode.\(name)"] ?? [])
			))
		}
		self.modes = modes
	}

	public func mode(_ id: ModeID) -> Mode? {
		modes.first { $0.id == id }
	}

	public func binding(_ key: String, in id: ModeID) -> Binding? {
		mode(id)?.bindings.first { $0.key == key }
	}

	/// The mode's binding of the combo, other than the one being changed.
	public func taken(_ combo: KeyCombo, in id: ModeID, except key: String? = nil) -> Binding? {
		mode(id)?.bindings.first { $0.combo == combo && $0.key != key }
	}

	// MARK: - Edits

	/// How an action is written: a command alone as a string, as people write it, else an inline
	/// table, its keys in the order the docs give them.
	public static func value(_ action: HotkeyAction) -> TOMLValue {
		if let run = action.run, action.shell == nil, action.mode == nil, action.send == nil, !action.block {
			return .string(run)
		}
		var fields: [TOMLValue.Field] = []
		if let run = action.run { fields.append(.init("run", .string(run))) }
		if let shell = action.shell { fields.append(.init("shell", .string(shell))) }
		if let mode = action.mode { fields.append(.init("mode", .string(mode))) }
		if let send = action.send { fields.append(.init("send", .string(send.description))) }
		if action.block { fields.append(.init("block", .bool(true))) }
		return .table(fields)
	}

	public func setAction(_ action: HotkeyAction, of key: String, in id: ModeID) -> [any ConfigChange] {
		guard let mode = mode(id), let binding = binding(key, in: id), binding.action != action else { return [] }
		return [ConfigEdit(table: mode.table, key: key, value: Self.value(action))]
	}

	/// On the binding's own line, so it keeps its place and comment. A shortcut the mode already
	/// has gives its binding up in the same write: the file cannot have both.
	public func setShortcut(_ combo: KeyCombo, of key: String, in id: ModeID) -> [any ConfigChange] {
		guard let mode = mode(id), let binding = binding(key, in: id), combo.description != key else { return [] }
		var changes: [any ConfigChange] = taken(combo, in: id, except: key).map { remove($0.key, from: id) } ?? []
		changes.append(ConfigEdit(target: .table(mode.table), key: combo.description, value: Self.value(binding.action), replacing: key))
		return changes
	}

	/// After the mode's last shortcut. Its table is added when the file has none yet.
	public func add(_ combo: KeyCombo, _ action: HotkeyAction, in id: ModeID) -> [any ConfigChange] {
		guard let mode = mode(id) else { return [] }
		var changes: [any ConfigChange] = taken(combo, in: id).map { remove($0.key, from: id) } ?? []
		changes.append(ConfigEdit(table: mode.table, key: combo.description, value: Self.value(action)))
		return changes
	}

	public func remove(_ key: String, from id: ModeID) -> [any ConfigChange] {
		guard let mode = mode(id), binding(key, in: id) != nil else { return [] }
		return [ConfigEdit(table: mode.table, key: key, value: nil)]
	}

	/// Letters, digits, `-` and `_`: the name is a bare key in `[hotkeys.mode.<name>]`.
	public func canAddMode(_ name: String) -> Bool {
		!name.isEmpty && name != "default" && mode(.named(name)) == nil
			&& name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
	}

	/// With Esc back to the default mode, the way out a mode most often has.
	public func addMode(_ name: String) -> [any ConfigChange] {
		guard canAddMode(name) else { return [] }
		return [ConfigEdit(table: "hotkeys.mode.\(name)", key: "escape", value: .table([.init("mode", .string("default"))]))]
	}

	/// The mode's table, and what switches to it elsewhere, which the config would refuse to
	/// keep: a shortcut that only switched to it goes, one that does more stops switching.
	public func removeMode(_ name: String) -> [any ConfigChange] {
		guard let removed = mode(.named(name)) else { return [] }
		var changes: [any ConfigChange] = []

		for mode in modes where mode.id != removed.id {
			for binding in mode.bindings where binding.action.mode == name {
				var action = binding.action
				action.mode = nil
				let doesMore = action.run != nil || action.shell != nil || action.send != nil || action.block
				changes += doesMore ? setAction(action, of: binding.key, in: mode.id) : remove(binding.key, from: mode.id)
			}
		}
		changes.append(TableEdit.remove(removed.table))
		return changes
	}

	public func setBlacklist(_ apps: [String]) -> [any ConfigChange] {
		[ConfigEdit(table: "hotkeys", key: "blacklist", value: apps.isEmpty ? nil : .array(apps.map(TOMLValue.string)))]
	}

	public func setOnModeChange(_ command: String?) -> [any ConfigChange] {
		let command = command?.trimmingCharacters(in: .whitespaces)
		return [ConfigEdit(table: "hotkeys", key: "on_mode_change", value: command.flatMap { $0.isEmpty ? nil : .string($0) })]
	}

	/// The file's keys first, as they come; a binding written some other way (a dotted key, an
	/// inline table) after them, by its combo.
	private static func bindings(_ table: [KeyCombo: HotkeyAction], _ keys: [String]) -> [Binding] {
		var seen = Set<KeyCombo>()
		var result: [Binding] = []

		for key in keys {
			guard let combo = try? KeyCombo.parse(key), let action = table[combo], seen.insert(combo).inserted else { continue }
			result.append(Binding(key: key, combo: combo, action: action))
		}

		let rest = table.filter { !seen.contains($0.key) }.map { Binding(key: $0.key.description, combo: $0.key, action: $0.value) }
		return result + rest.sorted { $0.key < $1.key }
	}

	/// The keys of each `[hotkeys…]` table in file order, and the tables in the order they come.
	struct Keys {
		var order: [String] = []
		var tables: [String: [String]] = [:]

		subscript(_ table: String) -> [String]? { tables[table] }
	}

	static func keys(in text: String) -> Keys {
		var keys = Keys()
		var table: String?

		for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
			let line = line.trimmingCharacters(in: .whitespaces)
			if line.hasPrefix("[") {
				let name = line.dropFirst().prefix { $0 != "]" }.trimmingCharacters(in: .whitespaces)
				table = name.hasPrefix("hotkeys.") && !line.hasPrefix("[[") ? name : nil
				if let table, keys.tables[table] == nil {
					keys.order.append(table)
					keys.tables[table] = []
				}
				continue
			}
			guard let table, let key = Self.key(of: line) else { continue }
			keys.tables[table]?.append(key)
		}
		return keys
	}

	/// The key of a `key = value` line, unquoted; nil for a comment or anything else.
	private static func key(of line: String) -> String? {
		guard let first = line.first, first != "#" else { return nil }

		if first == "\"" || first == "'" {
			var key = ""
			var escaped = false
			for character in line.dropFirst() {
				if escaped {
					key.append(character)
					escaped = false
				} else if character == "\\" && first == "\"" {
					escaped = true
				} else if character == first {
					return key
				} else {
					key.append(character)
				}
			}
			return nil
		}

		let key = line.prefix { $0 != "=" }.trimmingCharacters(in: .whitespaces)
		return key.isEmpty || key.contains(".") || line.firstIndex(of: "=") == nil ? nil : key
	}
}
