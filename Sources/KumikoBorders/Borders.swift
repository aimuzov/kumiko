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
		case let .windowChanged(info) where info.id == focused:
			update()
		case let .windowDestroyed(id) where id == focused:
			focused = nil
			update()
		case .workspacesChanged:
			update()
		default:
			break
		}
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
			let frame = Self.appKitFrame(info.frame, width: config.width),
			Self.isOnScreen(info.frame)
		else {
			overlay?.orderOut(nil)
			return
		}

		let overlay = overlay ?? BorderWindow(config)
		self.overlay = overlay

		overlay.setFrame(frame, display: true)
		overlay.order(.above, relativeTo: Int(id))
	}

	/// The overlay's frame in AppKit coordinates: the window's AX frame grown by the border width
	/// and flipped, since AX counts y down from the top of the main screen.
	private static func appKitFrame(_ frame: CGRect, width: Double) -> CGRect? {
		guard let main = NSScreen.screens.first else { return nil }
		let grown = frame.insetBy(dx: -width, dy: -width)
		return CGRect(x: grown.minX, y: main.frame.height - grown.maxY, width: grown.width, height: grown.height)
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
private final class BorderWindow: NSWindow {
	private let shape = CAShapeLayer()
	private var width = 0.0
	private var radius = 0.0

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
		// Frames move in steps as the layout changes; animating them would trail behind the window.
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

	/// AppKit keeps windows out from under the menu bar; the frame of a window right below it has
	/// to reach up there, or its top edge would be drawn over the window instead.
	override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
		frameRect
	}

	override func setFrame(_ frameRect: NSRect, display flag: Bool) {
		super.setFrame(frameRect, display: flag)
		redraw()
	}

	/// The stroke runs along the middle of the band between the window edge and the overlay edge,
	/// so it covers exactly `width` points outside the window and none of the window itself.
	private func redraw() {
		guard let bounds = contentView?.bounds, bounds.width > width * 2, bounds.height > width * 2 else { return }

		CATransaction.begin()
		CATransaction.setDisableActions(true)
		shape.frame = bounds
		let inset = bounds.insetBy(dx: width / 2, dy: width / 2)
		let corner = min(radius + width / 2, min(inset.width, inset.height) / 2)
		shape.path = CGPath(roundedRect: inset, cornerWidth: corner, cornerHeight: corner, transform: nil)
		CATransaction.commit()
	}
}
