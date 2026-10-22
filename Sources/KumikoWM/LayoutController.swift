import AppKit
import KumikoCore

/// Arranges managed windows: one BSP tree per display, fed by the tracker's events, and the
/// `window` and `workspace` commands that change those trees.
///
/// For now there is one layout per display. Virtual workspaces will put several trees on each
/// display; until then windows on other native Spaces are left out, because a window that is not
/// on screen would otherwise hold a slot nobody can see.
@MainActor
public final class LayoutController {
	private let bus: EventBus
	private let tracker: WindowTracker
	private var config: Config.WM

	private var trees: [CGDirectDisplayID: BSPTree] = [:]
	private var floating: Set<UInt32> = []
	/// Focused windows, oldest first, for `focus recent`.
	private var history: [UInt32] = []
	/// What decided eligibility the last time each window was seen, to tell a window that was
	/// minimized from one that was merely moved (by kumiko itself, most of the time).
	private var known: [UInt32: EligibilityKey] = [:]
	private var syncScheduled = false
	private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

	private struct EligibilityKey: Equatable {
		let isManaged: Bool
		let isMinimized: Bool
		let isHidden: Bool
	}

	public init(bus: EventBus, tracker: WindowTracker, config: Config.WM) {
		self.bus = bus
		self.tracker = tracker
		self.config = config
	}

	public func start() {
		bus.subscribe { [weak self] event in self?.handle(event) }

		let workspace = NSWorkspace.shared.notificationCenter
		let app = NotificationCenter.default

		observe(workspace, NSWorkspace.activeSpaceDidChangeNotification)
		observe(app, NSApplication.didChangeScreenParametersNotification)
	}

	public func apply(_ config: Config.WM) {
		self.config = config

		if !config.enabled {
			trees = [:]
			floating = []
		}

		scheduleSync()
	}

	/// What `query` shows about a window beyond what the tracker knows.
	public func state(of id: UInt32) -> (isFloating: Bool, stackIndex: Int, zoom: String?) {
		guard let tree = tree(containing: id) else { return (true, 0, nil) }
		return (false, tree.stackIndex(of: id), tree.zoom(of: id)?.rawValue)
	}

	// MARK: - Events

	private func handle(_ event: Event) {
		switch event {
		case .windowCreated:
			scheduleSync()
			// A new window is often not on screen yet when AX announces it; look once more after
			// it has had time to appear.
			DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
				MainActor.assumeIsolated { self?.scheduleSync() }
			}
		case let .windowChanged(info):
			let key = EligibilityKey(isManaged: info.isManaged, isMinimized: info.isMinimized, isHidden: info.isHidden)
			if known[info.id] != key { scheduleSync() }
		case let .windowDestroyed(id):
			floating.remove(id)
			known[id] = nil
			scheduleSync()
		case let .windowFocused(id):
			guard let id else { return }
			history.removeAll { $0 == id }
			history.append(id)
			if history.count > 16 { history.removeFirst() }
			tree(containing: id)?.activate(id)
		case .configReloaded:
			break
		}
	}

	private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
		let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.scheduleSync() }
		}
		observers.append((center, token))
	}

	// MARK: - Sync and layout

	/// Coalesces a burst of events — kumiko starting up sees every window at once — into one pass.
	private func scheduleSync() {
		guard !syncScheduled else { return }
		syncScheduled = true

		DispatchQueue.main.async { [weak self] in
			MainActor.assumeIsolated {
				self?.syncScheduled = false
				self?.sync()
			}
		}
	}

	/// Brings the trees in line with the windows: takes out what no longer belongs, puts in what
	/// newly does, then lays everything out.
	private func sync() {
		guard config.enabled, tracker.isRunning else { return }

		let displays = Display.all()
		let onScreen = Self.onScreenWindowIDs()
		let focused = tracker.focusedWindowID

		for info in tracker.windows.values {
			known[info.id] = EligibilityKey(isManaged: info.isManaged, isMinimized: info.isMinimized, isHidden: info.isHidden)
		}

		// A display that went away takes its tree with it; its windows are placed again below.
		for id in trees.keys where !displays.contains(where: { $0.id == id }) {
			trees[id] = nil
		}

		for tree in trees.values {
			for id in tree.allWindows where !isEligible(id, onScreen: onScreen) {
				tree.remove(id)
			}
		}

		for info in tracker.sortedWindows where isEligible(info.id, onScreen: onScreen) && tree(containing: info.id) == nil {
			guard let display = Display.containing(info.frame, in: displays) else { continue }

			let tree = trees[display.id] ?? BSPTree()
			trees[display.id] = tree
			tree.insert(info.id, near: focused.flatMap { tree.contains($0) ? $0 : nil }, in: area(of: display), gap: gap)
		}

		layout(displays)
	}

	private func isEligible(_ id: UInt32, onScreen: Set<UInt32>) -> Bool {
		guard let info = tracker.windows[id] else { return false }
		return info.isManaged && !info.isMinimized && !info.isHidden && !floating.contains(id) && onScreen.contains(id)
	}

	private func layout(_ displays: [Display]? = nil) {
		for display in displays ?? Display.all() {
			guard let tree = trees[display.id] else { continue }

			for (id, frame) in tree.frames(in: area(of: display), gap: gap) {
				if let current = tracker.windows[id]?.frame, current.isClose(to: frame) { continue }
				tracker.setFrame(id, frame)
			}
		}
	}

	private var gap: Double { Double(config.gap) }

	private func area(of display: Display) -> CGRect {
		let padding = config.padding
		return CGRect(
			x: display.visibleFrame.minX + Double(padding.left),
			y: display.visibleFrame.minY + Double(padding.top),
			width: display.visibleFrame.width - Double(padding.left + padding.right),
			height: display.visibleFrame.height - Double(padding.top + padding.bottom)
		)
	}

	/// Windows on the current native Space that are not minimized or hidden. Public API: the
	/// window list knows what is on screen without asking every app.
	private static func onScreenWindowIDs() -> Set<UInt32> {
		let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
		guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
		return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
	}

	private func tree(containing id: UInt32) -> BSPTree? {
		trees.values.first { $0.contains(id) }
	}

	private func display(of tree: BSPTree) -> Display? {
		guard let id = trees.first(where: { $0.value === tree })?.key else { return nil }
		return Display.all().first { $0.id == id }
	}

	/// Where the windows in front are right now, on every display.
	private func visibleFrames() -> [UInt32: CGRect] {
		var result: [UInt32: CGRect] = [:]

		for display in Display.all() {
			guard let tree = trees[display.id] else { continue }
			let frames = tree.frames(in: area(of: display), gap: gap)
			for id in tree.visibleWindows { result[id] = frames[id] }
		}

		return result
	}

	/// The closest window in a direction, across displays. Windows that line up with the source
	/// (overlap it across the direction) win over ones that are only diagonally there.
	private func neighbor(of id: UInt32, _ direction: Direction) -> UInt32? {
		var frames = visibleFrames()
		guard let source = frames.removeValue(forKey: id) ?? tracker.windows[id]?.frame else { return nil }

		let slack = gap + 1
		let candidates = frames.filter { _, frame in
			switch direction {
			case .west: frame.maxX <= source.minX + slack
			case .east: frame.minX >= source.maxX - slack
			case .north: frame.maxY <= source.minY + slack
			case .south: frame.minY >= source.maxY - slack
			}
		}

		func overlaps(_ frame: CGRect) -> Bool {
			direction.axis == .columns
				? frame.minY < source.maxY && frame.maxY > source.minY
				: frame.minX < source.maxX && frame.maxX > source.minX
		}

		func score(_ frame: CGRect) -> (Int, Double, Double) {
			let distance = switch direction {
			case .west: source.minX - frame.maxX
			case .east: frame.minX - source.maxX
			case .north: source.minY - frame.maxY
			case .south: frame.minY - source.maxY
			}
			let across = direction.axis == .columns ? abs(frame.midY - source.midY) : abs(frame.midX - source.midX)
			return (overlaps(frame) ? 0 : 1, distance, across)
		}

		return candidates.min { score($0.value) < score($1.value) }?.key
	}

	// MARK: - Commands

	public func handle(_ args: [String]) -> Response {
		guard config.enabled, tracker.isRunning else { return .failure("window management is not running") }

		switch args.first {
		case "window": return window(Array(args.dropFirst()))
		case "workspace": return workspace(Array(args.dropFirst()))
		default: return .failure("unknown command: \(args.first ?? "")")
		}
	}

	private func window(_ args: [String]) -> Response {
		guard let id = tracker.focusedWindowID else { return .failure("no focused window") }

		let command = args.first ?? ""
		let argument = args.count > 1 ? args[1] : nil

		switch command {
		case "focus": return focus(id, argument)
		case "warp": return warp(id, argument)
		case "resize": return resize(id, argument, args.count > 2 ? args[2] : nil)
		case "ratio": return ratio(id, argument)
		case "float": return float(id, Array(args.dropFirst()))
		case "zoom": return zoom(id, argument)
		case "stack": return stack(id, argument)
		case "unstack": return unstack(id)
		case "close": return tracker.close(id) ? .success() : .failure("the window has no close button")
		default:
			return .failure("usage: kumiko window focus|warp|resize|ratio|float|zoom|stack|unstack|close …")
		}
	}

	private func focus(_ id: UInt32, _ target: String?) -> Response {
		let next: UInt32?

		switch target {
		case let name? where Direction(rawValue: name) != nil:
			next = neighbor(of: id, Direction(rawValue: name)!)
		case "first":
			next = tree(containing: id)?.visibleWindows.first
		case "last":
			next = tree(containing: id)?.visibleWindows.last
		case "recent":
			next = history.dropLast().last { tracker.windows[$0] != nil && $0 != id }
		case "stack-next":
			next = tree(containing: id)?.cycleStack(of: id, by: 1)
		case "stack-prev":
			next = tree(containing: id)?.cycleStack(of: id, by: -1)
		default:
			return .failure("usage: kumiko window focus west|east|north|south|first|last|recent|stack-next|stack-prev")
		}

		guard let next, next != id else { return .failure("no window there") }
		tracker.focus(next)
		return .success()
	}

	private func warp(_ id: UInt32, _ target: String?) -> Response {
		guard let tree = tree(containing: id) else { return .failure("the window is not tiled") }

		switch target {
		case "first", "last":
			let windows = tree.visibleWindows
			guard let other = target == "first" ? windows.first : windows.last, other != id else {
				return .failure("the window is already \(target!)")
			}
			tree.swap(id, other)
		case let name? where Direction(rawValue: name) != nil:
			let direction = Direction(rawValue: name)!
			guard let other = neighbor(of: id, direction) else { return .failure("no window there") }

			if tree.contains(other) {
				tree.warp(id, to: other, direction: direction)
			} else if let otherTree = self.tree(containing: other), let display = display(of: otherTree) {
				// Across displays: the window leaves its tree and joins the other one, next to `other`.
				tree.remove(id)
				otherTree.insert(id, near: other, in: area(of: display), gap: gap)
			}
		default:
			return .failure("usage: kumiko window warp west|east|north|south|first|last")
		}

		layout()
		return .success()
	}

	private func resize(_ id: UInt32, _ edge: String?, _ delta: String?) -> Response {
		let edges: [String: Direction] = ["left": .west, "right": .east, "top": .north, "bottom": .south]

		guard let edge = edge.flatMap({ edges[$0] }), let delta = delta.flatMap(Double.init) else {
			return .failure("usage: kumiko window resize left|right|top|bottom <points>")
		}
		guard let tree = tree(containing: id), let display = display(of: tree) else {
			return .failure("the window is not tiled")
		}
		guard tree.resize(id, edge: edge, by: delta, in: area(of: display), gap: gap) else {
			return .failure("that edge cannot move")
		}

		layout()
		return .success()
	}

	private func ratio(_ id: UInt32, _ value: String?) -> Response {
		guard let share = value.flatMap(Double.init), share > 0, share < 1 else {
			return .failure("usage: kumiko window ratio <0…1>, the window's share of its split")
		}
		guard let tree = tree(containing: id), tree.setShare(id, share) else {
			return .failure("the window is not in a split")
		}

		layout()
		return .success()
	}

	/// Toggles floating. `--grid rows:cols:x:y:width:height` also places a window that starts
	/// floating on that cell of a grid laid over its display.
	private func float(_ id: UInt32, _ args: [String]) -> Response {
		if floating.remove(id) != nil {
			sync()
			return .success()
		}

		floating.insert(id)
		sync()

		if let index = args.firstIndex(of: "--grid"), index + 1 < args.count {
			guard let frame = gridFrame(args[index + 1], for: id) else {
				return .failure("usage: kumiko window float [--grid rows:cols:x:y:width:height]")
			}
			tracker.setFrame(id, frame)
		}

		return .success()
	}

	private func gridFrame(_ spec: String, for id: UInt32) -> CGRect? {
		let parts = spec.split(separator: ":").compactMap { Double($0) }
		guard
			parts.count == 6, parts[0] > 0, parts[1] > 0,
			let window = tracker.windows[id],
			let display = Display.containing(window.frame, in: Display.all())
		else { return nil }

		let area = display.visibleFrame
		let cellWidth = area.width / parts[1]
		let cellHeight = area.height / parts[0]

		return CGRect(
			x: area.minX + parts[2] * cellWidth,
			y: area.minY + parts[3] * cellHeight,
			width: parts[4] * cellWidth,
			height: parts[5] * cellHeight
		).integral
	}

	private func zoom(_ id: UInt32, _ kind: String?) -> Response {
		guard let zoom = kind.flatMap(Zoom.init(rawValue:)) else {
			return .failure("usage: kumiko window zoom fullscreen|parent")
		}
		guard let tree = tree(containing: id) else { return .failure("the window is not tiled") }

		tree.toggleZoom(id, zoom)
		layout()
		// A zoomed window covers its neighbours, so it has to be on top of them.
		tracker.focus(id)
		return .success()
	}

	private func stack(_ id: UInt32, _ direction: String?) -> Response {
		guard let direction = direction.flatMap(Direction.init(rawValue:)) else {
			return .failure("usage: kumiko window stack west|east|north|south")
		}
		guard let tree = tree(containing: id) else { return .failure("the window is not tiled") }
		guard let other = neighbor(of: id, direction), tree.contains(other) else {
			return .failure("no window there on this display")
		}

		tree.stack(id, onto: other)
		layout()
		tracker.focus(id)
		return .success()
	}

	private func unstack(_ id: UInt32) -> Response {
		guard let tree = tree(containing: id), let display = display(of: tree) else {
			return .failure("the window is not tiled")
		}
		guard tree.unstack(id, in: area(of: display), gap: gap) else { return .failure("the window is not stacked") }

		layout()
		tracker.focus(id)
		return .success()
	}

	private func workspace(_ args: [String]) -> Response {
		// The layout of the display with the focused window, or of the main display.
		let focusedTree = tracker.focusedWindowID.flatMap { tree(containing: $0) }
		guard let tree = focusedTree ?? Display.all().first.flatMap({ trees[$0.id] }) else {
			return .failure("no tiled windows here")
		}

		switch (args.first, args.count > 1 ? args[1] : nil) {
		case ("balance", _):
			tree.balance()
		case let ("rotate", degrees?) where [90, 180, 270].contains(Int(degrees) ?? 0):
			tree.rotate(Int(degrees)!)
		case ("mirror", "horizontal"):
			tree.mirror(.columns)
		case ("mirror", "vertical"):
			tree.mirror(.rows)
		default:
			return .failure("usage: kumiko workspace balance|rotate 90|180|270|mirror horizontal|vertical")
		}

		layout()
		return .success()
	}
}

private extension CGRect {
	/// AX reports frames in whole points and apps round sizes their own way, so a frame within a
	/// point of the target is already where it should be.
	func isClose(to other: CGRect) -> Bool {
		abs(minX - other.minX) <= 1 && abs(minY - other.minY) <= 1
			&& abs(width - other.width) <= 1 && abs(height - other.height) <= 1
	}
}
