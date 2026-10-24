import KumikoCore
import Testing

@Suite("Workspaces grouped by display")
struct WorkspaceAreasTests {
	private typealias Workspace = Config.Workspace

	/// The settings window's own shape: six on the monitor, then six on the laptop.
	private let grouped = (1...6).map { Workspace(name: "e\($0)", display: "external") }
		+ (1...6).map { Workspace(name: "m\($0)") }

	private let interleaved = [
		Workspace(name: "m1"), Workspace(name: "e1", display: "external"), Workspace(name: "b1", display: "builtin"),
		Workspace(name: "e2", display: "external"), Workspace(name: "s1", display: "Kuycon"),
	]

	/// The changes written to a file of `workspaces` and read back, as `name@display` in
	/// file order.
	private func written(_ changes: [any ConfigChange], to workspaces: [Workspace]) throws -> [String] {
		let inserts = workspaces.map { EntryEdit.insert("workspace", fields: $0.tomlFields) }
		let text = try ConfigWriter.apply(inserts, to: "")
		let config = try Config.parse(ConfigWriter.apply(changes, to: text))
		return config.workspaces.map { "\($0.name)@\($0.display)" }
	}

	private func names(_ workspaces: [Workspace], _ entries: [Int]) -> [String] { entries.map { workspaces[$0].name } }

	@Test func groupsTheSettingsWindowsShape() {
		let groups = WorkspaceAreas.groups(of: grouped)
		#expect(groups.map(\.area) == [.external, .main])
		#expect(groups[0].entries == Array(0..<6))
		#expect(groups[1].entries == Array(6..<12))
	}

	@Test func everyOtherDisplayIsMain() {
		let groups = WorkspaceAreas.groups(of: interleaved)
		#expect(groups.map(\.area) == [.main, .external])
		#expect(names(interleaved, groups[0].entries) == ["m1", "b1", "s1"])
		#expect(names(interleaved, groups[1].entries) == ["e1", "e2"])
	}

	@Test func anAreaWithNothingInItComesLast() {
		let groups = WorkspaceAreas.groups(of: [Workspace(name: "1"), Workspace(name: "2")])
		#expect(groups.map(\.area) == [.main, .external])
		#expect(groups[1].entries.isEmpty)
	}

	@Test func dropsAtTheTopOfTheOtherArea() throws {
		let changes = WorkspaceAreas.move(8, to: .external, slot: 0, in: grouped)
		let result = try written(changes, to: grouped)
		#expect(result.prefix(2) == ["m3@external", "e1@external"])
		#expect(result.filter { $0.hasSuffix("@external") }.count == 7)
	}

	@Test func dropsInTheMiddleOfTheOtherArea() throws {
		let changes = WorkspaceAreas.move(1, to: .main, slot: 2, in: grouped)
		let result = try written(changes, to: grouped)
		#expect(result == [
			"e1@external", "e3@external", "e4@external", "e5@external", "e6@external",
			"m1@main", "m2@main", "e2@main", "m3@main", "m4@main", "m5@main", "m6@main",
		])
	}

	@Test func dropsAtTheEndOfTheOtherArea() throws {
		let toMain = try written(WorkspaceAreas.move(0, to: .main, slot: 6, in: grouped), to: grouped)
		#expect(toMain.last == "e1@main")
		let toExternal = try written(WorkspaceAreas.move(11, to: .external, slot: .max, in: grouped), to: grouped)
		#expect(toExternal[6] == "m6@external")
		#expect(toExternal.suffix(5) == ["m1@main", "m2@main", "m3@main", "m4@main", "m5@main"])
	}

	@Test func dropsIntoAnEmptyArea() throws {
		let workspaces = [Workspace(name: "1"), Workspace(name: "2"), Workspace(name: "3")]
		let result = try written(WorkspaceAreas.move(0, to: .external, slot: 0, in: workspaces), to: workspaces)
		#expect(result == ["2@main", "3@main", "1@external"])
	}

	@Test func movesWithinAnArea() throws {
		let down = WorkspaceAreas.move(6, to: .main, slot: 3, in: grouped)
		#expect(down.count == 1)
		#expect(down.first as? EntryEdit == .move("workspace", from: 6, to: 9))
		let up = WorkspaceAreas.move(3, to: .external, slot: 0, in: grouped)
		#expect(up.first as? EntryEdit == .move("workspace", from: 3, to: 0))
	}

	@Test func leavesAnEntryWhereItIs() {
		#expect(WorkspaceAreas.move(2, to: .external, slot: 2, in: grouped).isEmpty)
		#expect(WorkspaceAreas.move(5, to: .external, slot: .max, in: grouped).isEmpty)
		#expect(WorkspaceAreas.move(12, to: .main, slot: 0, in: grouped).isEmpty)
	}

	@Test func keepsWhatAnotherDisplaySaysWithinMain() throws {
		let changes = WorkspaceAreas.move(4, to: .main, slot: 0, in: interleaved)
		#expect(changes.count == 1)
		#expect(try written(changes, to: interleaved).first == "s1@Kuycon")
	}

	@Test func placesBetweenTheEntriesOfAnInterleavedFile() throws {
		// Right before s1, past e2 of the other area in between.
		let toMain = try written(WorkspaceAreas.move(1, to: .main, slot: 2, in: interleaved), to: interleaved)
		#expect(toMain == ["m1@main", "b1@builtin", "e2@external", "e1@main", "s1@Kuycon"])
		let toExternal = try written(WorkspaceAreas.move(4, to: .external, slot: 1, in: interleaved), to: interleaved)
		#expect(toExternal == ["m1@main", "e1@external", "b1@builtin", "s1@external", "e2@external"])
	}

	@Test func addsAtTheEndOfItsArea() throws {
		let external = WorkspaceAreas.add(Workspace(name: "new", display: "external"), to: grouped)
		#expect(try written(external, to: grouped)[6] == "new@external")
		let main = WorkspaceAreas.add(Workspace(name: "new"), to: grouped)
		#expect(main.count == 1)
		#expect(try written(main, to: grouped).last == "new@main")
	}
}
