import AppKit
import ScreenCaptureKit

/// Pictures of the menu bar items as they look in the menu bar, for the settings window's list.
/// They need Screen Recording; without it there are none, and the list shows the app's icon.
public enum MenuBarSnapshots {
	public static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

	/// Asks once, in System Settings' own prompt; macOS only shows it the first time.
	public static func requestAccess() {
		CGRequestScreenCaptureAccess()
	}

	/// By window, those the window server could draw. Items out of sight behind the divider are
	/// drawn too: a window is captured on its own, not the screen under it.
	public static func images(of windows: [CGWindowID]) async -> [CGWindowID: NSImage] {
		guard isAllowed, !windows.isEmpty,
		      let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
		else { return [:] }

		let wanted = Set(windows)
		var images: [CGWindowID: NSImage] = [:]
		let scale = NSScreen.main?.backingScaleFactor ?? 2

		for window in content.windows where wanted.contains(window.windowID) {
			let configuration = SCStreamConfiguration()
			configuration.width = Int(window.frame.width * scale)
			configuration.height = Int(window.frame.height * scale)
			configuration.showsCursor = false
			configuration.ignoreShadowsSingleWindow = true
			guard let image = try? await SCScreenshotManager.captureImage(
				contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration
			) else { continue }
			images[window.windowID] = NSImage(cgImage: image, size: window.frame.size)
		}
		return images
	}
}
