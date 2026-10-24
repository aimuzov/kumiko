/// Where a row carried up or down a list lands, worked out from the layout the lift saw: the
/// settings window's workspaces, one section without areas or one per area with them. Only
/// numbers, so the cases a pointer can barely reach are tested and not found by hand.
public struct ListDrag: Sendable {
	/// The rows of one section, top to bottom. Without areas there is one, with no id.
	public struct Section: Equatable, Sendable {
		public let id: String
		public let names: [String]

		public init(id: String, names: [String]) {
			self.id = id
			self.names = names
		}
	}

	/// A place to land in: a section and a slot in it, counted with the lifted row out.
	public struct Drop: Equatable, Sendable {
		public let section: String
		public let slot: Int

		public init(section: String, slot: Int) {
			self.section = section
			self.slot = slot
		}
	}

	public let name: String
	public let sections: [Section]
	/// Each row top to bottom as laid out, in the space of the whole list.
	public let rows: [String: ClosedRange<Double>]
	/// Each area from its label to its end; empty without areas.
	public let spans: [String: ClosedRange<Double>]
	public let origin: Drop
	public let lifted: ClosedRange<Double>
	/// How far the others move aside: the lifted row's height and the space after it.
	public let gap: Double
	public let spacing: Double

	/// Nil for a row the layout has not measured, or that no section has.
	public init?(
		lifting name: String, sections: [Section], rows: [String: ClosedRange<Double>],
		spans: [String: ClosedRange<Double>], spacing: Double
	) {
		guard let lifted = rows[name],
		      let section = sections.first(where: { $0.names.contains(name) }),
		      let index = section.names.firstIndex(of: name) else { return nil }
		self.name = name
		self.sections = sections
		self.rows = rows
		self.spans = spans.filter { id, _ in sections.contains { $0.id == id } }
		self.lifted = lifted
		self.spacing = spacing
		origin = Drop(section: section.id, slot: index)
		gap = lifted.upperBound - lifted.lowerBound + spacing
	}

	/// How far the row can be carried from where it was: over every area, an empty one too;
	/// without areas, from the first row to the last. Its middle goes as far as the edges, half
	/// of it hanging over: passing a row takes passing its middle, and a row taller than the
	/// first or the last one would not get past theirs if it stopped flush with the edge.
	public var reach: ClosedRange<Double> {
		let edges = spans.isEmpty ? sections.flatMap(\.names).compactMap { rows[$0] } : Array(spans.values)
		let middle = Self.middle(lifted)
		let top = edges.map(\.lowerBound).min() ?? middle
		let bottom = edges.map(\.upperBound).max() ?? middle
		return min(top - middle, 0)...max(bottom - middle, 0)
	}

	/// The place for the lifted row's middle at `centre`. In its own area the row is compared
	/// with the others where they stand. In another one they stand where the area moved to once
	/// the row left: a row is passed when the lifted one's middle passes the middle it is seen at.
	public func drop(at centre: Double) -> Drop {
		let section = section(at: centre)
		let own = section.id == origin.section
		let slot = others(in: section).count { other in
			let middle = rows[other].map(Self.middle) ?? .infinity
			return (own ? middle : closed(middle)) < centre
		}
		return Drop(section: section.id, slot: slot)
	}

	/// Where the place the row would land in opens, in the layout: whatever is laid out from
	/// here down moves down by the gap. Nil for an empty other area, which only lights up; the
	/// row's own area, emptied by the lift, keeps its place open.
	public func opening(for drop: Drop) -> Double? {
		guard let section = sections.first(where: { $0.id == drop.section }) else { return nil }
		let others = others(in: section)
		guard let last = others.last else { return section.id == origin.section ? lifted.lowerBound : nil }
		if drop.slot < others.count { return rows[others[drop.slot]]?.lowerBound }
		return rows[last].map { $0.upperBound + spacing / 2 }
	}

	/// Where something laid out at `y` stands with the lifted row taken out.
	public func closed(_ y: Double) -> Double { y > lifted.lowerBound ? y - gap : y }

	/// The area the middle of the row is over, the gaps between areas split halfway. The row's
	/// own area keeps its height while the row is in it, so its edge below stays where it was
	/// laid out: closed, it would come up a gap and take the row away before it passed the
	/// area's last one. Other areas stand as they do with the row taken out.
	private func section(at centre: Double) -> Section {
		for (section, next) in zip(sections, sections.dropFirst()) {
			guard let span = spans[section.id], let below = spans[next.id] else { continue }
			let own = section.id == origin.section
			let edge = own ? span.upperBound : closed(span.upperBound)
			let start = own ? below.lowerBound : closed(below.lowerBound)
			if centre < (edge + start) / 2 { return section }
		}
		return sections.last { spans[$0.id] != nil } ?? sections.first { $0.id == origin.section } ?? sections[0]
	}

	private func others(in section: Section) -> [String] { section.names.filter { $0 != name } }

	private static func middle(_ range: ClosedRange<Double>) -> Double { (range.lowerBound + range.upperBound) / 2 }
}
