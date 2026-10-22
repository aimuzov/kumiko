import Testing

@testable import KumikoVim

struct KeysTests {
	@Test func printableKeysAreText() {
		#expect(Keys.translate(keyCode: 0x0D, characters: "w", control: false) == .text("w"))
		#expect(Keys.translate(keyCode: 0x0D, characters: "W", control: false) == .text("W"))
	}

	/// Another alphabet stays text: Vim's langmap is what turns it into commands.
	@Test func otherAlphabetsStayText() {
		#expect(Keys.translate(keyCode: 0x0D, characters: "ц", control: false) == .text("ц"))
	}

	@Test func namedKeysUseVimNotation() {
		#expect(Keys.translate(keyCode: 0x35, characters: "\u{1B}", control: false) == .key("<Esc>"))
		#expect(Keys.translate(keyCode: 0x24, characters: "\r", control: false) == .key("<CR>"))
		#expect(Keys.translate(keyCode: 0x33, characters: "\u{7F}", control: false) == .key("<BS>"))
	}

	@Test func controlChordsGoByKeyPosition() {
		#expect(Keys.translate(keyCode: 0x0F, characters: "\u{12}", control: true) == .key("<C-r>"))
		#expect(Keys.translate(keyCode: 0x21, characters: nil, control: true) == .key("<Esc>"))
		#expect(Keys.translate(keyCode: 0x12, characters: "1", control: true) == nil)
	}

	@Test func controlCharactersAreDropped() {
		#expect(Keys.translate(keyCode: 0x63, characters: "\u{10}", control: false) == nil)
	}
}

struct TextTests {
	@Test func offsetsCountLineBreaks() {
		let text = Text("one\ntwo")
		#expect(text.offset(line: 2, byteColumn: 1) == 5)
		#expect(text.position(offset: 5) == (2, 1))
	}

	/// Cyrillic letters are two UTF-8 bytes and one UTF-16 unit each.
	@Test func multibyteColumnsMapToUTF16() {
		let text = Text("привет мир")
		#expect(text.offset(line: 1, byteColumn: 12) == 6)
		#expect(text.position(offset: 7) == (1, 13))
		#expect(text.characterLength(line: 1, byteColumn: 0) == 1)
	}

	@Test func positionsAreClampedIntoTheText() {
		let text = Text("ab\ncd")
		#expect(text.position(offset: 99) == (2, 2))
		#expect(text.offset(line: 9, byteColumn: 9) == 5)
	}

	@Test func emptyTextHasOneEmptyLine() {
		#expect(Text("").lines == [""])
		#expect(Text(lines: []).lines == [""])
	}
}

@MainActor
struct EngineTests {
	private func engine(_ text: String, cursor: (Int, Int) = (1, 0)) -> Engine {
		let engine = Engine(commands: [])
		engine.load(Text(text), cursor: cursor)
		engine.input(.key("<Esc>"))
		engine.load(Text(text), cursor: cursor)
		return engine
	}

	private func type(_ keys: String, into engine: Engine) {
		for character in keys { engine.input(.text(String(character))) }
	}

	@Test func motionsMoveTheCursor() {
		let engine = engine("hello world")
		type("w", into: engine)
		#expect(engine.cursor == (1, 6))
		type("$", into: engine)
		#expect(engine.cursor == (1, 10))
	}

	@Test func operatorsEditTheText() {
		let engine = engine("hello brave world")
		type("wdw", into: engine)
		#expect(engine.text.string == "hello world")
		type("u", into: engine)
		#expect(engine.text.string == "hello brave world")
	}

	@Test func linesComeAndGo() {
		let engine = engine("one\ntwo\nthree")
		type("jdd", into: engine)
		#expect(engine.text.lines == ["one", "three"])
		type("p", into: engine)
		#expect(engine.text.lines == ["one", "three", "two"])
	}

	@Test func insertCommandsReportInsertMode() {
		let engine = engine("abc")
		type("A", into: engine)
		#expect(engine.mode == .insert)
		engine.input(.key("<Esc>"))
		#expect(engine.mode == .normal)
	}

	@Test func visualModeReportsItsRange() {
		let engine = engine("hello world")
		type("vw", into: engine)
		#expect(engine.mode == .visual)
		let selection = engine.selection
		#expect(selection.map { $0.start == (1, 0) && $0.end == (1, 6) } == true)
	}

	@Test func commandLineShowsWhatIsTyped() {
		let engine = engine("abc")
		type(":set", into: engine)
		#expect(engine.mode == .commandLine)
		#expect(engine.commandLine == "set")
		engine.input(.key("<Esc>"))
	}

	@Test func langmapTurnsCyrillicIntoCommands() {
		let engine = Engine(commands: ["set langmap=цв;wd"])
		engine.load(Text("hello brave world"), cursor: (1, 0))
		engine.input(.key("<Esc>"))
		type("цвц", into: engine)
		#expect(engine.text.string == "hello world")
	}
}
