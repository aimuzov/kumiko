import AppKit
import KumikoCore

/// The keyboard side of kumiko: an event tap that runs every key press through the engine and
/// swallows, rewrites or passes it.
@MainActor
public final class Hotkeys {
	public typealias Runner = @MainActor ([String]) -> Response

	private let bus: EventBus
	private let run: Runner
	private var config: Config.Hotkeys
	private var engine: Engine
	private var tap: CFMachPort?
	private var source: CFRunLoopSource?
	private var permissionTimer: Timer?

	public var mode: String { engine.mode }

	/// Gets every key event the hotkeys pass on, with whether it is a press; returning true
	/// swallows it. Vim modes sit here, behind the hotkeys.
	public var passthrough: (@MainActor (CGEvent, Bool) -> Bool)?
	public var isRunning: Bool { tap != nil }

	/// `run` executes a kumiko command, the same way the CLI does.
	public init(bus: EventBus, config: Config.Hotkeys, run: @escaping Runner) {
		self.bus = bus
		self.config = config
		self.run = run
		engine = Engine(config)
	}

	/// Installs the tap, or waits for the permissions and installs it once they are there. An
	/// active tap needs Accessibility as well as Input Monitoring.
	public func start() {
		guard config.enabled, tap == nil else { return }

		guard AXIsProcessTrusted(), CGPreflightListenEventAccess(), install() else {
			guard permissionTimer == nil else { return }
			permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
				MainActor.assumeIsolated {
					guard let self, self.install() else { return }
					self.permissionTimer?.invalidate()
					self.permissionTimer = nil
				}
			}
			return
		}
	}

	public func stop() {
		permissionTimer?.invalidate()
		permissionTimer = nil

		if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
		if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
		source = nil
		tap = nil

		apply(engine.reset())
	}

	public func apply(_ config: Config.Hotkeys) {
		self.config = config
		engine.update(config)

		if config.enabled { start() } else { stop() }
	}

	private func install() -> Bool {
		guard config.enabled, tap == nil, AXIsProcessTrusted(), CGPreflightListenEventAccess() else { return false }

		let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
		let refcon = Unmanaged.passUnretained(self).toOpaque()

		guard let tap = CGEvent.tapCreate(
			tap: .cgSessionEventTap,
			place: .headInsertEventTap,
			options: .defaultTap,
			eventsOfInterest: CGEventMask(mask),
			callback: tapCallback,
			userInfo: refcon
		) else { return false }

		let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
		CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
		CGEvent.tapEnable(tap: tap, enable: true)

		self.tap = tap
		self.source = source
		return true
	}

	/// Runs on the main thread for every key event, so it only decides; commands run afterwards.
	/// Returns whether the event goes on, rewritten in place when it is remapped.
	fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
		switch type {
		case .tapDisabledByTimeout, .tapDisabledByUserInput:
			// macOS turns a slow tap off; turn it back on, from a clean slate.
			if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
			apply(engine.reset())
			return true
		case .keyDown, .keyUp:
			break
		default:
			return true
		}

		let keyEvent = KeyEvent(
			keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
			modifiers: Self.modifiers(of: event.flags),
			isDown: type == .keyDown,
			isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
		)

		let (decision, effects) = engine.handle(keyEvent, frontmostApp: NSWorkspace.shared.frontmostApplication?.localizedName)

		if !effects.isEmpty {
			DispatchQueue.main.async { [weak self] in
				MainActor.assumeIsolated { self?.apply(effects) }
			}
		}

		switch decision {
		case .pass:
			return !(passthrough?(event, type == .keyDown) ?? false)
		case .swallow:
			return false
		case let .remap(keyCode, modifiers):
			event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
			event.flags = Self.flags(for: modifiers, keyCode: keyCode, keeping: event.flags)
			return true
		}
	}

	private func apply(_ effects: [Effect]) {
		for effect in effects {
			switch effect {
			case let .run(command):
				runChain(command)
			case let .shell(command):
				Self.shell(command, environment: [:])
			case let .modeChanged(mode):
				bus.publish(.hotkeyModeChanged(mode))
				if let hook = config.onModeChange {
					Self.shell(hook, environment: ["KUMIKO_MODE": mode])
				}
			}
		}
	}

	/// `a || b`: runs b only when a fails, the way skhd bindings chain yabai commands.
	private func runChain(_ chain: String) {
		for command in chain.components(separatedBy: "||") {
			let words = Self.words(command)
			guard !words.isEmpty else { continue }
			if run(words).ok { return }
		}
	}

	/// Splits a command into words, keeping double-quoted parts together.
	nonisolated static func words(_ command: String) -> [String] {
		var words: [String] = []
		var current = ""
		var quoted = false

		for character in command {
			if character == "\"" {
				quoted.toggle()
			} else if character == " ", !quoted {
				if !current.isEmpty { words.append(current) }
				current = ""
			} else {
				current.append(character)
			}
		}

		if !current.isEmpty { words.append(current) }
		return words
	}

	private static func shell(_ command: String, environment: [String: String]) {
		let process = Process()
		process.executableURL = URL(filePath: "/bin/sh")
		process.arguments = ["-c", command]
		process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
		try? process.run()
	}

	// MARK: - Flags

	// Device-dependent bits of CGEventFlags: they tell the left and right modifier keys apart.
	private static let sideBits: [(UInt64, HeldModifiers)] = [
		(0x08, .leftCmd), (0x10, .rightCmd), (0x20, .leftAlt), (0x40, .rightAlt),
		(0x01, .leftCtrl), (0x2000, .rightCtrl), (0x02, .leftShift), (0x04, .rightShift),
	]

	static func modifiers(of flags: CGEventFlags) -> HeldModifiers {
		var held: HeldModifiers = []
		for (bit, modifier) in sideBits where flags.rawValue & bit != 0 {
			held.insert(modifier)
		}
		if flags.contains(.maskSecondaryFn) { held.insert(.fn) }
		return held
	}

	/// The flags of a remapped event: the target modifiers, plus the bits a real arrow or F-key
	/// press carries, so apps cannot tell the difference.
	private static func flags(for modifiers: HeldModifiers, keyCode: UInt16, keeping old: CGEventFlags) -> CGEventFlags {
		var flags = CGEventFlags(rawValue: old.rawValue & CGEventFlags.maskAlphaShift.rawValue)

		for (bit, modifier) in sideBits where modifiers.contains(modifier) {
			flags.insert(CGEventFlags(rawValue: bit))
		}
		if modifiers.contains(.leftCmd) || modifiers.contains(.rightCmd) { flags.insert(.maskCommand) }
		if modifiers.contains(.leftAlt) || modifiers.contains(.rightAlt) { flags.insert(.maskAlternate) }
		if modifiers.contains(.leftCtrl) || modifiers.contains(.rightCtrl) { flags.insert(.maskControl) }
		if modifiers.contains(.leftShift) || modifiers.contains(.rightShift) { flags.insert(.maskShift) }

		let arrows: ClosedRange<UInt16> = 0x7B...0x7E
		let functionKeys: Set<UInt16> = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]

		if arrows.contains(keyCode) { flags.insert([.maskSecondaryFn, .maskNumericPad]) }
		if functionKeys.contains(keyCode) || modifiers.contains(.fn) { flags.insert(.maskSecondaryFn) }

		return flags
	}
}

private func tapCallback(
	_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
	guard let refcon else { return Unmanaged.passUnretained(event) }
	let hotkeys = Unmanaged<Hotkeys>.fromOpaque(refcon).takeUnretainedValue()
	// The tap's run loop source is on the main run loop.
	nonisolated(unsafe) let shared = event

	let keep = MainActor.assumeIsolated { hotkeys.handle(type, shared) }
	return keep ? Unmanaged.passUnretained(event) : nil
}
