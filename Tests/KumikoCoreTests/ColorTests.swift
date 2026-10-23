import KumikoCore
import Testing

struct ColorTests {
	@Test func hashFormIsOpaqueRGB() throws {
		#expect(try Color.parse("#ff0080") == Color(red: 1, green: 0, blue: 128.0 / 255))
	}

	@Test func hashFormTakesAlphaLast() throws {
		#expect(try Color.parse("#ff000080").alpha == 128.0 / 255)
	}

	@Test func hexFormTakesAlphaFirst() throws {
		let color = try Color.parse("0x80ff0000")
		#expect(color.alpha == 128.0 / 255)
		#expect(color.red == 1)
	}

	@Test func hexReadsBackAsTheSameColour() throws {
		#expect(try Color.parse("0xff8aadf4").hex == "#8aadf4")
		#expect(try Color.parse("#8aadf480").hex == "#8aadf480")
		#expect(try Color.parse(Color(red: 0.5, green: 0.25, blue: 1, alpha: 0.5).hex).hex == "#8040ff80")
	}

	@Test func otherFormsAreErrors() {
		#expect(throws: ConfigError.self) { try Color.parse("ff0000") }
		#expect(throws: ConfigError.self) { try Color.parse("#ff00") }
		#expect(throws: ConfigError.self) { try Color.parse("0xff0000") }
	}
}
