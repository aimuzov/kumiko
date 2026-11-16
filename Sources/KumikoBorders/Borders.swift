import AppKit
import KumikoCore

/// A frame around the focused window, replacing JankyBorders.
///
/// It is one transparent, click-through window ordered right above the focused one, so windows
/// stacked over the focused window still cover the frame too. It moves on the window manager's
/// events rather than on a timer of its own.
@MainActor
public final class Borders {
	public typealias WindowLookup = @MainActor (UInt32) -> WindowInfo?

	private let bus: EventBus
	private let lookup: WindowLookup
	private var config: Config.Borders
	/// The bar's palette, for the colour of a hotkey mode.
	private var palette: Config.Bar.Palette
	private var mode = "default"
	private var focused: UInt32?
	private var overlay: BorderWindow?
	private var observers: [any NSObjectProtocol] = []
	/// Watches the Dock for Mission Control, App Exposé and Show Desktop.
	private var dockObserver: AXObserver?
	/// While one of them is open the frame steps aside: macOS animates the overlay like any window,
	/// and the frame would shrink to the middle of the screen and grow back out of it.
	private var isExposeOpen = false
	/// Hears the Mission Control shortcuts, which come before the animation; the Dock's own word
	/// comes about 0.4 s into it, by when the frame has been seen lingering.
	private var shortcutTap: CFMachPort?
	private var shortcuts = MissionControlShortcuts.current()
	private var shortcutsRead = Date()
	/// Set by a shortcut, cleared once the Dock confirms or the wait for it ran out.
	private var awaitingDock = 0
	/// Told which of kumiko's own windows is in focus, nil when none is, so the WindowServer's move
	/// events come for it too and the frame keeps up with a drag.
	public var onOwnWindow: @MainActor (UInt32?) -> Void = { _ in }

	/// `lookup` answers what the tracker knows about a window.
	public init(
		bus: EventBus, config: Config.Borders, palette: Config.Bar.Palette, focused: UInt32?,
		lookup: @escaping WindowLookup
	) {
		self.bus = bus
		self.config = config
		self.palette = palette
		self.focused = focused
		self.lookup = lookup
	}

	public func start() {
		bus.subscribe { [weak self] event in self?.handle(event) }
		observeOwnWindows()
		observeAccentColor()
		observeDock()
		listenForShortcuts()
		update()
	}

	/// A listen-only tap: it sees keys without holding any of them up.
	private func listenForShortcuts() {
		let refcon = Unmanaged.passUnretained(self).toOpaque()
		guard
			let tap = CGEvent.tapCreate(
				tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
				eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue), callback: shortcutCallback,
				userInfo: refcon
			)
		else { return }

		CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
		CGEvent.tapEnable(tap: tap, enable: true)
		shortcutTap = tap
	}

	fileprivate func keyDown(_ event: CGEvent) {
		// Shortcuts changed in System Settings are picked up within a few seconds; macOS does not say
		// when they change.
		if Date().timeIntervalSince(shortcutsRead) > 5 {
			shortcuts = MissionControlShortcuts.current()
			shortcutsRead = Date()
		}
		guard !isExposeOpen,
		      shortcuts.matches(
		      	keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags.rawValue
		      )
		else { return }

		isExposeOpen = true
		awaitingDock &+= 1
		let token = awaitingDock
		update()

		// A shortcut that opened nothing, taken by an app or turned off since, gives the frame back.
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
			MainActor.assumeIsolated {
				guard let self, self.awaitingDock == token else { return }
				self.awaitingDock = 0
				self.isExposeOpen = false
				self.update()
			}
		}
	}

	fileprivate func tapDisabled() {
		if let shortcutTap { CGEvent.tapEnable(tap: shortcutTap, enable: true) }
	}

	/// The Dock runs Mission Control and says when it opens and closes. A Dock that restarts, as
	/// after `killall Dock`, gets a new observer; one that quit mid-animation closed it too.
	private func observeDock() {
		register()
		observers.append(
			NSWorkspace.shared.notificationCenter.addObserver(
				forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
			) { [weak self] notification in
				let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
				guard app?.bundleIdentifier == "com.apple.dock" else { return }
				MainActor.assumeIsolated {
					guard let self else { return }
					self.isExposeOpen = false
					self.awaitingDock = 0
					self.register()
					self.update()
				}
			}
		)
	}

	private static let exposeOpened = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop"]
	private static let exposeClosed = "AXExposeExit"

	private func register() {
		if let old = dockObserver {
			CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
			dockObserver = nil
		}
		guard
			let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
		else { return }

		var observer: AXObserver?
		guard AXObserverCreate(dock.processIdentifier, dockCallback, &observer) == .success, let observer else { return }
		let element = AXUIElementCreateApplication(dock.processIdentifier)
		// The observer outlives nothing it points at: Borders lives as long as kumiko.
		let refcon = Unmanaged.passUnretained(self).toOpaque()
		for name in Self.exposeOpened + [Self.exposeClosed] {
			AXObserverAddNotification(observer, element, name as CFString, refcon)
		}
		CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
		dockObserver = observer
	}

	fileprivate func exposeChanged(_ name: String) {
		let isOpen = Self.exposeOpened.contains(name)
		// The Dock confirms what a shortcut started; the frame is hidden already.
		awaitingDock = 0
		guard isOpen != isExposeOpen || name == Self.exposeClosed else { return }
		isExposeOpen = isOpen
		update()
	}

	/// A frame in the accent colour takes the new one as soon as it is picked in System Settings.
	/// AppKit posts its own notification once it has the new colour; the distributed one comes from
	/// System Settings and may come first, so the colour is read on the next pass of the run loop.
	private func observeAccentColor() {
		let restyle: @Sendable (Notification) -> Void = { [weak self] _ in
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					guard let self, self.styled.color == nil else { return }
					self.overlay?.style(self.styled)
				}
			}
		}

		observers.append(
			NotificationCenter.default.addObserver(
				forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main, using: restyle
			)
		)
		observers.append(
			DistributedNotificationCenter.default().addObserver(
				forName: NSNotification.Name("AppleColorPreferencesChangedNotification"), object: nil, queue: .main,
				using: restyle
			)
		)
	}

	/// kumiko's own windows, the settings, are not the tracker's, so no bus event speaks of them;
	/// the frame follows them by AppKit's notifications instead.
	private func observeOwnWindows() {
		let center = NotificationCenter.default
		let names = [
			NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didMoveNotification,
			NSWindow.didResizeNotification, NSWindow.didMiniaturizeNotification,
			NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
		]

		for name in names {
			observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
				// The overlay moves to another screen with its window; that is no reason to look again.
				guard !(notification.object is BorderWindow) else { return }
				MainActor.assumeIsolated { self?.update() }
			})
		}

		// A closing window is still key while it closes; look once it is gone.
		observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
			[weak self] _ in
			DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
		})
	}

	/// kumiko's own window in focus, like the settings. The tracker leaves kumiko out and never
	/// reports one, so this comes before the window it last reported.
	private var ownFocused: NSWindow? {
		guard
			NSApp.isActive,
			let window = NSApp.keyWindow,
			window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen),
			window.isVisible, !window.isMiniaturized
		else { return nil }
		return window
	}

	public func apply(_ config: Config.Borders, palette: Config.Bar.Palette) {
		self.config = config
		self.palette = palette
		overlay?.style(styled)
		update()
	}

	/// While a hotkey mode is on, the frame takes its colour: the mode shows where the user looks,
	/// and keys typed into the window would be the mode's commands.
	private var styled: Config.Borders {
		var styled = config
		if mode != "default" { styled.color = palette.mode(mode) }
		return styled
	}

	private func handle(_ event: Event) {
		switch event {
		case let .hotkeyModeChanged(mode):
			self.mode = mode
			overlay?.style(styled)
		case let .windowFocused(id):
			focused = id
			update()
		case let .windowFrameChanged(id, frame):
			follow(id, frame)
		case let .windowChanged(info) where info.id == focused:
			// Unhidden, back from a corner, turned into a standard window: any of it may mean the
			// frame should now show. During a drag the WindowServer events carry the frame instead.
			if NSEvent.pressedMouseButtons & 1 == 0 || !WindowServer.isAvailable { update() }
		case let .windowDestroyed(id) where id == focused:
			focused = nil
			update()
		case .workspacesChanged:
			update()
		default:
			break
		}
	}

	/// A move or resize of the focused window, straight from the WindowServer. Only the frame's
	/// path changes, so this skips everything `update` checks and reads nothing from the app.
	private func follow(_ id: UInt32, _ bounds: CGRect) {
		guard id == ownFocused.map({ UInt32($0.windowNumber) }) ?? focused else { return }

		// A frame that stepped aside because the window was not on screen yet (on its way out of
		// a corner as its workspace is shown) checks again now that the window moved.
		guard let overlay, overlay.isVisible else {
			update()
			return
		}

		place(overlay, around: bounds)
	}

	/// Draws the frame around a window frame given in AX coordinates.
	private func place(_ overlay: BorderWindow, around bounds: CGRect) {
		guard let main = NSScreen.screens.first else { return }
		let flipped = CGRect(
			x: bounds.minX, y: main.frame.height - bounds.maxY, width: bounds.width, height: bounds.height
		)
		overlay.outline(flipped)
	}

	/// Puts the frame around the focused window, or takes it away when there is nothing to frame.
	private func update() {
		onOwnWindow(ownFocused.map { UInt32($0.windowNumber) })

		guard config.enabled, !isExposeOpen, let (id, bounds) = target() else {
			overlay?.orderOut(nil)
			return
		}

		let overlay = overlay ?? BorderWindow(styled)
		self.overlay = overlay
		overlay.radius = WindowServer.cornerRadius(of: id) ?? BorderWindow.fallbackRadius

		place(overlay, around: bounds)
		overlay.order(.above, relativeTo: Int(id))
	}

	/// The window to frame and its frame in AX coordinates; nil when there is nothing to frame.
	private func target() -> (id: UInt32, bounds: CGRect)? {
		if let window = ownFocused {
			let id = UInt32(window.windowNumber)
			return (id, WindowServer.bounds(of: id) ?? Self.topLeft(window.frame))
		}

		guard
			let id = focused,
			let info = lookup(id),
			!info.isMinimized, !info.isHidden, !info.isFullscreen,
			!config.blacklist.contains(info.app),
			info.subrole == "AXStandardWindow",
			// The WindowServer's frame is current; the AX one may still be the corner it left.
			case let bounds = WindowServer.bounds(of: id) ?? info.frame,
			Self.isOnScreen(bounds)
		else { return nil }

		return (id, bounds)
	}

	/// An AppKit frame, origin bottom left, in the top-left coordinates AX uses.
	private static func topLeft(_ frame: CGRect) -> CGRect {
		let height = NSScreen.screens.first?.frame.height ?? 0
		return CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
	}

	/// A window parked in a screen corner by a hidden workspace has a point or two on screen; it is
	/// not one to frame.
	private static func isOnScreen(_ frame: CGRect) -> Bool {
		guard let main = NSScreen.screens.first else { return false }
		let height = main.frame.height

		return NSScreen.screens.contains { screen in
			let rect = CGRect(
				x: screen.frame.minX, y: height - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height
			)
			let visible = rect.intersection(frame)
			return visible.width > 40 && visible.height > 40
		}
	}
}

/// The transparent window that draws the frame.
///
/// It covers the whole screen and never moves while the frame follows a window: only the path of
/// one shape layer changes. Moving or resizing a window costs a layout pass, and resizing one
/// also a new backing store, every step of a drag; a new path costs neither, so the frame keeps
/// up with a window being resized.
private final class BorderWindow: NSWindow {
	private let shape = CAShapeLayer()
	private var width = 0.0
	/// The framed window, in AppKit screen coordinates.
	private var target: CGRect?

	/// For a window whose corners the WindowServer does not report: the radius of a standard
	/// macOS window.
	static let fallbackRadius = 12.0

	/// The corner radius of the window being framed; changes with the focused app.
	var radius = fallbackRadius {
		didSet { if radius != oldValue { redraw() } }
	}

	init(_ config: Config.Borders) {
		super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)

		isOpaque = false
		backgroundColor = .clear
		hasShadow = false
		ignoresMouseEvents = true
		isReleasedWhenClosed = false
		level = .normal
		// Present on every Space, never in cmd-tab or the window cycle, and left in place by Exposé:
		// `.transient` would have Mission Control shrink it away, which shows as the frame flying to
		// the middle of the screen. Borders hides it once the Dock says Mission Control is open.
		collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

		let view = NSView()
		view.wantsLayer = true
		view.layer?.addSublayer(shape)
		contentView = view

		shape.fillColor = nil
		// The path changes in steps as the window moves; animating it would trail behind.
		shape.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]

		style(config)
	}

	func style(_ config: Config.Borders) {
		width = config.width
		shape.lineWidth = width
		if let color = config.color {
			shape.strokeColor = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
		} else {
			shape.strokeColor = NSColor.controlAccentColor.usingColorSpace(.sRGB)?.cgColor
		}
		redraw()
	}

	/// Frames a window. The overlay itself only moves when the window is on another screen.
	func outline(_ window: CGRect) {
		target = window

		let center = CGPoint(x: window.midX, y: window.midY)
		let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.screens.first

		if let screen, frame != screen.frame {
			setFrame(screen.frame, display: false)
		}

		redraw()
	}

	/// AppKit keeps windows out from under the menu bar; a frame around a window right below it
	/// has to reach up there.
	override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
		frameRect
	}

	/// The stroke runs `width / 2` outside the window edge, so it covers exactly `width` points
	/// outside the window and none of the window itself.
	private func redraw() {
		guard let target, let bounds = contentView?.bounds else { return }

		let local = target.offsetBy(dx: -frame.minX, dy: -frame.minY).insetBy(dx: -width / 2, dy: -width / 2)
		let corner = min(radius + width / 2, min(local.width, local.height) / 2)

		CATransaction.begin()
		CATransaction.setDisableActions(true)
		shape.frame = bounds
		shape.path = CGPath(roundedRect: local, cornerWidth: corner, cornerHeight: corner, transform: nil)
		CATransaction.commit()
		// Hands the new path to the render server now instead of at the end of this run loop pass.
		CATransaction.flush()
	}
}

/// The Dock's Exposé notifications arrive on the main run loop, where the observer was added.
private func dockCallback(_: AXObserver, _: AXUIElement, _ name: CFString, _ refcon: UnsafeMutableRawPointer?) {
	guard let refcon else { return }
	let borders = Unmanaged<Borders>.fromOpaque(refcon).takeUnretainedValue()
	let name = name as String
	MainActor.assumeIsolated { borders.exposeChanged(name) }
}

/// Runs on the main run loop, where the tap's source was added.
private func shortcutCallback(
	_: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
	guard let refcon else { return Unmanaged.passUnretained(event) }
	let borders = Unmanaged<Borders>.fromOpaque(refcon).takeUnretainedValue()
	nonisolated(unsafe) let event = event
	MainActor.assumeIsolated {
		switch type {
		case .keyDown: borders.keyDown(event)
		case .tapDisabledByTimeout, .tapDisabledByUserInput: borders.tapDisabled()
		default: break
		}
	}
	return Unmanaged.passUnretained(event)
}
