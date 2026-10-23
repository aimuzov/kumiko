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

	@Test func alternativesInAppPatternAreAllAnchored() {
		let rules = Rules(.init(manage: false, rules: [WindowRule(app: "Arc|Dia", manage: true)]))
		#expect(rules.isManaged(app: "Dia", title: "", subrole: standard))
		#expect(!rules.isManaged(app: "Diary", title: "", subrole: standard))
		#expect(!rules.isManaged(app: "Search", title: "", subrole: standard))
	}
}
