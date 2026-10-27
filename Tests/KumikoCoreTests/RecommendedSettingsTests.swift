import Foundation
import KumikoCore
import Testing

@Suite("Recommended settings")
struct RecommendedSettingsTests {
	private let names = [
		"Code", "Web", "AI", "Design", "Files", "Inbox", "System", "Agenda", "Misc", "Chats", "Calls", "Media",
	]

	@Test("every workspace is there, in hotkey order, even with no app installed")
	func workspacesAlways() throws {
		let result = RecommendedSettings.make(installed: Set<String>())
		let config = try Config.parse(result.text)

		#expect(config.workspaces.map(\.name) == names)
		#expect(result.workspaces.map(\.name) == names)
		#expect(config.workspaces.allSatisfy { $0.apps.isEmpty && $0.stack.isEmpty && $0.last.isEmpty && $0.size.isEmpty })
		#expect(config.workspaces.filter(\.isDefault).map(\.name) == ["Misc"])
		#expect(config.workspaces.prefix(6).allSatisfy { $0.display == "main" })
		#expect(config.workspaces.dropFirst(6).allSatisfy { $0.display == "external" })
		#expect(config.wm.rules.isEmpty)
		#expect(config.borders.blacklist.isEmpty)
		#expect(config.vim.blacklist.isEmpty)
	}

	@Test("the file is what the result says it writes")
	func resultMatchesText() throws {
		let result = RecommendedSettings.make(installed: ["Safari", "Telegram", "Time", "Steam", "zoom.us"])
		#expect(try Config.parse(result.text).workspaces == result.workspaces)
	}

	@Test("only installed apps are listed, in the preset's order")
	func filtersApps() throws {
		let config = try Config.parse(RecommendedSettings.make(installed: ["Zed", "WezTerm", "Safari", "Finder"]).text)

		#expect(config.workspaces[0].apps == ["WezTerm", "Zed"])
		#expect(config.workspaces[1].apps == ["Safari"])
		#expect(config.workspaces[4].apps == ["Finder"])
		#expect(config.workspaces[2].apps.isEmpty)
	}

	@Test("stack, last and size keep only the installed apps")
	func filtersOtherLists() throws {
		let chats = try Config.parse(RecommendedSettings.make(installed: ["Telegram", "Time"]).text).workspaces[9]
		#expect(chats.apps == ["Telegram", "Time"])
		#expect(chats.stack == ["Telegram"])
		#expect(chats.last == ["Telegram"])
		#expect(chats.size == ["Time": 0.6])

		let without = try Config.parse(RecommendedSettings.make(installed: ["Telegram"]).text).workspaces[9]
		#expect(without.size.isEmpty)

		// Mail is stacked on Agenda although it opens on Inbox.
		let agenda = try Config.parse(RecommendedSettings.make(installed: ["Mail"]).text).workspaces[7]
		#expect(agenda.apps.isEmpty)
		#expect(agenda.stack == ["Mail"])
	}

	@Test("a name is written the way kumiko sees the app, a dot and all")
	func localizedNames() throws {
		let result = RecommendedSettings.make(installed: ["Photos": "Фото", "zoom.us": "zoom.us", "Mail": "Почта"])
		let config = try Config.parse(result.text)

		#expect(config.workspaces[11].apps == ["Фото"])
		#expect(config.workspaces[10].opens("zoom.us"))
		#expect(!config.workspaces[10].opens("zoomXus"))
		#expect(config.workspaces[5].apps == ["Почта"])
		#expect(config.wm.rules == [WindowRule(app: "Почта", manage: true)])
	}

	@Test("rules and blacklists name only installed apps")
	func filtersRulesAndBlacklists() throws {
		let config = try Config.parse(RecommendedSettings.make(installed: [
			"Steam", "iPhone Mirroring", "Notes", "Ghostty",
		]).text)

		#expect(config.wm.rules == [WindowRule(app: "Steam", manage: true)])
		#expect(config.borders.blacklist == ["iPhone Mirroring"])
		#expect(config.vim.blacklist == ["Ghostty", "Notes"])
		#expect(config.hotkeys.blacklist == ["loginwindow", "screensaver"])
	}

	@Test("alt-1 ... alt-= focus the twelve workspaces")
	func workspaceHotkeys() throws {
		let config = try Config.parse(RecommendedSettings.make(installed: Set<String>()).text)
		let bindings = config.hotkeys.bindings

		#expect(bindings[try KeyCombo.parse("alt - 1")] == HotkeyAction(run: "workspace focus 1"))
		#expect(bindings[try KeyCombo.parse("alt - 0x18")] == HotkeyAction(run: "workspace focus 12"))
		#expect(Set(config.hotkeys.modes.keys) == ["window", "command"])
	}

	@Test("hiding menu bar items stays off next to another menu bar manager")
	func menuBarManager() throws {
		#expect(try Config.parse(RecommendedSettings.make(installed: Set<String>()).text).menuBar.enabled)
		#expect(try !Config.parse(RecommendedSettings.make(installed: ["Bartender 5"]).text).menuBar.enabled)
	}

	@Test("the whole preset installed parses, every app placed")
	func everythingInstalled() throws {
		let all: Set<String> = [
			"WezTerm", "Ghostty", "Code", "Zed", "GitUp", "Dia", "Safari", "ChatGPT", "Claude", "Google Chrome",
			"Perplexity", "OpenCode", "Figma", "Blender", "SF Symbols", "Finder", "Cyberduck", "Preview",
			"Transmission", "Mail", "App Store", "System Settings", "MacPass", "KeePassXC", "Kumiko", "Steam",
			"OrbStack", "AppCleaner", "Pearcleaner", "logioptionsplus", "Things", "Calendar", "Telegram", "Time",
			"zoom.us", "Spotify", "Photos", "VLC",
		]
		let config = try Config.parse(RecommendedSettings.make(installed: all).text)
		let placed = config.workspaces.flatMap(\.appRows)

		#expect(Set(placed) == all)
		#expect(config.wm.rules.count == 3)
		#expect(config.borders.color?.hex == Config.Borders.ownColor.hex)
		#expect(config.wm.shadows == false)
		#expect(config.wm.keepOnScreen)
	}

	@Test("applied, it replaces the whole file")
	func replacesTheFile() throws {
		let url = FileManager.default.temporaryDirectory.appending(path: "kumiko-\(UUID()).toml")
		defer { try? FileManager.default.removeItem(at: url) }
		try "# mine\n[wm]\ngap = 20\n\n[[workspace]]\nname = \"Old\"\n".write(to: url, atomically: true, encoding: .utf8)

		let result = RecommendedSettings.make(installed: ["Safari"])
		let config = try ConfigWriter.write([result], to: url)

		#expect(try String(contentsOf: url, encoding: .utf8) == result.text)
		#expect(config.wm.gap == 8)
		#expect(config.workspaces.map(\.name) == names)
	}
}
