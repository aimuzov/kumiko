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

	@Test func menuBarHidingIsOffByDefault() throws {
		let config = try Config.parse("[menubar]")
		#expect(config.menuBar == Config.MenuBar())
		#expect(config.menuBar.enabled == false)
	}

	@Test func menuBarReadsItsKeys() throws {
		let config = try Config.parse("""
			[menubar]
			enabled = true
			rehide = 15
			""")

		#expect(config.menuBar.enabled)
		#expect(config.menuBar.rehide == 15)
	}

	@Test func negativeRehideIsAnError() {
		#expect(throws: ConfigError.self) { try Config.parse("[menubar]\nrehide = -1") }
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
		#expect(config.wm.padding == Insets(all: 4))
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

	@Test func workspacesAndRulesAreOnUnlessTurnedOff() throws {
		let defaults = try Config.parse("").wm
		#expect(defaults.useWorkspaces && defaults.useRules)

		let off = try Config.parse("[wm]\nworkspaces = false\nrules = false").wm
		#expect(!off.useWorkspaces && !off.useRules)
	}

	@Test func shadowsStayUnlessTurnedOff() throws {
		#expect(try Config.parse("").wm.shadows)
		#expect(try Config.parse("[wm]\nshadows = false").wm.shadows == false)
	}

	@Test func bordersTakeTheJankyBordersSettings() throws {
		let config = try Config.parse("""
			[borders]
			width = 8
			color = "0xff8aadf4"
			blacklist = ["Steam Helper", "dota2"]
			""")

		#expect(config.borders.width == 8)
		#expect(config.borders.color == Color(red: 0x8A / 255, green: 0xAD / 255, blue: 0xF4 / 255))
		#expect(config.borders.blacklist == ["Steam Helper", "dota2"])
	}


	@Test func borderColourIsTheAccentUnlessSet() throws {
		#expect(try Config.parse("").borders.color == nil)
		#expect(try Config.parse("[borders]\ncolor = \"accent\"").borders.color == nil)
		#expect(try Config.parse("[borders]\ncolor = \"#112233\"").borders.color == (try Color.parse("#112233")))
	}

	@Test func bordersOwnColourIsTheBarsBlue() {
		#expect(Config.Borders.ownColor == Config.Bar.Palette().blue)
	}

	@Test func badBorderColourIsAnError() {
		#expect(throws: ConfigError.self) { try Config.parse("[borders]\ncolor = \"blue\"") }
	}

	@Test func barDefaultsToTheSketchybarSetup() throws {
		let bar = try Config.parse("").bar
		#expect(bar.height == 36)
		#expect(bar.left == ["workspaces", "mode", "window"])
		#expect(bar.right == ["datetime", "caffeinate", "battery", "input"])
		#expect(bar.colors.blue == (try Color.parse("0xff8aadf4")))
		#expect(bar.font.isEmpty && bar.fontSize == 0 && bar.colors.text == nil)
	}

	@Test func leftoverBarPositionIsIgnored() throws {
		// The bar could once go on top; a config that still says so must load, with the bar at the bottom.
		#expect(try Config.parse("[bar]\nposition = \"top\"") == Config())
	}

	@Test func barTakesHeightColoursAndShellItems() throws {
		let bar = try Config.parse("""
			[bar]
			height = 40
			right = ["datetime", "vpn"]

			[bar.colors]
			blue = "#112233"

			[[bar.shell]]
			name = "vpn"
			command = "echo on"
			interval = 10
			""").bar

		#expect(bar.height == 40)
		#expect(bar.colors.blue == (try Color.parse("#112233")))
		#expect(bar.colors.red == Config.Bar.Palette().red)
		#expect(bar.shell == [Config.Bar.ShellItem(name: "vpn", command: "echo on", interval: 10)])
	}

	@Test func unknownBarItemIsAnError() {
		#expect(throws: ConfigError.invalid("bar: no item \"clock\"")) {
			try Config.parse("[bar]\nleft = [\"clock\"]")
		}
	}

	@Test func barMagnifiesLikeTheDockUnlessTold() throws {
		#expect(try Config.parse("").bar.magnification == .dock)
		#expect(try Config.parse("").bar.magnificationSize == 0)

		let bar = try Config.parse("[bar]\nmagnification = \"off\"\nmagnification_size = 28").bar
		#expect(bar.magnification == .off)
		#expect(bar.magnificationSize == 28)
	}

	@Test func badMagnificationIsAnError() {
		#expect(throws: ConfigError.self) { try Config.parse("[bar]\nmagnification = \"big\"") }
		#expect(throws: ConfigError.invalid("bar: magnification_size must not be negative")) {
			try Config.parse("[bar]\nmagnification_size = -1")
		}
	}

	@Test func barIsAtScaleOneByDefault() throws {
		let bar = try Config.parse("").bar
		#expect(bar.scale == 1)
		#expect(bar.height == 36)
	}

	@Test func barReadsItsScale() throws {
		let bar = try Config.parse("[bar]\nscale = 1.5\nheight = 60").bar
		#expect(bar.scale == 1.5)
		#expect(bar.height == 60)
	}

	@Test func barIsNeverLowerThanItsScaleNeeds() throws {
		#expect(try Config.parse("[bar]\nscale = 1.5\nheight = 40").bar.height == 54)
		#expect(try Config.parse("[bar]\nheight = 20").bar.height == 36)
	}

	@Test func leastHeightIsInWholePoints() throws {
		#expect(try Config.parse("[bar]\nscale = 1.05").bar.height == 38)
		#expect(try Config.parse("[bar]\nscale = 1.25").bar.height == 45)
		// Twelfths, as the settings window writes them.
		#expect(try Config.parse("[bar]\nscale = 1.0833").bar.height == 39)
		#expect(try Config.parse("[bar]\nscale = 1.1667").bar.height == 42)
	}

	@Test func scaleThatIsNotPositiveIsAnError() {
		for scale in ["0", "-1"] {
			#expect(throws: ConfigError.invalid("bar: scale must be greater than 0")) {
				try Config.parse("[bar]\nscale = \(scale)")
			}
		}
	}
}
