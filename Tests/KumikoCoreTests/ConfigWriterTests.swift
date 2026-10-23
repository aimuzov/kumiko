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
}
