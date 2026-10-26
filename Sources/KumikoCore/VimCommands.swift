import Foundation

/// `[vim] commands` the way the Vim page shows them: the Russian layout as a switch, the other
/// commands as a list. Each edit gives back the whole array to write, in the order Vim runs it.
public enum VimCommands {
	/// Normal-mode keys on the Russian layout: each Cyrillic letter stands for the Latin key it
	/// shares with ЙЦУКЕН, so `о` moves down like `j`.
	public static let russianLayout =
		"set langmap=ФИСВУАПРШОЛДЬТЩЗЙКЫЕГМЦЧНЯ;ABCDEFGHIJKLMNOPQRSTUVWXYZ,фисвуапршолдьтщзйкыегмцчня;abcdefghijklmnopqrstuvwxyz"

	public static func hasRussianLayout(_ commands: [String]) -> Bool {
		commands.contains(russianLayout)
	}

	/// The commands the list shows: all but the switch's.
	public static func others(_ commands: [String]) -> [String] {
		commands.filter { $0 != russianLayout }
	}

	/// On, the command goes first, before anything that could rely on it; off, it goes wherever it was.
	public static func setRussianLayout(_ on: Bool, in commands: [String]) -> [String] {
		on ? (hasRussianLayout(commands) ? commands : [russianLayout] + commands) : others(commands)
	}

	/// The list edited, with the switch's command kept in its place among them.
	public static func setOthers(_ others: [String], in commands: [String]) -> [String] {
		var result = others.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
		if let place = commands.firstIndex(of: russianLayout) {
			result.insert(russianLayout, at: min(place, result.count))
		}
		return result
	}
}
