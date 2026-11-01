import Carbon
import KumikoCore

@MainActor
final class SecureHotkeys {
	private var handler: EventHandlerRef?
	private var registrations: [KeyCombo: (EventHotKeyRef, UInt32)] = [:]
	private var nextID: UInt32 = 0
	private let pressed: (KeyCombo) -> Void

	init(pressed: @escaping (KeyCombo) -> Void) {
		self.pressed = pressed
	}

	static func bindings(_ config: Config.Hotkeys, mode: String) -> Set<KeyCombo> {
		let table = mode == "default" ? config.bindings : config.modes[mode] ?? [:]
		let bindings = table.merging(config.global) { current, _ in current }
		let supported: Set<KeyCombo.Modifier> = [.cmd, .alt, .ctrl, .shift]
		return Set(bindings.compactMap { combo, action in
			guard action.send == nil, combo.modifiers.isSubset(of: supported),
			      !combo.modifiers.intersection([.cmd, .alt, .ctrl]).isEmpty else { return nil }
			return combo
		})
	}

	func update(_ wanted: Set<KeyCombo>) {
		for combo in registrations.keys where !wanted.contains(combo) {
			if let (reference, _) = registrations.removeValue(forKey: combo) { UnregisterEventHotKey(reference) }
		}
		guard !wanted.isEmpty else { return }
		if handler == nil {
			var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
			let context = Unmanaged.passUnretained(self).toOpaque()
			guard InstallEventHandler(GetApplicationEventTarget(), secureHotkeyCallback, 1, &type, context, &handler) == noErr else {
				return
			}
		}
		for combo in wanted where registrations[combo] == nil {
			nextID += 1
			var reference: EventHotKeyRef?
			let id = EventHotKeyID(signature: Self.signature, id: nextID)
			let status = RegisterEventHotKey(UInt32(combo.keyCode), Self.flags(combo), id, GetApplicationEventTarget(), 0, &reference)
			if status == noErr, let reference { registrations[combo] = (reference, nextID) }
		}
	}

	func stop() {
		update([])
		if let handler { RemoveEventHandler(handler) }
		handler = nil
	}

	fileprivate func handle(id: UInt32) -> OSStatus {
		guard let combo = registrations.first(where: { $0.value.1 == id })?.key else {
			return OSStatus(eventNotHandledErr)
		}
		pressed(combo)
		return noErr
	}

	nonisolated fileprivate static let signature: OSType = 0x4B554D49

	private static func flags(_ combo: KeyCombo) -> UInt32 {
		var flags: UInt32 = 0
		if combo.modifiers.contains(.cmd) { flags |= UInt32(cmdKey) }
		if combo.modifiers.contains(.alt) { flags |= UInt32(optionKey) }
		if combo.modifiers.contains(.ctrl) { flags |= UInt32(controlKey) }
		if combo.modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
		return flags
	}
}

private func secureHotkeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?) -> OSStatus {
	guard let event, let context else { return OSStatus(eventNotHandledErr) }
	var id = EventHotKeyID()
	guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
	                        MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
	      id.signature == SecureHotkeys.signature else { return OSStatus(eventNotHandledErr) }
	let hotkeys = Unmanaged<SecureHotkeys>.fromOpaque(context).takeUnretainedValue()
	let identifier = id.id
	return MainActor.assumeIsolated {
		hotkeys.handle(id: identifier)
	}
}
