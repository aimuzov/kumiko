import AppKit

/// How light the desktop is under a bar, read from the pixels of the desktop window itself, so
/// it is right for any wallpaper: a picture, a colour, a live one. Only the desktop window is
/// captured, never the apps above it.
///
/// CGWindowListCreateImage is marked unavailable in the macOS 15 SDK but still answers, so it is
/// looked up at run time; when it does not, the caller falls back to the menu bar's look.
@MainActor
enum Desktop {
	private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

	private static let createImage: CreateImage? = {
		let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
		return dlsym(handle, "CGWindowListCreateImage").map { unsafeBitCast($0, to: CreateImage.self) }
	}()

	/// kCGWindowListOptionIncludingWindow: just the one window named.
	private static let includingWindow: UInt32 = 1 << 3

	/// Relative luminance 0...1 of the desktop under `rect` (top-left screen coordinates).
	static func brightness(under rect: CGRect) -> Double? {
		guard let createImage, let window = desktopWindow(),
		      let image = createImage(rect, includingWindow, window, 0)?.takeRetainedValue()
		else { return nil }

		// Drawing the strip into a single pixel averages it.
		guard let context = CGContext(
			data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
			space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		), let data = context.data else { return nil }

		context.interpolationQuality = .medium
		context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))

		let pixel = data.assumingMemoryBound(to: UInt8.self)
		return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
	}

	/// The Dock's desktop picture window: the lowest layer on screen.
	private static func desktopWindow() -> UInt32? {
		guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
			return nil
		}

		return list
			.filter { ($0[kCGWindowOwnerName as String] as? String) == "Dock" }
			.min { ($0[kCGWindowLayer as String] as? Int ?? 0) < ($1[kCGWindowLayer as String] as? Int ?? 0) }
			.flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
	}
}
