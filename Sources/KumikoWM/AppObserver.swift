import AppKit
import ApplicationServices

/// Notifications every tracked window is subscribed to.
private let windowNotifications = [
	kAXUIElementDestroyedNotification,
	kAXWindowMiniaturizedNotification,
	kAXWindowDeminiaturizedNotification,
	kAXTitleChangedNotification,
	kAXWindowMovedNotification,
	kAXWindowResizedNotification,
]

/// Listens to one running app through Accessibility and passes what it hears to the tracker.
@MainActor
final class AppObserver {
	let app: NSRunningApplication
	let element: AXUIElement
	/// The windows of this app that are being watched, by WindowServer id.
	private(set) var windows: [CGWindowID: AXUIElement] = [:]

	private weak var tracker: WindowTracker?
	private var observer: AXObserver?
	private var attempts = 0

	var pid: pid_t { app.processIdentifier }

	init(app: NSRunningApplication, tracker: WindowTracker) {
		self.app = app
		self.tracker = tracker
		element = AXUIElementCreateApplication(app.processIdentifier)

		// A hung app would otherwise stall every AX call, and with it all of kumiko, for the system
		// default of six seconds.
		AXUIElementSetMessagingTimeout(element, 1)
	}

	/// Subscribes to the app. An app that has only just launched often answers "cannot complete"
	/// until its AX side is up, so that case is retried for a few seconds before giving up.
	func start() {
		var created: AXObserver?
		let refcon = Unmanaged.passUnretained(self).toOpaque()

		guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else { return }

		let result = AXObserverAddNotification(observer, element, kAXWindowCreatedNotification as CFString, refcon)

		switch result {
		case .success, .notificationAlreadyRegistered:
			break
		case .cannotComplete where attempts < 20:
			attempts += 1
			DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
				MainActor.assumeIsolated { self?.retry() }
			}
			return
		default:
			// Not an AX-capable app (or one that never came up): nothing kumiko can arrange.
			return
		}

		AXObserverAddNotification(observer, element, kAXFocusedWindowChangedNotification as CFString, refcon)
		// A click on Finder's desktop moves focus without changing Finder's focused window.
		AXObserverAddNotification(observer, element, kAXFocusedUIElementChangedNotification as CFString, refcon)
		CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
		self.observer = observer

		rescan()
	}

	/// Picks up windows kumiko has not seen yet. AX announces a new window but not one that arrives
	/// from another native Space (when that Space is removed, say), so the list is read again now
	/// and then; windows already watched are skipped.
	func rescan() {
		guard observer != nil else { return }

		for window in AX.elements(element, kAXWindowsAttribute) {
			tracker?.windowAppeared(window, in: self)
		}
	}

	func stop() {
		if let observer {
			CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
		}

		observer = nil
		windows = [:]
	}

	/// Starts watching a window. Returns false when the window has no id (it is already gone) or
	/// is watched already.
	func watch(_ window: AXUIElement, id: CGWindowID) -> Bool {
		guard let observer, windows[id] == nil else { return false }

		let refcon = Unmanaged.passUnretained(self).toOpaque()
		for notification in windowNotifications {
			AXObserverAddNotification(observer, window, notification as CFString, refcon)
		}

		windows[id] = window
		return true
	}

	func forget(_ id: CGWindowID) {
		windows[id] = nil
	}

	/// A destroyed element can no longer report its id, so it is found by identity among the
	/// windows this app already knows.
	func id(of window: AXUIElement) -> CGWindowID? {
		AX.windowID(window) ?? windows.first { CFEqual($0.value, window) }?.key
	}

	fileprivate func handle(_ notification: String, _ element: AXUIElement) {
		tracker?.notification(notification, element: element, in: self)
	}

	private func retry() {
		guard observer == nil, !app.isTerminated else { return }
		start()
	}
}

/// The C callback AX calls on the main run loop; `refcon` is the AppObserver that subscribed.
/// The observer is held by the tracker for as long as its run loop source is installed, so the
/// unretained pointer is valid whenever this runs.
private func axCallback(
	_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
	guard let refcon else { return }
	let app = Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue()
	let name = notification as String
	// AX delivers on the main run loop, the same thread the observer lives on; the element only
	// looks like it crosses an isolation boundary because AXUIElement is not marked Sendable.
	nonisolated(unsafe) let element = element

	MainActor.assumeIsolated {
		app.handle(name, element)
	}
}
