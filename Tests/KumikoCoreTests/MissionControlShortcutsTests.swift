import Foundation
import KumikoCore
import Testing

struct MissionControlShortcutsTests {
	/// ctrl-down as macOS reports it: control, keypad, function and the left control key's own bit.
	private let controlDown: UInt64 = 0xA4_0001

	@Test func aMacThatNeverChangedThemHasTheDefaults() {
		let shortcuts = MissionControlShortcuts(hotkeys: nil)

		#expect(shortcuts.matches(keyCode: 125, flags: controlDown))
		#expect(shortcuts.matches(keyCode: 126, flags: controlDown))
		#expect(shortcuts.matches(keyCode: 103, flags: 0x80_0000))
		#expect(!shortcuts.matches(keyCode: 125, flags: 0xA0_0000))
		#expect(!shortcuts.matches(keyCode: 125, flags: 0x10_0000 | 0xA0_0000))
	}

	@Test func aChangedShortcutReplacesItsDefault() {
		let hotkeys: [String: Any] = [
			"33": ["enabled": true, "value": ["parameters": [65535, 125, 0x10_0000], "type": "standard"]],
		]
		let shortcuts = MissionControlShortcuts(hotkeys: hotkeys)

		#expect(shortcuts.matches(keyCode: 125, flags: 0xB0_0000))
		#expect(!shortcuts.matches(keyCode: 125, flags: controlDown))
		#expect(shortcuts.matches(keyCode: 126, flags: controlDown))
	}

	@Test func aDisabledShortcutOpensNothing() {
		let hotkeys: [String: Any] = [
			"32": ["enabled": false, "value": ["parameters": [65535, 126, 0x84_0000], "type": "standard"]],
			"33": ["enabled": 0, "value": ["parameters": [65535, 125, 0x84_0000], "type": "standard"]],
		]
		let shortcuts = MissionControlShortcuts(hotkeys: hotkeys)

		#expect(!shortcuts.matches(keyCode: 126, flags: controlDown))
		#expect(!shortcuts.matches(keyCode: 125, flags: controlDown))
	}
}
