/// Everything the modules tell each other. Later stages add workspace and mode events here.
public enum Event: Sendable, Equatable {
	case configReloaded(Config)

	case windowCreated(WindowInfo)
	/// Title, frame, minimized, hidden or managed state changed.
	case windowChanged(WindowInfo)
	case windowDestroyed(id: UInt32)
	/// `nil` when no window has focus: the desktop, or an app with no windows.
	case windowFocused(id: UInt32?)
}

/// In-process publish/subscribe between modules. It lives on the main actor because every
/// consumer — AX callbacks, AppKit views, the event tap — runs there anyway, so delivery is a plain
/// synchronous call with no queues in between.
@MainActor
public final class EventBus {
	public typealias Handler = @MainActor (Event) -> Void

	public struct Subscription: Hashable, Sendable {
		fileprivate let id: Int
	}

	private var handlers: [Int: Handler] = [:]
	private var nextID = 0

	public init() {}

	@discardableResult
	public func subscribe(_ handler: @escaping Handler) -> Subscription {
		defer { nextID += 1 }
		handlers[nextID] = handler
		return Subscription(id: nextID)
	}

	public func unsubscribe(_ subscription: Subscription) {
		handlers[subscription.id] = nil
	}

	/// Handlers run in subscription order, so a module that subscribed first sees an event first.
	public func publish(_ event: Event) {
		for id in handlers.keys.sorted() {
			handlers[id]?(event)
		}
	}
}
