import CoreGraphics
import Foundation

/// The private SkyLight calls JankyBorders is built on, looked up at run time; none needs SIP.
/// They let kumiko hear about a window's moves straight from the WindowServer, on the same beat
/// the window itself moves, instead of from the app through Accessibility, which lags behind and
/// arrives in bursts while a window is dragged.
public enum WindowServer {
	/// Event numbers of SLSRegisterNotifyProc for a window's moves and resizes; the payload is the
	/// window id.
	public static let windowMoved: UInt32 = 806
	public static let windowResized: UInt32 = 807

	public typealias Handler = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void

	private typealias MainConnection = @convention(c) () -> Int32
	private typealias RegisterNotify = @convention(c) (Handler, UInt32, UnsafeMutableRawPointer?) -> CGError
	private typealias RequestNotifications = @convention(c) (Int32, UnsafePointer<UInt32>, Int32) -> CGError
	private typealias GetBounds = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> CGError
	private typealias QueryWindows = @convention(c) (Int32, CFArray, UInt32) -> Unmanaged<CFTypeRef>?
	private typealias CopyWindows = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
	private typealias IteratorAdvance = @convention(c) (CFTypeRef) -> Bool
	private typealias IteratorRadii = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?

	private struct Functions {
		let connection: Int32
		let registerNotify: RegisterNotify
		let requestNotifications: RequestNotifications
		let getBounds: GetBounds
		let query: QueryWindows
		let copyWindows: CopyWindows
		let advance: IteratorAdvance
		/// Missing on older systems; borders fall back to the radius of a standard window then.
		let radii: IteratorRadii?
	}

	private static let functions: Functions? = {
		guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
			return nil
		}

		func symbol<T>(_ name: String, _ type: T.Type) -> T? {
			dlsym(lib, name).map { unsafeBitCast($0, to: type) }
		}

		guard
			let main = symbol("SLSMainConnectionID", MainConnection.self),
			let register = symbol("SLSRegisterNotifyProc", RegisterNotify.self),
			let request = symbol("SLSRequestNotificationsForWindows", RequestNotifications.self),
			let bounds = symbol("SLSGetWindowBounds", GetBounds.self),
			let query = symbol("SLSWindowQueryWindows", QueryWindows.self),
			let copy = symbol("SLSWindowQueryResultCopyWindows", CopyWindows.self),
			let advance = symbol("SLSWindowIteratorAdvance", IteratorAdvance.self)
		else { return nil }

		return Functions(
			connection: main(),
			registerNotify: register,
			requestNotifications: request,
			getBounds: bounds,
			query: query,
			copyWindows: copy,
			advance: advance,
			radii: symbol("SLSWindowIteratorGetCornerRadii", IteratorRadii.self)
		)
	}()

	public static var isAvailable: Bool { functions != nil }

	public static func register(_ handler: Handler, for event: UInt32, context: UnsafeMutableRawPointer?) {
		_ = functions?.registerNotify(handler, event, context)
	}

	/// Asks for move and resize events of exactly these windows, replacing the previous list.
	public static func watch(_ ids: [UInt32]) {
		guard let functions else { return }
		// The list is never read past `count`; the placeholder only gives an empty list an address.
		var list = ids.isEmpty ? [0] : ids
		_ = functions.requestNotifications(functions.connection, &list, Int32(ids.count))
	}

	/// The window's frame right now, in the top-left coordinates AX uses.
	public static func bounds(of id: UInt32) -> CGRect? {
		guard let functions else { return nil }
		var rect = CGRect.zero
		guard functions.getBounds(functions.connection, id, &rect) == .success, !rect.isEmpty else { return nil }
		return rect
	}

	/// The corner radius the window is drawn with, as the WindowServer knows it.
	public static func cornerRadius(of id: UInt32) -> Double? {
		guard let functions, let radii = functions.radii else { return nil }

		let ids = [NSNumber(value: id)] as CFArray
		guard
			let query = functions.query(functions.connection, ids, 0)?.takeRetainedValue(),
			let iterator = functions.copyWindows(query)?.takeRetainedValue(),
			functions.advance(iterator),
			let values = radii(iterator)?.takeRetainedValue() as? [NSNumber],
			let radius = values.first?.doubleValue, radius > 0
		else { return nil }

		return radius
	}
}

/// Turns the WindowServer's move and resize events of the focused window into bus events, for
/// the frame and for the layout to follow a drag as it happens.
@MainActor
public final class WindowServerEvents {
	private let bus: EventBus
	private var focused: UInt32?
	/// kumiko's own window in focus, like the settings, followed along with the focused one: the
	/// tracker leaves kumiko out and never reports it as focused.
	public var own: UInt32? {
		didSet { if own != oldValue { watch() } }
	}

	public init(bus: EventBus) {
		self.bus = bus
	}

	public func start() {
		guard WindowServer.isAvailable else { return }

		bus.subscribe { [weak self] event in
			if case let .windowFocused(id) = event {
				self?.focused = id
				self?.watch()
			}
		}

		// Registered once for the life of the app; the instance lives as long.
		let context = Unmanaged.passUnretained(self).toOpaque()
		WindowServer.register(windowServerHandler, for: WindowServer.windowMoved, context: context)
		WindowServer.register(windowServerHandler, for: WindowServer.windowResized, context: context)
	}

	private func watch() {
		guard WindowServer.isAvailable else { return }
		WindowServer.watch([focused, own].compactMap(\.self))
	}

	fileprivate func changed(_ id: UInt32) {
		guard let frame = WindowServer.bounds(of: id) else { return }
		bus.publish(.windowFrameChanged(id: id, frame: frame))
	}
}

/// Called by SkyLight with the id of a window that moved or changed size.
private func windowServerHandler(
	_ event: UInt32, _ data: UnsafeMutableRawPointer?, _ length: Int, _ context: UnsafeMutableRawPointer?
) {
	guard let data, let context, length >= MemoryLayout<UInt32>.size else { return }
	let id = data.load(as: UInt32.self)
	let events = Unmanaged<WindowServerEvents>.fromOpaque(context).takeUnretainedValue()

	// SkyLight calls through the run loop source of the main connection, so on the main thread;
	// should that ever change, hop over instead of trapping.
	if Thread.isMainThread {
		MainActor.assumeIsolated { events.changed(id) }
	} else {
		DispatchQueue.main.async { MainActor.assumeIsolated { events.changed(id) } }
	}
}
