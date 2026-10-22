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
	private var permissionTimer: Timer?

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
	}

	public func stop() {
		permissionTimer?.invalidate()
		permissionTimer = nil

		guard isRunning else { return }
		isRunning = false

		let center = NSWorkspace.shared.notificationCenter
		workspaceObservers.forEach(center.removeObserver)
		workspaceObservers = []

		for pid in Array(apps.keys) {
			remove(pid)
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
			refresh(id)
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
		on(NSWorkspace.didActivateApplicationNotification) { [weak self] _ in self?.updateFocus() }
	}

	/// Only regular apps — the ones with a Dock icon — have windows worth arranging. Agents and
	/// kumiko itself are left alone.
	private func add(_ app: NSRunningApplication) {
		let pid = app.processIdentifier
		guard
			app.activationPolicy == .regular,
			pid != ProcessInfo.processInfo.processIdentifier,
			apps[pid] == nil
		else { return }

		let observer = AppObserver(app: app, tracker: self)
		apps[pid] = observer
		observer.start()
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
	}

	func notification(_ name: String, element: AXUIElement, in observer: AppObserver) {
		switch name {
		case kAXWindowCreatedNotification:
			windowAppeared(element, in: observer)
		case kAXFocusedWindowChangedNotification:
			// Background apps move their own focus around too; only the frontmost app's counts.
			if observer.app.isActive { updateFocus() }
		case kAXUIElementDestroyedNotification:
			if let id = observer.id(of: element) { untrack(id) }
		default:
			if let id = observer.id(of: element) { refresh(id) }
		}
	}

	/// Rereads a window and reports it if anything changed.
	private func refresh(_ id: UInt32) {
		guard
			let old = windows[id],
			let observer = apps[old.pid],
			let element = observer.windows[id]
		else { return }

		guard let info = describe(element, id: id, in: observer) else {
			untrack(id)
			return
		}

		guard info != old else { return }

		windows[id] = info
		bus.publish(.windowChanged(info))
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
	private func describe(_ element: AXUIElement, id: UInt32, in observer: AppObserver) -> WindowInfo? {
		guard let frame = AX.frame(element) else { return nil }

		let app = observer.app.localizedName ?? ""
		let title = AX.string(element, kAXTitleAttribute) ?? ""
		let subrole = AX.string(element, kAXSubroleAttribute)

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
			isManaged: rules.isManaged(app: app, title: title, subrole: subrole)
		)
	}

	// MARK: - Focus

	private func updateFocus() {
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

	private func setFocus(_ id: UInt32?) {
		guard id != focusedWindowID else { return }
		focusedWindowID = id
		bus.publish(.windowFocused(id: id))
	}
}
