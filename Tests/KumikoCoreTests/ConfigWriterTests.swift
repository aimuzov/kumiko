import Foundation
import KumikoCore
import Testing

struct ConfigWriterTests {
	private func apply(_ table: String, _ key: String, _ value: TOMLValue, to text: String) throws -> String {
		try ConfigWriter.apply(ConfigEdit(table: table, key: key, value: value), to: text)
	}

	@Test func replacesTheValueAndKeepsTheComment() throws {
		let text = """
			# Borders
			[borders]
				width  =  4   # thick enough
			enabled = true
			"""

		#expect(try apply("borders", "width", .double(6), to: text) == """
			# Borders
			[borders]
				width  =  6   # thick enough
			enabled = true
			""")
	}

	@Test func addsAMissingKeyAfterTheSectionsLastKey() throws {
		let text = """
			[wm]
			gap = 8

			# The bar
			[bar]
			height = 30
			"""

		#expect(try apply("wm", "shadows", .bool(false), to: text) == """
			[wm]
			gap = 8
			shadows = false

			# The bar
			[bar]
			height = 30
			""")
	}

	@Test func addsTheKeyRightAfterAnEmptySectionsHeader() throws {
		#expect(try apply("vim", "enabled", .bool(true), to: "[vim]\n\n[bar]\n") == "[vim]\nenabled = true\n\n[bar]\n")
	}

	@Test func addsAMissingSectionAtTheEnd() throws {
		#expect(try apply("menubar", "enabled", .bool(true), to: "") == "[menubar]\nenabled = true\n")
		#expect(try apply("menubar", "rehide", .double(15), to: "[wm]\ngap = 4") == """
			[wm]
			gap = 4

			[menubar]
			rehide = 15

			""")
	}

	@Test func leavesKeysOfArrayTablesAlone() throws {
		let text = """
			[[wm.rule]]
			app = "Finder"
			manage = true

			[wm]
			manage = true

			[[wm.rule]]
			app = "Mail"
			manage = false
			"""

		let changed = try apply("wm", "manage", .bool(false), to: text)

		#expect(changed == text.replacingOccurrences(of: "[wm]\nmanage = true", with: "[wm]\nmanage = false"))
		#expect(try Config.parse(changed).wm.manage == false)
		#expect(try Config.parse(changed).wm.rules.map(\.manage) == [true, false])
	}

	@Test func looksPastMultilineValuesAndBracketsInStrings() throws {
		let text = """
			[bar]
			left = [
				"workspaces", # [not a header]
				"mode",
			]
			font = "Menlo [#1]"
			height = 30
			"""

		let changed = try apply("bar", "height", .double(40), to: text)

		#expect(changed == text.replacingOccurrences(of: "height = 30", with: "height = 40"))
		#expect(try Config.parse(changed).bar.font == "Menlo [#1]")
	}

	@Test func addsAKeyAfterAMultilineValue() throws {
		#expect(try apply("bar", "height", .double(40), to: "[bar]\nleft = [\n\t\"mode\",\n]\n") == """
			[bar]
			left = [
				"mode",
			]
			height = 40

			""")
	}

	@Test func refusesKeysItCannotChangeOnALine() {
		for text in ["wm = { gap = 4 }", "wm.gap = 4", "[wm]\ngap.x = 4", "[wm.gap]\nx = 1"] {
			#expect(throws: ConfigError.self) { try apply("wm", "gap", .int(6), to: text) }
		}
	}

	@Test func quotesStrings() throws {
		let changed = try apply("bar", "font", .string("A \"B\" \\ C"), to: "[bar]\nfont = \"\"")
		#expect(changed == "[bar]\nfont = \"A \\\"B\\\" \\\\ C\"")
		#expect(try Config.parse(changed).bar.font == "A \"B\" \\ C")
	}

	@Test func writesFractionsAsTheyAre() throws {
		#expect(try apply("borders", "width", .double(2.5), to: "[borders]\nwidth = 4") == "[borders]\nwidth = 2.5")
	}

	@Test func writeCreatesAMissingFile() throws {
		let url = FileManager.default.temporaryDirectory.appending(path: "kumiko-\(UUID())/kumiko.toml")
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

		let config = try ConfigWriter.write(ConfigEdit(table: "borders", key: "enabled", value: .bool(false)), to: url)

		#expect(config.borders.enabled == false)
		#expect(try String(contentsOf: url, encoding: .utf8) == "[borders]\nenabled = false\n")
	}

	@Test func writeLeavesABrokenFileAlone() throws {
		let url = FileManager.default.temporaryDirectory.appending(path: "kumiko-\(UUID()).toml")
		defer { try? FileManager.default.removeItem(at: url) }
		try "[bar\n".write(to: url, atomically: true, encoding: .utf8)

		#expect(throws: ConfigError.self) {
			try ConfigWriter.write(ConfigEdit(table: "bar", key: "height", value: .double(40)), to: url)
		}
		#expect(try String(contentsOf: url, encoding: .utf8) == "[bar\n")
	}

	@Test func writeRefusesAValueTheConfigRejects() throws {
		let url = FileManager.default.temporaryDirectory.appending(path: "kumiko-\(UUID()).toml")
		defer { try? FileManager.default.removeItem(at: url) }
		try "[menubar]\nrehide = 5\n".write(to: url, atomically: true, encoding: .utf8)

		#expect(throws: ConfigError.invalid("menubar: rehide must not be negative")) {
			try ConfigWriter.write(ConfigEdit(table: "menubar", key: "rehide", value: .double(-1)), to: url)
		}
		#expect(try String(contentsOf: url, encoding: .utf8) == "[menubar]\nrehide = 5\n")
	}

	@Test func paddingIsANumberWhenEverySideIsTheSame() {
		#expect(Insets(all: 6).tomlValue == .int(6))
		#expect(Insets(top: 4, bottom: 40).tomlValue == .table([
			.init("top", .int(4)), .init("bottom", .int(40)), .init("left", .int(0)), .init("right", .int(0)),
		]))
	}

	@Test func paddingNumberBecomesATable() throws {
		let changed = try apply("wm", "padding", Insets(top: 4, bottom: 40).tomlValue, to: "[wm]\ngap = 6\npadding = 4\n")

		#expect(changed == "[wm]\ngap = 6\npadding = { top = 4, bottom = 40, left = 0, right = 0 }\n")
		#expect(try Config.parse(changed).wm.padding == Insets(top: 4, bottom: 40))
	}

	@Test func paddingTableBecomesANumber() throws {
		let changed = try apply("wm", "padding", Insets(all: 8).tomlValue, to: "[wm]\npadding = { top = 4, bottom = 40 }\ngap = 6")

		#expect(changed == "[wm]\npadding = 8\ngap = 6")
		#expect(try Config.parse(changed).wm.padding == Insets(all: 8))
	}

	@Test func paddingTableIsReplacedWithItsComment() throws {
		let text = "[wm]\npadding = { top = 4, bottom = 40 } # room for the bar\n"
		let changed = try apply("wm", "padding", Insets(top: 4, bottom: 40, left: 8, right: 8).tomlValue, to: text)

		#expect(changed == "[wm]\npadding = { top = 4, bottom = 40, left = 8, right = 8 } # room for the bar\n")
		#expect(try Config.parse(changed).wm.padding == Insets(top: 4, bottom: 40, left: 8, right: 8))
	}

	@Test func paddingWrittenAsItsOwnTableIsRefused() {
		for text in ["[wm.padding]\ntop = 4", "[wm]\npadding.top = 4", "wm.padding = 4"] {
			#expect(throws: ConfigError.self) { try apply("wm", "padding", .int(6), to: text) }
		}
	}

	private func remove(_ table: String, _ key: String, from text: String) throws -> String {
		try ConfigWriter.apply(ConfigEdit(table: table, key: key, value: nil), to: text)
	}

	@Test func removingAKeyTakesOnlyItsLine() throws {
		let text = """
			[wm]
			# Tight.
			gap = 4  # was 8
			shadows = false

			[[wm.rule]]
			gap = 1
			"""

		let changed = try remove("wm", "gap", from: text)

		#expect(changed == text.replacingOccurrences(of: "gap = 4  # was 8\n", with: ""))
		#expect(try Config.parse("[wm]\nshadows = false").wm.gap == 8)
	}

	@Test func removingAKeyTakesAllTheLinesOfItsValue() throws {
		#expect(try remove("bar", "left", from: "[bar]\nleft = [\n\t\"mode\",\n]\nheight = 40\n") == "[bar]\nheight = 40\n")
	}

	@Test func removingAMissingKeyLeavesTheFileAlone() throws {
		#expect(try remove("wm", "gap", from: "[wm]\nshadows = false\n") == "[wm]\nshadows = false\n")
		#expect(try remove("wm", "gap", from: "") == "")
	}

	@Test func refusesToRemoveAKeyWrittenAnotherWay() {
		#expect(throws: ConfigError.self) { try remove("wm", "gap", from: "wm = { gap = 4 }") }
	}

	@Test func writesArrays() throws {
		let changed = try apply("vim", "blacklist", .array([.string("Code"), .string("Ghostty")]), to: "[vim]")
		#expect(changed == "[vim]\nblacklist = [\"Code\", \"Ghostty\"]")
		#expect(try Config.parse(changed).vim.blacklist == ["Code", "Ghostty"])
		#expect(try apply("vim", "commands", .array([]), to: "[vim]") == "[vim]\ncommands = []")
	}

	@Test func workspaceFieldsLeaveDefaultsOut() {
		#expect(
			Config.Workspace(name: "A").tomlFields == [.init("name", .string("A")), .init("display", .string("main"))])
	}

	@Test func shareKeepsTheAppsOrderThenNames() {
		let value = Config.Workspace.shareValue(["B": 0.3, "A": 0.6, "C": 0.1], order: ["C", "C", "B"])
		#expect(value == .table([.init("C", .double(0.1)), .init("B", .double(0.3)), .init("A", .double(0.6))]))
	}

	// Shaped like the user's own config: rules before, a comment above the first entry and one
	// right on top of the last, an inline table, a key with a comment of its own.
	private let code = """
		[[workspace]]
		name = "Code"
		display = "external"
		apps = ["Ghostty", "Code"]
		"""
	private let plan = """
		[[workspace]]
		name = "Plan"
		display = "builtin"
		apps = ["Things", "Mail"] # the day
		stack = ["Things", "Mail"]
		"""
	private let chat = """
		[[workspace]]
		name = "Chat"
		apps = ["Time", "Telegram"]
		share = { Time = 0.7 }
		"""

	private func file(_ first: String, _ second: String, _ third: String) -> String {
		"[[wm.rule]]\napp = \"Finder\"\nmanage = true\n\n# Numbers follow alt-1 ... alt-=.\n\n" + first + "\n\n"
			+ second + "\n\n# Chats last.\n" + third + "\n\n[hotkeys]\nenabled = true"
	}

	private func entry(_ index: Int, _ key: String, _ value: TOMLValue?, in text: String) throws -> String {
		try ConfigWriter.apply(ConfigEdit(target: .entry("workspace", index), key: key, value: value), to: text)
	}

	@Test func setsAKeyOfTheNthEntryOnly() throws {
		let changed = try entry(1, "display", .string("external"), in: file(code, plan, chat))
		#expect(changed == file(code, plan.replacingOccurrences(of: "builtin", with: "external"), chat))
	}

	@Test func keepsTheCommentOfAnEntrysKey() throws {
		let changed = try entry(1, "apps", .array([.string("Things")]), in: file(code, plan, chat))
		let narrowed = plan.replacingOccurrences(of: "[\"Things\", \"Mail\"] #", with: "[\"Things\"] #")
		#expect(changed == file(code, narrowed, chat))
	}

	@Test func addsAKeyAfterTheEntrysLastKey() throws {
		let before = file(code, plan, chat)
		#expect(try entry(2, "default", .bool(true), in: before) == file(code, plan, chat + "\ndefault = true"))
		#expect(try entry(0, "default", .bool(true), in: before) == file(code + "\ndefault = true", plan, chat))
	}

	@Test func removesAKeyOfAnEntry() throws {
		let changed = try entry(2, "share", nil, in: file(code, plan, chat))
		#expect(changed == file(code, plan, chat.replacingOccurrences(of: "\nshare = { Time = 0.7 }", with: "")))
		#expect(try Config.parse(changed).workspaces[2].share.isEmpty)
	}

	@Test func refusesAnEntryThatIsNotThere() {
		#expect(throws: ConfigError.invalid("there is no workspace #4")) {
			try entry(3, "display", .string("main"), in: file(code, plan, chat))
		}
	}

	@Test func refusesADottedKeyInAnEntry() {
		#expect(throws: ConfigError.self) {
			try entry(
				0, "share", .table([.init("Time", .double(0.5))]), in: "[[workspace]]\nname = \"A\"\nshare.Time = 0.7")
		}
	}

	@Test func ignoresTheSubTableOfAnotherEntry() throws {
		let text = "[[workspace]]\nname = \"A\"\nshare = { Time = 0.5 }\n\n"
			+ "[[workspace]]\nname = \"B\"\n\n[workspace.share]\nTime = 0.7"
		let changed = try entry(0, "share", .table([.init("Time", .double(0.6))]), in: text)
		#expect(changed == text.replacingOccurrences(of: "0.5", with: "0.6"))
	}

	@Test func refusesAKeyWrittenAsTheSubTableOfItsEntry() {
		let text = "[[workspace]]\nname = \"A\"\n\n[[workspace]]\nname = \"B\"\n\n[workspace.share]\nTime = 0.7"
		#expect(throws: ConfigError.invalid(
			"share of workspace #2 is written in a way the settings window cannot change; change it in kumiko.toml"
		)) {
			try entry(1, "share", .table([.init("Time", .double(0.6))]), in: text)
		}
	}

	@Test func leavesTheFileAloneWhenAnEntryLacksTheKeyToRemove() throws {
		#expect(try entry(0, "last", nil, in: file(code, plan, chat)) == file(code, plan, chat))
	}

	@Test func readsPastAMultilineArrayOfAnEarlierEntry() throws {
		let text = "[[workspace]]\nname = \"A\"\napps = [\n\t\"X\",\n]\n\n[[workspace]]\nname = \"B\""
		#expect(try entry(1, "display", .string("main"), in: text) == text + "\ndisplay = \"main\"")
	}

	@Test func addsAKeyAfterAnEntrysMultilineArray() throws {
		let text = "[[workspace]]\nname = \"A\"\napps = [\n\t\"X\",\n]\n\n[hotkeys]\nenabled = true"
		let expected =
			"[[workspace]]\nname = \"A\"\napps = [\n\t\"X\",\n]\ndisplay = \"main\"\n\n[hotkeys]\nenabled = true"
		#expect(try entry(0, "display", .string("main"), in: text) == expected)
	}

	@Test func addsAKeyBeforeTheEntrysSubTable() throws {
		let text = "[[workspace]]\nname = \"A\"\n\n[workspace.share]\nTime = 0.7"
		#expect(try entry(0, "display", .string("main"), in: text)
			== "[[workspace]]\nname = \"A\"\ndisplay = \"main\"\n\n[workspace.share]\nTime = 0.7")
	}

	private let media = Config.Workspace(name: "Media", display: "builtin")

	@Test func workspaceLayoutIsWrittenOnlyWhenNotBSP() throws {
		#expect(!Config.Workspace(name: "A").tomlFields.contains { $0.key == "layout" })
		let workspace = Config.Workspace(name: "A", layout: .float)
		let text = try ConfigWriter.apply(EntryEdit.insert("workspace", fields: workspace.tomlFields), to: "")
		#expect(try Config.parse(text).workspaces == [workspace])
	}

	@Test func workspaceFieldsReadBackAsTheWorkspace() throws {
		let workspace = Config.Workspace(
			name: "Chat", display: "builtin", apps: ["Time", "Telegram"], isDefault: true, last: ["Telegram"],
			share: ["Time": 0.7]
		)
		let text = try ConfigWriter.apply(EntryEdit.insert("workspace", fields: workspace.tomlFields), to: "")

		#expect(text == """
			[[workspace]]
			name = "Chat"
			display = "builtin"
			apps = ["Time", "Telegram"]
			default = true
			last = ["Telegram"]
			share = { Time = 0.7 }

			""")
		#expect(try Config.parse(text).workspaces == [workspace])
	}

	@Test func insertsAnEntryAfterTheLastOne() throws {
		let insert = EntryEdit.insert("workspace", fields: media.tomlFields)
		let changed = try ConfigWriter.apply(insert, to: file(code, plan, chat))
		#expect(changed == file(code, plan, chat + "\n\n[[workspace]]\nname = \"Media\"\ndisplay = \"builtin\""))
	}

	@Test func insertsTheFirstEntryAtTheEnd() throws {
		let insert = EntryEdit.insert("workspace", fields: media.tomlFields)
		let changed = try ConfigWriter.apply(insert, to: "[wm]\ngap = 4")
		#expect(changed == "[wm]\ngap = 4\n\n[[workspace]]\nname = \"Media\"\ndisplay = \"builtin\"\n")
	}

	@Test func removesAnEntryAndOneBlankLine() throws {
		let tail = "\n\n# Chats last.\n"
		#expect(try ConfigWriter.apply(EntryEdit.remove("workspace", 0), to: file(code, plan, chat))
			== file(code, plan, chat).replacingOccurrences(of: code + "\n\n", with: ""))
		#expect(try ConfigWriter.apply(EntryEdit.remove("workspace", 1), to: file(code, plan, chat))
			== file(code, plan, chat).replacingOccurrences(of: "\n\n" + plan + tail, with: tail))
		#expect(try ConfigWriter.apply(EntryEdit.remove("workspace", 2), to: file(code, plan, chat))
			== file(code, plan, chat).replacingOccurrences(of: chat + "\n\n", with: ""))
	}

	@Test func movesEntriesAndLeavesCommentsWhereTheyAre() throws {
		let down = try ConfigWriter.apply(EntryEdit.move("workspace", from: 0, to: 2), to: file(code, plan, chat))
		let up = try ConfigWriter.apply(EntryEdit.move("workspace", from: 2, to: 0), to: file(code, plan, chat))

		#expect(down == file(plan, chat, code))
		#expect(up == file(chat, code, plan))
		#expect(try Config.parse(down).workspaces.map(\.name) == ["Plan", "Chat", "Code"])
	}

	@Test func refusesEntriesThatAreNotThere() {
		#expect(throws: ConfigError.invalid("there is no workspace #4")) {
			try ConfigWriter.apply(EntryEdit.remove("workspace", 3), to: file(code, plan, chat))
		}
		#expect(throws: ConfigError.invalid("there is no workspace #4")) {
			try ConfigWriter.apply(EntryEdit.move("workspace", from: 0, to: 3), to: file(code, plan, chat))
		}
	}

	private let sub = "[[workspace]]\nname = \"A\"\n\n[workspace.share]\nTime = 0.7"

	@Test func insertsAfterTheLastEntrysSubTable() throws {
		let insert = EntryEdit.insert("workspace", fields: media.tomlFields)
		#expect(try ConfigWriter.apply(insert, to: sub + "\n")
			== sub + "\n\n[[workspace]]\nname = \"Media\"\ndisplay = \"builtin\"\n")
	}

	@Test func removesAnEntryWithItsSubTable() throws {
		let text = "[[workspace]]\nname = \"A\"\n\n[[workspace]]\nname = \"B\"\n\n[workspace.share]\nTime = 0.7"
		#expect(try ConfigWriter.apply(EntryEdit.remove("workspace", 1), to: text) == "[[workspace]]\nname = \"A\"")

		let first = sub + "\n\n[[workspace]]\nname = \"B\""
		#expect(try ConfigWriter.apply(EntryEdit.remove("workspace", 0), to: first) == "[[workspace]]\nname = \"B\"")
	}

	@Test func movesAnEntryWithItsSubTable() throws {
		let text = sub + "\n\n[[workspace]]\nname = \"B\""
		let moved = try ConfigWriter.apply(EntryEdit.move("workspace", from: 0, to: 1), to: text)

		#expect(moved == "[[workspace]]\nname = \"B\"\n\n" + sub)
		#expect(try Config.parse(moved).workspaces.map(\.name) == ["B", "A"])
		#expect(try Config.parse(moved).workspaces[1].share == ["Time": 0.7])
	}

	@Test func refusesAnArrayWrittenInline() {
		let text = "workspace = [{ name = \"A\" }]\n\n[wm]\ngap = 4"
		let refusal = ConfigError.invalid(
			"workspace is written in a way the settings window cannot change; change it in kumiko.toml"
		)
		#expect(throws: refusal) {
			try ConfigWriter.apply(EntryEdit.insert("workspace", fields: media.tomlFields), to: text)
		}
		#expect(throws: refusal) { try ConfigWriter.apply(EntryEdit.remove("workspace", 0), to: text) }
		#expect(throws: refusal) { try ConfigWriter.apply(EntryEdit.move("workspace", from: 0, to: 0), to: text) }
	}

	@Test func removesTheOnlyEntry() throws {
		#expect(try ConfigWriter.apply(EntryEdit.remove("workspace", 0), to: "[[workspace]]\nname = \"A\"\n") == "")
	}

	@Test func movesAnEntryOntoItselfAsNothing() throws {
		let text = file(code, plan, chat)
		#expect(try ConfigWriter.apply(EntryEdit.move("workspace", from: 1, to: 1), to: text) == text)
	}

	@Test func movesAMultilineEntryWhole() throws {
		let multi = "[[workspace]]\nname = \"A\"\napps = [\n\t\"X\",\n]"
		let other = "[[workspace]]\nname = \"B\""
		#expect(try ConfigWriter.apply(EntryEdit.move("workspace", from: 0, to: 1), to: multi + "\n\n" + other)
			== other + "\n\n" + multi)
	}

	@Test func refusesAMoveFromAnEntryThatIsNotThere() {
		#expect(throws: ConfigError.invalid("there is no workspace #4")) {
			try ConfigWriter.apply(EntryEdit.move("workspace", from: 3, to: 0), to: file(code, plan, chat))
		}
	}

	@Test func refusesASubTableThatStandsApart() {
		let refusal = ConfigError.invalid(
			"workspace is written in a way the settings window cannot change; change it in kumiko.toml"
		)
		let apart = "[[workspace]]\nname = \"A\"\n\n[[workspace]]\nname = \"B\"\n\n"
			+ "[hotkeys]\nenabled = true\n\n[workspace.share]\nTime = 0.7"
		#expect(throws: refusal) { try ConfigWriter.apply(EntryEdit.remove("workspace", 0), to: apart) }
		#expect(throws: refusal) { try ConfigWriter.apply(EntryEdit.move("workspace", from: 0, to: 1), to: apart) }

		let first = "[workspace.share]\nTime = 0.7\n\n[wm]\ngap = 4"
		#expect(throws: refusal) { try ConfigWriter.apply(EntryEdit.remove("workspace", 0), to: first) }
	}

	@Test func refusesAPlainTableOfTheArraysName() {
		let text = "[workspace]\nname = \"A\"\n"
		let refusal = ConfigError.invalid(
			"workspace is written in a way the settings window cannot change; change it in kumiko.toml"
		)
		#expect(throws: refusal) {
			try ConfigWriter.apply(EntryEdit.insert("workspace", fields: media.tomlFields), to: text)
		}
		#expect(throws: refusal) { try ConfigWriter.apply(EntryEdit.remove("workspace", 0), to: text) }
	}

	@Test func appliesChangesInOrder() throws {
		let changes: [any ConfigChange] = [
			EntryEdit.move("workspace", from: 0, to: 2),
			ConfigEdit(target: .entry("workspace", 2), key: "display", value: .string("main")),
		]
		let changed = try ConfigWriter.apply(changes, to: file(code, plan, chat))
		#expect(changed == file(plan, chat, code.replacingOccurrences(of: "external", with: "main")))
	}

	@Test func appliesEntryAndKeyChangesInOneBatch() throws {
		let changes: [any ConfigChange] = [
			EntryEdit.insert("workspace", fields: media.tomlFields),
			ConfigEdit(target: .entry("workspace", 3), key: "display", value: .string("external")),
		]
		let original = file(code, plan, chat)
		let changed = try ConfigWriter.apply(changes, to: original)
		let inserted = try ConfigWriter.apply(EntryEdit.insert("workspace", fields: media.tomlFields), to: original)
		#expect(changed == (try entry(3, "display", .string("external"), in: inserted)))
	}

	@Test func writesNoneOfTheChangesWhenOneFails() throws {
		let url = FileManager.default.temporaryDirectory.appending(path: "kumiko-\(UUID()).toml")
		defer { try? FileManager.default.removeItem(at: url) }
		try file(code, plan, chat).write(to: url, atomically: true, encoding: .utf8)

		#expect(throws: ConfigError.invalid("workspace \"Code\" is defined twice")) {
			try ConfigWriter.write([
				ConfigEdit(target: .entry("workspace", 2), key: "display", value: .string("main")),
				ConfigEdit(target: .entry("workspace", 1), key: "name", value: .string("Code")),
			], to: url)
		}
		#expect(try String(contentsOf: url, encoding: .utf8) == file(code, plan, chat))
	}

	@Test func leavesTheFileAloneWhenNothingChanges() throws {
		let url = FileManager.default.temporaryDirectory.appending(path: "kumiko-\(UUID()).toml")
		defer { try? FileManager.default.removeItem(at: url) }

		_ = try ConfigWriter.write([], to: url)
		#expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))

		_ = try ConfigWriter.write(ConfigEdit(target: .table("wm"), key: "gap", value: nil), to: url)
		#expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
	}
}
