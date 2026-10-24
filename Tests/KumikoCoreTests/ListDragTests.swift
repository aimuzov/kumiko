import KumikoCore
import Testing

@Suite("A row carried up or down the workspaces list")
struct ListDragTests {
	private typealias Section = ListDrag.Section
	private typealias Drop = ListDrag.Drop

	/// The list's own numbers: rows 28 pt tall, 2 pt apart.
	private static let height = 28.0
	private static let spacing = 2.0

	private func rows(_ names: [String], from top: Double) -> [String: ClosedRange<Double>] {
		Dictionary(uniqueKeysWithValues: names.enumerated().map { place, name in
			let y = top + Double(place) * (Self.height + Self.spacing)
			return (name, y...(y + Self.height))
		})
	}

	/// The drop for the row carried as far down as it goes.
	private func bottom(_ drag: ListDrag) -> Drop {
		drag.drop(at: (drag.lifted.lowerBound + drag.lifted.upperBound) / 2 + drag.reach.upperBound)
	}

	@Test func reachesTheEndWithoutAreas() throws {
		let drag = try #require(ListDrag(
			lifting: "a", sections: [Section(id: "", names: ["a", "b", "c"])],
			rows: rows(["a", "b", "c"], from: 0), spans: [:], spacing: Self.spacing
		))
		#expect(bottom(drag) == Drop(section: "", slot: 2))
	}

	/// Main on top: a label, a and b, the end; External under it: a label, c and d, the end.
	private let sections = [Section(id: "main", names: ["a", "b"]), Section(id: "external", names: ["c", "d"])]
	private var twoAreas: [String: ClosedRange<Double>] {
		rows(["a", "b"], from: 22).merging(rows(["c", "d"], from: 114)) { $1 }
	}

	private let spans: [String: ClosedRange<Double>] = ["main": 0...82, "external": 84...174]

	@Test func passesTheLastRowOfTheTopAreaBeforeLeavingIt() throws {
		let drag = try #require(ListDrag(
			lifting: "a", sections: sections, rows: twoAreas, spans: spans, spacing: Self.spacing
		))
		// Just past b's middle, which is still above the edge of the area the row is in.
		#expect(drag.drop(at: 67) == Drop(section: "main", slot: 1))
		#expect(drag.drop(at: 90) == Drop(section: "external", slot: 0))
	}

	@Test func reachesTheEndOfTheBottomArea() throws {
		let drag = try #require(ListDrag(
			lifting: "c", sections: sections, rows: twoAreas, spans: spans, spacing: Self.spacing
		))
		#expect(bottom(drag) == Drop(section: "external", slot: 1))
	}

	@Test func reachesTheEndOfTheBottomAreaFromTheTop() throws {
		let drag = try #require(ListDrag(
			lifting: "a", sections: sections, rows: twoAreas, spans: spans, spacing: Self.spacing
		))
		#expect(bottom(drag) == Drop(section: "external", slot: 2))
	}

	@Test func carriesATallRowPastAShortLastOne() throws {
		let rows: [String: ClosedRange<Double>] = ["a": 0...44, "b": 44...72]
		let drag = try #require(ListDrag(
			lifting: "a", sections: [Section(id: "", names: ["a", "b"])], rows: rows, spans: [:], spacing: 0
		))
		#expect(bottom(drag) == Drop(section: "", slot: 1))
	}

	@Test func opensAfterTheLastRowForTheEnd() throws {
		let drag = try #require(ListDrag(
			lifting: "a", sections: [Section(id: "", names: ["a", "b", "c"])],
			rows: rows(["a", "b", "c"], from: 0), spans: [:], spacing: Self.spacing
		))
		#expect(drag.opening(for: Drop(section: "", slot: 2)) == 89)
		#expect(drag.opening(for: Drop(section: "", slot: 0)) == 30)
	}
}
