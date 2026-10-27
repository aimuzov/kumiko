import Foundation

/// The settings a new user can start from with one button: the author's own setup, twelve
/// workspaces on alt-1 ... alt-= and the apps that open on each. An app this Mac does not have is
/// left out of every list, so the file names only what is there.
///
/// What only fits one person stays out: the remaps of a keyboard layout, vim with the langmap of
/// a Russian layout, apps few people have.
public enum RecommendedSettings {
	/// One workspace of the preset, its apps by the names they are known by on any Mac.
	struct Workspace {
		var name: String
		var display: String
		var apps: [String] = []
		var isDefault = false
		var stack: [String] = []
		var last: [String] = []
		var size: [String: Double] = [:]
	}

	/// In the order of their hotkeys: the first is alt-1, the twelfth alt-=.
	static let workspaces: [Workspace] = [
		.init(name: "Code", display: "main", apps: ["WezTerm", "Ghostty", "Code", "Zed", "GitUp"]),
		.init(name: "Web", display: "main", apps: ["Dia", "Safari"]),
		.init(name: "AI", display: "main", apps: ["ChatGPT", "Claude", "Google Chrome", "Perplexity", "OpenCode"]),
		.init(name: "Design", display: "main", apps: ["Figma", "Blender", "SF Symbols"]),
		.init(name: "Files", display: "main", apps: ["Finder", "Cyberduck", "Preview", "Transmission"]),
		.init(name: "Inbox", display: "main", apps: ["Mail"]),
		.init(
			name: "System", display: "external",
			apps: [
				"App Store", "System Settings", "MacPass", "KeePassXC", "Kumiko", "Steam", "OrbStack", "AppCleaner",
				"Pearcleaner", "logioptionsplus",
			],
			stack: ["Steam"]
		),
		.init(name: "Agenda", display: "external", apps: ["Things", "Calendar"], stack: ["Things", "Calendar", "Mail"]),
		.init(name: "Misc", display: "external", isDefault: true),
		.init(
			name: "Chats", display: "external", apps: ["Telegram", "Time"], stack: ["Telegram"], last: ["Telegram"],
			size: ["Time": 0.6]
		),
		.init(name: "Calls", display: "external", apps: ["zoom.us"]),
		.init(name: "Media", display: "external", apps: ["Spotify", "Photos", "VLC"]),
	]

	/// `[[wm.rule]]` by app: these apps' windows are tiled, or left alone, whatever else says.
	static let rules: [(app: String, manage: Bool)] = [("Calendar", true), ("Mail", true), ("Steam", true)]

	/// Processes that are no app in a folder of apps, but whose windows the hotkeys keep away from.
	static let hotkeysSystemBlacklist = ["loginwindow", "screensaver"]
	static let bordersBlacklist = ["iPhone Mirroring"]
	static let vimBlacklist = ["Ghostty", "Notes", "Claude", "Telegram"]

	/// Other menu bar managers: with one of them installed, kumiko's own hiding stays off, or the
	/// two would fight over the same items.
	static let menuBarManagers = ["Bartender", "Bartender 4", "Bartender 5", "Ice", "Hidden Bar", "Dozer", "Vanilla"]

	/// What applying the preset writes.
	public struct Result: Equatable, Sendable {
		/// The whole of kumiko.toml.
		public var text: String
		/// The workspaces, each with the apps of this Mac it opens, as the file names them.
		public var workspaces: [Config.Workspace]
	}

	/// `installed` maps every name an installed app is known by (its bundle's file name, its
	/// `CFBundleName`) to the name kumiko sees it under, its `localizedName`: on a Mac in Russian
	/// `Photos` is `Фото`, and that is what the file has to say.
	public static func make(installed: [String: String]) -> Result {
		let workspaces = workspaces.map { preset in
			let apps = resolved(preset.apps, installed)
			return Config.Workspace(
				name: preset.name,
				display: preset.display,
				apps: apps.map(Config.Workspace.pattern),
				isDefault: preset.isDefault,
				stack: resolved(preset.stack, installed),
				last: resolved(preset.last, installed),
				size: Dictionary(uniqueKeysWithValues: preset.size.compactMap { app, size in
					installed[app].map { ($0, size) }
				})
			)
		}
		return Result(text: text(workspaces: workspaces, installed: installed), workspaces: workspaces)
	}

	/// For an installed set whose names are already what kumiko sees.
	public static func make(installed: Set<String>) -> Result {
		make(installed: Dictionary(uniqueKeysWithValues: installed.map { ($0, $0) }))
	}

	/// The names of `apps` this Mac has, as kumiko sees them, once each.
	private static func resolved(_ apps: [String], _ installed: [String: String]) -> [String] {
		var seen = Set<String>()
		return apps.compactMap { installed[$0] }.filter { seen.insert($0).inserted }
	}

	private static func array(_ items: [String]) -> String {
		TOMLValue.array(items.map(TOMLValue.string)).literal
	}

	private static func text(workspaces: [Config.Workspace], installed: [String: String]) -> String {
		var sections: [String] = []

		sections.append("""
			# Recommended settings, written by the settings window. Apps this Mac did not have are left out.

			[wm]
			gap = 8
			hide_apps = true
			workspaces = true
			shadows = false
			manage = true
			float_fixed_size = true
			keep_on_screen = true
			""")

		for rule in rules {
			guard let app = installed[rule.app] else { continue }
			sections.append("""
				[[wm.rule]]
				app = \(TOMLValue.string(Config.Workspace.pattern(for: app)).literal)
				manage = \(rule.manage)
				""")
		}

		for (index, workspace) in workspaces.enumerated() {
			let fields = workspace.tomlFields.map { "\(ConfigWriter.bare($0.key)) = \($0.value.literal)" }
			let header = index == 0 ? "# Numbers follow alt-1 ... alt-=, so the order here is the order of the hotkeys.\n\n" : ""
			sections.append(header + (["[[workspace]]"] + fields).joined(separator: "\n"))
		}

		let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "0x1b", "0x18"]
		let focus = zip(keys, 1...).map { key, number in "\"alt - \(key)\" = \"workspace focus \(number)\"" }
		sections.append("""
			[hotkeys]
			blacklist = \(array(hotkeysSystemBlacklist))

			[hotkeys.bind]
			\(focus.joined(separator: "\n"))

			"alt - h" = "window focus west"
			"alt - j" = "window focus south"
			"alt - k" = "window focus north"
			"alt - l" = "window focus east"

			# Entering a mode works from any mode.
			[hotkeys.global]
			"cmd + ctrl - w" = { mode = "window" }
			"cmd + ctrl - 0x29" = { mode = "command" }

			# Stays on until Esc. hjkl is the direction, the modifier the verb: none focuses, shift moves,
			# ctrl resizes, alt stacks.
			[hotkeys.mode.window]
			"escape" = { mode = "default" }
			"ctrl - 0x21" = { mode = "default" }
			"h" = "window focus west"
			"j" = "window focus south"
			"k" = "window focus north"
			"l" = "window focus east"
			"shift - h" = "window warp west || window move prev --focus"
			"shift - j" = "window warp south"
			"shift - k" = "window warp north"
			"shift - l" = "window warp east || window move next --focus"
			"ctrl - h" = "window resize right -20 || window resize left -20"
			"ctrl - j" = "window resize bottom 20 || window resize top 20"
			"ctrl - k" = "window resize bottom -20 || window resize top -20"
			"ctrl - l" = "window resize right 20 || window resize left 20"
			"alt - h" = "window stack west"
			"alt - j" = "window stack south"
			"alt - k" = "window stack north"
			"alt - l" = "window stack east"
			"n" = "window focus stack-next"
			"p" = "window focus stack-prev"
			"u" = "window unstack"
			"f" = "window float --grid 10:10:1:1:8:8"
			"m" = "window zoom fullscreen"
			"z" = "window zoom parent"
			"e" = "workspace balance"
			"r" = "workspace rotate 270"
			"x" = "workspace mirror vertical"
			"y" = "workspace mirror horizontal"
			"q" = "window close"

			# One-off actions, each goes back to the default mode.
			[hotkeys.mode.command]
			"escape" = { mode = "default" }
			"ctrl - 0x21" = { mode = "default" }
			"w" = { run = "reload", mode = "default" }
			"l" = { shell = "pmset displaysleepnow", mode = "default" }
			"t" = { run = "appearance toggle", mode = "default" }
			""")

		sections.append("""
			[borders]
			width = 4
			color = "#8aadf4"
			blacklist = \(array(resolved(bordersBlacklist, installed)))
			""")

		sections.append("""
			[vim]
			blacklist = \(array(resolved(vimBlacklist, installed)))
			""")

		let otherManager = menuBarManagers.contains { installed[$0] != nil }
		sections.append("""
			[menubar]
			enabled = \(!otherManager)
			""")

		return sections.joined(separator: "\n\n") + "\n"
	}
}

/// Applied, the preset is the whole file: whatever was in it goes.
extension RecommendedSettings.Result: ConfigChange {
	public func apply(to _: String) throws(ConfigError) -> String { text }
}
