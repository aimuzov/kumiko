import KumikoCore
import Testing

struct VimCommandsTests {
	private let layout = VimCommands.russianLayout

	@Test func theSwitchReadsTheUsersCommand() throws {
		let text = """
			[vim]
			commands = [
				"set langmap=ФИСВУАПРШОЛДЬТЩЗЙКЫЕГМЦЧНЯ;ABCDEFGHIJKLMNOPQRSTUVWXYZ,фисвуапршолдьтщзйкыегмцчня;abcdefghijklmnopqrstuvwxyz",
			]
			"""
		let commands = try Config.parse(text).vim.commands

		#expect(VimCommands.hasRussianLayout(commands))
		#expect(VimCommands.others(commands).isEmpty)
	}

	@Test func turningTheLayoutOnPutsItFirstOnce() {
		#expect(VimCommands.setRussianLayout(true, in: ["set ignorecase"]) == [layout, "set ignorecase"])
		#expect(VimCommands.setRussianLayout(true, in: ["a", layout]) == ["a", layout])
	}

	@Test func turningTheLayoutOffTakesOnlyItAway() {
		#expect(VimCommands.setRussianLayout(false, in: ["a", layout, "b"]) == ["a", "b"])
	}

	/// Another langmap is the user's own command, not the switch's.
	@Test func anotherLangmapIsAnOrdinaryCommand() {
		let own = "set langmap=йцук;qwer"
		#expect(!VimCommands.hasRussianLayout([own]))
		#expect(VimCommands.others([own]) == [own])
	}

	@Test func editingTheListKeepsTheLayoutInPlace() {
		let commands = ["a", layout, "b"]
		#expect(VimCommands.setOthers(["a", "c", "b"], in: commands) == ["a", layout, "c", "b"])
		#expect(VimCommands.setOthers([], in: commands) == [layout])
		#expect(VimCommands.setOthers([" x ", "  "], in: ["y"]) == ["x"])
	}
}
