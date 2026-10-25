import Foundation
import KumikoCore
import Testing

struct HotkeyBindingsTests {
	/// The hotkeys of the kumiko.toml the page was made for, shortened.
	private let text = """
		[hotkeys]
		blacklist = ["LayerX", "loginwindow"]

		[hotkeys.bind]
		"0xa" = { send = "0x32" }
		"cmd + ctrl - j" = { send = "down" } # vim keys
		"cmd - h" = { block = true }
		"alt - 1" = "workspace focus 1"

		# Entering a mode works from any mode.
		[hotkeys.global]
		"cmd + ctrl - i" = { mode = "window" }

		[hotkeys.mode.window]
		"escape" = { mode = "default" }
		"h" = "window focus west"
		"f" = "window float --grid 10:10:1:1:8:8"

		[hotkeys.mode.command]
		"w" = { run = "reload", mode = "default" }

		[[workspace]]
		name = "Code"
		"""

	private func read(_ text: String) throws -> HotkeyBindings {
		HotkeyBindings(try Config.parse(text).hotkeys, text: text)
	}

	private func apply(_ changes: [any ConfigChange]) throws -> String {
		let changed = try ConfigWriter.apply(changes, to: text)
		_ = try Config.parse(changed)
		return changed
	}

	private func combo(_ text: String) throws -> KeyCombo {
		try KeyCombo.parse(text)
	}

	// MARK: - Reading

	@Test func readsTheModesAndBindingsInFileOrder() throws {
		let bindings = try read(text)

		#expect(bindings.modes.map(\.title) == ["Default", "Every mode", "Window", "Command"])
		#expect(bindings.mode(.default)?.bindings.map(\.key) == ["0xa", "cmd + ctrl - j", "cmd - h", "alt - 1"])
		#expect(bindings.mode(.named("window"))?.bindings.map(\.key) == ["escape", "h", "f"])
	}

	@Test func namesActionsAndShortcutsForPeople() throws {
		let window = try #require(try read(text).mode(.named("window")))

		#expect(window.bindings.map { HotkeyCatalog.title(of: $0.action) } == [
			"Switch to Default", "Focus window · Left", "window float --grid 10:10:1:1:8:8",
		])
		#expect(HotkeyCatalog.symbols(try combo("cmd + ctrl - j")) == "⌃⌘J")
		#expect(HotkeyCatalog.symbols(try combo("rcmd - 1")) == "R⌘1")
		#expect(HotkeyCatalog.symbols(try combo("0xa")) == "§")
		#expect(HotkeyCatalog.title(of: HotkeyAction(run: "reload", mode: "default")) == "Reload config, then Default")
	}

	@Test func catalogRoundTripsItsCommands() {
		#expect(HotkeyCatalog.command(for: "workspace focus 3")?.command.title == "Show workspace")
		#expect(HotkeyCatalog.command(for: "window focus west")?.option?.title == "Left")
		#expect(HotkeyCatalog.command(for: "window focus nowhere") == nil)
		#expect(HotkeyCatalog.command(for: "window resize right 20 || window resize left 20") == nil)
	}

	// MARK: - Writing

	@Test func changesAnActionOnItsLine() throws {
		let changed = try apply(try read(text).setAction(HotkeyAction(send: try combo("up")), of: "cmd + ctrl - j", in: .default))
		#expect(changed.contains(#""cmd + ctrl - j" = { send = "up" } # vim keys"#))
		#expect(changed.replacingOccurrences(of: #"{ send = "up" }"#, with: #"{ send = "down" }"#) == text)
	}

	@Test func writesACommandAloneAsAString() throws {
		let changed = try apply(try read(text).setAction(HotkeyAction(run: "window close"), of: "cmd - h", in: .default))
		#expect(changed.contains(#""cmd - h" = "window close""#))
	}

	@Test func changesAShortcutInPlace() throws {
		let changed = try apply(try read(text).setShortcut(try combo("ctrl + cmd - n"), of: "cmd + ctrl - j", in: .default))
		#expect(changed.contains(#""cmd + ctrl - n" = { send = "down" } # vim keys"#))
		#expect(try read(changed).mode(.default)?.bindings.map(\.key) == ["0xa", "cmd + ctrl - n", "cmd - h", "alt - 1"])
	}

	@Test func aTakenShortcutGivesUpItsBinding() throws {
		let changed = try apply(try read(text).setShortcut(try combo("cmd - h"), of: "alt - 1", in: .default))
		let keys = try read(changed).mode(.default)?.bindings.map(\.key)
		#expect(keys == ["0xa", "cmd + ctrl - j", "cmd - h"])
		#expect(try read(changed).binding("cmd - h", in: .default)?.action == HotkeyAction(run: "workspace focus 1"))
	}

	@Test func addsAfterTheLastShortcutAndRemoves() throws {
		let added = try apply(try read(text).add(try combo("h"), HotkeyAction(run: "window close"), in: .named("command")))
		#expect(try read(added).mode(.named("command"))?.bindings.map(\.key) == ["w", "h"])

		let removed = try ConfigWriter.apply(try read(text).remove("cmd - h", from: .default), to: text)
		#expect(!removed.contains("cmd - h"))
	}

	@Test func addsAModeWithEscBackToDefault() throws {
		let bindings = try read(text)
		#expect(!bindings.canAddMode("window"))
		#expect(!bindings.canAddMode("my mode"))

		let changed = try apply(bindings.addMode("launch"))
		#expect(changed.contains("[hotkeys.mode.launch]\nescape = { mode = \"default\" }"))
		#expect(try read(changed).mode(.named("launch"))?.bindings.count == 1)
	}

	@Test func removesAModeAndWhatSwitchesToIt() throws {
		let changed = try apply(try read(text).removeMode("window"))

		#expect(!changed.contains("[hotkeys.mode.window]"))
		#expect(!changed.contains("cmd + ctrl - i"))
		#expect(changed.contains("# Entering a mode works from any mode.\n[hotkeys.global]"))
		#expect(try read(changed).modes.map(\.title) == ["Default", "Every mode", "Command"])
	}

	@Test func removingAModeKeepsWhatElseAShortcutDoes() throws {
		let text = self.text + "\n\n[hotkeys.mode.stack]\n\"r\" = { run = \"reload\", mode = \"command\" }\n"
		let changed = try ConfigWriter.apply(try read(text).removeMode("command"), to: text)
		#expect(changed.contains(#""r" = "reload""#))
		_ = try Config.parse(changed)
	}

	@Test func editsTheExceptionsAndTheModeChangeCommand() throws {
		let bindings = try read(text)
		let changed = try apply(bindings.setBlacklist(["LayerX"]) + bindings.setOnModeChange("sketchybar --trigger mode"))
		let hotkeys = try Config.parse(changed).hotkeys
		#expect(hotkeys.blacklist == ["LayerX"])
		#expect(hotkeys.onModeChange == "sketchybar --trigger mode")
	}
}
