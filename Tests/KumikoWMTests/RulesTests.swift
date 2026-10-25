import KumikoCore
import Testing

@testable import KumikoWM

struct RulesTests {
	private let standard = "AXStandardWindow"

	@Test func rulesTurnedOffLeaveTheDefault() {
		var config = Config.WM(manage: false, rules: [WindowRule(app: "Ghostty", manage: true)])
		#expect(Rules(config).isManaged(app: "Ghostty", title: "", subrole: standard))

		config.useRules = false
		#expect(!Rules(config).isManaged(app: "Ghostty", title: "", subrole: standard))
	}

	@Test func defaultPolicyAppliesWithoutRules() {
		#expect(Rules(.init(manage: true)).isManaged(app: "Ghostty", title: "", subrole: standard))
		#expect(!Rules(.init(manage: false)).isManaged(app: "Ghostty", title: "", subrole: standard))
	}

	@Test func nonStandardWindowsAreNeverManaged() {
		let rules = Rules(.init(manage: true, rules: [WindowRule(app: "Finder", manage: true)]))
		#expect(!rules.isManaged(app: "Finder", title: "Copy", subrole: "AXDialog"))
		#expect(!rules.isManaged(app: "Finder", title: "", subrole: nil))
	}

	@Test func appPatternMatchesTheWholeName() {
		let rules = Rules(.init(manage: false, rules: [WindowRule(app: "Code", manage: true)]))
		#expect(rules.isManaged(app: "Code", title: "", subrole: standard))
		#expect(!rules.isManaged(app: "Xcode", title: "", subrole: standard))
	}

	@Test func titlePatternMatchesAnywhere() {
		let rules = Rules(.init(manage: true, rules: [WindowRule(title: "Settings", manage: false)]))
		#expect(!rules.isManaged(app: "Dia", title: "Dia Settings", subrole: standard))
		#expect(rules.isManaged(app: "Dia", title: "GitHub", subrole: standard))
	}

	/// The dotfiles setup: nothing by default, a whitelist of apps, and settings windows of a
	/// whitelisted app left floating.
	@Test func lastMatchingRuleWins() {
		let rules = Rules(.init(manage: false, rules: [
			WindowRule(app: "Finder", manage: true),
			WindowRule(app: "Finder", title: "Copy|Info|Finder Settings", manage: false),
		]))

		#expect(rules.isManaged(app: "Finder", title: "Downloads", subrole: standard))
		#expect(!rules.isManaged(app: "Finder", title: "Finder Settings", subrole: standard))
		#expect(!rules.isManaged(app: "Mail", title: "Inbox", subrole: standard))
	}

	@Test func ruleNeedsEveryPatternToMatch() {
		let rules = Rules(.init(manage: true, rules: [WindowRule(app: "Mail", title: "Accounts", manage: false)]))
		#expect(rules.isManaged(app: "Mail", title: "Inbox", subrole: standard))
		#expect(rules.isManaged(app: "Things", title: "Accounts", subrole: standard))
		#expect(!rules.isManaged(app: "Mail", title: "Accounts", subrole: standard))
	}

	/// Dia's settings window has no title, only an identifier.
	@Test func idPatternMatchesTheWindowsIdentifier() {
		var config = Config.WM(manage: false, rules: [
			WindowRule(app: "Dia", manage: true),
			WindowRule(app: "Dia", id: "preferencesWindow", manage: false),
		])
		config.floatSettings = false
		let rules = Rules(config)

		#expect(!rules.isManaged(app: "Dia", title: "", identifier: "preferencesWindow", subrole: standard))
		#expect(rules.isManaged(app: "Dia", title: "GitHub", identifier: "bigBrowserWindow_1", subrole: standard))
		#expect(rules.isManaged(app: "Dia", title: "GitHub", subrole: standard))
	}

	@Test func settingsWindowsFloatWhateverTheRulesSay() {
		let rules = Rules(.init(manage: true, rules: [WindowRule(app: "Dia", manage: true)]))
		#expect(!rules.isManaged(app: "Dia", title: "", identifier: "preferencesWindow", subrole: standard))
		#expect(!rules.isManaged(app: "Ghostty", title: "", identifier: "com_apple_SwiftUI_Settings_window", subrole: standard))
		#expect(!rules.isManaged(app: "Mail", title: "Settings", subrole: standard))
		// A title that only has the word in it names a document as often as a settings window.
		#expect(rules.isManaged(app: "Code", title: "Project Settings", subrole: standard))
	}

	/// Calendar's settings window is titled by its tab and has no identifier.
	@Test func windowsOfOneSizeFloatUnlessTurnedOff() {
		var config = Config.WM(manage: true)
		config.floatSettings = false
		#expect(!Rules(config).isManaged(app: "Calendar", title: "Alerts", isResizable: false, subrole: standard))

		config.floatFixedSize = false
		#expect(Rules(config).isManaged(app: "Calendar", title: "Alerts", isResizable: false, subrole: standard))
	}

	@Test func settingsWindowsFollowTheRulesWhenTurnedOff() {
		var config = Config.WM(manage: true)
		config.floatSettings = false
		#expect(Rules(config).isManaged(app: "Dia", title: "", identifier: "preferencesWindow", subrole: standard))
	}

	/// kumiko's settings float by default, tiled only when a rule asks for it.
	@Test func aFallbackOfItsOwnGivesWayToRules() {
		#expect(!Rules(.init(manage: true)).isManaged(app: "Kumiko", title: "kumiko Settings", subrole: standard, fallback: false))

		let tiled = Rules(.init(manage: true, rules: [WindowRule(app: "Kumiko", manage: true)]))
		#expect(tiled.isManaged(app: "Kumiko", title: "kumiko Settings", subrole: standard, fallback: false))
	}

	@Test func alternativesInAppPatternAreAllAnchored() {
		let rules = Rules(.init(manage: false, rules: [WindowRule(app: "Arc|Dia", manage: true)]))
		#expect(rules.isManaged(app: "Dia", title: "", subrole: standard))
		#expect(!rules.isManaged(app: "Diary", title: "", subrole: standard))
		#expect(!rules.isManaged(app: "Search", title: "", subrole: standard))
	}
}
