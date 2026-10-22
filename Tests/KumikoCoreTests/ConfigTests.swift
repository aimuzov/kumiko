import Foundation
import KumikoCore
import Testing

struct ConfigTests {
	@Test func emptyFileIsTheDefault() throws {
		#expect(try Config.parse("") == Config())
	}

	@Test func everyModuleIsOnByDefault() throws {
		let config = try Config.parse("")
		#expect(config.wm.enabled && config.hotkeys.enabled && config.bar.enabled && config.borders.enabled)
	}

	@Test func sectionCanTurnItsModuleOff() throws {
		let config = try Config.parse("""
			[bar]
			enabled = false
			""")

		#expect(config.bar.enabled == false)
		#expect(config.wm.enabled)
	}

	@Test func emptySectionKeepsDefaults() throws {
		#expect(try Config.parse("[borders]") == Config())
	}

	@Test func brokenTOMLIsAnError() {
		#expect(throws: ConfigError.self) { try Config.parse("[bar") }
	}

	@Test func wrongTypeIsAnError() {
		#expect(throws: ConfigError.self) { try Config.parse("[wm]\nenabled = \"yes\"") }
	}

	@Test func missingFileIsTheDefault() throws {
		let url = FileManager.default.temporaryDirectory.appending(path: "kumiko-\(UUID()).toml")
		#expect(try Config.load(from: url) == Config())
	}
}
