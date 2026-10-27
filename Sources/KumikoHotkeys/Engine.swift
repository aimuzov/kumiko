import Foundation
import KumikoCore

/// Modifier keys as they are held, side by side, the way a key event reports them.
struct HeldModifiers: OptionSet, Hashable {
	let rawValue: UInt16

	static let leftCmd = HeldModifiers(rawValue: 1 << 0)
	static let rightCmd = HeldModifiers(rawValue: 1 << 1)
	static let leftAlt = HeldModifiers(rawValue: 1 << 2)
	static let rightAlt = HeldModifiers(rawValue: 1 << 3)
	static let leftCtrl = HeldModifiers(rawValue: 1 << 4)
	static let rightCtrl = HeldModifiers(rawValue: 1 << 5)
	static let leftShift = HeldModifiers(rawValue: 1 << 6)
	static let rightShift = HeldModifiers(rawValue: 1 << 7)
	static let fn = HeldModifiers(rawValue: 1 << 8)

	/// The held set a remap sends for a combo: generic modifiers are pressed on the left.
	init(_ modifiers: Set<KeyCombo.Modifier>) {
		var held: HeldModifiers = []
		for modifier in modifiers {
			switch modifier {
			case .cmd, .lcmd: held.insert(.leftCmd)
			case .rcmd: held.insert(.rightCmd)
			case .alt, .lalt: held.insert(.leftAlt)
			case .ralt: held.insert(.rightAlt)
			case .ctrl, .lctrl: held.insert(.leftCtrl)
			case .rctrl: held.insert(.rightCtrl)
			case .shift, .lshift: held.insert(.leftShift)
			case .rshift: held.insert(.rightShift)
			case .fn: held.insert(.fn)
			}
		}
		self = held
	}

	init(rawValue: UInt16) {
		self.rawValue = rawValue
	}
}

struct KeyEvent {
	var keyCode: UInt16
	var modifiers: HeldModifiers
	var isDown: Bool
	var isRepeat = false
}

/// What to do with the event that came in.
enum Decision: Equatable {
	case pass
	case swallow
	/// Send this key instead, with exactly these modifiers held.
	case remap(keyCode: UInt16, modifiers: HeldModifiers)
}

/// What a hotkey asks the app to do, after the event has been decided.
enum Effect: Equatable {
	case run(String)
	case shell(String)
	case modeChanged(String)
}

/// Matches key events against the bindings of the current mode. Pure state: it never touches a
/// real event, so every rule here is tested without a keyboard.
struct Engine {
	private(set) var mode = "default"
	private var config: Config.Hotkeys
	/// Keys whose press was consumed or remapped, so their release gets the same treatment and an
	/// app never sees a lone key-up.
	private var held: [UInt16: Decision] = [:]
	/// The last key pressed while a mode was on, the one that turned it on included, in uptime
	/// seconds.
	private var lastKey: TimeInterval = 0

	static let escape: UInt16 = 0x35
	/// How long after a key of the mode an app coming to the front counts as that key's doing.
	static let activationGrace: TimeInterval = 1

	init(_ config: Config.Hotkeys) {
		self.config = config
	}

	mutating func update(_ config: Config.Hotkeys) {
		self.config = config
		if mode != "default", config.modes[mode] == nil { mode = "default" }
	}

	/// Forgets the mode and held keys: after the tap was off, the state may be stale.
	mutating func reset() -> [Effect] {
		held = [:]
		return leaveMode()
	}

	/// When the mode times out, in uptime seconds; nil while it never does.
	var deadline: TimeInterval? {
		guard mode != "default", config.modeTimeout > 0 else { return nil }
		return lastKey + config.modeTimeout
	}

	/// Ends a mode no key was pressed in for `mode_timeout`: it was most likely forgotten.
	mutating func expire(at now: TimeInterval) -> [Effect] {
		guard let deadline, now >= deadline else { return [] }
		return leaveMode()
	}

	/// A click means the user went back to the mouse and the mode is no longer wanted.
	mutating func click() -> [Effect] {
		leaveMode()
	}

	/// Another app came to the front. Right after a key of the mode, its command did that, like
	/// `window focus west`; later it is the user's doing, and the mode goes.
	mutating func appActivated(at now: TimeInterval) -> [Effect] {
		guard now - lastKey >= Self.activationGrace else { return [] }
		return leaveMode()
	}

	mutating func handle(
		_ event: KeyEvent, frontmostApp: String?, now: TimeInterval = ProcessInfo.processInfo.systemUptime
	) -> (Decision, [Effect]) {
		if !event.isDown {
			return (held.removeValue(forKey: event.keyCode) ?? .pass, [])
		}

		// A key after the timeout is the default mode's, so it reaches the app as it was typed.
		let expired = expire(at: now)
		let (decision, effects) = decide(event, frontmostApp: frontmostApp)
		if mode != "default" { lastKey = now }
		return (decision, expired + effects)
	}

	private mutating func leaveMode() -> [Effect] {
		guard mode != "default" else { return [] }
		mode = "default"
		return [.modeChanged(mode)]
	}

	private mutating func decide(_ event: KeyEvent, frontmostApp: String?) -> (Decision, [Effect]) {
		if let app = frontmostApp, config.blacklist.contains(app) {
			return (.pass, [])
		}

		let table = mode == "default" ? config.bindings : config.modes[mode] ?? [:]

		guard let action = Self.match(event, in: table) ?? Self.match(event, in: config.global) else {
			if mode == "default" { return (.pass, []) }

			// A mode with no way out must not trap the keyboard.
			if event.keyCode == Self.escape {
				held[event.keyCode] = .swallow
				mode = "default"
				return (.swallow, [.modeChanged(mode)])
			}

			held[event.keyCode] = .swallow
			return (.swallow, [])
		}

		if let send = action.send {
			let decision = Decision.remap(keyCode: send.keyCode, modifiers: HeldModifiers(send.modifiers))
			held[event.keyCode] = decision
			return (decision, [])
		}

		held[event.keyCode] = .swallow

		// Holding a key repeats a command (resizing does that), never a mode switch.
		if event.isRepeat, action.mode != nil, action.run == nil, action.shell == nil {
			return (.swallow, [])
		}

		var effects: [Effect] = []
		if let command = action.run { effects.append(.run(command)) }
		if let command = action.shell { effects.append(.shell(command)) }
		if let next = action.mode, next != mode {
			mode = next
			effects.append(.modeChanged(next))
		}

		return (.swallow, effects)
	}

	private static func match(_ event: KeyEvent, in table: [KeyCombo: HotkeyAction]) -> HotkeyAction? {
		table.first { $0.key.keyCode == event.keyCode && matches($0.key.modifiers, event.modifiers) }?.value
	}

	/// Exact match per family: a binding without shift does not fire with shift held. `fn` only
	/// counts when the binding names it, because macOS sets it on its own for arrows and F-keys.
	static func matches(_ wanted: Set<KeyCombo.Modifier>, _ held: HeldModifiers) -> Bool {
		let families: [(generic: KeyCombo.Modifier, left: KeyCombo.Modifier, right: KeyCombo.Modifier,
		                 leftHeld: HeldModifiers, rightHeld: HeldModifiers)] = [
			(.cmd, .lcmd, .rcmd, .leftCmd, .rightCmd),
			(.alt, .lalt, .ralt, .leftAlt, .rightAlt),
			(.ctrl, .lctrl, .rctrl, .leftCtrl, .rightCtrl),
			(.shift, .lshift, .rshift, .leftShift, .rightShift),
		]

		for family in families {
			let left = held.contains(family.leftHeld)
			let right = held.contains(family.rightHeld)

			let ok = if wanted.contains(family.generic) {
				left || right
			} else if wanted.contains(family.left) {
				left && !right
			} else if wanted.contains(family.right) {
				right && !left
			} else {
				!left && !right
			}

			guard ok else { return false }
		}

		return !wanted.contains(.fn) || held.contains(.fn)
	}
}
