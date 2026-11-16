import AppKit
import Carbon
import KumikoCore
import os

/// The keyboard side of kumiko: an event tap that runs every key press through the engine and
/// swallows, rewrites or passes it.
///
/// The tap has a thread of its own. Every key on the Mac waits for the tap's answer, and the main
/// thread is often busy with an app that is slow to answer Accessibility; on the main thread, a
/// key would wait for that app too, and after about a second macOS would turn the tap off and let
/// keys through or drop them. On its own thread the tap answers at once. What it decides with
/// lives in `Shared`, behind one lock; whatever it decides to do runs on the main thread after.
@MainActor
public final class Hotkeys {
	public typealias Runner = @MainActor ([String]) -> Response

	/// Everything a key event is decided with, shared by the tap thread and the main thread.
	struct Shared: Sendable {
		var engine: Engine
		var isPaused = false
		/// Set while the tap is off, so a key the tap was still deciding when it stopped does nothing.
		var isStopped = false
		/// The app in front, as the main thread last saw it. Keys say which app they go to themselves;
		/// this is for the rare key that does not, and for the secure input fallback.
		var frontmostApp: String?
		/// Whether anything listens behind the hotkeys (Vim). Only then does a passed key wait for
		/// the main thread, where that listener lives.
		var passthroughEnabled = false
		var secureInput = false
		/// Commands queued before an interruption must not run when input resumes.
		var generation: UInt64 = 0
		var diagnostics = InputDiagnostics()
	}

	private let bus: EventBus
	private let run: Runner
	private var config: Config.Hotkeys
	nonisolated let shared: OSAllocatedUnfairLock<Shared>
	private var tap: Tap?
	private var permissionTimer: Timer?
	/// Ends the mode at its timeout, so the bar stops showing it before the next key comes.
	private var modeTimer: Timer?
	private var activationObserver: (any NSObjectProtocol)?
	private var secureInputTimer: Timer?
	private var refreshingSecureHotkeys = false
	private lazy var secureHotkeys = SecureHotkeys { [weak self] combo in
		self?.handleSecureHotkey(combo)
	}

	public var mode: String { shared.withLock { $0.engine.mode } }

	/// Gets every key event the hotkeys pass on, with whether it is a press; returning true
	/// swallows it. Vim modes sit here, behind the hotkeys. Called on the main thread, and only
	/// while `passthroughEnabled` is on.
	public var passthrough: (@MainActor (CGEvent, Bool) -> Bool)?
	/// Whether `passthrough` wants keys at all. Off, a passed key never waits for the main thread.
	public var passthroughEnabled: Bool {
		get { shared.withLock { $0.passthroughEnabled } }
		set { shared.withLock { $0.passthroughEnabled = newValue } }
	}
	/// The consumer missed the same events: discard its pending input state too.
	public var resetPassthrough: (@MainActor () -> Void)?

	public var diagnostics: InputDiagnostics {
		var result = shared.withLock { state in
			var diagnostics = state.diagnostics
			diagnostics.secureInput = state.secureInput
			diagnostics.mode = state.engine.mode
			return diagnostics
		}
		result.tapEnabled = tap?.isEnabled ?? false
		result.secureRegistrations = secureHotkeys.registrationCount
		result.secureRegistrationFailures = secureHotkeys.registrationFailures
		result.lastRegistrationError = secureHotkeys.lastError
		return result
	}
	public var isRunning: Bool { tap != nil }
	/// Every key goes through untouched, Vim's too: the settings window records a shortcut.
	public var isPaused: Bool {
		get { shared.withLock { $0.isPaused } }
		set {
			let changed = shared.withLock { state in
				defer { state.isPaused = newValue }
				return state.isPaused != newValue
			}
			guard changed else { return }
			resetKeyboardState()
			refreshSecureHotkeys()
		}
	}

	/// `run` executes a kumiko command, the same way the CLI does.
	public init(bus: EventBus, config: Config.Hotkeys, run: @escaping Runner) {
		self.bus = bus
		self.config = config
		self.run = run
		shared = OSAllocatedUnfairLock(initialState: Shared(engine: Engine(config), frontmostApp: Self.frontmostName()))

		activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				let now = ProcessInfo.processInfo.systemUptime
				let frontmost = Self.frontmostName()
				let effects = self.shared.withLock { state in
					state.frontmostApp = frontmost
					return state.engine.appActivated(at: now)
				}
				self.apply(effects)
				self.refreshSecureHotkeys()
			}
		}
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
		secureInputTimer?.invalidate()
		secureInputTimer = nil
		secureHotkeys.stop()

		shared.withLock { $0.isStopped = true }
		tap?.stop()
		tap = nil

		resetKeyboardState()
	}

	public func apply(_ config: Config.Hotkeys) {
		self.config = config
		shared.withLock { $0.engine.update(config) }
		scheduleExpiry()

		if config.enabled { start() } else { stop() }
		refreshSecureHotkeys()
	}

	private func install() -> Bool {
		guard config.enabled, tap == nil, AXIsProcessTrusted(), CGPreflightListenEventAccess(),
		      let tap = Tap(hotkeys: self)
		else { return false }

		self.tap = tap
		shared.withLock { $0.isStopped = false }
		let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.refreshSecureHotkeys() }
		}
		secureInputTimer = timer
		RunLoop.main.add(timer, forMode: .common)
		refreshSecureHotkeys()
		return true
	}

	private func refreshSecureHotkeys() {
		refreshSecureHotkeys(secureInput: IsSecureEventInputEnabled())
	}

	func refreshSecureHotkeys(secureInput enabled: Bool) {
		guard !refreshingSecureHotkeys else { return }
		refreshingSecureHotkeys = true
		defer { refreshingSecureHotkeys = false }
		let changed = shared.withLock { state in
			defer { state.secureInput = enabled }
			return state.secureInput != enabled
		}
		if changed { resetKeyboardState() }
		updateSecureRegistrations(secureInput: enabled)
	}

	/// Registers the secure input hotkeys when secure input is on, without touching the shared state.
	private func updateSecureRegistrations(secureInput enabled: Bool) {
		guard tap != nil, config.enabled, !isPaused, enabled,
		      !(Self.frontmostApp().map { config.blacklist.contains($0) } ?? false) else {
			secureHotkeys.update([])
			return
		}
		secureHotkeys.update(SecureHotkeys.bindings(config, mode: mode))
	}

	private func handleSecureHotkey(_ combo: KeyCombo) {
		shared.withLock { $0.diagnostics.secureCallbacks += 1 }
		guard !isPaused, config.enabled, shared.withLock({ $0.secureInput }), IsSecureEventInputEnabled() else {
			shared.withLock { $0.diagnostics.discardedSecureCallbacks += 1 }
			refreshSecureHotkeys()
			return
		}
		let frontmost = Self.frontmostApp()
		let (effects, generation) = shared.withLock { state in
			let event = KeyEvent(keyCode: combo.keyCode, modifiers: [], isDown: true)
			let (_, effects) = state.engine.handle(event, frontmostApp: frontmost, registeredCombo: combo)
			_ = state.engine.handle(KeyEvent(keyCode: combo.keyCode, modifiers: [], isDown: false), frontmostApp: nil)
			return (effects, state.generation)
		}
		later(effects, generation: generation)
		scheduleExpiry()
	}

	/// Decides on one event: whether it goes on, rewritten in place when it is remapped. Runs on
	/// the tap's thread, or on the main thread in tests; either way it only decides, under the
	/// lock, and leaves the work to the main thread.
	nonisolated func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
		let began = ProcessInfo.processInfo.systemUptime
		defer {
			let milliseconds = (ProcessInfo.processInfo.systemUptime - began) * 1000
			shared.withLock { state in
				state.diagnostics.maxCallbackMilliseconds = max(state.diagnostics.maxCallbackMilliseconds, milliseconds)
				if milliseconds >= 50 { state.diagnostics.slowCallbacks += 1 }
			}
		}
		switch type {
		case .flagsChanged:
			onMain { $0.refreshSecureHotkeys() }
			return true
		case .tapDisabledByTimeout, .tapDisabledByUserInput:
			// macOS turns a slow tap off; it is turned back on by the tap itself, and the state starts
			// clean, here and in Vim.
			let effects = shared.withLock { state -> [Effect] in
				guard !state.isStopped else { return [] }
				if type == .tapDisabledByTimeout { state.diagnostics.tapTimeouts += 1 }
				else { state.diagnostics.tapUserDisables += 1 }
				return Self.reset(&state)
			}
			onMain { hotkeys in
				hotkeys.resetPassthrough?()
				hotkeys.apply(effects)
				hotkeys.scheduleExpiry()
			}
			return true
		case .keyDown, .keyUp:
			break
		case .leftMouseDown, .rightMouseDown, .otherMouseDown:
			// The click goes on as it is; only the mode ends.
			let (effects, generation) = shared.withLock { state in
				(state.isPaused || state.isStopped ? [] : state.engine.click(), state.generation)
			}
			later(effects, generation: generation)
			return true
		default:
			return true
		}

		let secureNow = IsSecureEventInputEnabled()
		let keyEvent = KeyEvent(
			keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
			modifiers: Self.modifiers(of: event.flags),
			isDown: type == .keyDown,
			isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
		)
		let lockedScreen = Self.isScreenLocked()
		// The WindowServer has already picked the app this key goes to. The main thread's idea of
		// the front app lags while it is busy, and the blacklist must not: a key meant for Screen
		// Sharing has to reach it even then.
		let target = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
		let targetApp = target > 0 ? NSRunningApplication(processIdentifier: target)?.localizedName : nil

		let outcome: (Decision, [Effect], UInt64, Bool, [Effect]?)? = shared.withLock { state in
			guard !state.isPaused, !state.isStopped else { return nil }
			if !keyEvent.modifiers.intersection([.unsidedCmd, .unsidedAlt, .unsidedCtrl, .unsidedShift]).isEmpty {
				state.diagnostics.unsidedModifierEvents += 1
			}
			// Secure input coming or going starts a new input session before this key is decided,
			// so the key's own command belongs to the new one.
			var reset: [Effect]?
			if secureNow != state.secureInput {
				state.secureInput = secureNow
				reset = Self.reset(&state)
			}
			let app = targetApp ?? state.frontmostApp
			let frontmost = app == "loginwindow" && !lockedScreen ? nil : app
			let (decision, effects) = state.engine.handle(keyEvent, frontmostApp: frontmost)
			return (decision, effects, state.generation, state.passthroughEnabled, reset)
		}
		guard let (decision, effects, generation, passthroughEnabled, reset) = outcome else { return true }

		if let reset {
			onMain { hotkeys in
				// Read now, not when the key came: by the time the main thread gets here the tap may
				// have stopped, or seen secure input flip again. A newer flip queues its own block
				// after this one, so the effects still arrive in order.
				let (stopped, secure) = hotkeys.shared.withLock { ($0.isStopped, $0.secureInput) }
				guard !stopped else { return }
				hotkeys.resetPassthrough?()
				hotkeys.apply(reset)
				// The tap owns the shared value now; this only brings the registrations along, and
				// writes nothing a key on the tap thread could have changed in between.
				hotkeys.updateSecureRegistrations(secureInput: secure)
			}
		}
		later(effects, generation: generation)
		if keyEvent.isDown { onMain { $0.scheduleExpiry() } }

		switch decision {
		case .pass:
			guard passthroughEnabled else { return true }
			// Vim lives on the main thread and decides on keys it has not seen, so the key waits for it.
			nonisolated(unsafe) let event = event
			let isDown = type == .keyDown
			return !onMainAndWait { $0.passthrough?(event, isDown) ?? false }
		case .swallow:
			return false
		case let .remap(keyCode, modifiers):
			event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
			event.flags = Self.flags(for: modifiers, keyCode: keyCode, keeping: event.flags)
			return true
		}
	}

	/// Forgets the mode and held keys and starts a new input session: commands queued in the old one
	/// do not run.
	private nonisolated static func reset(_ state: inout Shared) -> [Effect] {
		state.generation &+= 1
		state.diagnostics.stateResets += 1
		return state.engine.reset()
	}

	/// Runs `body` on the main thread: right away when already there, as in tests, later otherwise.
	private nonisolated func onMain(_ body: @escaping @MainActor (Hotkeys) -> Void) {
		if Thread.isMainThread {
			MainActor.assumeIsolated { body(self) }
		} else {
			DispatchQueue.main.async { [weak self] in
				MainActor.assumeIsolated {
					guard let self else { return }
					body(self)
				}
			}
		}
	}

	private nonisolated func onMainAndWait(_ body: @MainActor (Hotkeys) -> Bool) -> Bool {
		if Thread.isMainThread { return MainActor.assumeIsolated { body(self) } }
		return DispatchQueue.main.sync { MainActor.assumeIsolated { body(self) } }
	}

	/// Effects of an event the tap is still deciding on: they run once it has gone on its way, and
	/// only if no reset came in between.
	private nonisolated func later(_ effects: [Effect], generation: UInt64) {
		guard !effects.isEmpty else { return }
		DispatchQueue.main.async { [weak self] in
			MainActor.assumeIsolated {
				guard let self, self.currentGeneration == generation else { return }
				self.apply(effects, generation: generation)
			}
		}
	}

	private var currentGeneration: UInt64 { shared.withLock { $0.generation } }

	private func resetKeyboardState() {
		let effects = shared.withLock { Self.reset(&$0) }
		resetPassthrough?()
		apply(effects)
		scheduleExpiry()
	}

	/// Sets the timer to the mode's deadline again: a key in the mode moves it on.
	private func scheduleExpiry() {
		modeTimer?.invalidate()
		modeTimer = nil

		guard let deadline = shared.withLock({ $0.engine.deadline }) else { return }
		let delay = max(deadline - ProcessInfo.processInfo.systemUptime, 0)

		modeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.modeTimer = nil
				let now = ProcessInfo.processInfo.systemUptime
				self.apply(self.shared.withLock { $0.engine.expire(at: now) })
			}
		}
	}

	func apply(_ effects: [Effect], generation: UInt64? = nil) {
		for effect in effects {
			if let generation, generation != currentGeneration { return }
			switch effect {
			case let .run(command):
				runChain(command, generation: generation)
			case let .shell(command):
				Self.shell(command, environment: [:])
			case let .modeChanged(mode):
				guard mode == self.mode else { continue }
				refreshSecureHotkeys()
				guard mode == self.mode else { continue }
				if let generation, generation != currentGeneration { return }
				bus.publish(.hotkeyModeChanged(mode))
				if let generation, generation != currentGeneration { return }
				if let hook = config.onModeChange {
					Self.shell(hook, environment: ["KUMIKO_MODE": mode])
				}
			}
		}
	}

	/// The app keys go to, as the blacklist means it. With every app hidden — an empty workspace
	/// shown — macOS names loginwindow as frontmost; that is not the login or lock screen a
	/// blacklisted loginwindow stands for, so it only counts while the screen is locked.
	private static func frontmostApp() -> String? {
		let name = frontmostName()
		guard name == "loginwindow" else { return name }
		return isScreenLocked() ? name : nil
	}

	private static func frontmostName() -> String? {
		NSWorkspace.shared.frontmostApplication?.localizedName
	}

	private nonisolated static func isScreenLocked() -> Bool {
		let session = CGSessionCopyCurrentDictionary() as? [String: Any]
		return session?["CGSSessionScreenIsLocked"] as? Bool == true
	}

	/// `a || b`: runs b only when a fails, the way skhd bindings chain yabai commands.
	private func runChain(_ chain: String, generation: UInt64? = nil) {
		for command in chain.components(separatedBy: "||") {
			if let generation, generation != currentGeneration { return }
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
	private nonisolated static let sideBits: [(UInt64, HeldModifiers)] = [
		(0x08, .leftCmd), (0x10, .rightCmd), (0x20, .leftAlt), (0x40, .rightAlt),
		(0x01, .leftCtrl), (0x2000, .rightCtrl), (0x02, .leftShift), (0x04, .rightShift),
	]

	nonisolated static func modifiers(of flags: CGEventFlags) -> HeldModifiers {
		var held: HeldModifiers = []
		for (bit, modifier) in sideBits where flags.rawValue & bit != 0 {
			held.insert(modifier)
		}
		// A family flag without side bits still means a modifier, but says nothing about its side.
		let families: [(CGEventFlags, HeldModifiers, HeldModifiers)] = [
			(.maskCommand, [.leftCmd, .rightCmd], .unsidedCmd),
			(.maskAlternate, [.leftAlt, .rightAlt], .unsidedAlt),
			(.maskControl, [.leftCtrl, .rightCtrl], .unsidedCtrl),
			(.maskShift, [.leftShift, .rightShift], .unsidedShift),
		]
		for (flag, sides, unsided) in families where flags.contains(flag) && held.intersection(sides).isEmpty {
			held.insert(unsided)
		}
		if flags.contains(.maskSecondaryFn) { held.insert(.fn) }
		return held
	}

	/// The flags of a remapped event: the target modifiers, plus the bits a real arrow or F-key
	/// press carries, so apps cannot tell the difference.
	private nonisolated static func flags(
		for modifiers: HeldModifiers, keyCode: UInt16, keeping old: CGEventFlags
	) -> CGEventFlags {
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

/// The event tap and the thread whose run loop it runs on. The callback gets this object, never
/// the Hotkeys directly: the port it turns back on after a timeout lives here.
private final class Tap: @unchecked Sendable {
	/// Set once, before the thread starts; read only from the tap's thread after that.
	private(set) var port: CFMachPort!
	private weak var hotkeys: Hotkeys?
	private var runLoop: CFRunLoop?
	private var source: CFRunLoopSource?

	@MainActor
	init?(hotkeys: Hotkeys) {
		self.hotkeys = hotkeys
		let mask = [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
			.reduce(0) { $0 | 1 << $1.rawValue }

		guard let port = CGEvent.tapCreate(
			tap: .cgSessionEventTap,
			place: .headInsertEventTap,
			options: .defaultTap,
			eventsOfInterest: CGEventMask(mask),
			callback: tapCallback,
			userInfo: Unmanaged.passUnretained(self).toOpaque()
		) else { return nil }
		self.port = port

		// Handed to the thread below, which only adds it to its own run loop.
		nonisolated(unsafe) let source = CFMachPortCreateRunLoopSource(nil, port, 0)!
		self.source = source
		let ready = DispatchSemaphore(value: 0)
		nonisolated(unsafe) var loop: CFRunLoop?
		// The thread holds on to the tap until its run loop ends, so a callback still running while
		// the tap stops never finds it gone.
		let thread = Thread { [self] in
			withExtendedLifetime(self) {
				loop = CFRunLoopGetCurrent()
				CFRunLoopAddSource(loop, source, .commonModes)
				ready.signal()
				CFRunLoopRun()
			}
		}
		thread.name = "\(Kumiko.bundleIdentifier).event-tap"
		thread.qualityOfService = .userInteractive
		thread.start()
		ready.wait()
		runLoop = loop
		CGEvent.tapEnable(tap: port, enable: true)
	}

	var isEnabled: Bool { CGEvent.tapIsEnabled(tap: port) }

	@MainActor
	func stop() {
		CGEvent.tapEnable(tap: port, enable: false)
		if let runLoop, let source {
			CFRunLoopRemoveSource(runLoop, source, .commonModes)
			CFRunLoopStop(runLoop)
		}
		CFMachPortInvalidate(port)
		runLoop = nil
		source = nil
	}

	func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
		let keep = hotkeys?.handle(type, event) ?? true
		if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
			CGEvent.tapEnable(tap: port, enable: true)
		}
		return keep
	}
}

private func tapCallback(
	_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
	guard let refcon else { return Unmanaged.passUnretained(event) }
	let tap = Unmanaged<Tap>.fromOpaque(refcon).takeUnretainedValue()
	return tap.handle(type, event) ? Unmanaged.passUnretained(event) : nil
}
