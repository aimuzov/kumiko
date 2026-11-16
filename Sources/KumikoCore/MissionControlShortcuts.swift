import Foundation

/// The keyboard shortcuts that open Mission Control, App Exposé and Show Desktop, as set in System
/// Settings > Keyboard > Keyboard Shortcuts > Mission Control.
///
/// The Dock says it opened one of them only about 0.4 s after the key, when its animation is well
/// under way; the key itself comes some 20 ms before the animation starts.
public struct MissionControlShortcuts: Equatable, Sendable {
	public struct Shortcut: Hashable, Sendable {
		public var keyCode: Int64
		/// Shift, control, option and command, as `CGEventFlags` and `NSEvent.ModifierFlags` share them.
		public var modifiers: UInt64

		public init(keyCode: Int64, modifiers: UInt64) {
			self.keyCode = keyCode
			self.modifiers = modifiers & Self.mask
		}

		/// Shift, control, option, command: the flags a shortcut is told apart by. Arrow keys also
		/// carry the function and keypad flags, which say nothing about the shortcut.
		static let mask: UInt64 = 0x1E_0000
	}

	public var shortcuts: Set<Shortcut>

	/// Mission Control, its slow variant, App Exposé, its slow variant, Show Desktop and its slow
	/// variant, by their numbers in `com.apple.symbolichotkeys`, with the shortcut macOS gives each
	/// until it is changed.
	static let defaults: [(id: String, shortcut: Shortcut)] = [
		("32", Shortcut(keyCode: 126, modifiers: 0x4_0000)),
		("34", Shortcut(keyCode: 126, modifiers: 0x6_0000)),
		("33", Shortcut(keyCode: 125, modifiers: 0x4_0000)),
		("35", Shortcut(keyCode: 125, modifiers: 0x6_0000)),
		("36", Shortcut(keyCode: 103, modifiers: 0)),
		("37", Shortcut(keyCode: 103, modifiers: 0x2_0000)),
	]

	/// `hotkeys` is the `AppleSymbolicHotKeys` dictionary of `com.apple.symbolichotkeys`. An entry
	/// missing there has its default shortcut; a disabled one has none.
	public init(hotkeys: [String: Any]?) {
		var shortcuts: Set<Shortcut> = []
		for (id, fallback) in Self.defaults {
			guard let entry = hotkeys?[id] as? [String: Any] else {
				shortcuts.insert(fallback)
				continue
			}
			guard
				(entry["enabled"] as? Bool) ?? (entry["enabled"] as? Int).map({ $0 != 0 }) ?? false,
				let value = entry["value"] as? [String: Any],
				let parameters = value["parameters"] as? [Any], parameters.count == 3,
				let keyCode = (parameters[1] as? NSNumber)?.int64Value, keyCode != 65535,
				let modifiers = (parameters[2] as? NSNumber)?.uint64Value
			else { continue }
			shortcuts.insert(Shortcut(keyCode: keyCode, modifiers: modifiers))
		}
		self.shortcuts = shortcuts
	}

	/// The shortcuts set on this Mac now.
	public static func current() -> MissionControlShortcuts {
		let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
		return MissionControlShortcuts(hotkeys: hotkeys)
	}

	public func matches(keyCode: Int64, flags: UInt64) -> Bool {
		shortcuts.contains(Shortcut(keyCode: keyCode, modifiers: flags))
	}
}
