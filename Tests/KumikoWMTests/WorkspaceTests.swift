import CoreGraphics
import KumikoCore
import Testing

@testable import KumikoWM

private let builtin = Display(
	id: 1, name: "Built-in Retina Display", isBuiltin: true,
	frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 32, width: 1512, height: 950)
)
private let external = Display(
	id: 2, name: "DELL U2723QE", isBuiltin: false,
	frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080)
)

struct PlacementTests {
	@Test func appGoesToItsWorkspace() {
		let placement = Placement([
			Config.Workspace(name: "Code", apps: ["Ghostty", "Code"]),
			Config.Workspace(name: "Web", apps: ["Arc|Dia"]),
		])

		#expect(placement.workspace(for: "Ghostty") == "Code")
		#expect(placement.workspace(for: "Dia") == "Web")
		#expect(placement.workspace(for: "Xcode") == nil)
	}

	/// The dotfiles setup has its catch-all in the middle of the list, where its number puts it.
	@Test func defaultWorkspaceTakesUnmatchedAppsWhereverItStands() {
		let placement = Placement([
			Config.Workspace(name: "Code", apps: ["Ghostty"]),
			Config.Workspace(name: "Any", isDefault: true),
			Config.Workspace(name: "Social", apps: ["Telegram"]),
		])

		#expect(placement.workspace(for: "Ghostty") == "Code")
		#expect(placement.workspace(for: "Telegram") == "Social")
		#expect(placement.workspace(for: "Notes") == "Any")
	}

	@Test func firstMatchingWorkspaceWins() {
		let placement = Placement([
			Config.Workspace(name: "Web", apps: ["Arc"]),
			Config.Workspace(name: "Other", apps: [".*"]),
		])

		#expect(placement.workspace(for: "Arc") == "Web")
	}
}

struct DisplayMatchingTests {
	private let both = [builtin, external]

	@Test func keywordsPickByKind() {
		#expect(Display.matching("main", in: both) == builtin)
		#expect(Display.matching("builtin", in: both) == builtin)
		#expect(Display.matching("external", in: both) == external)
	}

	@Test func anythingElseIsPartOfTheName() {
		#expect(Display.matching("dell", in: both) == external)
	}

	/// The menu bar moved onto the monitor makes the monitor main, as System Settings says.
	@Test func withTheMenuBarOnTheMonitorTheLaptopIsExternal() {
		let monitorFirst = [external, builtin]
		#expect(Display.matching("main", in: monitorFirst) == external)
		#expect(Display.matching("external", in: monitorFirst) == builtin)
		#expect(Display.matching("builtin", in: monitorFirst) == builtin)
	}

	@Test func externalPrefersAMonitorToTheLaptop() {
		let frame = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
		let second = Display(id: 3, name: "LG UltraFine", isBuiltin: false, frame: frame, visibleFrame: frame)
		#expect(Display.matching("external", in: [external, builtin, second]) == second)
		#expect(Display.matching("external", in: [external]) == external)
	}

	@Test func missingScreenFallsBackToMain() {
		#expect(Display.matching("external", in: [builtin]) == builtin)
		#expect(Display.matching("LG", in: both) == builtin)
	}
}

struct HidingTests {
	private let size = CGSize(width: 800, height: 600)

	@Test func windowGoesToTheBottomRightWithOnePointOnScreen() {
		let origin = Display.hiddenOrigin(for: size, on: builtin.frame, others: [])
		#expect(origin == CGPoint(x: 1511, y: 981))
	}

	/// The external screen sits to the right of the laptop, so the right corner would put the window
	/// onto it; the left corner is free.
	@Test func cornerTouchingAnotherScreenIsAvoided() {
		let origin = Display.hiddenOrigin(for: size, on: builtin.frame, others: [external.frame])
		#expect(origin == CGPoint(x: -799, y: 981))
	}
}
