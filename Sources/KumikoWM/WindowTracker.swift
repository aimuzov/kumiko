import AppKit
import ApplicationServices
import KumikoCore

/// Knows every window of every regular app, whether kumiko manages it and which one has focus,
/// and reports changes on the bus. It moves nothing: arranging windows is the layout's job.
@MainActor
public final class WindowTracker {
	public private(set) var windows: [UInt32: WindowInfo] = [:]
	public private(set) var focusedWindowID: UInt32?
	public private(set) var isRunning = false

	private let bus: EventBus
	private var config: Config.WM
	private var rules: Rules
	private var apps: [pid_t: AppObserver] = [:]
	private var workspaceObservers: [any NSObjectProtocol] = []
	private var resignObserver: (any NSObjectProtocol)?
	/// Whether kumiko keeps its Dock icon when another app comes in front: while a window of its own,
	/// like the settings, is open and the user needs a way back to it.
	public var keepsDockIcon: @MainActor () -> Bool = { false }
	private var permissionTimer: Timer?
	private var rescanTimer: Timer?
	private var pendingRefreshes: Set<UInt32> = []
	private let writer = FrameWriter()
	/// kumiko's own windows, the settings. They go through AppKit, not AX: AX asked of kumiko's
	/// own process from its main thread waits for that same thread to answer.
	private var own: [UInt32: NSWindow] = [:]
	private var ownObservers: [UInt32: [any NSObjectProtocol]] = [:]
	/// Coming forward for an empty workspace, kumiko gets back the window that was key, which may
	/// be the settings parked on a hidden workspace; that is no reason to switch to it.
	private var ownFocusIgnoredUntil = Date.distantPast

	public init(bus: EventBus, config: Config.WM) {
		self.bus = bus
		self.config = config
		rules = Rules(config)
	}

	/// Windows ordered by app and then id, so that output stays put between two queries.
	public var sortedWindows: [WindowInfo] {
		windows.values.sorted { ($0.app, $0.id) < ($1.app, $1.id) }
	}

	// MARK: - Lifecycle

	/// Starts tracking, or waits for the Accessibility permission and starts once it is granted:
	/// macOS gives no notification for that, so it is checked every couple of seconds.
	public func start() {
		guard config.enabled, !isRunning else { return }

		guard AXIsProcessTrusted() else {
			guard permissionTimer == nil else { return }

			permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
				MainActor.assumeIsolated {
					guard AXIsProcessTrusted() else { return }
					self?.permissionTimer?.invalidate()
					self?.permissionTimer = nil
					self?.start()
				}
			}
			return
		}

		isRunning = true
		observeWorkspace()

		for app in NSWorkspace.shared.runningApplications {
			add(app)
		}

		updateFocus()

		rescanTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.rescan() }
		}
	}

	/// Reads every app's window list again for windows that slipped past the AX notifications.
	public func rescan() {
		for observer in apps.values {
			observer.rescan()
			updateTabs(of: observer)
		}
	}

	public func stop() {
		permissionTimer?.invalidate()
		permissionTimer = nil
		rescanTimer?.invalidate()
		rescanTimer = nil

		guard isRunning else { return }
		isRunning = false

		let center = NSWorkspace.shared.notificationCenter
		workspaceObservers.forEach(center.removeObserver)
		workspaceObservers = []
		resignObserver.map(NotificationCenter.default.removeObserver)
		resignObserver = nil

		for pid in Array(apps.keys) {
			remove(pid)
		}
		for id in Array(own.keys) {
			untrackOwn(id)
		}

		setFocus(nil)
	}

	/// Takes a new `[wm]` section: turns tracking on or off and re-decides which windows are managed.
	public func apply(_ config: Config.WM) {
		self.config = config
		rules = Rules(config)

		guard config.enabled else {
			stop()
			return
		}

		start()

		for id in Array(windows.keys) {
			own[id] == nil ? refresh(id) : refreshOwn(id)
		}
	}

	// MARK: - Apps

	private func observeWorkspace() {
		let center = NSWorkspace.shared.notificationCenter

		func on(_ name: Notification.Name, _ action: @escaping @MainActor (NSRunningApplication) -> Void) {
			let token = center.addObserver(forName: name, object: nil, queue: .main) { notification in
				guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
				else { return }
				MainActor.assumeIsolated { action(app) }
			}
			workspaceObservers.append(token)
		}

		on(NSWorkspace.didLaunchApplicationNotification) { [weak self] in self?.add($0) }
		on(NSWorkspace.didTerminateApplicationNotification) { [weak self] in self?.remove($0.processIdentifier) }
		on(NSWorkspace.didHideApplicationNotification) { [weak self] in self?.refreshWindows(of: $0) }
		on(NSWorkspace.didUnhideApplicationNotification) { [weak self] in self?.refreshWindows(of: $0) }
		// Back to no Dock icon once another app is in front; see focusNothing.
		resignObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				guard self?.keepsDockIcon() != true else { return }
				_ = NSApp.setActivationPolicy(.accessory)
			}
		}

		on(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
			self?.apps[app.processIdentifier]?.rescan()
			self?.updateFocus()
		}

		let token = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
			[weak self] _ in
			MainActor.assumeIsolated { self?.rescan() }
		}
		workspaceObservers.append(token)
	}

	/// Only regular apps — the ones with a Dock icon — have windows worth arranging. Agents are
	/// left alone, and kumiko's own windows come through `track(own:)`.
	private func add(_ app: NSRunningApplication) {
		let pid = app.processIdentifier
		guard
			app.activationPolicy == .regular,
			!Self.isAgent(app),
			pid != ProcessInfo.processInfo.processIdentifier,
			apps[pid] == nil
		else { return }

		let observer = AppObserver(app: app, tracker: self)
		apps[pid] = observer
		observer.start()
	}

	/// Built as an agent, like Raycast: a Dock icon only while its settings are open.
	/// Its panels open over any workspace, and hiding the app with one closes them.
	private static func isAgent(_ app: NSRunningApplication) -> Bool {
		guard let url = app.bundleURL, let value = Bundle(url: url)?.object(forInfoDictionaryKey: "LSUIElement")
		else { return false }
		return (value as? Bool) ?? ((value as? String).map { $0 == "1" || $0.lowercased() == "true" } ?? false)
	}

	private func remove(_ pid: pid_t) {
		guard let observer = apps.removeValue(forKey: pid) else { return }

		for id in observer.windows.keys {
			untrack(id)
		}

		observer.stop()
	}

	private func refreshWindows(of app: NSRunningApplication) {
		guard let observer = apps[app.processIdentifier] else { return }

		for id in observer.windows.keys {
			refresh(id)
		}
	}

	// MARK: - Windows

	func windowAppeared(_ element: AXUIElement, in observer: AppObserver) {
		guard
			let id = AX.windowID(element),
			observer.watch(element, id: id),
			let info = describe(element, id: id, in: observer)
		else { return }

		windows[id] = info
		bus.publish(.windowCreated(info))
		// A new tab (cmd-T) sends the tab in front behind it.
		updateTabs(of: observer, appeared: id)
	}

	func notification(_ name: String, element: AXUIElement, in observer: AppObserver) {
		switch name {
		case kAXWindowCreatedNotification:
			windowAppeared(element, in: observer)
		case kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification:
			if name == kAXFocusedWindowChangedNotification { updateTabs(of: observer) }
			// Background apps move their own focus around too; only the frontmost app's counts.
			if observer.app.isActive { updateFocus() }
		case kAXMainWindowChangedNotification:
			updateTabs(of: observer)
		case kAXUIElementDestroyedNotification:
			if let id = observer.id(of: element) {
				updateTabs(of: observer, gone: id)
				untrack(id)
			}
		case kAXWindowMovedNotification, kAXWindowResizedNotification:
			if let id = observer.id(of: element) { scheduleRefresh(id) }
		default:
			if let id = observer.id(of: element) { refresh(id) }
		}
	}

	/// Moves and resizes come dozens a second while a window is dragged, and each reread is a
	/// round trip to an app that is busy redrawing. While a mouse button is down the reread waits
	/// for it to come up: the WindowServer's events carry the drag in the meantime. Otherwise the
	/// burst is folded into one reread after 30 ms.
	private func scheduleRefresh(_ id: UInt32) {
		guard pendingRefreshes.insert(id).inserted else { return }

		func attempt() {
			DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
				MainActor.assumeIsolated {
					guard let self, self.pendingRefreshes.contains(id) else { return }
					if NSEvent.pressedMouseButtons & 1 != 0, WindowServer.isAvailable {
						attempt()
						return
					}
					self.refresh(id)
				}
			}
		}

		attempt()
	}

	/// Rereads a window and reports it if anything changed.
	func refresh(_ id: UInt32) {
		pendingRefreshes.remove(id)
		guard
			let old = windows[id],
			let observer = apps[old.pid],
			let element = observer.windows[id]
		else { return }

		guard let info = describe(element, id: id, in: observer, previous: old) else {
			untrack(id)
			return
		}

		guard info != old else { return }

		windows[id] = info
		bus.publish(.windowChanged(info))
	}

	/// Marks the app's tabs behind another, and tells which tab took whose place. The replacement
	/// goes out first, so the layout swaps the windows before it sees the old one leave.
	private func updateTabs(of observer: AppObserver, appeared: UInt32? = nil, gone: UInt32? = nil) {
		let known = windows.values.filter { $0.pid == observer.pid }
		guard !known.isEmpty, let listed = observer.listedWindows() else { return }

		let changes = NativeTabs.changes(
			windows: Dictionary(known.map { ($0.id, $0.isBackgroundTab) }, uniquingKeysWith: { first, _ in first }),
			listed: listed.ids, showsTabs: listed.showsTabs, appeared: appeared, gone: gone
		)

		for replacement in changes.replaced {
			bus.publish(.tabReplaced(old: replacement.old, new: replacement.new))
		}

		for (id, isBehind) in changes.background.sorted(by: { $0.key < $1.key }) {
			guard var info = windows[id] else { continue }
			info.isBackgroundTab = isBehind
			windows[id] = info
			bus.publish(.windowChanged(info))
		}
	}

	private func untrack(_ id: UInt32) {
		guard let info = windows.removeValue(forKey: id) else { return }

		apps[info.pid]?.forget(id)
		bus.publish(.windowDestroyed(id: id))

		if focusedWindowID == id {
			updateFocus()
		}
	}

	/// Returns nil when the window is gone: AX answers nothing at all for a closed window.
	///
	/// While an app is hidden AX reports some of its windows as `AXDialog`; trusting that would turn
	/// them into dialogs, unmanaged and out of the layout, every time kumiko hides the app. So for
	/// a hidden app the subrole seen before it was hidden stands.
	private func describe(
		_ element: AXUIElement, id: UInt32, in observer: AppObserver, previous: WindowInfo? = nil
	) -> WindowInfo? {
		guard let frame = AX.frame(element) else { return nil }

		let app = observer.app.localizedName ?? ""
		let title = AX.string(element, kAXTitleAttribute) ?? ""
		let identifier = AX.string(element, kAXIdentifierAttribute)
		let subrole = observer.app.isHidden && previous != nil
			? previous?.subrole
			: AX.string(element, kAXSubroleAttribute)
		// The same distrust of a hidden app; and a window that does not answer is taken as resizable,
		// so a busy app does not see its windows leave the layout.
		let isResizable = observer.app.isHidden && previous != nil
			? previous?.isResizable ?? true
			: AX.isSettable(element, kAXSizeAttribute) ?? true

		return WindowInfo(
			id: id,
			pid: observer.pid,
			app: app,
			bundleID: observer.app.bundleIdentifier,
			title: title,
			subrole: subrole,
			frame: frame,
			isMinimized: AX.bool(element, kAXMinimizedAttribute) ?? false,
			isHidden: observer.app.isHidden,
			isFullscreen: AX.bool(element, "AXFullScreen") ?? false,
			isManaged: rules.isManaged(
				app: app, title: title, identifier: identifier, isResizable: isResizable, subrole: subrole
			),
			identifier: identifier,
			isResizable: isResizable,
			// A tab goes behind or comes in front only as `updateTabs` sees it.
			isBackgroundTab: previous?.isBackgroundTab ?? false
		)
	}

	// MARK: - Own windows

	/// A window of kumiko's own, shown again: it joins the layout like any other until it closes.
	public func track(own window: NSWindow) {
		guard isRunning, window.windowNumber > 0 else { return }
		let id = UInt32(window.windowNumber)

		guard own[id] == nil else {
			refreshOwn(id)
			updateFocus()
			return
		}

		own[id] = window
		let center = NotificationCenter.default
		func on(_ name: Notification.Name, _ action: @escaping @MainActor (WindowTracker) -> Void) -> any NSObjectProtocol {
			center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self.map(action) }
			}
		}
		let changes: [Notification.Name] = [
			NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didMiniaturizeNotification,
			NSWindow.didDeminiaturizeNotification, NSWindow.didEnterFullScreenNotification,
			NSWindow.didExitFullScreenNotification,
		]
		ownObservers[id] = changes.map { on($0) { $0.refreshOwn(id) } } + [
			on(NSWindow.willCloseNotification) { $0.untrackOwn(id) },
			on(NSWindow.didBecomeKeyNotification) { $0.updateFocus() },
			on(NSWindow.didResignKeyNotification) { $0.updateFocus() },
		]

		let info = describe(own: window, id: id)
		windows[id] = info
		bus.publish(.windowCreated(info))
		updateFocus()
	}

	private func refreshOwn(_ id: UInt32) {
		guard let window = own[id], let old = windows[id] else { return }
		let info = describe(own: window, id: id)
		guard info != old else { return }
		windows[id] = info
		bus.publish(.windowChanged(info))
	}

	private func untrackOwn(_ id: UInt32) {
		ownObservers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
		own[id] = nil
		untrack(id)
	}

	/// What AX would tell about the window, read from AppKit. No identifier: the settings window is
	/// told apart by its app, and must not pass for another app's settings, which float.
	private func describe(own window: NSWindow, id: UInt32) -> WindowInfo {
		let app = NSRunningApplication.current.localizedName ?? "Kumiko"
		let subrole = kAXStandardWindowSubrole as String
		let isResizable = window.styleMask.contains(.resizable)

		return WindowInfo(
			id: id,
			pid: getpid(),
			app: app,
			bundleID: Bundle.main.bundleIdentifier,
			title: window.title,
			subrole: subrole,
			frame: Self.topLeft(window.frame),
			isMinimized: window.isMiniaturized,
			isHidden: NSApp.isHidden,
			isFullscreen: window.styleMask.contains(.fullScreen),
			isManaged: rules.isManaged(
				app: app, title: window.title, isResizable: isResizable, subrole: subrole, fallback: false
			),
			isResizable: isResizable
		)
	}

	/// AppKit counts from the bottom left of the main screen, AX and the layout from its top left.
	private static func topLeft(_ frame: CGRect) -> CGRect {
		let height = NSScreen.screens.first?.frame.height ?? 0
		return CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
	}

	/// Never smaller than the window allows: its page would be cut off instead.
	private func setOwnFrame(_ window: NSWindow, _ frame: CGRect) {
		var size = frame.size
		size.width = max(size.width, window.minSize.width)
		size.height = max(size.height, window.minSize.height)
		let height = NSScreen.screens.first?.frame.height ?? 0
		window.setFrame(CGRect(x: frame.minX, y: height - frame.minY - size.height, width: size.width, height: size.height), display: true)
	}

	// MARK: - Acting on windows

	/// Moves a window without waiting for its app: each app has its own queue for these, since an
	/// app busy redrawing answers slowly and the main thread has everything else to do. Only the
	/// latest frame asked for a window is applied.
	public func setFrame(_ id: UInt32, _ frame: CGRect) {
		if let window = own[id] {
			setOwnFrame(window, frame)
			return
		}
		guard let (element, _) = elements(of: id), let pid = windows[id]?.pid else { return }
		writer.setFrame(element, id: id, pid: pid, frame: frame)
	}

	/// Waits until every frame asked for is applied; for quitting, when nothing may be left behind.
	public func flushFrames() {
		writer.flush()
	}

	public func focus(_ id: UInt32) {
		if let window = own[id] {
			bringKumikoForward()
			window.makeKeyAndOrderFront(nil)
			return
		}
		guard let (element, app) = elements(of: id), let pid = windows[id]?.pid else { return }
		AX.focus(element, app: app, pid: pid, id: id)
	}

	@discardableResult
	public func close(_ id: UInt32) -> Bool {
		if let window = own[id] {
			window.performClose(nil)
			return true
		}
		guard let (element, _) = elements(of: id) else { return false }
		return AX.close(element)
	}

	private func elements(of id: UInt32) -> (window: AXUIElement, app: AXUIElement)? {
		guard let pid = windows[id]?.pid, let observer = apps[pid], let window = observer.windows[id] else {
			return nil
		}
		return (window, observer.element)
	}

	// MARK: - Focus

	private func updateFocus() {
		if NSApp.isActive, Date() > ownFocusIgnoredUntil, let key = NSApp.keyWindow,
		   let id = own.first(where: { $0.value === key })?.key
		{
			setFocus(id)
			return
		}

		// Finder in front with its desktop focused (a click on the desktop, an empty workspace) has
		// no window in focus, whatever window it last had.
		if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.bundleIdentifier == Self.finder,
		   let observer = apps[frontmost.processIdentifier], Self.isDesktopFocused(in: observer.element)
		{
			setFocus(nil)
			return
		}

		guard
			let frontmost = NSWorkspace.shared.frontmostApplication,
			let observer = apps[frontmost.processIdentifier],
			let window = AX.element(observer.element, kAXFocusedWindowAttribute),
			let id = AX.windowID(window)
		else {
			setFocus(nil)
			return
		}

		// A window that opened before its app's observer was ready is picked up here.
		if windows[id] == nil {
			windowAppeared(window, in: observer)
		}

		setFocus(windows[id] == nil ? nil : id)
	}

	static let finder = "com.apple.finder"

	/// Finder shows the desktop as a scroll area of its own, outside any window.
	private static func isDesktopFocused(in app: AXUIElement) -> Bool {
		guard let element = AX.element(app, kAXFocusedUIElementAttribute) else { return false }
		return AX.string(element, kAXRoleAttribute) == kAXScrollAreaRole && AX.element(element, kAXWindowAttribute) == nil
	}

	/// Leaves no window in focus, for an empty workspace: kumiko itself comes forward. Its menu
	/// takes over the menu bar, and Finder, hidden along with its windows on other workspaces,
	/// stays hidden, which it would not if the desktop got focus.
	public func focusNothing() {
		// macOS gives the menu bar only to apps with a Dock icon; kumiko has one while in front.
		NSApp.setActivationPolicy(.regular)
		ownFocusIgnoredUntil = Date().addingTimeInterval(1)
		bringKumikoForward()
		setFocus(nil)
	}

	/// Makes kumiko the front app the way a click in the Dock would. `NSApp.activate()` only asks,
	/// and the app in front may say no; then kumiko is not active and comes last in cmd-tab.
	public func bringKumikoForward() {
		AX.bringForward(pid: getpid())
	}

	/// Whether a point is on the empty desktop: Finder's desktop window on top there, and no icon
	/// under it.
	/// The menu bar of the display under a point, in window server coordinates (origin top left).
	private static func menuBarStrip(at point: CGPoint) -> CGRect? {
		guard let primary = NSScreen.screens.first else { return nil }

		for screen in NSScreen.screens {
			let top = primary.frame.maxY - screen.frame.maxY
			let frame = CGRect(x: screen.frame.minX, y: top, width: screen.frame.width, height: screen.frame.height)
			guard frame.contains(point) else { continue }
			return CGRect(x: frame.minX, y: top, width: frame.width, height: screen.frame.maxY - screen.visibleFrame.maxY)
		}

		return nil
	}

	/// How far past a window's edge macOS still starts a resize, in points.
	static let resizeReach: CGFloat = 8

	static func isEmptyDesktop(at point: CGPoint) -> Bool {
		guard
			let finder = NSRunningApplication.runningApplications(withBundleIdentifier: finder).first,
			let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
		else { return false }

		// Front to back, past the windows that let clicks through, like the border overlay. Other
		// windows of kumiko's, the bar or the About panel, take the click themselves.
		// Everything below the backstop level, where kumiko's bar sits, is the desktop: Finder's
		// desktop window, the wallpaper, and a window server strip under the menu bar above them.
		let desktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
		let backstopLevel = Int(CGWindowLevelForKey(.backstopMenu))
		let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
		let clickThrough = Set(NSApp.windows.filter(\.ignoresMouseEvents).map { $0.windowNumber })
		let menuBar = menuBarStrip(at: point)
		let under = list.filter {
			guard
				($0[kCGWindowNumber as String] as? Int).map({ !clickThrough.contains($0) }) ?? true,
				let bounds = $0[kCGWindowBounds as String].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) })
			else { return false }
			// Menu bar tools like Ice lay a window over the menu bar that reaches a few points below
			// it and lets clicks through there.
			if let menuBar, !menuBar.contains(point), bounds.minY == menuBar.minY, bounds.height <= menuBar.height + 8 {
				return false
			}
			// An app window can be grabbed for a resize a few points past its edge, over the desktop
			// in the gap between windows.
			let layer = $0[kCGWindowLayer as String] as? Int ?? 0
			let reach = (0..<menuBarLevel).contains(layer) ? resizeReach : 0
			return bounds.insetBy(dx: -reach, dy: -reach).contains(point)
		}
		guard
			!under.contains(where: { ($0[kCGWindowLayer as String] as? Int ?? 0) >= backstopLevel }),
			under.contains(where: {
				($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == finder.processIdentifier
					&& $0[kCGWindowLayer as String] as? Int == desktopLevel
			})
		else { return false }

		// Asked of Finder itself: system-wide, the hit lands on kumiko's border overlay.
		var element: AXUIElement?
		let app = AXUIElementCreateApplication(finder.processIdentifier)
		guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success, let element
		else { return true }
		return [kAXGroupRole, kAXScrollAreaRole].contains(AX.string(element, kAXRoleAttribute))
	}

	private func setFocus(_ id: UInt32?) {
		guard id != focusedWindowID else { return }
		focusedWindowID = id
		bus.publish(.windowFocused(id: id))
	}
}

/// Applies window frames on a serial queue per app, keeping only the newest frame per window.
private final class FrameWriter: @unchecked Sendable {
	private let lock = NSLock()
	private var pending: [UInt32: (element: AXUIElement, frame: CGRect)] = [:]
	private var queues: [pid_t: DispatchQueue] = [:]

	func setFrame(_ element: AXUIElement, id: UInt32, pid: pid_t, frame: CGRect) {
		lock.lock()
		let isQueued = pending[id] != nil
		pending[id] = (element, frame)
		let queue = queues[pid] ?? DispatchQueue(label: "kumiko.frames.\(pid)", qos: .userInteractive)
		queues[pid] = queue
		lock.unlock()

		// One block per window in flight; a newer frame just replaces what it will apply.
		guard !isQueued else { return }

		queue.async { [self] in
			lock.lock()
			let next = pending.removeValue(forKey: id)
			lock.unlock()

			if let next { AX.setFrame(next.element, next.frame) }
		}
	}

	func flush() {
		lock.lock()
		let all = Array(queues.values)
		lock.unlock()

		for queue in all {
			queue.sync {}
		}
	}
}
