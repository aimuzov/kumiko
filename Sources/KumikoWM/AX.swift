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
		var reader = Reader(element)
		return reader.value(attribute)
	}

	static func string(_ element: AXUIElement, _ attribute: String) -> String? {
		value(element, attribute) as? String
	}

	static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
		(value(element, attribute) as? NSNumber)?.boolValue
	}

	/// Nil when the element does not answer, which is not the same as no.
	static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool? {
		var reader = Reader(element)
		return reader.isSettable(attribute)
	}

	/// Reads of one element that remember whether its app ran out of time on any of them. A timeout
	/// is not an answer: the window is still there and its app is busy, unlike a window that closed,
	/// which answers at once that it is gone.
	struct Reader {
		let element: AXUIElement
		private(set) var timedOut = false

		init(_ element: AXUIElement) {
			self.element = element
		}

		mutating func value(_ attribute: String) -> CFTypeRef? {
			var value: CFTypeRef?
			let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
			note(error)
			return error == .success ? value : nil
		}

		mutating func string(_ attribute: String) -> String? {
			value(attribute) as? String
		}

		mutating func bool(_ attribute: String) -> Bool? {
			(value(attribute) as? NSNumber)?.boolValue
		}

		mutating func isSettable(_ attribute: String) -> Bool? {
			var settable = DarwinBoolean(false)
			let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
			note(error)
			return error == .success ? settable.boolValue : nil
		}

		mutating func frame() -> CGRect? {
			var position = CGPoint.zero
			var size = CGSize.zero

			guard
				let positionValue = axValue(kAXPositionAttribute),
				let sizeValue = axValue(kAXSizeAttribute),
				AXValueGetValue(positionValue, .cgPoint, &position),
				AXValueGetValue(sizeValue, .cgSize, &size)
			else { return nil }

			return CGRect(origin: position, size: size)
		}

		private mutating func axValue(_ attribute: String) -> AXValue? {
			guard let value = value(attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
			return (value as! AXValue)
		}

		private mutating func note(_ error: AXError) {
			if error == .cannotComplete { timedOut = true }
		}
	}

	static func setSize(_ element: AXUIElement, _ requested: CGSize) -> Bool {
		var size = requested
		guard let value = AXValueCreate(.cgSize, &size) else { return false }
		return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
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

	/// Brings the app forward and makes this window its key window, on top. Goes through SkyLight
	/// first, the way yabai and AeroSpace do: plain AX activation is ignored by some apps (Chromium
	/// browsers among them), and NSRunningApplication.activate may be refused to a background app on
	/// macOS 14+. Without SkyLight it falls back to AX.
	static func focus(_ window: AXUIElement, app: AXUIElement, pid: pid_t, id: CGWindowID) {
		if !SkyLight.focus(pid: pid, window: id) {
			AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
		}

		AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
		AXUIElementPerformAction(window, kAXRaiseAction as CFString)
	}

	/// Brings a process forward with one of its windows key, without an AX element for it: for
	/// Finder's desktop window, which AX does not list as a window.
	@discardableResult
	static func focus(pid: pid_t, window: CGWindowID) -> Bool {
		SkyLight.focus(pid: pid, window: window)
	}

	/// Brings a process forward without making any of its windows key: for kumiko itself, which
	/// has none, on an empty workspace.
	@discardableResult
	static func bringForward(pid: pid_t) -> Bool {
		SkyLight.bringForward(pid: pid)
	}

	/// Presses the window's close button, the way a click would, so the app can still ask about
	/// unsaved changes.
	@discardableResult
	static func close(_ window: AXUIElement) -> Bool {
		guard let button = element(window, kAXCloseButtonAttribute) else { return false }
		return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
	}

	static func frame(_ element: AXUIElement) -> CGRect? {
		var reader = Reader(element)
		return reader.frame()
	}
}

/// Private SkyLight calls for activating a window, looked up at run time. None of them needs SIP;
/// they are what the Dock and Mission Control use to bring a window forward.
private enum SkyLight {
	private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
	private typealias SetFrontProcess = @convention(c) (UnsafePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
	private typealias PostEventRecord = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> CGError

	private static let functions: (GetProcessForPID, SetFrontProcess, PostEventRecord)? = {
		guard
			let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
			let services = dlopen(
				"/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY
			),
			let getProcess = dlsym(services, "GetProcessForPID"),
			let setFront = dlsym(skyLight, "_SLPSSetFrontProcessWithOptions"),
			let post = dlsym(skyLight, "SLPSPostEventRecordTo")
		else { return nil }

		return (
			unsafeBitCast(getProcess, to: GetProcessForPID.self),
			unsafeBitCast(setFront, to: SetFrontProcess.self),
			unsafeBitCast(post, to: PostEventRecord.self)
		)
	}()

	/// Brings the process forward with this window and posts the two event records that make the
	/// window key. The record layout is WindowServer's and is the one yabai has used for years.
	static func focus(pid: pid_t, window: CGWindowID) -> Bool {
		guard let (getProcess, setFront, post) = functions else { return false }

		var psn = ProcessSerialNumber()
		guard getProcess(pid, &psn) == noErr else { return false }

		// 0x200 marks the activation as user generated, so the app treats it like a click.
		guard setFront(&psn, window, 0x200) == .success else { return false }

		var bytes = [UInt8](repeating: 0, count: 0xf8)
		bytes[0x04] = 0xf8
		bytes[0x3a] = 0x10
		withUnsafeBytes(of: window) { id in
			for (offset, byte) in id.enumerated() { bytes[0x3c + offset] = byte }
		}
		for offset in 0x20..<0x30 { bytes[offset] = 0xff }

		bytes[0x08] = 0x01
		_ = post(&psn, bytes)
		bytes[0x08] = 0x02
		_ = post(&psn, bytes)

		return true
	}

	static func bringForward(pid: pid_t) -> Bool {
		guard let (getProcess, setFront, _) = functions else { return false }

		var psn = ProcessSerialNumber()
		guard getProcess(pid, &psn) == noErr else { return false }

		// 0x400 activates the process with no window at all.
		return setFront(&psn, 0, 0x400) == .success
	}
}
