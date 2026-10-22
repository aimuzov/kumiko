import ApplicationServices

// Thin typed reads over AXUIElementCopyAttributeValue. Every read can fail for ordinary reasons —
// the window just closed, the app is busy — so they return nil instead of throwing.

/// The one private call kumiko relies on: there is no public way to get from an AX window to its
/// WindowServer id, and without the id a window cannot be told apart from its twin with the same
/// title. Every tiling WM on macOS uses it; it has been stable since 10.6.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
	static func windowID(_ element: AXUIElement) -> CGWindowID? {
		var id: CGWindowID = 0
		guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
		return id
	}

	static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
		return value
	}

	static func string(_ element: AXUIElement, _ attribute: String) -> String? {
		value(element, attribute) as? String
	}

	static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
		(value(element, attribute) as? NSNumber)?.boolValue
	}

	static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
		guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
		return (value as! AXUIElement)
	}

	static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
		guard let array = value(element, attribute) as? [CFTypeRef] else { return [] }
		return array.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
	}

	/// Moves and resizes a window. Size goes first and again last: an app refuses a position that
	/// would push its current size off the screen, and refuses a size that does not fit where the
	/// window currently is, so moving a big window to a small spot needs both rounds.
	static func setFrame(_ element: AXUIElement, _ frame: CGRect) {
		var size = frame.size
		var origin = frame.origin

		guard
			let sizeValue = AXValueCreate(.cgSize, &size),
			let originValue = AXValueCreate(.cgPoint, &origin)
		else { return }

		AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
		AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, originValue)
		AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
	}

	/// Brings the app forward and puts this window on top of it. Activation goes through AX rather
	/// than NSRunningApplication.activate, which macOS 14+ may refuse to a background app.
	static func focus(_ window: AXUIElement, app: AXUIElement) {
		AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
		AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
		AXUIElementPerformAction(window, kAXRaiseAction as CFString)
	}

	/// Presses the window's close button, the way a click would, so the app can still ask about
	/// unsaved changes.
	@discardableResult
	static func close(_ window: AXUIElement) -> Bool {
		guard let button = element(window, kAXCloseButtonAttribute) else { return false }
		return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
	}

	static func frame(_ element: AXUIElement) -> CGRect? {
		var position = CGPoint.zero
		var size = CGSize.zero

		guard
			let positionValue = axValue(element, kAXPositionAttribute),
			let sizeValue = axValue(element, kAXSizeAttribute),
			AXValueGetValue(positionValue, .cgPoint, &position),
			AXValueGetValue(sizeValue, .cgSize, &size)
		else { return nil }

		return CGRect(origin: position, size: size)
	}

	private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
		guard let value = value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
		return (value as! AXValue)
	}
}
