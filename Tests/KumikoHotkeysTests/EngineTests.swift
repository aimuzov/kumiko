import KumikoCore
import Testing

@testable import KumikoHotkeys

private func combo(_ text: String) -> KeyCombo {
	try! KeyCombo.parse(text)
}

private func press(_ text: String, held: HeldModifiers? = nil, repeat isRepeat: Bool = false) -> KeyEvent {
	let combo = combo(text)
	return KeyEvent(keyCode: combo.keyCode, modifiers: held ?? HeldModifiers(combo.modifiers), isDown: true, isRepeat: isRepeat)
}

private func release(_ text: String) -> KeyEvent {
	KeyEvent(keyCode: combo(text).keyCode, modifiers: [], isDown: false)
}

private func config(
	bind: [String: HotkeyAction] = [:], global: [String: HotkeyAction] = [:],
	modes: [String: [String: HotkeyAction]] = [:], blacklist: [String] = []
) -> Config.Hotkeys {
	var config = Config.Hotkeys()
	config.bindings = Dictionary(uniqueKeysWithValues: bind.map { (combo($0.key), $0.value) })
	config.global = Dictionary(uniqueKeysWithValues: global.map { (combo($0.key), $0.value) })
	config.modes = modes.mapValues { table in Dictionary(uniqueKeysWithValues: table.map { (combo($0.key), $0.value) }) }
	config.blacklist = blacklist
	return config
}

struct KeyComboTests {
	@Test func parsesModifiersAndNamedKeys() throws {
		#expect(try KeyCombo.parse("cmd + ctrl - m") == KeyCombo(keyCode: 0x2E, modifiers: [.cmd, .ctrl]))
		#expect(try KeyCombo.parse("rcmd - escape") == KeyCombo(keyCode: 0x35, modifiers: [.rcmd]))
	}

	@Test func parsesHexKeyCodesWithoutModifiers() throws {
		#expect(try KeyCombo.parse("0xa") == KeyCombo(keyCode: 0x0A))
		#expect(try KeyCombo.parse("alt - 0x1B") == KeyCombo(keyCode: 0x1B, modifiers: [.alt]))
	}

	@Test func dashIsAKeyToo() throws {
		#expect(try KeyCombo.parse("-") == KeyCombo(keyCode: 0x1B))
		#expect(try KeyCombo.parse("cmd - -") == KeyCombo(keyCode: 0x1B, modifiers: [.cmd]))
	}

	@Test func rejectsUnknownNamesAndRepeatedFamilies() {
		#expect(throws: ConfigError.self) { try KeyCombo.parse("hyper - a") }
		#expect(throws: ConfigError.self) { try KeyCombo.parse("cmd - nope") }
		#expect(throws: ConfigError.self) { try KeyCombo.parse("cmd + rcmd - a") }
	}
}

struct EngineTests {
	@Test func boundKeyRunsItsCommandAndIsSwallowed() {
		var engine = Engine(config(bind: ["alt - 1": HotkeyAction(run: "workspace focus 1")]))
		let (decision, effects) = engine.handle(press("alt - 1"), frontmostApp: nil)

		#expect(decision == .swallow)
		#expect(effects == [.run("workspace focus 1")])
	}

	@Test func unboundKeyPassesInDefaultMode() {
		var engine = Engine(config(bind: ["alt - 1": HotkeyAction(run: "x")]))
		#expect(engine.handle(press("alt - 2"), frontmostApp: nil).0 == .pass)
	}

	@Test func extraModifierIsNotTheSameHotkey() {
		var engine = Engine(config(bind: ["alt - 1": HotkeyAction(run: "x")]))
		#expect(engine.handle(press("alt + shift - 1"), frontmostApp: nil).0 == .pass)
	}

	@Test func genericModifierTakesEitherSideButSidedOneDoesNot() {
		var engine = Engine(config(bind: ["cmd - a": HotkeyAction(run: "any"), "rcmd - b": HotkeyAction(run: "right")]))

		#expect(engine.handle(press("a", held: .rightCmd), frontmostApp: nil).1 == [.run("any")])
		#expect(engine.handle(press("b", held: .leftCmd), frontmostApp: nil).0 == .pass)
		#expect(engine.handle(press("b", held: .rightCmd), frontmostApp: nil).1 == [.run("right")])
	}

	@Test func fnSetByMacOSOnArrowsIsIgnored() {
		var engine = Engine(config(bind: ["ctrl - left": HotkeyAction(run: "x")]))
		#expect(engine.handle(press("left", held: [.leftCtrl, .fn]), frontmostApp: nil).0 == .swallow)
	}

	@Test func sendRemapsPressAndRelease() {
		var engine = Engine(config(bind: ["cmd + ctrl - j": HotkeyAction(send: combo("down"))]))
		let remap = Decision.remap(keyCode: 0x7D, modifiers: [])

		#expect(engine.handle(press("cmd + ctrl - j"), frontmostApp: nil).0 == remap)
		#expect(engine.handle(release("j"), frontmostApp: nil).0 == remap)
	}

	@Test func releaseOfASwallowedKeyIsSwallowedToo() {
		var engine = Engine(config(bind: ["cmd - h": HotkeyAction(block: true)]))

		#expect(engine.handle(press("cmd - h"), frontmostApp: nil).0 == .swallow)
		#expect(engine.handle(release("h"), frontmostApp: nil).0 == .swallow)
		#expect(engine.handle(release("h"), frontmostApp: nil).0 == .pass)
	}

	@Test func modeSwitchesAndSwallowsUnboundKeys() {
		var engine = Engine(config(
			global: ["cmd + ctrl - m": HotkeyAction(mode: "move")],
			modes: ["move": ["h": HotkeyAction(run: "window warp west"), "escape": HotkeyAction(mode: "default")]]
		))

		#expect(engine.handle(press("cmd + ctrl - m"), frontmostApp: nil).1 == [.modeChanged("move")])
		#expect(engine.handle(press("h"), frontmostApp: nil).1 == [.run("window warp west")])
		#expect(engine.handle(press("z"), frontmostApp: nil).0 == .swallow)
		#expect(engine.handle(press("escape"), frontmostApp: nil).1 == [.modeChanged("default")])
		#expect(engine.mode == "default")
	}

	@Test func globalBindingsWorkInEveryMode() {
		var engine = Engine(config(
			global: ["cmd + ctrl - m": HotkeyAction(mode: "move"), "cmd + ctrl - n": HotkeyAction(mode: "resize")],
			modes: ["move": [:], "resize": [:]]
		))

		_ = engine.handle(press("cmd + ctrl - m"), frontmostApp: nil)
		#expect(engine.handle(press("cmd + ctrl - n"), frontmostApp: nil).1 == [.modeChanged("resize")])
	}

	@Test func escapeLeavesAModeWithoutAnExit() {
		var engine = Engine(config(bind: ["alt - m": HotkeyAction(mode: "trap")], modes: ["trap": [:]]))

		_ = engine.handle(press("alt - m"), frontmostApp: nil)
		#expect(engine.handle(press("escape"), frontmostApp: nil).1 == [.modeChanged("default")])
	}

	@Test func commandAndModeTogether() {
		var engine = Engine(config(
			bind: ["alt - c": HotkeyAction(mode: "command")],
			modes: ["command": ["w": HotkeyAction(run: "reload", mode: "default")]]
		))

		_ = engine.handle(press("alt - c"), frontmostApp: nil)
		#expect(engine.handle(press("w"), frontmostApp: nil).1 == [.run("reload"), .modeChanged("default")])
	}

	@Test func repeatRunsCommandsButNotModeSwitches() {
		var engine = Engine(config(
			bind: ["alt - l": HotkeyAction(run: "window resize right 20"), "alt - m": HotkeyAction(mode: "move")],
			modes: ["move": [:]]
		))

		#expect(engine.handle(press("alt - l", repeat: true), frontmostApp: nil).1 == [.run("window resize right 20")])
		#expect(engine.handle(press("alt - m", repeat: true), frontmostApp: nil).1 == [])
	}

	@Test func blacklistedAppGetsEveryKey() {
		var engine = Engine(config(bind: ["alt - 1": HotkeyAction(run: "x")], blacklist: ["LayerX"]))
		#expect(engine.handle(press("alt - 1"), frontmostApp: "LayerX").0 == .pass)
		#expect(engine.handle(press("alt - 1"), frontmostApp: "Ghostty").0 == .swallow)
	}

	@Test func wordsKeepQuotedParts() {
		#expect(Hotkeys.words(#"workspace focus "My Work""#) == ["workspace", "focus", "My Work"])
		#expect(Hotkeys.words("  window  warp west ") == ["window", "warp", "west"])
	}
}
