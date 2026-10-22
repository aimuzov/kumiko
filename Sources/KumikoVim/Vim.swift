import AppKit
import ApplicationServices
import KumikoCore

/// Vim modes in any text field, replacing SketchyVim.
///
/// Typing goes to the app as usual (insert mode) until escape is pressed in a text field. Then
/// the field's text and cursor are loaded into Vim's core, every key goes through Vim, and the
/// text, cursor and selection Vim ends up with are written back to the field through
/// Accessibility. A Vim command that enters insert mode hands typing back to the app.
@MainActor
public final class Vim {
	private let bus: EventBus
	private var config: Config.Vim
	private var engine: Engine?

	/// The text field Vim is attached to; another field starts over in insert mode.
	private var field: AXUIElement?
	private var mode = Engine.Mode.insert
	/// What kumiko last wrote to the field, to tell the user's own edits and clicks from it.
	private var written: (text: String, range: CFRange)?
	/// Keys whose press Vim took, so the release does not reach the app on its own either.
	private var swallowed: Set<UInt16> = []
	private var shown: String?

	private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]

	public init(bus: EventBus, config: Config.Vim) {
		self.bus = bus
		self.config = config
	}

	public func start() {
		bus.subscribe { [weak self] event in
			// Focus moved: whatever field Vim held is not the one the user is in any more.
			if case .windowFocused = event { self?.detach() }
		}
	}

	public func apply(_ config: Config.Vim) {
		let commandsChanged = config.commands != self.config.commands
		self.config = config

		if !config.enabled { detach() }
		if commandsChanged { engine = nil }
	}

	/// Called for every key event the hotkeys left alone. Returns whether Vim took it.
	public func handle(_ event: CGEvent, isDown: Bool) -> Bool {
		guard config.enabled else { return false }

		let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
		guard isDown else { return swallowed.remove(keyCode) != nil }

		// Command shortcuts are the app's, in any mode.
		if event.flags.contains(.maskCommand) { return false }

		if let app = NSWorkspace.shared.frontmostApplication?.localizedName, config.blacklist.contains(app) {
			detach()
			return false
		}

		guard let element = Self.focusedTextField() else {
			detach()
			return false
		}

		if let field, CFEqual(field, element) {} else {
			field = element
			mode = .insert
			written = nil
		}

		guard let input = Keys.translate(
			keyCode: keyCode, characters: Self.characters(of: event), control: event.flags.contains(.maskControl)
		) else {
			return false
		}

		if mode == .insert {
			guard input == .key("<Esc>") else {
				show(.insert)
				return false
			}
			enterNormalMode(in: element)
		} else if mode == .normal, input == .key("<Esc>") {
			// A second escape is the app's: it cancels a rename in Finder, closes a search field.
			// Vim lets go of the field, which may be gone after that anyway.
			detach()
			return false
		} else {
			let engine = engine(for: element)
			catchUp(engine, with: element)
			engine.input(input)
			writeBack(engine, to: element)
			mode = engine.mode
		}

		show(mode)
		swallowed.insert(keyCode)
		return true
	}

	// MARK: - Modes

	private func enterNormalMode(in element: AXUIElement) {
		let engine = engine(for: element)
		load(engine, from: element)

		// Escape out of Vim's own insert mode moves the cursor back one, as Vim does.
		if engine.mode == .insert { engine.input(.key("<Esc>")) }

		writeBack(engine, to: element)
		mode = engine.mode
	}

	private func detach() {
		field = nil
		mode = .insert
		written = nil
		show(nil)
	}

	private func engine(for element: AXUIElement) -> Engine {
		if let engine { return engine }
		let engine = Engine(commands: config.commands)
		self.engine = engine
		return engine
	}

	// MARK: - Field and buffer

	/// Loads the field when it changed since kumiko last wrote it: the user typed in insert mode,
	/// pasted, or clicked somewhere else in it.
	private func catchUp(_ engine: Engine, with element: AXUIElement) {
		guard let value = Self.value(of: element), let range = Self.selectedRange(of: element) else { return }
		if let written, written.text == value, written.range.location == range.location, written.range.length == range.length {
			return
		}
		load(engine, from: element)
	}

	private func load(_ engine: Engine, from element: AXUIElement) {
		let text = Text(Self.value(of: element) ?? "")
		let location = Self.selectedRange(of: element)?.location ?? 0
		let position = text.position(offset: location)
		engine.load(text, cursor: (position.line, position.byteColumn))
	}

	/// Puts Vim's text in the field if it changed, then its cursor or visual selection.
	private func writeBack(_ engine: Engine, to element: AXUIElement) {
		let text = engine.text
		let string = text.string

		if Self.value(of: element) != string {
			AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, string as CFString)
		}

		var range = Self.range(for: engine, in: text)
		if let value = AXValueCreate(.cfRange, &range) {
			AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
		}

		written = (string, range)
	}

	/// The visual selection as a range of the field, ends included as Vim includes them. Outside
	/// visual mode the cursor: in normal mode the character it is on, like Vim's block cursor
	/// (a caret would sit before that character, one place left of where Vim has it), and an
	/// empty range in insert mode.
	private static func range(for engine: Engine, in text: Text) -> CFRange {
		guard let selection = engine.selection else {
			let cursor = engine.cursor
			let location = text.offset(line: cursor.line, byteColumn: cursor.column)
			let block = engine.mode == .insert ? 0 : text.characterLength(line: cursor.line, byteColumn: cursor.column)
			return CFRange(location: location, length: block)
		}

		var start = selection.start
		var end = selection.end
		if (end.line, end.column) < (start.line, start.column) { swap(&start, &end) }

		let lower: Int
		let upper: Int

		if selection.type == Int(UInt8(ascii: "V")) {
			lower = text.offset(line: start.line, byteColumn: 0)
			upper = text.offset(line: end.line, byteColumn: 0) + text.length(ofLine: end.line)
		} else {
			lower = text.offset(line: start.line, byteColumn: start.column)
			upper = text.offset(line: end.line, byteColumn: end.column) + text.characterLength(line: end.line, byteColumn: end.column)
		}

		return CFRange(location: lower, length: max(0, upper - lower))
	}

	private func show(_ mode: Engine.Mode?) {
		let name = mode?.rawValue
		let commandLine = mode == .commandLine ? engine?.commandLine : nil
		guard name != shown || commandLine != nil else { return }

		shown = name
		bus.publish(.vimModeChanged(mode: name, commandLine: commandLine))
	}

	// MARK: - Accessibility

	/// The focused element, if it is a text field or area whose text can be written.
	private static func focusedTextField() -> AXUIElement? {
		let system = AXUIElementCreateSystemWide()
		// A hung app must not hold every key up for the system default of six seconds.
		AXUIElementSetMessagingTimeout(system, 0.2)

		var focused: CFTypeRef?
		guard
			AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
			let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
		else { return nil }

		let element = focused as! AXUIElement
		var role: CFTypeRef?
		AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
		guard let role = role as? String, textRoles.contains(role) else { return nil }

		var settable: DarwinBoolean = false
		AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
		return settable.boolValue && value(of: element) != nil ? element : nil
	}

	private static func value(of element: AXUIElement) -> String? {
		var value: CFTypeRef?
		AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
		return value as? String
	}

	private static func selectedRange(of element: AXUIElement) -> CFRange? {
		var value: CFTypeRef?
		guard
			AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
			let value, CFGetTypeID(value) == AXValueGetTypeID()
		else { return nil }

		var range = CFRange()
		return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
	}

	/// What the press types in the current input source, shift included.
	private static func characters(of event: CGEvent) -> String {
		var length = 0
		var units = [UniChar](repeating: 0, count: 8)
		event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &units)
		return String(utf16CodeUnits: units, count: length)
	}
}
