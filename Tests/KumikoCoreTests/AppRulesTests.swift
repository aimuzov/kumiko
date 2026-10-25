import Foundation
import KumikoCore
import Testing

struct AppRulesTests {
	/// The rules of the kumiko.toml the page was made for, shortened.
	private let text = """
		[wm]
		manage = false

		[[wm.rule]]
		app = "ChatGPT|Google Chrome|Arc|Code"
		manage = true

		[[wm.rule]]
		app = "Calendar"
		manage = true

		[[wm.rule]]
		app = "Calendar"
		title = "General|Accounts|Alerts|Advanced"
		manage = false

		[[wm.rule]]
		app = "Finder"
		manage = true

		[[wm.rule]]
		app = "Finder"
		title = "Copy|Connect|Finder Settings"
		manage = false

		[[workspace]]
		name = "Code"
		"""

	private func read(_ text: String) throws -> AppRules {
		AppRules(try Config.parse(text).wm.rules)
	}

	private func apply(_ changes: [any ConfigChange]) throws -> String {
		try ConfigWriter.apply(changes, to: text)
	}

	// MARK: - Reading

	@Test func readsEachAppOfTheRules() throws {
		let rules = try read(text)

		#expect(rules.apps.map(\.name) == ["Arc", "Calendar", "ChatGPT", "Code", "Finder", "Google Chrome"])
		#expect(rules.apps.filter { !$0.tiles }.isEmpty)
		#expect(rules.app(named: "Calendar")?.exceptions == ["General", "Accounts", "Alerts", "Advanced"])
		#expect(rules.app(named: "Finder")?.exceptions == ["Copy", "Connect", "Finder Settings"])
		#expect(rules.app(named: "Code")?.exceptions == [])
		#expect(rules.patterns.isEmpty)
	}

	@Test func readsEscapedNamesAsTheyAre() {
		let rules = AppRules([WindowRule(app: #"Info \(Beta\)"#, manage: true)])
		#expect(rules.apps.map(\.name) == ["Info (Beta)"])
	}

	@Test func leavesRealPatternsAsPatterns() {
		let rules = AppRules([
			WindowRule(app: "Code.*", manage: true),
			WindowRule(title: "Picture in Picture", manage: false),
			WindowRule(manage: true),
		])
		#expect(rules.apps.isEmpty)
		#expect(rules.patterns.map(\.index) == [0, 1, 2])
	}

	@Test func takesTheLastRuleThatNamesAnApp() {
		let rules = AppRules([
			WindowRule(app: "Mail", manage: false),
			WindowRule(app: "Mail|Notes", manage: true),
		])
		#expect(rules.app(named: "Mail")?.tiles == true)
		// The first rule decides nothing any more: it stays in sight as a pattern.
		#expect(rules.patterns.map(\.index) == [0])
	}

	@Test func readsATitleRuleBeforeItsAppAsAPattern() {
		let rules = AppRules([
			WindowRule(app: "Mail", title: "General", manage: false),
			WindowRule(app: "Mail", manage: true),
		])
		#expect(rules.app(named: "Mail")?.exceptions == [])
		#expect(rules.patterns.map(\.index) == [0])
	}

	// MARK: - Editing

	@Test func turnsAnAppWithARuleOfItsOwn() throws {
		let changed = try apply(try read(text).setTiles("Calendar", false))
		let rules = try read(changed)

		#expect(rules.app(named: "Calendar")?.tiles == false)
		// Its exceptions keep meaning "the other way".
		#expect(try Config.parse(changed).wm.rules[2].manage == true)
		#expect(rules.app(named: "Calendar")?.exceptions == ["General", "Accounts", "Alerts", "Advanced"])
	}

	@Test func takesAnAppOutOfASharedRule() throws {
		let changed = try apply(try read(text).setTiles("Arc", false))

		#expect(changed.contains("""
			[[wm.rule]]
			app = "ChatGPT|Google Chrome|Code"
			manage = true

			[[wm.rule]]
			app = "Arc"
			manage = false

			[[wm.rule]]
			app = "Calendar"
			"""))
		#expect(try read(changed).app(named: "Arc")?.tiles == false)
		#expect(try read(changed).app(named: "Code")?.tiles == true)
	}

	@Test func addsAnApp() throws {
		let changed = try apply(try read(text).addApp("Steam", tiles: false))
		#expect(try read(changed).app(named: "Steam")?.tiles == false)
		#expect(changed.contains("app = \"Steam\"\nmanage = false\n\n[[workspace]]"))
	}

	@Test func removesAnAppWithItsExceptions() throws {
		let changed = try apply(try read(text).removeApp("Finder"))
		let config = try Config.parse(changed)

		#expect(!config.wm.rules.contains { $0.app == "Finder" })
		#expect(try read(changed).apps.map(\.name) == ["Arc", "Calendar", "ChatGPT", "Code", "Google Chrome"])
	}

	@Test func removesAnAppFromASharedRule() throws {
		let changed = try apply(try read(text).removeApp("Code"))
		#expect(changed.contains(#"app = "ChatGPT|Google Chrome|Arc""#))
		#expect(try read(changed).app(named: "Code") == nil)
	}

	@Test func changesTheTitlesOfAnException() throws {
		let changed = try apply(try read(text).setExceptions("Finder", ["Copy", "Get Info"]))
		#expect(changed.contains(#"title = "Copy|Get Info""#))
		#expect(try read(changed).app(named: "Finder")?.exceptions == ["Copy", "Get Info"])
	}

	@Test func addsTheFirstExceptionRightAfterTheApp() throws {
		let changed = try apply(try read(text).setExceptions("Code", ["Settings (Code)"]))
		let rules = try Config.parse(changed).wm.rules

		#expect(rules[1] == WindowRule(app: "Code", title: #"Settings \(Code\)"#, manage: false))
		#expect(try read(changed).app(named: "Code")?.exceptions == ["Settings (Code)"])
	}

	@Test func removesTheExceptionWithItsLastTitle() throws {
		let changed = try apply(try read(text).setExceptions("Calendar", []))
		#expect(!changed.contains("General|Accounts"))
		#expect(try read(changed).app(named: "Calendar")?.exceptions == [])
	}

	@Test func editsAndRemovesAPattern() throws {
		let text = "[[wm.rule]]\napp = \"Code.*\"\nmanage = true\n"
		let rules = AppRules(try Config.parse(text).wm.rules)

		let edited = try ConfigWriter.apply(rules.setPattern(0, app: nil, title: "PiP", tiles: false), to: text)
		#expect(try Config.parse(edited).wm.rules == [WindowRule(title: "PiP", manage: false)])

		let removed = try ConfigWriter.apply(rules.removePattern(0), to: text)
		#expect(try Config.parse(removed).wm.rules.isEmpty)
	}
}
