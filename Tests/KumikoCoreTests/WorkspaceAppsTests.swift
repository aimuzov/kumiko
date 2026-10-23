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
}
