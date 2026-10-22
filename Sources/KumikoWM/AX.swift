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
