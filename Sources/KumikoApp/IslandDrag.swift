import AppKit
import KumikoCore
import SwiftUI

/// A workspace row lifted and carried up or down the list, the others making way. With a
/// monitor attached it can be carried into the other area too: the area it leaves closes
/// up, the one it is over opens a place. Only the list watches it: the rest of the window
/// does not draw again with every move. Where the row lands is `ListDrag`'s, which only
/// counts; this is the pointer, the keyboard and the animation around it.
@MainActor
final class IslandDrag: ObservableObject {
	typealias Section = ListDrag.Section
	typealias Drop = ListDrag.Drop

	/// Between two workspace rows, close as a sidebar keeps them, and counted into how far
	/// the others make way.
	static let spacing = 2.0
	/// The pointer moves this far before a press stops being a click.
	static let threshold = 4.0
	static let spring = Animation.spring(duration: 0.3, bounce: 0.15)

	@Published private(set) var dragged: String?
	@Published private(set) var translation = 0.0
	/// The place the row lands in if let go now.
	@Published private(set) var target: Drop?
	/// The row gliding into its place, kept above the ones it passes over until it is
	/// there.
	@Published private(set) var settling: String?
	/// Where each row is laid out, in the space of the whole stack, both areas in it.
	/// Written when the layout changes, not observed: the rows make way with offsets,
	/// which leave the layout as it is.
	var frames: [String: CGRect] = [:]
	let areas = AreaLayout()
	let autoScroll = IslandAutoScroll()

	/// What the lift saw, so a move only compares numbers.
	private var geometry: ListDrag?
	/// The space between the rows this drag carries: the app table's rows touch, a divider
	/// being part of each.
	private let rowSpacing: Double
	private var reach = 0.0...0.0
	/// Where the place the row would land in opens. See `ListDrag.opening(for:)`.
	private var opening: Double?
	/// The pointer's own part of the translation, and what the page scrolled since it last
	/// moved: held at the edge, the row goes along with the page under a still pointer.
	private var pointer = 0.0
	private var scrolled = 0.0
	private var cancelled = false
	/// The press went past the threshold, lifted or not, and is no click when let go.
	private var moved = false
	private var escape: Any?

	init(spacing: Double = IslandDrag.spacing) {
		rowSpacing = spacing
	}

	/// How far a row other than the lifted one is moved aside.
	func shift(of name: String) -> Double {
		guard name != dragged, let row = geometry?.rows[name] else { return 0 }
		return shift(at: row.lowerBound)
	}

	/// How far an area's top and bottom are moved: the area the row leaves gets shorter,
	/// the one it is over taller, and the areas under them move with their edges.
	func shift(ofArea id: String) -> (top: Double, bottom: Double) {
		guard let span = geometry?.spans[id] else { return (0, 0) }
		return (shift(at: span.lowerBound), shift(at: span.upperBound))
	}

	/// Up by the gap past the place the row was taken from, down by as much from the
	/// place it would land in: for one area that is the old row-by-row rule, and it
	/// holds for the area labels and edges in between as well.
	private func shift(at y: Double) -> Double {
		guard dragged != nil, target != nil, let geometry else { return 0 }
		var shift = y > geometry.lifted.lowerBound ? -geometry.gap : 0
		if let opening, y >= opening { shift += geometry.gap }
		return shift
	}

	/// The sections are read once, when the row lifts. A lift left over from a press whose
	/// end never came, the view gone under it, gives way to the new one. A press that moved
	/// and could not lift still counts the move, so letting go is no click.
	func move(_ name: String, by translation: CGSize, sections: @autoclosure () -> [Section]) {
		guard !cancelled else { return }
		if dragged != name {
			guard hypot(translation.width, translation.height) >= Self.threshold else { return }
			moved = true
			// The row still settling moves the frames once more: the lift waits for them.
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
		guard let geometry else { return }
		translation = min(max(pointer + scrolled, reach.lowerBound), reach.upperBound)
		let lifted = geometry.lifted
		let drop = geometry.drop(at: (lifted.lowerBound + lifted.upperBound) / 2 + translation)
		guard drop != target else { return }
		opening = geometry.opening(for: drop)
		target = drop
	}

	/// Lets go of the row, writing its new place with `write` in the same animation that
	/// brings it there: the file reorders the rows at once, and the offset going back to
	/// zero then carries the row from where it was let go into its place. True when the
	/// pointer never went past the threshold: a press that did is no click, even one that
	/// could not lift.
	func end(_ name: String, write: (Drop) -> Void) -> Bool {
		defer {
			cancelled = false
			moved = false
		}
		guard dragged == name else { return !moved }
		let target = target
		let origin = geometry?.origin
		settle(name) {
			if let target, target != origin { write(target) }
		}
		return false
	}

	private func lift(_ name: String, in sections: [Section]) {
		guard let geometry = ListDrag(
			lifting: name, sections: sections, rows: frames.mapValues { Double($0.minY)...Double($0.maxY) },
			spans: areas.spans, spacing: rowSpacing
		) else { return }
		self.geometry = geometry
		reach = geometry.reach
		// Its own place: what comes after it moves up by the gap and back down by as much.
		opening = geometry.lifted.lowerBound
		watchEscape()
		autoScroll.start { [weak self] distance in
			self?.scrolled += distance
			self?.place()
		} lost: { [weak self] in
			self?.abandon()
		}
		withAnimation(Self.spring) {
			dragged = name
			target = geometry.origin
		}
	}

	/// Puts the row back where it was lifted from, and the rest of the press moves nothing:
	/// for Escape, and for a reload that changes the rows under the lift.
	func cancel() {
		guard let name = dragged else { return }
		cancelled = true
		settle(name) {}
	}

	/// Puts the row back for a press that will never end, whose gesture is gone: no end
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

/// Where each area runs, from the top of its label to the bottom of its last row. All rows
/// are in one stack, so a row carried into the other area glides there and keeps its view;
/// these spans tell the drag which area it is over.
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

/// Scrolls the page while a lifted row is held at its top or bottom, so a place out of
/// sight can be reached: a long list does not fit a short window.
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

		// Behind the rows, and never what a click lands on.
		override func hitTest(_ point: NSPoint) -> NSView? { nil }
	}
}
