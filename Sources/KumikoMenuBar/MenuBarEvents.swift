import AppKit

/// Clicks and scrolls anywhere on screen, watched but never held back. A click on the
/// empty menu bar goes to no app, so an event tap is the only way to see it.
@MainActor
final class MenuBarEvents {
	typealias ClickHandler = @MainActor (CGPoint) -> Void
	typealias ScrollHandler = @MainActor (CGFloat, CGPoint) -> Void

	private let onClick: ClickHandler
	private let onScroll: ScrollHandler
	private var tap: CFMachPort?
	private var source: CFRunLoopSource?
	private var permissionTimer: Timer?

	init(onClick: @escaping ClickHandler, onScroll: @escaping ScrollHandler) {
		self.onClick = onClick
		self.onScroll = onScroll
	}

	/// Installs the tap, or keeps trying until the permissions for it are granted.
	func start() {
		guard tap == nil, permissionTimer == nil, !install() else { return }

		permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, self.install() else { return }
				self.permissionTimer?.invalidate()
				self.permissionTimer = nil
			}
		}
	}

	func stop() {
		permissionTimer?.invalidate()
		permissionTimer = nil
		if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
		if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
		source = nil
		tap = nil
	}

	private func install() -> Bool {
		let types: [CGEventType] = [.leftMouseDown, .scrollWheel]
		let mask = types.reduce(0) { $0 | (1 << $1.rawValue) }

		guard let tap = CGEvent.tapCreate(
			tap: .cgSessionEventTap,
			place: .tailAppendEventTap,
			options: .listenOnly,
			eventsOfInterest: CGEventMask(mask),
			callback: menuBarEventCallback,
			userInfo: Unmanaged.passUnretained(self).toOpaque()
		) else { return false }

		let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
		CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
		CGEvent.tapEnable(tap: tap, enable: true)
		self.tap = tap
		self.source = source
		return true
	}

	fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
		switch type {
		case .tapDisabledByTimeout, .tapDisabledByUserInput:
			if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
		case .leftMouseDown:
			onClick(event.location)
		case .scrollWheel:
			// Sideways scrolling counts as well, the way Ice does it.
			guard let scroll = NSEvent(cgEvent: event) else { return }
			onScroll((scroll.scrollingDeltaX + scroll.scrollingDeltaY) / 2, event.location)
		default:
			break
		}
	}
}

private func menuBarEventCallback(
	_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
	guard let refcon else { return Unmanaged.passUnretained(event) }
	let events = Unmanaged<MenuBarEvents>.fromOpaque(refcon).takeUnretainedValue()
	// The tap's run loop source is on the main run loop.
	nonisolated(unsafe) let shared = event

	MainActor.assumeIsolated { events.handle(type, shared) }
	return Unmanaged.passUnretained(event)
}

/// Where things are in the menu bar. Points are in the coordinates of events and the
/// WindowServer: origin at the top left of the main screen, y going down.
@MainActor
enum MenuBarGeometry {
	static var mouseLocation: CGPoint {
		CGEvent(source: nil)?.location ?? .zero
	}

	/// The screen whose menu bar is under the point.
	static func screen(at point: CGPoint) -> NSScreen? {
		NSScreen.screens.first { menuBar(of: $0).contains(point) }
	}

	/// A point on a menu bar with neither an app menu nor a status item under it.
	static func isEmptySpace(_ point: CGPoint) -> Bool {
		guard let screen = screen(at: point) else { return false }
		return !isOnStatusItem(point) && point.x - frame(of: screen).minX > appMenusWidth()
	}

	private static func menuBar(of screen: NSScreen) -> CGRect {
		let frame = frame(of: screen)
		// An auto-hidden menu bar leaves the visible frame whole, yet it shows on hover.
		let height = screen.frame.maxY - screen.visibleFrame.maxY
		return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: height > 0 ? height : NSStatusBar.system.thickness)
	}

	private static func frame(of screen: NSScreen) -> CGRect {
		let mainHeight = NSScreen.screens.first?.frame.height ?? 0
		return CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
	}

	private static func isOnStatusItem(_ point: CGPoint) -> Bool {
		guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
			return false
		}

		return windows.contains { window in
			guard window[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.statusWindow)),
			      let bounds = window[kCGWindowBounds as String] as? NSDictionary,
			      let rect = CGRect(dictionaryRepresentation: bounds)
			else { return false }
			return rect.contains(point)
		}
	}

	/// How far the menus of the app in front reach from the left edge of their screen, the
	/// Apple menu included. Every menu bar shows them at the same offset.
	private static func appMenusWidth() -> CGFloat {
		guard let app = NSWorkspace.shared.menuBarOwningApplication else { return 0 }
		let element = AXUIElementCreateApplication(app.processIdentifier)
		// A hung app must not hold up every click.
		AXUIElementSetMessagingTimeout(element, 0.2)

		guard let bar: AXUIElement = attribute(element, kAXMenuBarAttribute),
		      let menus: [AXUIElement] = attribute(bar, kAXChildrenAttribute)
		else { return 0 }

		let frames = menus.compactMap { menu -> CGRect? in
			guard let position: AXValue = attribute(menu, kAXPositionAttribute),
			      let size: AXValue = attribute(menu, kAXSizeAttribute)
			else { return nil }
			var origin = CGPoint.zero
			var extent = CGSize.zero
			AXValueGetValue(position, .cgPoint, &origin)
			AXValueGetValue(size, .cgSize, &extent)
			return CGRect(origin: origin, size: extent)
		}

		guard let first = frames.first, let screen = NSScreen.screens.first(where: { frame(of: $0).contains(first.origin) }),
		      let end = frames.map(\.maxX).max()
		else { return 0 }
		return end - frame(of: screen).minX
	}

	private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
		return value as? T
	}
}
