import AppKit

/// A screen in the coordinates AX uses: origin at the top left of the main screen, y going down.
/// AppKit counts from the bottom left instead, so every NSScreen rectangle is flipped once here.
struct Display {
	let id: CGDirectDisplayID
	let frame: CGRect
	/// The frame without the menu bar and the Dock.
	let visibleFrame: CGRect

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
			return Display(id: number.uint32Value, frame: flip(screen.frame), visibleFrame: flip(screen.visibleFrame))
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

	private static func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
		hypot(rect.midX - point.x, rect.midY - point.y)
	}
}
