import AppKit
import SwiftUI

/// An island lifted by its header and carried up or down the page, the others making
/// way. With a monitor attached it can be carried into the other area too: the area it
/// leaves closes up, the one it is over opens a place. Only the stack watches it: the
/// rest of the window does not draw again with every move.
@MainActor
final class IslandDrag: ObservableObject {
	/// The islands of one area, top to bottom. Without areas there is one, with no id.
	struct Section: Equatable {
		let id: String
		let names: [String]
	}

	/// A place to land in: a section and a slot in it, counted with the lifted island out.
	struct Drop: Equatable {
		let section: String
		let slot: Int
	}

	/// Between two islands, close as Raycast keeps them, and counted into how far the
	/// others make way.
	static let spacing = 8.0
	/// The pointer moves this far before a press stops being a click.
	static let threshold = 4.0
	static let spring = Animation.spring(duration: 0.3, bounce: 0.15)

	@Published private(set) var dragged: String?
	@Published private(set) var translation = 0.0
	/// The place the island lands in if let go now.
	@Published private(set) var target: Drop?
	/// The island gliding into its place, kept above the ones it passes over until it is
	/// there.
	@Published private(set) var settling: String?
	/// Where each island is laid out, in the space of the whole stack, both areas in it.
	/// Written when the layout changes, not observed: the islands make way with offsets,
	/// which leave the layout as it is.
	var frames: [String: CGRect] = [:]
	let areas = AreaLayout()
	let autoScroll = IslandAutoScroll()

	/// What the lift saw, so a move only compares numbers: the sections, the islands and
	/// areas as they were laid out, and how far the lifted one can go.
	private var sections: [Section] = []
	private var laidOut: [String: CGRect] = [:]
	private var spans: [String: ClosedRange<Double>] = [:]
	private var origin = Drop(section: "", slot: 0)
	private var lifted = CGRect.zero
	/// How far the others move aside: the lifted island's height and the space after it.
	private var gap = 0.0
	private var reach = 0.0...0.0
	/// Where the place the island would land in opens, in the layout: whatever is laid out
	/// from here down moves down by the gap. Nil for an empty other area, which only lights
	/// up; the island's own area, emptied by the lift, keeps its place open.
	private var opening: Double?
	/// The pointer's own part of the translation, and what the page scrolled since it last
	/// moved: held at the edge, the island goes along with the page under a still pointer.
	private var pointer = 0.0
	private var scrolled = 0.0
	private var cancelled = false
	/// The press went past the threshold, lifted or not, and is no click when let go.
	private var moved = false
	private var escape: Any?

	/// How far an island other than the lifted one is moved aside.
	func shift(of name: String) -> Double {
		guard name != dragged, let frame = laidOut[name] else { return 0 }
		return shift(at: frame.minY)
	}

	/// How far an area's top and bottom are moved: the area the island leaves gets shorter,
	/// the one it is over taller, and the areas under them move with their edges.
	func shift(ofArea id: String) -> (top: Double, bottom: Double) {
		guard let span = spans[id] else { return (0, 0) }
		return (shift(at: span.lowerBound), shift(at: span.upperBound))
	}

	/// Up by the gap past the place the island was taken from, down by as much from the
	/// place it would land in: for one area that is the old island-by-island rule, and it
	/// holds for the area labels and edges in between as well.
	private func shift(at y: Double) -> Double {
		guard dragged != nil, target != nil else { return 0 }
		var shift = y > lifted.minY ? -gap : 0
		if let opening, y >= opening { shift += gap }
		return shift
	}

	/// The sections are read once, when the island lifts. A lift left over from a press
	/// whose end never came, the view gone under it, gives way to the new one. An island
	/// that can't lift, an open one, still counts the move, so letting go is no click.
	func move(
		_ name: String, by translation: CGSize, canLift: Bool = true, sections: @autoclosure () -> [Section]
	) {
		guard !cancelled else { return }
		if dragged != name {
			guard hypot(translation.width, translation.height) >= Self.threshold else { return }
			moved = true
			guard canLift else { return }
			// The island still settling moves the frames once more: the lift waits for them.
			guard settling == nil else { return }
			lift(name, in: sections())
		}
		guard dragged == name else { return }

		// Measured in the stack, the gesture's translation has the scrolling in it already.
		pointer = translation.height
		scrolled = 0
		place()
	}

	private func place() {
		translation = min(max(pointer + scrolled, reach.lowerBound), reach.upperBound)
		let centre = lifted.midY + translation
		let section = section(at: centre)
		let others = section.names.filter { $0 != dragged }
		// In its own area the island is compared with the others where they stand. In another
		// one they stand where the area moved to once the island left: an island is passed
		// when the lifted one's middle passes the middle it is seen at.
		let own = section.id == origin.section
		let slot = others.count { name in
			let middle = laidOut[name]?.midY ?? .infinity
			return (own ? middle : closed(middle)) < centre
		}
		let drop = Drop(section: section.id, slot: slot)
		guard drop != target else { return }
		opening = if others.isEmpty {
			section.id == origin.section ? lifted.minY : nil
		} else if slot < others.count {
			laidOut[others[slot]].map { Double($0.minY) }
		} else {
			laidOut[others[others.count - 1]].map { $0.maxY + IslandDrag.spacing / 2 }
		}
		target = drop
	}

	/// Where something laid out at `y` stands with the lifted island taken out.
	private func closed(_ y: Double) -> Double { y > lifted.minY ? y - gap : y }

	/// The area the middle of the island is over, the gaps between areas split halfway, as
	/// the areas stand with the island taken out.
	private func section(at centre: Double) -> Section {
		for (section, next) in zip(sections, sections.dropFirst()) {
			guard let span = spans[section.id], let below = spans[next.id] else { continue }
			if centre < (closed(span.upperBound) + closed(below.lowerBound)) / 2 { return section }
		}
		return sections.last { spans[$0.id] != nil } ?? sections.first { $0.id == origin.section } ?? sections[0]
	}

	/// Lets go of the island, writing its new place with `write` in the same animation that
	/// brings it there: the file reorders the islands at once, and the offset going back to
	/// zero then carries the island from where it was let go into its place. True when the
	/// pointer never went past the threshold: a press that did is no click, even one that
	/// could not lift.
	func end(_ name: String, write: (Drop) -> Void) -> Bool {
		defer {
			cancelled = false
			moved = false
		}
		guard dragged == name else { return !moved }
		let target = target
		settle(name) {
			if let target, target != origin { write(target) }
		}
		return false
	}

	private func lift(_ name: String, in sections: [Section]) {
		guard let frame = frames[name],
		      let section = sections.first(where: { $0.names.contains(name) }),
		      let index = section.names.firstIndex(of: name) else { return }
		self.sections = sections
		laidOut = frames
		spans = areas.spans.filter { id, _ in sections.contains { $0.id == id } }
		origin = Drop(section: section.id, slot: index)
		lifted = frame
		gap = frame.height + IslandDrag.spacing
		// Over every area, an empty one too; without areas, from the first island to the last.
		let edges = spans.isEmpty
			? sections.flatMap(\.names).compactMap { frames[$0] }.map { $0.minY...$0.maxY }
			: Array(spans.values)
		let top = edges.map(\.lowerBound).min() ?? frame.minY
		var bottom = edges.map(\.upperBound).max() ?? frame.maxY
		// Its own place: what comes after it moves up by the gap and back down by as much.
		opening = frame.minY
		// The last area ends a gap higher once the island has left it, and that is the end
		// the island can be carried to.
		if !spans.isEmpty { bottom = closed(bottom) }
		reach = min(top - frame.minY, 0)...max(bottom - frame.maxY, 0)
		watchEscape()
		autoScroll.start { [weak self] distance in
			self?.scrolled += distance
			self?.place()
		} lost: { [weak self] in
			self?.abandon()
		}
		withAnimation(Self.spring) {
			dragged = name
			target = origin
		}
	}

	/// Puts the island back where it was lifted from, and the rest of the press moves nothing:
	/// for Escape, and for a reload that changes the islands under the lift.
	func cancel() {
		guard let name = dragged else { return }
		cancelled = true
		settle(name) {}
	}

	/// Puts the island back for a press that will never end, whose gesture is gone: no end
	/// comes to clear the press, and the next one elsewhere would be taken for its rest.
	func abandon() {
		cancel()
		cancelled = false
		moved = false
	}

	/// Drops everything at once, for a page that is gone: there is nothing left to animate.
	func reset() {
		unwatchEscape()
		autoScroll.stop()
		dragged = nil
		target = nil
		translation = 0
		settling = nil
		cancelled = false
		moved = false
	}

	private func settle(_ name: String, _ write: () -> Void) {
		unwatchEscape()
		autoScroll.stop()
		settling = name
		withAnimation(Self.spring, completionCriteria: .logicallyComplete) {
			write()
			dragged = nil
			translation = 0
			target = nil
		} completion: { [weak self] in
			if self?.settling == name { self?.settling = nil }
		}
	}

	private func watchEscape() {
		unwatchEscape()
		escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			let code = event.keyCode
			let handled = MainActor.assumeIsolated {
				guard code == 53, let self, self.dragged != nil else { return false }
				self.cancel()
				return true
			}
			return handled ? nil : event
		}
	}

	private func unwatchEscape() {
		if let escape { NSEvent.removeMonitor(escape) }
		escape = nil
	}
}

/// Where each area runs, from the top of its label to the bottom of its Add Workspace row.
/// The areas' backgrounds are drawn from these behind the one stack all islands are in, so
/// an island carried into the other area glides there and keeps its view, and its focus.
@MainActor
final class AreaLayout: ObservableObject {
	@Published private(set) var spans: [String: ClosedRange<Double>] = [:]
	private var tops: [String: Double] = [:]
	private var bottoms: [String: Double] = [:]

	func top(of area: String, at y: Double) {
		tops[area] = y
		update(area)
	}

	func bottom(of area: String, at y: Double) {
		bottoms[area] = y
		update(area)
	}

	/// For a page that is gone, or that shows no areas any more.
	func forget() {
		tops = [:]
		bottoms = [:]
		if !spans.isEmpty { spans = [:] }
	}

	private func update(_ area: String) {
		guard let top = tops[area], let bottom = bottoms[area], top <= bottom else { return }
		if spans[area] != top...bottom { spans[area] = top...bottom }
	}
}

/// Scrolls the page while a lifted island is held at its top or bottom, so a place out of
/// sight can be reached: twelve workspaces do not fit the window.
@MainActor
final class IslandAutoScroll {
	/// How near the edge the pointer starts the scrolling, and the most a tick scrolls, right
	/// at the edge or past it.
	static let edge = 40.0
	static let fastest = 20.0

	/// The page's own scroll view, found from inside it: SwiftUI hands out no way to scroll it
	/// by a distance.
	weak var scrollView: NSScrollView?
	private var timer: Timer?
	private var scrolled: (Double) -> Void = { _ in }
	private var lost: () -> Void = {}
	/// Ticks since the button came up. A real release reaches the gesture well within them.
	private var released = 0

	/// `scrolled` gets the distance of every tick that moved the page, down positive. `lost`
	/// is for a press whose end the gesture never hears: the window closed under it, or the
	/// button came up and the gesture did not end.
	func start(scrolled: @escaping (Double) -> Void, lost: @escaping () -> Void) {
		stop()
		self.scrolled = scrolled
		self.lost = lost
		released = 0
		let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.tick() }
		}
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	func stop() {
		timer?.invalidate()
		timer = nil
	}

	private func tick() {
		released = NSEvent.pressedMouseButtons & 1 == 0 ? released + 1 : 0
		if released > 10 || scrollView.map({ $0.window?.isVisible != true }) == true {
			stop()
			lost()
			return
		}

		// SwiftUI's document view is flipped, which the distances below count on.
		guard let scrollView, let window = scrollView.window, let document = scrollView.documentView,
		      document.isFlipped else { return }
		let point = scrollView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
		let height = scrollView.bounds.height
		let insets = scrollView.contentInsets
		let fromTop = (scrollView.isFlipped ? point.y : height - point.y) - insets.top
		let fromBottom = height - insets.top - insets.bottom - fromTop

		// Faster the deeper in, slow at first so a pointer passing by barely moves the page.
		let depth = fromTop < Self.edge ? -(Self.edge - fromTop) / Self.edge
			: fromBottom < Self.edge ? (Self.edge - fromBottom) / Self.edge : 0
		guard depth != 0 else { return }
		let step = min(max(depth * abs(depth), -1), 1) * Self.fastest

		let clip = scrollView.contentView
		let bottom = max(-insets.top, document.frame.height - clip.bounds.height + insets.bottom)
		let next = min(max(clip.bounds.origin.y + step, -insets.top), bottom)
		let distance = next - clip.bounds.origin.y
		guard distance != 0 else { return }
		clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: next))
		scrollView.reflectScrolledClipView(clip)
		scrolled(distance)
	}
}

/// Hands the scroll view around the page to the auto-scroll once it is in a window.
struct ScrollViewProbe: NSViewRepresentable {
	let found: (NSScrollView?) -> Void

	func makeNSView(context: Context) -> Probe { Probe(found: found) }

	func updateNSView(_ view: Probe, context: Context) {}

	final class Probe: NSView {
		let found: (NSScrollView?) -> Void

		init(found: @escaping (NSScrollView?) -> Void) {
			self.found = found
			super.init(frame: .zero)
		}

		required init?(coder: NSCoder) { nil }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			found(enclosingScrollView)
		}

		// Behind the islands, and never what a click lands on.
		override func hitTest(_ point: NSPoint) -> NSView? { nil }
	}
}
