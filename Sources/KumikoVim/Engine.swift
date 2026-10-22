import CLibvim
import Foundation

/// Vim's own core, libvim, holding one buffer: the text field being edited. libvim keeps global
/// state and is not thread safe, so everything happens on the main actor.
@MainActor
final class Engine {
	enum Mode: String, Equatable {
		case normal = "N"
		case insert = "I"
		case visual = "V"
		case commandLine = "C"
		case pending = "_"
	}

	struct Selection: Equatable {
		var start: (line: Int, column: Int)
		var end: (line: Int, column: Int)
		/// "v", "V" or ctrl-v, as Vim names its visual types.
		var type: Int

		static func == (a: Selection, b: Selection) -> Bool {
			a.start == b.start && a.end == b.end && a.type == b.type
		}
	}

	private static var started = false

	init(commands: [String]) {
		if !Self.started {
			vimInit(0, nil)
			// A buffer needs a file behind it before lines can be set in it: an empty one, which
			// is never written, since kumiko only ever reads the buffer back.
			let path = FileManager.default.temporaryDirectory.appending(path: "kumiko-vim.txt").path(percentEncoded: false)
			FileManager.default.createFile(atPath: path, contents: Data())
			var bytes = Array(path.utf8CString).map { UInt8(bitPattern: $0) }
			_ = vimBufferOpen(&bytes, 1, 0)
			Self.started = true
		}
		// Plain Vim behaviour, whatever a vimrc would have set, then the user's own.
		run("set nocompatible")
		commands.forEach(run)
	}

	func run(_ command: String) {
		var bytes = Array(command.utf8CString).map { UInt8(bitPattern: $0) }
		vimExecute(&bytes)
	}

	var mode: Mode {
		let bits = vimGetMode()
		if bits & VIM_CMDLINE != 0 { return .commandLine }
		if bits & VIM_INSERT != 0 { return .insert }
		if bits & VIM_VISUAL != 0 { return .visual }
		if bits & VIM_OP_PENDING != 0 { return .pending }
		return .normal
	}

	var text: Text {
		let buffer = vimBufferGetCurrent()
		let count = vimBufferGetLineCount(buffer)
		let lines = (0..<count).map { index -> String in
			guard let line = vimBufferGetLine(buffer, vim_linenr(index + 1)) else { return "" }
			return String(cString: line)
		}
		return Text(lines: lines)
	}

	func load(_ text: Text, cursor: (line: Int, column: Int)) {
		let buffer = vimBufferGetCurrent()
		var storage = text.lines.map { Array($0.utf8CString).map { UInt8(bitPattern: $0) } }
		var pointers = storage.indices.map { index in
			storage[index].withUnsafeMutableBufferPointer { $0.baseAddress }
		}
		// -1 as the end replaces every line there is.
		vimBufferSetLines(buffer, 0, -1, &pointers, Int32(pointers.count))
		_ = storage
		vimCursorSetPosition(vim_pos(lnum: cursor.line, col: Int32(cursor.column), coladd: 0))
	}

	var cursor: (line: Int, column: Int) {
		let position = vimCursorGetPosition()
		return (position.lnum, Int(position.col))
	}

	var selection: Selection? {
		guard vimVisualIsActive() != 0 else { return nil }
		var start = vim_pos()
		var end = vim_pos()
		vimVisualGetRange(&start, &end)
		return Selection(
			start: (start.lnum, Int(start.col)), end: (end.lnum, Int(end.col)), type: Int(vimVisualGetType())
		)
	}

	var commandLine: String? {
		guard mode == .commandLine, let text = vimCommandLineGetText() else { return nil }
		return String(cString: text)
	}

	func input(_ input: VimInput) {
		switch input {
		case let .text(text):
			var bytes = Array(text.utf8CString).map { UInt8(bitPattern: $0) }
			vimInput(&bytes)
		case let .key(key):
			var bytes = Array(key.utf8CString).map { UInt8(bitPattern: $0) }
			vimKey(&bytes)
		}
	}
}
