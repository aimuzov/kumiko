import AppKit

/// Keeps clicks on the empty desktop away from Finder while kumiko has it hidden. Finder would
/// come back for such a click and bring its windows from other workspaces along, for nothing:
/// the desktop is empty there. Clicks on desktop icons still reach it.
@MainActor
final class DesktopClicks {
	/// Whether a press at this point should be kept from Finder.
	var shouldSwallow: (@MainActor (CGPoint) -> Bool)?

	private var tap: CFMachPort?
	private var source: CFRunLoopSource?
	// The release of a swallowed press is swallowed too, or Finder gets a stray mouse up.
	private var swallowing: Set<CGEventType> = []

	func start() {
		guard tap == nil else { return }

		let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
		let mask = types.reduce(0) { $0 | (1 << $1.rawValue) }
		let refcon = Unmanaged.passUnretained(self).toOpaque()

		guard let tap = CGEvent.tapCreate(
			tap: .cgSessionEventTap,
			place: .headInsertEventTap,
			options: .defaultTap,
			eventsOfInterest: CGEventMask(mask),
			callback: desktopClickCallback,
			userInfo: refcon
		) else { return }

		let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
		CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
		CGEvent.tapEnable(tap: tap, enable: true)

		self.tap = tap
		self.source = source
	}

	func stop() {
		if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
		if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
		source = nil
		tap = nil
		swallowing = []
	}

	/// Returns whether the event goes on.
	fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
		switch type {
		case .tapDisabledByTimeout, .tapDisabledByUserInput:
			if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
			swallowing = []
			return true
		case .leftMouseDown, .rightMouseDown:
			guard shouldSwallow?(event.location) == true else { return true }
			swallowing.insert(type == .leftMouseDown ? .leftMouseUp : .rightMouseUp)
			return false
		case .leftMouseUp, .rightMouseUp:
			return swallowing.remove(type) == nil
		default:
			return true
		}
	}
}

private func desktopClickCallback(
	_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
	guard let refcon else { return Unmanaged.passUnretained(event) }
	let clicks = Unmanaged<DesktopClicks>.fromOpaque(refcon).takeUnretainedValue()
	// The tap's run loop source is on the main run loop.
	nonisolated(unsafe) let shared = event

	let keep = MainActor.assumeIsolated { clicks.handle(type, shared) }
	return keep ? Unmanaged.passUnretained(event) : nil
}
