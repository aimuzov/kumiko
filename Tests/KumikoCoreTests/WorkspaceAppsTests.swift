import KumikoCore
import Testing

@Suite("Workspace app names and patterns")
struct WorkspaceAppsTests {
	private typealias Workspace = Config.Workspace

	@Test("a plain name is its own pattern", arguments: [
		"Safari", "Steam Helper", "Толк", "Google Chrome", "System Settings", "Dota 2",
	])
	func plainName(name: String) {
		#expect(Workspace.pattern(for: name) == name)
		#expect(Workspace.name(of: name) == name)
	}

	@Test("a dot is part of a name, escaped or not")
	func dottedName() {
		#expect(Workspace.name(of: "zoom.us") == "zoom.us")
		#expect(Workspace.name(of: "zoom\\.us") == "zoom.us")
		#expect(Workspace.name(of: "Notes.app") == "Notes.app")
		#expect(Workspace(name: "w", apps: ["zoom.us"], stack: ["zoom.us"]).isPattern("zoom.us") == false)
	}

	@Test("a name with regex syntax is escaped and comes back unescaped", arguments: [
		"Foo (Beta)", "Notes.app", "C++ Editor", "Foo \\(Beta\\)",
	])
	func roundTrip(name: String) {
		let pattern = Workspace.pattern(for: name)
		#expect(pattern != name)
		#expect(Workspace.name(of: pattern) == name)
		#expect(Workspace(name: "w", apps: [pattern]).opens(name))
	}

	@Test("a real pattern has no name")
	func realPattern() {
		#expect(Workspace.name(of: "Arc|Dia") == nil)
		#expect(Workspace.name(of: "Foo (Beta)") == nil)
		#expect(Workspace.name(of: "Code.*") == nil)
		#expect(Workspace.name(of: "trailing\\") == nil)
	}

	@Test("an escaped and an exact entry are one row")
	func oneRow() {
		let workspace = Workspace(name: "w", apps: ["Foo \\(Beta\\)", "Arc|Dia"], stack: ["Foo (Beta)"])
		#expect(workspace.appRows == ["Foo (Beta)", "Arc|Dia"])
		#expect(workspace.isPattern("Arc|Dia"))
		#expect(!workspace.isPattern("Foo (Beta)"))
		#expect(workspace.listsInApps("Foo (Beta)"))
	}

	@Test("patterns match the whole name")
	func wholeName() {
		let workspace = Workspace(name: "w", apps: ["Code"])
		#expect(workspace.opens("Code"))
		#expect(!workspace.opens("Xcode"))
	}

	@Test("windows follow the order of the apps, unranked ones after, pinned last ones at the end")
	func layoutOrder() {
		let workspace = Workspace(name: "w", apps: ["Telegram", "Arc|Dia", "Time"], last: ["Telegram"])
		let windows: [(id: Int, app: String)] = [
			(1, "Time"), (2, "Finder"), (3, "Telegram"), (4, "Dia"), (5, "Notes"), (6, "Arc"), (7, "Time"),
		]
		#expect(workspace.layoutOrder(windows) == [4, 6, 1, 7, 2, 5, 3])
		#expect(workspace.orderedApps == ["Arc|Dia", "Time", "Telegram"])
		#expect(workspace.appRows == ["Arc|Dia", "Time", "Telegram"])
	}

	@Test("windows already in order stay as they are")
	func stableOrder() {
		let workspace = Workspace(name: "w", apps: ["A", "B"])
		let windows: [(id: Int, app: String)] = [(1, "A"), (2, "A"), (3, "B"), (4, "C")]
		#expect(workspace.layoutOrder(windows) == [1, 2, 3, 4])
	}
}
