import AppKit

/// A screen in the coordinates AX uses: origin at the top left of the main screen, y going down.
/// AppKit counts from the bottom left instead, so every NSScreen rectangle is flipped once here.
struct Display: Equatable {
	let id: CGDirectDisplayID
	let name: String
	let isBuiltin: Bool
	let frame: CGRect
	/// The frame without the menu bar and the Dock.
	let visibleFrame: CGRect

	/// The first one is the main display, the one with the menu bar.
	@MainActor
	static func all() -> [Display] {
		guard let main = NSScreen.screens.first else { return [] }
		let height = main.frame.height

		func flip(_ rect: CGRect) -> CGRect {
			CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
		}

		return NSScreen.screens.compactMap { screen in
			guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
			else { return nil }

			let id = number.uint32Value
			return Display(
				id: id,
				name: screen.localizedName,
				isBuiltin: CGDisplayIsBuiltin(id) != 0,
				frame: flip(screen.frame),
				visibleFrame: flip(screen.visibleFrame)
			)
		}
	}

	/// Resolves a workspace's `display` setting: `main`, `builtin`, `external`, or part of a screen
	/// name. Whatever is not attached right now falls back to the main display, so a laptop without
	/// its monitor still shows every workspace.
	///
	/// `main` is the screen System Settings calls main, the one with the menu bar, and `external`
	/// the other one: a monitor first, the laptop's own screen when the menu bar was moved onto
	/// the monitor. Read as "not built in", it would be the same screen as `main` then.
	static func matching(_ spec: String, in displays: [Display]) -> Display? {
		let main = displays.first
		let others = displays.dropFirst()

		switch spec.lowercased() {
		case "main": return main
		case "builtin": return displays.first(where: \.isBuiltin) ?? main
		case "external": return others.first { !$0.isBuiltin } ?? others.first ?? main
		case let name: return displays.first { $0.name.lowercased().contains(name) } ?? main
		}
	}

	/// The display a window belongs to: the one holding its centre, or the nearest one for a window
	/// that sits off every screen.
	static func containing(_ rect: CGRect, in displays: [Display]) -> Display? {
		let center = CGPoint(x: rect.midX, y: rect.midY)

		if let display = displays.first(where: { $0.frame.contains(center) }) {
			return display
		}

		return displays.min { distance($0.frame, center) < distance($1.frame, center) }
	}

	/// Where a window of `size` goes while its workspace is not shown: into a bottom corner of its
	/// display with one point still on screen, because macOS pulls a window that is entirely off
	/// screen back. The corner is the one not touching another display, so the window does not
	/// appear there instead.
	static func hiddenOrigin(for size: CGSize, on display: CGRect, others: [CGRect]) -> CGPoint {
		let right = CGPoint(x: display.maxX - 1, y: display.maxY - 1)
		let left = CGPoint(x: display.minX - size.width + 1, y: display.maxY - 1)

		for origin in [right, left] {
			let rect = CGRect(origin: origin, size: size)
			if !others.contains(where: { $0.intersects(rect) }) { return origin }
		}

		return right
	}

	private static func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
		hypot(rect.midX - point.x, rect.midY - point.y)
	}
}

/// How many native macOS Spaces exist, from the private SkyLight framework, read only. kumiko
/// expects one per display; more means windows can sit on a Space kumiko cannot show. Looked up
/// at run time, so a macOS without these symbols just skips the check.
enum NativeSpaces {
	private typealias MainConnection = @convention(c) () -> Int32
	private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

	/// Spaces per display, in the order SkyLight lists displays; nil when the lookup is unavailable.
	static func countPerDisplay() -> [Int]? {
		guard
			let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
			let mainSymbol = dlsym(handle, "SLSMainConnectionID"),
			let copySymbol = dlsym(handle, "SLSCopyManagedDisplaySpaces")
		else { return nil }

		let connection = unsafeBitCast(mainSymbol, to: MainConnection.self)()
		let copy = unsafeBitCast(copySymbol, to: CopyManagedDisplaySpaces.self)

		guard let displays = copy(connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }

		// Spaces of type 4 are native full-screen apps; they come and go with the app and are not
		// the user's to remove.
		return displays.map { display in
			let spaces = display["Spaces"] as? [[String: Any]] ?? []
			return spaces.filter { ($0["type"] as? Int) != 4 }.count
		}
	}
}
