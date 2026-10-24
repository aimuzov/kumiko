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
	/// Windows the user toggled with `window float`, overriding the rules: true puts the window in
	/// the layout even if the rules leave it out, false keeps it out even if they manage it.
	private var tiledByUser: [UInt32: Bool] = [:]
	/// Windows moved out of sight, with the frame to give back to the ones that are not tiled.
	private var hidden: [UInt32: CGRect] = [:]
	/// Apps kumiko hid because all their windows are on hidden workspaces. Apps the user hid are
	/// not here and are left hidden.
	private var hiddenApps: Set<pid_t> = []
	private var hidingScheduled = false
	private var pendingUnhides: Set<pid_t> = []
	/// Hiding an app hands focus to some other app, maybe one with a window on another hidden
	/// workspace; that focus is not the user's and must not switch workspaces.
	private var autoSwitchPausedUntil = Date.distantPast
	/// The frame each tiled window was last given, to notice when the user moves one by hand.
	private var expected: [UInt32: CGRect] = [:]
	private var placement = Placement([])
	private var previousWorkspace: String?
	/// New name to old, from the settings window before it writes a rename. The hint waits for the
	/// pass that brings the new name, and that pass keeps the workspace's layout and windows.
	private var renames: [String: String] = [:]
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
	private let desktopClicks = DesktopClicks()

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

	private let stateFile: URL?

	/// `stateFile` keeps the shown workspaces across restarts; nil remembers nothing.
	public init(bus: EventBus, tracker: WindowTracker, config: Config, stateFile: URL? = nil) {
		self.bus = bus
		self.tracker = tracker
		self.config = config
		self.stateFile = stateFile
		placement = Placement(config.wm.useWorkspaces ? config.workspaces : [])
	}

	public func start() {
		bus.subscribe { [weak self] event in self?.handle(event) }
		observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)

		let center = NSWorkspace.shared.notificationCenter
		let token = center.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main) {
			[weak self] notification in
			guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
			MainActor.assumeIsolated { self?.rehide(app) }
		}
		observers.append((center, token))

		desktopClicks.shouldSwallow = { [weak self] point in
			guard let self, !self.isFinderShown, WindowTracker.isEmptyDesktop(at: point) else { return false }
			// The tap waits for this answer; focus can move a moment later.
			DispatchQueue.main.async { MainActor.assumeIsolated { self.tracker.focusNothing() } }
			return true
		}
		desktopClicks.start()
	}

	/// Whether Finder has a window on a shown workspace. Without one, hidden by kumiko or with no
	/// windows at all, a click on the desktop has nothing of Finder's to bring forward.
	private var isFinderShown: Bool {
		guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: WindowTracker.finder).first
		else { return false }
		return appVisibility()[finder.processIdentifier] == true
	}

	public func apply(_ config: Config) {
		self.config = config
		placement = Placement(config.wm.useWorkspaces ? config.workspaces : [])

		if !config.wm.enabled {
			showEverything()
			workspaces = []
			visible = [:]
			assignment = [:]
			tiledByUser = [:]
			expected = [:]
		}

		scheduleSync()
	}

	/// Puts every hidden window back on screen. Runs on quit and when the module is turned off, so
	/// windows are never left stranded in a corner.
	public func showEverything() {
		saveVisible()

		for pid in hiddenApps {
			NSRunningApplication(processIdentifier: pid)?.unhide()
		}
		hiddenApps = []

		for (id, frame) in hidden {
			tracker.setFrame(id, frame)
		}
		hidden = [:]

		// Frames are applied in the background; quitting must not cut them off.
		tracker.flushFrames()
	}

	// MARK: - Query

	public func state(of id: UInt32) -> (isFloating: Bool, stackIndex: Int, zoom: String?, workspace: String?) {
		let workspace = assignment[id]
		guard let tree = workspace?.tree, tree.contains(id) else { return (true, 0, nil, workspace?.name) }
		return (false, tree.stackIndex(of: id), tree.zoom(of: id)?.rawValue, workspace?.name)
	}

	/// 1-based place of a window in its stack and the size of the stack; nil when not stacked.
	public func stackPosition(of id: UInt32) -> (index: Int, count: Int)? {
		guard let tree = assignment[id]?.tree, tree.stackIndex(of: id) > 0 else { return nil }
		return (tree.stackIndex(of: id), tree.stackCount(of: id))
	}

	/// `[[workspace]]` in use. Off, each display has the one workspace of its own, which has nothing
	/// to tell apart from.
	public var usesWorkspaces: Bool { config.wm.useWorkspaces }

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
			} else if !WindowServer.isAvailable {
				// Without the WindowServer's events a drag is only seen through AX, late.
				noticeUserFrameChange(info.id, info.frame)
			}
		case let .windowFrameChanged(id, frame):
			noticeUserFrameChange(id, frame)
		case let .windowDestroyed(id):
			tiledByUser[id] = nil
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
			if !isVisible(workspace), Date() > autoSwitchPausedUntil {
				show(workspace)
			}
		case .configReloaded, .workspacesChanged, .hotkeyModeChanged, .vimModeChanged:
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

		// On the first pass each display shows what it showed when kumiko last quit. Failing that,
		// the display with the focused window shows that window's workspace, so starting kumiko does
		// not hide what the user is looking at.
		if !hasShownFocusedWorkspace {
			if restoreVisible(displays) {
				hasShownFocusedWorkspace = true
				// Whatever app macOS puts in front while kumiko starts is not the user's choice: focus
				// goes to the restored workspace, and stray focus does not switch for a moment.
				autoSwitchPausedUntil = Date().addingTimeInterval(1)
				if let workspace = Display.all().first.flatMap({ visible[$0.id] }), let id = windowToFocus(in: workspace) {
					DispatchQueue.main.async { [weak self] in
						MainActor.assumeIsolated { self?.tracker.focus(id) }
					}
				}
			} else if let id = tracker.focusedWindowID, let workspace = assignment[id] {
				visible[workspace.display.id] = workspace
				hasShownFocusedWorkspace = true
			}
		}

		for workspace in workspaces {
			guard let previous = workspace.changedLayout else { continue }
			workspace.changedLayout = nil
			relayout(workspace, from: previous)
		}

		for workspace in workspaces {
			for id in workspace.tree.allWindows where !isTiled(id, in: workspace) {
				workspace.tree.remove(id)
			}
		}

		for workspace in workspaces {
			workspace.seen = workspace.seen.filter { assignment[$0] === workspace }
		}

		for info in tracker.sortedWindows {
			guard let workspace = assignment[info.id], isTiled(info.id, in: workspace), !workspace.tree.contains(info.id)
			else { continue }
			add(info, to: workspace)
		}

		// A reload that changed a workspace's apps or sizes applies them to the windows it has
		// already, once they are all in: the order and sizes change in front of the user.
		for workspace in workspaces {
			guard let previous = workspace.changedRules else { continue }
			workspace.changedRules = nil
			applyLayoutRules(workspace, reorder: true, previous: previous)
		}

		arrange(displays)
	}

	/// Rebuilds the workspace list from the config, keeping the layout of every workspace whose
	/// name stays or whose rename the settings window told about, and makes sure each display shows one.
	private func updateWorkspaces(_ displays: [Display]) {
		// With workspaces off nothing comes from the config, and the loop below gives every display
		// the one workspace it then has.
		var configs = !config.wm.useWorkspaces ? []
			: config.workspaces.isEmpty ? Config.Workspace.builtIn
			: config.workspaces

		// A display no workspace is meant for still gets one, or it could show nothing at all.
		for (index, display) in displays.enumerated() {
			let claimed = configs.contains { Display.matching($0.display, in: displays) == display }
			if !claimed {
				configs.append(Config.Workspace(name: "display-\(index + 1)", display: display.name))
			}
		}

		let old = Dictionary(workspaces.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
		let names = Set(configs.map(\.name))

		workspaces = configs.map { config in
			let display = Display.matching(config.display, in: displays) ?? displays[0]
			// The old name must be gone from the file too: one still there was not renamed after all.
			let renamed = renames[config.name].flatMap { names.contains($0) ? nil : old[$0] }

			if let workspace = old[config.name] ?? renamed {
				if renamed != nil, previousWorkspace == workspace.name { previousWorkspace = config.name }
				let previous = workspace.config
				if previous.apps != config.apps || previous.last != config.last || previous.size != config.size
					|| previous.layout != config.layout
				{
					workspace.changedRules = workspace.changedRules ?? previous
				}
				if previous.layout != config.layout {
					workspace.changedLayout = workspace.changedLayout ?? previous.layout
				}
				workspace.config = config
				workspace.display = display
				return workspace
			}

			return Workspace(config: config, display: display)
		}

		// Windows of a workspace that is gone are placed again, like new ones.
		let kept = Set(workspaces.map(\.name))
		for (id, workspace) in assignment where !kept.contains(workspace.name) {
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

		// A hint is used up once the file has the new name; until then, passes that come before the
		// reload leave it for the one that brings it.
		let arrived = renames.keys.filter(names.contains)
		if !arrived.isEmpty {
			arrived.forEach { renames[$0] = nil }
			if hasShownFocusedWorkspace { saveVisible() }
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
		// A floating workspace tiles nothing, not even a window toggled into the layout by hand.
		guard workspace.config.layout != .float, let info = tracker.windows[id], assignment[id] === workspace
		else { return false }
		// A toggle can bring in a window the rules skip, but never a dialog or a panel.
		let wanted = tiledByUser[id].map { $0 && info.subrole == "AXStandardWindow" } ?? info.isManaged
		return wanted && !info.isMinimized && !isHiddenByUser(info) && !info.isFullscreen
	}

	/// Hidden by cmd-h, not by kumiko: a window of an app kumiko hid keeps its place in the layout.
	private func isHiddenByUser(_ info: WindowInfo) -> Bool {
		info.isHidden && !hiddenApps.contains(info.pid)
	}

	/// Puts a window into its workspace's layout, then applies the workspace's layout rules.
	private func add(_ info: WindowInfo, to workspace: Workspace) {
		let tree = workspace.tree
		let near = [tracker.focusedWindowID, workspace.lastFocused].compactMap(\.self).first { tree.contains($0) }
		tree.insert(info.id, near: near, in: area(of: workspace.display), gap: gap)

		let rules = workspace.config

		// The stack layout has one leaf, and every newcomer goes in front in it.
		if rules.layout == .stack, let other = tree.visibleWindows.first(where: { $0 != info.id }) {
			tree.stack(info.id, onto: other)
		} else if rules.stack.contains(info.app),
		   let other = tree.allWindows.first(where: { $0 != info.id && rules.stack.contains(tracker.windows[$0]?.app ?? "") })
		{
			tree.stack(info.id, onto: other)
		}

		// Only a window new to the workspace reorders it. One coming back, unminimized, shown
		// again or tiled again, leaves the layout as the user made it.
		applyLayoutRules(workspace, reorder: workspace.seen.insert(info.id).inserted)
	}

	/// Makes the tree over for a layout a reload switched to. Into a stack the windows go as
	/// one, the focused one in front. Out of one they are taken out, and the pass puts them back
	/// one by one with the `stack` rule, then in the apps' order with their sizes. Into and out
	/// of float needs nothing here: `isTiled` takes the windows out, or lets them back in.
	private func relayout(_ workspace: Workspace, from previous: Config.Workspace.Layout) {
		let tree = workspace.tree
		switch workspace.config.layout {
		case .stack:
			let active = [tracker.focusedWindowID, workspace.lastFocused].compactMap(\.self).first { tree.contains($0) }
			tree.collapse(active: active)
		case .bsp where previous == .stack:
			tree.allWindows.forEach(tree.remove)
		case .bsp, .float:
			break
		}
	}

	/// The workspace's apps put its windows in their order, and their sizes set: whole leaves
	/// move, so a stack stays one. Sizes go to every window, not only a newcomer's: the window
	/// that has a size may have joined first, when it had no split to take a part of.
	/// `previous` is the config before a reload changed it: an app whose size is gone splits
	/// evenly again.
	private func applyLayoutRules(_ workspace: Workspace, reorder: Bool, previous: Config.Workspace? = nil) {
		let tree = workspace.tree
		let rules = workspace.config

		if reorder {
			tree.permuteLeaves(rules.layoutOrder(of: tree.leaves.map { $0.windows.map(app) }))
		}

		for id in tree.visibleWindows {
			let app = app(of: id)
			if let size = rules.size[app] {
				tree.setSize(id, size)
			} else if previous?.size[app] != nil {
				tree.setSize(id, 0.5)
			}
		}
	}

	private func app(of id: UInt32) -> String { tracker.windows[id]?.app ?? "" }

	// MARK: - Arranging

	/// Lays out every visible workspace and moves the windows of the others out of sight.
	///
	/// Showing comes first and hiding waits for it: macOS unhides an app a few frames after being
	/// asked, and hiding the old windows straight away would leave the desktop bare for that long.
	private func arrange(_ displays: [Display]? = nil) {
		let displays = displays ?? Display.all()
		let unhidden = unhideApps()

		for workspace in workspaces where isVisible(workspace) {
			layout(workspace)
		}

		scheduleHiding(displays, after: unhidden)
	}

	/// For every app with windows: whether one of them is on a shown workspace. Minimized and
	/// full-screen windows do not count either way, and an app with only those is left alone.
	private func appVisibility() -> [pid_t: Bool] {
		var result: [pid_t: Bool] = [:]

		for info in tracker.windows.values where !info.isMinimized && !info.isFullscreen {
			let shown = assignment[info.id].map(isVisible) ?? true
			result[info.pid] = (result[info.pid] ?? false) || shown
		}

		return result
	}

	/// Unhides the apps kumiko hid that now have a window on a shown workspace; returns them.
	private func unhideApps() -> Set<pid_t> {
		let visibility = appVisibility()
		var unhidden = Set<pid_t>()

		for pid in hiddenApps where visibility[pid] != false || !config.wm.hideApps {
			hiddenApps.remove(pid)
			NSRunningApplication(processIdentifier: pid)?.unhide()
			unhidden.insert(pid)
		}

		return unhidden
	}

	/// Hides what is no longer shown once the apps that were unhidden are back on screen, checking
	/// every frame for at most a fifth of a second. By then focus has also moved to the workspace now
	/// shown, so hiding the frontmost app does not let macOS pick the next app on its own.
	private func scheduleHiding(_ displays: [Display], after unhidden: Set<pid_t>) {
		pendingUnhides.formUnion(unhidden)
		guard !hidingScheduled else { return }
		hidingScheduled = true

		func step(_ attempt: Int) {
			let waiting = pendingUnhides.contains { NSRunningApplication(processIdentifier: $0)?.isHidden == true }

			guard !waiting || attempt >= 12 else {
				DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) {
					MainActor.assumeIsolated { step(attempt + 1) }
				}
				return
			}

			hidingScheduled = false
			pendingUnhides = []

			// Whole apps first, which is instant; then the windows of apps that cannot be hidden,
			// because another of their windows is on screen, go to the corner.
			hideApps()

			// Hiding the app that was in front lets macOS pick the next one, which on an empty
			// workspace is loginwindow and a blank menu bar.
			if let focused = focusedWorkspace, windowToFocus(in: focused) == nil {
				tracker.focusNothing()
			}

			for workspace in workspaces where !isVisible(workspace) {
				hide(workspace, displays: displays)
			}
		}

		DispatchQueue.main.async {
			MainActor.assumeIsolated { step(0) }
		}
	}

	private func hideApps() {
		guard config.wm.hideApps else { return }

		for (pid, shown) in appVisibility() where !shown && !hiddenApps.contains(pid) {
			guard let app = NSRunningApplication(processIdentifier: pid), !app.isHidden else { continue }

			hiddenApps.insert(pid)
			autoSwitchPausedUntil = Date().addingTimeInterval(0.5)
			app.hide()
		}
	}

	/// An app kumiko hid came back on its own, with no window on a shown workspace: a click on the
	/// desktop does that to Finder, and macOS pulls its windows from the corner onto the screen.
	/// It goes back into hiding, and kumiko keeps focus on the empty workspace.
	private func rehide(_ app: NSRunningApplication) {
		// unhideApps forgets the apps it unhides first, so one still listed came back by itself.
		guard hiddenApps.contains(app.processIdentifier), appVisibility()[app.processIdentifier] == false else { return }

		autoSwitchPausedUntil = Date().addingTimeInterval(0.5)
		app.hide()

		if let focused = focusedWorkspace, windowToFocus(in: focused) == nil {
			tracker.focusNothing()
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
			guard let info = tracker.windows[id], !info.isMinimized, !isHiddenByUser(info), !info.isFullscreen else {
				continue
			}

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

	/// The display minus the menu bar and Dock, kumiko's own bar and the padding.
	private func area(of display: Display) -> CGRect {
		let padding = config.wm.padding
		let bar = config.bar.enabled ? config.bar.height : 0
		let top = Double(padding.top)
		let bottom = Double(padding.bottom) + bar

		return CGRect(
			x: display.visibleFrame.minX + Double(padding.left),
			y: display.visibleFrame.minY + top,
			width: display.visibleFrame.width - Double(padding.left + padding.right),
			height: display.visibleFrame.height - top - bottom
		)
	}

	// MARK: - Remembering

	/// Display name to workspace name; names, because display ids can change between runs.
	private func saveVisible() {
		guard let stateFile else { return }

		let displays = Display.all()
		var shown: [String: String] = [:]
		for display in displays {
			if let workspace = visible[display.id] { shown[display.name] = workspace.name }
		}

		try? JSONEncoder().encode(shown).write(to: stateFile, options: .atomic)
	}

	private func restoreVisible(_ displays: [Display]) -> Bool {
		guard
			let stateFile, let data = try? Data(contentsOf: stateFile),
			let shown = try? JSONDecoder().decode([String: String].self, from: data)
		else { return false }

		var restored = false

		for display in displays {
			guard
				let name = shown[display.name],
				let workspace = workspaces.first(where: { $0.name == name && $0.display == display })
			else { continue }

			visible[display.id] = workspace
			restored = true
		}

		return restored
	}

	// MARK: - Switching

	/// Shows a workspace on its display, hiding the one that was there.
	private func show(_ workspace: Workspace) {
		let display = workspace.display
		guard visible[display.id] !== workspace else { return }

		previousWorkspace = visible[display.id]?.name
		visible[display.id] = workspace
		// What macOS brings forward while the old workspace goes away (the next app when one is
		// hidden) is not the user's choice and must not switch back.
		autoSwitchPausedUntil = Date().addingTimeInterval(0.6)
		arrange()
		saveVisible()
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

	/// Says a workspace is about to be renamed in the file. The settings window tells it before the
	/// file is checked, so a hint for a name that never arrives is simply never used. A rename typed
	/// by hand is not told, and stays what it always was: one workspace gone and another one new.
	public func rename(_ old: String, to new: String) {
		// A to B and then B to C before a reload is one rename, C from A.
		let origin = renames.removeValue(forKey: old) ?? old
		renames = renames.filter { $0.value != origin }
		renames[new] = origin
	}

	/// Brings forward the window of an app on a workspace, showing the workspace first when it is
	/// hidden: a click on the app's icon in the bar. Of several windows the app has there, the one
	/// used last wins.
	@discardableResult
	public func focus(app pid: pid_t, on name: String) -> Bool {
		guard config.wm.enabled, let workspace = workspaces.first(where: { $0.name == name }) else { return false }

		let candidates = windows(of: workspace).filter { tracker.windows[$0]?.pid == pid }
		let id = history.last(where: candidates.contains)
			?? workspace.tree.visibleWindows.first(where: candidates.contains)
			?? candidates.first { tracker.windows[$0]?.isMinimized == false }
			?? candidates.first
		guard let id else { return false }

		show(workspace)
		tracker.focus(id)
		return true
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
	private func noticeUserFrameChange(_ id: UInt32, _ frame: CGRect) {
		guard
			NSEvent.pressedMouseButtons & 1 != 0,
			let expected = expected[id], !frame.isClose(to: expected),
			let workspace = assignment[id], workspace.tree.contains(id), isVisible(workspace)
		else { return }

		dragged.insert(id)

		// A resize reflows the layout while the edge is still being pulled, the way yabai does:
		// the splits follow the window and the neighbours move with them. The window under the
		// mouse is left to the user. A plain drag waits for the drop, which decides where it goes.
		if abs(frame.width - expected.width) > 2 || abs(frame.height - expected.height) > 2 {
			moveSplits(of: id, from: expected, to: frame, in: workspace)

			for (other, target) in workspace.tree.frames(in: area(of: workspace.display), gap: gap) {
				self.expected[other] = target
				guard other != id else { continue }
				if let current = tracker.windows[other]?.frame, current.isClose(to: target) { continue }
				tracker.setFrame(other, target)
			}
		}

		scheduleDragCheck()
	}

	/// Moves the splits along every edge of the window that moved between two frames.
	private func moveSplits(of id: UInt32, from old: CGRect, to frame: CGRect, in workspace: Workspace) {
		let edges: [(Direction, Double)] = [
			(.west, frame.minX - old.minX), (.east, frame.maxX - old.maxX),
			(.north, frame.minY - old.minY), (.south, frame.maxY - old.maxY),
		]

		for (edge, delta) in edges where abs(delta) > 2 {
			workspace.tree.resize(id, edge: edge, by: delta, in: area(of: workspace.display), gap: gap)
		}
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
		// The last move of the drag may still be waiting in the tracker's coalescing.
		tracker.refresh(id)

		guard
			let frame = tracker.windows[id]?.frame, let old = expected[id],
			let workspace = assignment[id], workspace.tree.contains(id)
		else { return }

		let resized = abs(frame.width - old.width) > 2 || abs(frame.height - old.height) > 2

		if resized {
			moveSplits(of: id, from: old, to: frame, in: workspace)
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
			if let next = windowToFocus(in: current) { tracker.focus(next) } else { tracker.focusNothing() }
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
		guard let size = value.flatMap(Double.init), size > 0, size < 1 else {
			return .failure("usage: kumiko window ratio <0…1>, the window's part of its split")
		}
		guard let tree = assignment[id]?.tree, tree.setSize(id, size) else {
			return .failure("the window is not in a split")
		}

		arrange()
		return .success()
	}

	/// Toggles floating, the way yabai does: a window in the layout floats, and any other window
	/// joins the layout, also one the rules leave out. `--grid rows:cols:x:y:width:height` places a
	/// window that starts floating on that cell of a grid laid over its display.
	private func float(_ id: UInt32, _ args: [String]) -> Response {
		guard assignment[id]?.tree.contains(id) == true else {
			guard tracker.windows[id]?.subrole == "AXStandardWindow" else {
				return .failure("only standard windows can join the layout")
			}
			tiledByUser[id] = true
			sync()
			return .success()
		}

		tiledByUser[id] = false
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
			if let id = windowToFocus(in: workspace) { tracker.focus(id) } else { tracker.focusNothing() }
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
