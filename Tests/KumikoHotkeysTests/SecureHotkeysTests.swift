import Carbon
import KumikoCore
import Testing

@testable import KumikoHotkeys

@MainActor
struct SecureHotkeysTests {
	@Test func registeredSystemEventReachesCommandHandler() throws {
		let combo = try KeyCombo.parse("cmd + ctrl + shift - f20")
		var received: [KeyCombo] = []
		let hotkeys = SecureHotkeys { received.append($0) }
		defer { hotkeys.stop() }
		hotkeys.update([combo])

		var event: EventRef?
		#expect(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr)
		let created = try #require(event)
		defer { ReleaseEvent(created) }
		var id = EventHotKeyID(signature: 0x4B554D49, id: 1)
		#expect(SetEventParameter(created, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
		                          MemoryLayout<EventHotKeyID>.size, &id) == noErr)
		#expect(SendEventToEventTarget(created, GetApplicationEventTarget()) == noErr)
		#expect(received == [combo])

		hotkeys.update([])
		#expect(SendEventToEventTarget(created, GetApplicationEventTarget()) == OSStatus(eventNotHandledErr))
		#expect(received == [combo])
	}

	@Test func workspaceShortcutsHaveSecureInputFallback() throws {
		let combo = try KeyCombo.parse("alt - 1")
		var config = Config.Hotkeys()
		config.bindings = [combo: HotkeyAction(run: "workspace focus 1")]
		#expect(SecureHotkeys.bindings(config, mode: "default") == [combo])
	}

	@Test func registeredGenericShortcutDoesNotPickASidedBinding() throws {
		let generic = try KeyCombo.parse("alt - 1")
		var config = Config.Hotkeys()
		config.bindings = [generic: HotkeyAction(run: "generic"), try KeyCombo.parse("lalt - 1"): HotkeyAction(run: "left")]
		var engine = Engine(config)
		let event = KeyEvent(keyCode: generic.keyCode, modifiers: [], isDown: true)
		#expect(engine.handle(event, frontmostApp: nil, registeredCombo: generic).1 == [.run("generic")])
	}

	@Test func fallbackUsesCurrentModeAndDoesNotRegisterRemapsOrSidedKeys() throws {
		let workspace = try KeyCombo.parse("alt - 1")
		let mode = try KeyCombo.parse("ctrl - m")
		let remap = try KeyCombo.parse("alt - 2")
		let sided = try KeyCombo.parse("ralt - 3")
		var config = Config.Hotkeys()
		config.bindings = [workspace: HotkeyAction(run: "workspace focus 1")]
		config.global = [mode: HotkeyAction(mode: "move")]
		config.modes = ["move": [remap: HotkeyAction(send: workspace), sided: HotkeyAction(run: "workspace focus 3")]]
		#expect(SecureHotkeys.bindings(config, mode: "move") == [mode])
	}
}
