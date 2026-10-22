import Foundation
import KumikoCore
import Testing

struct ConfigTests {
	@Test func emptyFileIsTheDefault() throws {
		#expect(try Config.parse("") == Config())
	}

	@Test func everyModuleIsOnByDefault() throws {
		let config = try Config.parse("")
		#expect(config.wm.enabled && config.hotkeys.enabled && config.bar.enabled && config.borders.enabled)
	}

	@Test func sectionCanTurnItsModuleOff() throws {
		let config = try Config.parse("""
			[bar]
			enabled = false
			""")

		#expect(config.bar.enabled == false)
		#expect(config.wm.enabled)
	}

	@Test func emptySectionKeepsDefaults() throws {
		#expect(try Config.parse("[borders]") == Config())
	}

	@Test func brokenTOMLIsAnError() {
		#expect(throws: ConfigError.self) { try Config.parse("[bar") }
	}

	@Test func wrongTypeIsAnError() {
		#expect(throws: ConfigError.self) { try Config.parse("[wm]\nenabled = \"yes\"") }
	}

	@Test func missingFileIsTheDefault() throws {
		let url = FileManager.default.temporaryDirectory.appending(path: "kumiko-\(UUID()).toml")
		#expect(try Config.load(from: url) == Config())
	}

	@Test func wmRulesKeepFileOrder() throws {
		let config = try Config.parse("""
			[wm]
			manage = false

			[[wm.rule]]
			app = "Finder"
			manage = true

			[[wm.rule]]
			app = "Finder"
			title = "Settings"
			manage = false
			""")

		#expect(config.wm.manage == false)
		#expect(config.wm.rules == [
			WindowRule(app: "Finder", manage: true),
			WindowRule(app: "Finder", title: "Settings", manage: false),
		])
	}

	@Test func ruleWithoutManageIsAnError() {
		#expect(throws: ConfigError.self) { try Config.parse("[[wm.rule]]\napp = \"Finder\"") }
	}

	@Test func badPatternIsReportedWithItsRule() {
		#expect(throws: ConfigError.invalid("wm.rule #2: bad pattern \"Fin(der\"")) {
			try Config.parse("""
				[[wm.rule]]
				app = "Mail"
				manage = true

				[[wm.rule]]
				app = "Fin(der"
				manage = true
				""")
		}
	}

	@Test func syntaxErrorNamesTheLine() {
		#expect(throws: ConfigError.invalid("(Line 2) Syntax error: invalid key.")) {
			try Config.parse("[wm]\n[bar")
		}
	}

	@Test func typeErrorNamesTheKey() {
		#expect(throws: ConfigError.invalid("(Line 2) Invalid boolean value for key 'enabled'.")) {
			try Config.parse("[wm]\nenabled = \"yes\"")
		}
	}
}
