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

	@Test func paddingIsOneNumberForAllSides() throws {
		let config = try Config.parse("[wm]\ngap = 6\npadding = 4")
		#expect(config.wm.gap == 6)
		#expect(config.wm.padding == Insets(all: 4))
	}

	@Test func paddingTableLeavesMissingSidesAtZero() throws {
		let config = try Config.parse("[wm]\npadding = { top = 4, bottom = 40 }")
		#expect(config.wm.padding == Insets(top: 4, bottom: 40))
	}

	@Test func layoutDefaultsWithoutAWmSection() throws {
		let config = try Config.parse("")
		#expect(config.wm.gap == 8)
		#expect(config.wm.padding == Insets(all: 8))
	}

	@Test func workspacesKeepFileOrderAndDefaults() throws {
		let config = try Config.parse("""
			[[workspace]]
			name = "Code"
			display = "external"
			apps = ["Ghostty", "Code"]

			[[workspace]]
			name = "Social"
			apps = ["Time", "Telegram"]
			last = ["Telegram"]
			share = { Time = 0.7 }
			""")

		#expect(config.workspaces == [
			Config.Workspace(name: "Code", display: "external", apps: ["Ghostty", "Code"]),
			Config.Workspace(name: "Social", apps: ["Time", "Telegram"], last: ["Telegram"], share: ["Time": 0.7]),
		])
	}

	@Test func duplicateWorkspaceNameIsAnError() {
		#expect(throws: ConfigError.invalid("workspace \"Code\" is defined twice")) {
			try Config.parse("[[workspace]]\nname = \"Code\"\n[[workspace]]\nname = \"Code\"")
		}
	}

	@Test func badWorkspacePatternIsAnError() {
		#expect(throws: ConfigError.invalid("workspace \"Web\": bad pattern \"Arc(\"")) {
			try Config.parse("[[workspace]]\nname = \"Web\"\napps = [\"Arc(\"]")
		}
	}

	@Test func hotkeysParseModesAndActions() throws {
		let config = try Config.parse("""
			[hotkeys]
			blacklist = ["LayerX"]

			[hotkeys.bind]
			"alt - 1" = "workspace focus 1"
			"0xa" = { send = "0x32" }

			[hotkeys.mode.move]
			"escape" = { mode = "default" }
			""")

		#expect(config.hotkeys.blacklist == ["LayerX"])
		#expect(config.hotkeys.bindings[try KeyCombo.parse("alt - 1")] == HotkeyAction(run: "workspace focus 1"))
		#expect(config.hotkeys.bindings[try KeyCombo.parse("0xa")] == HotkeyAction(send: try KeyCombo.parse("0x32")))
		#expect(config.hotkeys.modes["move"]?[try KeyCombo.parse("escape")] == HotkeyAction(mode: "default"))
	}

	@Test func hotkeyToAnUnknownModeIsAnError() {
		#expect(throws: ConfigError.invalid("hotkeys: no mode \"move\"")) {
			try Config.parse("[hotkeys.bind]\n\"alt - m\" = { mode = \"move\" }")
		}
	}

	@Test func badHotkeyIsReported() {
		#expect(throws: ConfigError.self) {
			try Config.parse("[hotkeys.bind]\n\"hyper - m\" = \"reload\"")
		}
	}

	@Test func hidingAppsIsOnUnlessTurnedOff() throws {
		#expect(try Config.parse("").wm.hideApps)
		#expect(try Config.parse("[wm]\nhide_apps = false").wm.hideApps == false)
	}

	@Test func bordersTakeTheJankyBordersSettings() throws {
		let config = try Config.parse("""
			[borders]
			width = 8
			radius = 10.5
			color = "0xff8aadf4"
			blacklist = ["Steam Helper", "dota2"]
			""")

		#expect(config.borders.width == 8)
		#expect(config.borders.radius == 10.5)
		#expect(config.borders.color == Color(red: 0x8A / 255, green: 0xAD / 255, blue: 0xF4 / 255))
		#expect(config.borders.blacklist == ["Steam Helper", "dota2"])
	}


	@Test func badBorderColourIsAnError() {
		#expect(throws: ConfigError.self) { try Config.parse("[borders]\ncolor = \"blue\"") }
	}

	@Test func barDefaultsToTheSketchybarSetup() throws {
		let bar = try Config.parse("").bar
		#expect(bar.position == .bottom)
		#expect(bar.height == 36)
		#expect(bar.left == ["workspaces", "mode", "window"])
		#expect(bar.right == ["datetime", "caffeinate", "battery", "input"])
		#expect(bar.colors.blue == (try Color.parse("0xff8aadf4")))
		#expect(bar.font.isEmpty && bar.fontSize == 0 && bar.colors.text == nil)
	}

	@Test func barTakesPositionColoursAndShellItems() throws {
		let bar = try Config.parse("""
			[bar]
			position = "top"
			height = 30
			right = ["datetime", "vpn"]

			[bar.colors]
			blue = "#112233"

			[[bar.shell]]
			name = "vpn"
			command = "echo on"
			interval = 10
			""").bar

		#expect(bar.position == .top)
		#expect(bar.height == 30)
		#expect(bar.colors.blue == (try Color.parse("#112233")))
		#expect(bar.colors.red == Config.Bar.Palette().red)
		#expect(bar.shell == [Config.Bar.ShellItem(name: "vpn", command: "echo on", interval: 10)])
	}

	@Test func unknownBarItemIsAnError() {
		#expect(throws: ConfigError.invalid("bar: no item \"clock\"")) {
			try Config.parse("[bar]\nleft = [\"clock\"]")
		}
	}
}
