import AppKit
import KumikoCore

/// Arranges windows into virtual workspaces, each with its own BSP layout, and answers the
/// `window` and `workspace` commands.
///
/// kumiko expects one native Space per display: the workspaces replace them. A workspace that is
/// not shown keeps its windows in a corner of its display, one point on screen, and brings them
/// back when it is shown again.
@MainActor
public final class WindowManager {
	private let bus: EventBus
	private let tracker: WindowTracker
	private var config: Config

	private var workspaces: [Workspace] = []
	/// The workspace shown on each display.
	private var visible: [CGDirectDisplayID: Workspace] = [:]
	private var assignment: [UInt32: Workspace] = [:]
	private var floating: Set<UInt32> = []
	/// Windows moved out of sight, with the frame to give back to the ones that are not tiled.
	private var hidden: [UInt32: CGRect] = [:]
	/// The frame each tiled window was last given, to notice when the user moves one by hand.
	private var expected: [UInt32: CGRect] = [:]
	private var placement = Placement([])
	private var previousWorkspace: String?
	private var hasShownFocusedWorkspace = false

	/// Focused windows, oldest first, for `focus recent`.
	private var history: [UInt32] = []
	/// What decided eligibility the last time each window was seen, to tell a window that was
	/// minimized from one that was merely moved.
	private var known: [UInt32: EligibilityKey] = [:]
	private var syncScheduled = false
	private var dragged: Set<UInt32> = []
	private var dragCheckScheduled = false
	private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

	private struct EligibilityKey: Equatable {
		let isManaged: Bool
		let isMinimized: Bool
		let isHidden: Bool
		let isFullscreen: Bool

		init(_ info: WindowInfo) {
			isManaged = info.isManaged
			isMinimized = info.isMinimized
			isHidden = info.isHidden
			isFullscreen = info.isFullscreen
		}
	}

	public init(bus: EventBus, tracker: WindowTracker, config: Config) {
		self.bus = bus
		self.tracker = tracker
		self.config = config
		placement = Placement(config.workspaces)
	}

	public func start() {
		bus.subscribe { [weak self] event in self?.handle(event) }
		observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)
	}

	public func apply(_ config: Config) {
		self.config = config
		placement = Placement(config.workspaces)

		if !config.wm.enabled {
			showEverything()
			workspaces = []
			visible = [:]
			assignment = [:]
			floating = []
			expected = [:]
		}

		scheduleSync()
	}

	/// Puts every hidden window back on screen. Runs on quit and when the module is turned off, so
	/// windows are never left stranded in a corner.
	public func showEverything() {
		for (id, frame) in hidden {
			tracker.setFrame(id, frame)
		}
		hidden = [:]
	}

	// MARK: - Query

	public func state(of id: UInt32) -> (isFloating: Bool, stackIndex: Int, zoom: String?, workspace: String?) {
		let workspace = assignment[id]
		guard let tree = workspace?.tree, tree.contains(id) else { return (true, 0, nil, workspace?.name) }
		return (false, tree.stackIndex(of: id), tree.zoom(of: id)?.rawValue, workspace?.name)
	}

	public var workspaceStates: [WorkspaceState] {
		let focused = focusedWorkspace
		return workspaces.enumerated().map { index, workspace in
			WorkspaceState(
				name: workspace.name,
				index: index + 1,
				display: workspace.display.id,
				isVisible: visible[workspace.display.id] === workspace,
				isFocused: workspace === focused,
				windows: windows(of: workspace)
			)
		}
	}

	public var displayStates: [DisplayState] {
		Display.all().map { display in
			DisplayState(
				id: display.id, name: display.name, isBuiltin: display.isBuiltin, frame: display.frame,
				workspace: visible[display.id]?.name
			)
		}
	}

	/// Native Spaces beyond one per display, or nil when there are none (or they cannot be counted).
	public var extraNativeSpaces: Int? {
		guard let counts = NativeSpaces.countPerDisplay() else { return nil }
		let extra = counts.reduce(0) { $0 + max(0, $1 - 1) }
		return extra > 0 ? extra : nil
	}

	private func windows(of workspace: Workspace) -> [UInt32] {
		assignment.filter { $0.value === workspace }.keys.sorted()
	}

	/// The workspace of the focused window, or the one shown on the main display.
	private var focusedWorkspace: Workspace? {
		if let id = tracker.focusedWindowID, let workspace = assignment[id], isVisible(workspace) {
			return workspace
		}
		return Display.all().first.flatMap { visible[$0.id] }
	}

	private func isVisible(_ workspace: Workspace) -> Bool {
		visible[workspace.display.id] === workspace
	}

	// MARK: - Events

	private func handle(_ event: Event) {
		switch event {
		case .windowCreated:
			scheduleSync()
		case let .windowChanged(info):
			if known[info.id] != EligibilityKey(info) {
				scheduleSync()
			} else {
				noticeUserFrameChange(info)
			}
		case let .windowDestroyed(id):
			floating.remove(id)
			hidden[id] = nil
			expected[id] = nil
			known[id] = nil
			scheduleSync()
		case let .windowFocused(id):
			guard let id else { return }
			history.removeAll { $0 == id }
			history.append(id)
			if history.count > 16 { history.removeFirst() }

			guard let workspace = assignment[id] else { return }
			workspace.lastFocused = id
			workspace.tree.activate(id)

			// Focus landed on a window of a hidden workspace — cmd-tab, a Dock click, a link opening
			// in a browser — so that workspace comes into view instead of the window staying unseen.
			if !isVisible(workspace) {
				show(workspace)
			}
		case .configReloaded, .workspacesChanged, .hotkeyModeChanged:
			break
		}
	}

	private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
		let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.scheduleSync() }
		}
		observers.append((center, token))
	}

	// MARK: - Sync

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

	/// Brings everything in line: workspaces with the screens, windows with workspaces, layouts with
	/// windows, and then puts every window where its workspace says.
	private func sync() {
		guard config.wm.enabled, tracker.isRunning else { return }

		let displays = Display.all()
		guard !displays.isEmpty else { return }

		updateWorkspaces(displays)

		for info in tracker.windows.values {
			known[info.id] = EligibilityKey(info)
		}

		for id in assignment.keys where tracker.windows[id] == nil {
			assignment[id] = nil
		}

		for info in tracker.sortedWindows where assignment[info.id] == nil {
			let workspace = workspace(forNew: info, displays: displays)
			assignment[info.id] = workspace

			// A window found almost entirely off screen was left in a corner by a kumiko that did not
			// get to quit properly. It counts as hidden, and comes back centred when shown.
			if let workspace, Self.isOffScreen(info.frame, displays: displays) {
				hidden[info.id] = Self.centered(info.frame.size, in: workspace.display.visibleFrame)
			}
		}

		// On the first pass the display with the focused window shows that window's workspace, so
		// starting kumiko does not hide what the user is looking at.
		if !hasShownFocusedWorkspace, let id = tracker.focusedWindowID, let workspace = assignment[id] {
			visible[workspace.display.id] = workspace
			hasShownFocusedWorkspace = true
		}

		for workspace in workspaces {
			for id in workspace.tree.allWindows where !isTiled(id, in: workspace) {
				workspace.tree.remove(id)
			}
		}

		for info in tracker.sortedWindows {
			guard let workspace = assignment[info.id], isTiled(info.id, in: workspace), !workspace.tree.contains(info.id)
			else { continue }
			add(info, to: workspace)
		}

		arrange(displays)
	}

	/// Rebuilds the workspace list from the config, keeping the layout of every workspace whose
	/// name stays, and makes sure each display shows one.
	private func updateWorkspaces(_ displays: [Display]) {
		var configs = config.workspaces.isEmpty
			? (1...9).map { Config.Workspace(name: String($0)) }
			: config.workspaces

		// A display no workspace is meant for still gets one, or it could show nothing at all.
		for (index, display) in displays.enumerated() {
			let claimed = configs.contains { Display.matching($0.display, in: displays) == display }
			if !claimed {
				configs.append(Config.Workspace(name: "display-\(index + 1)", display: display.name))
			}
		}

		let old = Dictionary(workspaces.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

		workspaces = configs.map { config in
			let display = Display.matching(config.display, in: displays) ?? displays[0]

			if let workspace = old[config.name] {
				workspace.config = config
				workspace.display = display
				return workspace
			}

			return Workspace(config: config, display: display)
		}

		// Windows of a workspace that is gone are placed again, like new ones.
		let names = Set(workspaces.map(\.name))
		for (id, workspace) in assignment where !names.contains(workspace.name) {
			assignment[id] = nil
		}

		for display in displays {
			let candidates = workspaces.filter { $0.display == display }
			if let current = visible[display.id], candidates.contains(where: { $0 === current }) { continue }
			visible[display.id] = candidates.first
		}

		for id in visible.keys where !displays.contains(where: { $0.id == id }) {
			visible[id] = nil
		}
	}

	/// The workspace a window joins when kumiko first sees it: the one its app belongs to, else the
	/// workspace shown where the window is.
	private func workspace(forNew info: WindowInfo, displays: [Display]) -> Workspace? {
		if let name = placement.workspace(for: info.app), let workspace = workspaces.first(where: { $0.name == name }) {
			return workspace
		}

		if !Self.isOffScreen(info.frame, displays: displays), let display = Display.containing(info.frame, in: displays) {
			return visible[display.id]
		}

		return focusedWorkspace
	}

	private func isTiled(_ id: UInt32, in workspace: Workspace) -> Bool {
		guard let info = tracker.windows[id], assignment[id] === workspace else { return false }
		return info.isManaged && !info.isMinimized && !info.isHidden && !info.isFullscreen && !floating.contains(id)
	}

	/// Puts a window into its workspace's layout, then applies the workspace's layout rules.
	private func add(_ info: WindowInfo, to workspace: Workspace) {
		let tree = workspace.tree
		let near = [tracker.focusedWindowID, workspace.lastFocused].compactMap(\.self).first { tree.contains($0) }
		tree.insert(info.id, near: near, in: area(of: workspace.display), gap: gap)

		let rules = workspace.config

		if rules.stack.contains(info.app),
		   let other = tree.allWindows.first(where: { $0 != info.id && rules.stack.contains(tracker.windows[$0]?.app ?? "") })
		{
			tree.stack(info.id, onto: other)
		}

		// Pinned-last apps go back to the end every time anything joins, not only when they do.
		if let pinned = tree.visibleWindows.first(where: { rules.last.contains(tracker.windows[$0]?.app ?? "") }),
		   let last = tree.visibleWindows.last, pinned != last
		{
			tree.swap(pinned, last)
		}

		// After the swap: a share belongs to the window's final place, not the one it was inserted in.
		if let share = rules.share[info.app] {
			tree.setShare(info.id, share)
		}
	}

	// MARK: - Arranging

	/// Lays out every visible workspace and moves the windows of the others out of sight.
	private func arrange(_ displays: [Display]? = nil) {
		let displays = displays ?? Display.all()

		for workspace in workspaces {
			if isVisible(workspace) {
				layout(workspace)
			} else {
				hide(workspace, displays: displays)
			}
		}
	}

	private func layout(_ workspace: Workspace) {
		for (id, frame) in workspace.tree.frames(in: area(of: workspace.display), gap: gap) {
			expected[id] = frame
			hidden[id] = nil
			if let current = tracker.windows[id]?.frame, current.isClose(to: frame) { continue }
			tracker.setFrame(id, frame)
		}

		// Windows that are not tiled come back to where they were before the workspace was hidden.
		for id in windows(of: workspace) where !workspace.tree.contains(id) {
			if let frame = hidden.removeValue(forKey: id) {
				tracker.setFrame(id, frame)
			}
		}
	}

	private func hide(_ workspace: Workspace, displays: [Display]) {
		let others = displays.filter { $0 != workspace.display }.map(\.frame)

		for id in windows(of: workspace) where hidden[id] == nil {
			guard let info = tracker.windows[id], !info.isMinimized, !info.isHidden, !info.isFullscreen else { continue }

			hidden[id] = info.frame
			let origin = Display.hiddenOrigin(for: info.frame.size, on: workspace.display.frame, others: others)
			tracker.setFrame(id, CGRect(origin: origin, size: info.frame.size))
		}
	}

	private var gap: Double { Double(config.wm.gap) }

	private static func isOffScreen(_ frame: CGRect, displays: [Display]) -> Bool {
		!displays.contains { display in
			let visible = display.frame.intersection(frame)
			return visible.width > 20 && visible.height > 20
		}
	}

	private static func centered(_ size: CGSize, in area: CGRect) -> CGRect {
		let width = min(size.width, area.width)
		let height = min(size.height, area.height)
		return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height).integral
	}

	private func area(of display: Display) -> CGRect {
		let padding = config.wm.padding
		return CGRect(
			x: display.visibleFrame.minX + Double(padding.left),
			y: display.visibleFrame.minY + Double(padding.top),
			width: display.visibleFrame.width - Double(padding.left + padding.right),
			height: display.visibleFrame.height - Double(padding.top + padding.bottom)
		)
	}

	// MARK: - Switching

	/// Shows a workspace on its display, hiding the one that was there.
	private func show(_ workspace: Workspace) {
		let display = workspace.display
		guard visible[display.id] !== workspace else { return }

		previousWorkspace = visible[display.id]?.name
		visible[display.id] = workspace
		arrange()
		bus.publish(.workspacesChanged)
	}

	/// The window that should get focus when a workspace comes into view.
	private func windowToFocus(in workspace: Workspace) -> UInt32? {
		if let id = workspace.lastFocused, assignment[id] === workspace, tracker.windows[id] != nil {
			return id
		}

		return workspace.tree.visibleWindows.first
			?? windows(of: workspace).first { tracker.windows[$0]?.isMinimized == false }
	}

	private func resolve(_ target: String, from current: Workspace?) -> Workspace? {
		switch target {
		case "next", "prev":
			// Cycles through the workspaces of the current display, in config order.
			guard let current else { return nil }
			let siblings = workspaces.filter { $0.display == current.display }
			guard let index = siblings.firstIndex(where: { $0 === current }) else { return nil }
			let step = target == "next" ? 1 : -1
			return siblings[(index + step + siblings.count) % siblings.count]
		case "recent":
			return previousWorkspace.flatMap { name in workspaces.first { $0.name == name } }
		default:
			if let workspace = workspaces.first(where: { $0.name == target }) { return workspace }
			if let number = Int(target), workspaces.indices.contains(number - 1) { return workspaces[number - 1] }
			return nil
		}
	}

	// MARK: - Moving windows by hand

	/// A tiled window changed frame while a mouse button was down: the user is dragging or
	/// resizing it. Frames that change with no button pressed come from kumiko itself or from the
	/// app (refusing a size, say) and are left alone, or kumiko would fight the app over them.
	private func noticeUserFrameChange(_ info: WindowInfo) {
		guard
			NSEvent.pressedMouseButtons & 1 != 0,
			let expected = expected[info.id], !info.frame.isClose(to: expected),
			let workspace = assignment[info.id], workspace.tree.contains(info.id), isVisible(workspace)
		else { return }

		dragged.insert(info.id)
		scheduleDragCheck()
	}

	/// Waits for the mouse button to come up, then settles what the user did.
	private func scheduleDragCheck() {
		guard !dragCheckScheduled else { return }
		dragCheckScheduled = true

		DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.dragCheckScheduled = false

				if NSEvent.pressedMouseButtons & 1 != 0 {
					self.scheduleDragCheck()
					return
				}

				let ids = self.dragged
				self.dragged = []
				ids.forEach(self.settleUserFrame)
				self.arrange()
			}
		}
	}

	/// A resize moves the splits along the edges the user pulled; a drag that ends over another
	/// window swaps the two; a drag that ends anywhere else snaps back into the layout.
	private func settleUserFrame(_ id: UInt32) {
		guard
			let frame = tracker.windows[id]?.frame, let old = expected[id],
			let workspace = assignment[id], workspace.tree.contains(id)
		else { return }

		let area = area(of: workspace.display)
		let resized = abs(frame.width - old.width) > 2 || abs(frame.height - old.height) > 2

		if resized {
			let edges: [(Direction, Double)] = [
				(.west, frame.minX - old.minX), (.east, frame.maxX - old.maxX),
				(.north, frame.minY - old.minY), (.south, frame.maxY - old.maxY),
			]
			for (edge, delta) in edges where abs(delta) > 2 {
				workspace.tree.resize(id, edge: edge, by: delta, in: area, gap: gap)
			}
			return
		}

		let pointer = Self.pointerLocation()
		let target = visibleFrames().first { $0.key != id && $0.value.contains(pointer) }?.key

		guard let target, let targetWorkspace = assignment[target] else { return }

		if targetWorkspace === workspace {
			workspace.tree.swap(id, target)
		} else {
			// Dropped on a window on another display: the window moves to that workspace.
			workspace.tree.remove(id)
			assignment[id] = targetWorkspace
			targetWorkspace.tree.insert(id, near: target, in: self.area(of: targetWorkspace.display), gap: gap)
		}
	}

	/// The mouse position in AX coordinates.
	private static func pointerLocation() -> CGPoint {
		let location = NSEvent.mouseLocation
		let height = NSScreen.screens.first?.frame.height ?? 0
		return CGPoint(x: location.x, y: height - location.y)
	}

	// MARK: - Geometry

	/// Where the windows in front are, on every visible workspace.
	private func visibleFrames() -> [UInt32: CGRect] {
		var result: [UInt32: CGRect] = [:]

		for workspace in workspaces where isVisible(workspace) {
			let frames = workspace.tree.frames(in: area(of: workspace.display), gap: gap)
			for id in workspace.tree.visibleWindows { result[id] = frames[id] }
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
		guard config.wm.enabled, tracker.isRunning else { return .failure("window management is not running") }

		switch args.first {
		case "window": return window(Array(args.dropFirst()))
		case "workspace": return workspace(Array(args.dropFirst()))
		default: return .failure("unknown command: \(args.first ?? "")")
		}
	}

	/// The focused window, if it is on a visible workspace: a window left focused on a workspace
	/// that was just hidden is not one to act on.
	private var focusedWindow: UInt32? {
		guard let id = tracker.focusedWindowID else { return nil }
		guard let workspace = assignment[id] else { return id }
		return isVisible(workspace) ? id : nil
	}

	private func window(_ args: [String]) -> Response {
		guard let id = focusedWindow else { return .failure("no focused window") }

		let command = args.first ?? ""
		let argument = args.count > 1 ? args[1] : nil

		switch command {
		case "focus": return focus(id, argument)
		case "warp": return warp(id, argument)
		case "move": return move(id, argument, follow: args.contains("--focus"))
		case "resize": return resize(id, argument, args.count > 2 ? args[2] : nil)
		case "ratio": return ratio(id, argument)
		case "float": return float(id, Array(args.dropFirst()))
		case "zoom": return zoom(id, argument)
		case "stack": return stack(id, argument)
		case "unstack": return unstack(id)
		case "close": return tracker.close(id) ? .success() : .failure("the window has no close button")
		default:
			return .failure("usage: kumiko window focus|warp|move|resize|ratio|float|zoom|stack|unstack|close …")
		}
	}

	private func focus(_ id: UInt32, _ target: String?) -> Response {
		let tree = assignment[id]?.tree
		let next: UInt32?

		switch target {
		case let name? where Direction(rawValue: name) != nil:
			next = neighbor(of: id, Direction(rawValue: name)!)
		case "first":
			next = tree?.visibleWindows.first
		case "last":
			next = tree?.visibleWindows.last
		case "recent":
			next = history.dropLast().last { tracker.windows[$0] != nil && $0 != id }
		case "stack-next":
			next = tree?.cycleStack(of: id, by: 1)
		case "stack-prev":
			next = tree?.cycleStack(of: id, by: -1)
		default:
			return .failure("usage: kumiko window focus west|east|north|south|first|last|recent|stack-next|stack-prev")
		}

		guard let next, next != id else { return .failure("no window there") }
		tracker.focus(next)
		return .success()
	}

	private func warp(_ id: UInt32, _ target: String?) -> Response {
		guard let workspace = assignment[id], workspace.tree.contains(id) else {
			return .failure("the window is not tiled")
		}
		let tree = workspace.tree

		switch target {
		case "first", "last":
			let windows = tree.visibleWindows
			guard let other = target == "first" ? windows.first : windows.last, other != id else {
				return .failure("the window is already \(target!)")
			}
			tree.swap(id, other)
		case let name? where Direction(rawValue: name) != nil:
			let direction = Direction(rawValue: name)!
			guard let other = neighbor(of: id, direction), let otherWorkspace = assignment[other] else {
				return .failure("no window there")
			}

			if otherWorkspace === workspace {
				tree.warp(id, to: other, direction: direction)
			} else {
				// Across displays: the window joins the workspace shown there, next to `other`.
				tree.remove(id)
				assignment[id] = otherWorkspace
				otherWorkspace.tree.insert(id, near: other, in: area(of: otherWorkspace.display), gap: gap)
			}
		default:
			return .failure("usage: kumiko window warp west|east|north|south|first|last")
		}

		arrange()
		return .success()
	}

	/// Sends a window to another workspace; with `--focus` the view follows it there.
	private func move(_ id: UInt32, _ target: String?, follow: Bool) -> Response {
		guard let target, let current = assignment[id], let destination = resolve(target, from: current) else {
			return .failure("usage: kumiko window move <workspace>|next|prev [--focus]")
		}
		guard destination !== current else { return .failure("the window is already on \(destination.name)") }

		current.tree.remove(id)
		assignment[id] = destination
		if current.lastFocused == id { current.lastFocused = nil }

		if let info = tracker.windows[id], isTiled(id, in: destination) {
			add(info, to: destination)
		}

		if follow {
			destination.lastFocused = id
			show(destination)
			arrange()
			tracker.focus(id)
		} else {
			arrange()
			bus.publish(.workspacesChanged)
			if let next = windowToFocus(in: current) { tracker.focus(next) }
		}

		return .success()
	}

	private func resize(_ id: UInt32, _ edge: String?, _ delta: String?) -> Response {
		let edges: [String: Direction] = ["left": .west, "right": .east, "top": .north, "bottom": .south]

		guard let edge = edge.flatMap({ edges[$0] }), let delta = delta.flatMap(Double.init) else {
			return .failure("usage: kumiko window resize left|right|top|bottom <points>")
		}
		guard let workspace = assignment[id], workspace.tree.contains(id) else {
			return .failure("the window is not tiled")
		}
		guard workspace.tree.resize(id, edge: edge, by: delta, in: area(of: workspace.display), gap: gap) else {
			return .failure("that edge cannot move")
		}

		arrange()
		return .success()
	}

	private func ratio(_ id: UInt32, _ value: String?) -> Response {
		guard let share = value.flatMap(Double.init), share > 0, share < 1 else {
			return .failure("usage: kumiko window ratio <0…1>, the window's share of its split")
		}
		guard let tree = assignment[id]?.tree, tree.setShare(id, share) else {
			return .failure("the window is not in a split")
		}

		arrange()
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
		guard parts.count == 6, parts[0] > 0, parts[1] > 0, let display = assignment[id]?.display else { return nil }

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
		guard let tree = assignment[id]?.tree, tree.contains(id) else { return .failure("the window is not tiled") }

		tree.toggleZoom(id, zoom)
		arrange()
		// A zoomed window covers its neighbours, so it has to be on top of them.
		tracker.focus(id)
		return .success()
	}

	private func stack(_ id: UInt32, _ direction: String?) -> Response {
		guard let direction = direction.flatMap(Direction.init(rawValue:)) else {
			return .failure("usage: kumiko window stack west|east|north|south")
		}
		guard let tree = assignment[id]?.tree, tree.contains(id) else { return .failure("the window is not tiled") }
		guard let other = neighbor(of: id, direction), tree.contains(other) else {
			return .failure("no window there on this workspace")
		}

		tree.stack(id, onto: other)
		arrange()
		tracker.focus(id)
		return .success()
	}

	private func unstack(_ id: UInt32) -> Response {
		guard let workspace = assignment[id], workspace.tree.contains(id) else {
			return .failure("the window is not tiled")
		}
		guard workspace.tree.unstack(id, in: area(of: workspace.display), gap: gap) else {
			return .failure("the window is not stacked")
		}

		arrange()
		tracker.focus(id)
		return .success()
	}

	private func workspace(_ args: [String]) -> Response {
		guard let current = focusedWorkspace else { return .failure("no workspace here") }
		let argument = args.count > 1 ? args[1] : nil

		switch (args.first, argument) {
		case let ("focus", target?):
			guard let workspace = resolve(target, from: current) else { return .failure("no workspace \(target)") }
			show(workspace)
			if let id = windowToFocus(in: workspace) { tracker.focus(id) }
			return .success()
		case ("balance", _):
			current.tree.balance()
		case let ("rotate", degrees?) where [90, 180, 270].contains(Int(degrees) ?? 0):
			current.tree.rotate(Int(degrees)!)
		case ("mirror", "horizontal"):
			current.tree.mirror(.columns)
		case ("mirror", "vertical"):
			current.tree.mirror(.rows)
		default:
			return .failure(
				"usage: kumiko workspace focus <name>|<n>|next|prev|recent|balance|rotate 90|180|270|mirror horizontal|vertical"
			)
		}

		arrange()
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
