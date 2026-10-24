import KumikoCore
import Testing

@Suite("Whether an app's windows are tiled")
struct AppTilingTests {
	@Test func managesByDefault() {
		#expect(Config.WM().tiles("Finder"))
		#expect(!Config.WM(manage: false).tiles("Finder"))
	}

	@Test func theLastMatchingRuleWins() {
		let wm = Config.WM(rules: [
			WindowRule(app: "Finder|Preview", manage: false),
			WindowRule(app: "Preview", manage: true),
		])
		#expect(!wm.tiles("Finder"))
		#expect(wm.tiles("Preview"))
	}

	@Test func matchesTheWholeName() {
		let wm = Config.WM(rules: [WindowRule(app: "Code", manage: false)])
		#expect(!wm.tiles("Code"))
		#expect(wm.tiles("Xcode"))
	}

	@Test func aRuleWithATitleDoesNotDecideTheApp() {
		let wm = Config.WM(rules: [WindowRule(app: "Finder", title: "Settings", manage: false)])
		#expect(wm.tiles("Finder"))
	}

	@Test func aRuleWithNoPatternsMatchesEveryApp() {
		let wm = Config.WM(rules: [WindowRule(manage: false), WindowRule(app: "Code", manage: true)])
		#expect(!wm.tiles("Finder"))
		#expect(wm.tiles("Code"))
	}

	@Test func withTheRulesOffManageAloneDecides() {
		var wm = Config.WM(manage: true, rules: [WindowRule(app: "Finder", manage: false)])
		wm.useRules = false
		#expect(wm.tiles("Finder"))
	}
}
