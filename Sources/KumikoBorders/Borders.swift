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
	private var focused: UInt32?
	private var overlay: BorderWindow?

	/// `lookup` answers what the tracker knows about a window.
	public init(bus: EventBus, config: Config.Borders, focused: UInt32?, lookup: @escaping WindowLookup) {
		self.bus = bus
		self.config = config
		self.focused = focused
		self.lookup = lookup
	}

	public func start() {
		bus.subscribe { [weak self] event in self?.handle(event) }
		update()
	}

	public func apply(_ config: Config.Borders) {
		self.config = config
		overlay?.style(config)
		update()
	}

	private func handle(_ event: Event) {
		switch event {
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
		guard id == focused else { return }

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
		guard
			config.enabled,
			let id = focused,
			let info = lookup(id),
			!info.isMinimized, !info.isHidden, !info.isFullscreen,
			!config.blacklist.contains(info.app),
			info.subrole == "AXStandardWindow",
			// The WindowServer's frame is current; the AX one may still be the corner it left.
			case let bounds = WindowServer.bounds(of: id) ?? info.frame,
			Self.isOnScreen(bounds)
		else {
			overlay?.orderOut(nil)
			return
		}

		let overlay = overlay ?? BorderWindow(config)
		self.overlay = overlay
		overlay.radius = WindowServer.cornerRadius(of: id) ?? config.radius

		place(overlay, around: bounds)
		overlay.order(.above, relativeTo: Int(id))
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

	/// The corner radius of the window being framed; changes with the focused app.
	var radius = 0.0 {
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
		// Present on every Space, never in cmd-tab, Exposé or the window cycle.
		collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]

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
		radius = config.radius
		shape.lineWidth = width
		shape.strokeColor = CGColor(
			srgbRed: config.color.red, green: config.color.green, blue: config.color.blue, alpha: config.color.alpha
		)
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
