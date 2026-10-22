import AppKit
import CoreImage

/// How light the desktop picture is under the bar, to pick text that reads on it: the menu bar
/// does the same with what is under it.
@MainActor
enum Wallpaper {
	private struct Key: Hashable {
		let url: URL
		let modified: Date?
		let strip: CGRect
	}

	private static var cache: [Key: Bool] = [:]
	private static let context = CIContext()

	/// Whether the picture under `strip` (in the screen's own coordinates, origin bottom left) is
	/// dark enough for white text; nil when the picture cannot be read.
	static func isDark(on screen: NSScreen, under strip: CGRect) -> Bool? {
		guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }

		let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
		let key = Key(url: url, modified: modified, strip: strip)
		if let cached = cache[key] { return cached }

		guard let image = CIImage(contentsOf: url) else { return nil }

		// The picture fills the screen: scaled to cover it and centred, the overflow cut off.
		let size = screen.frame.size
		let scale = max(size.width / image.extent.width, size.height / image.extent.height)
		let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
		let origin = CGPoint(
			x: scaled.extent.minX + (scaled.extent.width - size.width) / 2,
			y: scaled.extent.minY + (scaled.extent.height - size.height) / 2
		)
		let area = strip.offsetBy(dx: origin.x, dy: origin.y)

		let average = scaled.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: area)])
		var pixel = [UInt8](repeating: 0, count: 4)
		context.render(
			average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
			colorSpace: CGColorSpaceCreateDeviceRGB()
		)

		let luminance = (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
		// White text reads on mid tones too, with the shadow under it; black only on light ones.
		let dark = luminance < 0.6

		cache[key] = dark
		return dark
	}
}
