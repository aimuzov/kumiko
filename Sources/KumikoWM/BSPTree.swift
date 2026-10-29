import CoreGraphics

/// Which way a split divides its area.
enum Axis: Equatable {
	/// Children side by side: first on the left, second on the right.
	case columns
	/// Children one above the other: first on top, second below.
	case rows
}

enum Direction: String, CaseIterable {
	case west, east, north, south

	var axis: Axis {
		switch self {
		case .west, .east: .columns
		case .north, .south: .rows
		}
	}

	var opposite: Direction {
		switch self {
		case .west: .east
		case .east: .west
		case .north: .south
		case .south: .north
		}
	}

	/// Whether this side is where a split puts its first child.
	var isFirstSide: Bool { self == .west || self == .north }
}

enum Zoom: String, Equatable {
	/// The window covers the whole layout area.
	case fullscreen
	/// The window covers the area of its parent split, hiding its sibling.
	case parent
}

/// A node is either a split with two children or a leaf with one or more windows. A leaf with
/// several windows is a stack: they share one area and only the active one is in front.
final class Node {
	weak var parent: Node?

	var axis = Axis.columns
	/// The first child's share of the area, 0...1.
	var ratio = 0.5
	var first: Node?
	var second: Node?

	var windows: [UInt32] = []
	var active = 0

	var isLeaf: Bool { first == nil }
	var activeWindow: UInt32? { windows.isEmpty ? nil : windows[active] }

	init(windows: [UInt32]) {
		self.windows = windows
	}

	init(axis: Axis, first: Node, second: Node) {
		self.axis = axis
		self.first = first
		self.second = second
		first.parent = self
		second.parent = self
	}
}

/// The binary space partitioning layout of one area. It knows only window ids and rectangles, so
/// every operation can be tested without a single real window.
final class BSPTree {
	private(set) var root: Node?
	private var leafByWindow: [UInt32: Node] = [:]
	private var zoomed: [UInt32: Zoom] = [:]

	static let minRatio = 0.1
	static let maxRatio = 0.9

	var isEmpty: Bool { root == nil }

	func contains(_ id: UInt32) -> Bool { leafByWindow[id] != nil }

	/// Leaves from left to right (and top to bottom), the order `first` and `last` refer to.
	var leaves: [Node] {
		var result: [Node] = []
		func walk(_ node: Node?) {
			guard let node else { return }
			if node.isLeaf { result.append(node) } else { walk(node.first); walk(node.second) }
		}
		walk(root)
		return result
	}

	/// The windows in front: one per leaf.
	var visibleWindows: [UInt32] { leaves.compactMap(\.activeWindow) }

	var allWindows: [UInt32] { leaves.flatMap(\.windows) }

	func zoom(of id: UInt32) -> Zoom? { zoomed[id] }

	/// 1-based position in its stack, 0 for a window that is not stacked.
	func stackIndex(of id: UInt32) -> Int {
		guard let leaf = leafByWindow[id], leaf.windows.count > 1, let index = leaf.windows.firstIndex(of: id)
		else { return 0 }
		return index + 1
	}

	/// Whether the window is in a stack, behind the one in front.
	func isBehind(_ id: UInt32) -> Bool {
		guard let leaf = leafByWindow[id] else { return false }
		return leaf.activeWindow != id
	}

	func stackCount(of id: UInt32) -> Int {
		leafByWindow[id]?.windows.count ?? 0
	}

	// MARK: - Insert and remove

	/// Adds a window by splitting the leaf of `target` (or the last leaf), the new window taking the
	/// second half. The split follows the longer side of that leaf, so windows stay close to square.
	func insert(_ id: UInt32, near target: UInt32?, in area: CGRect, gap: Double) {
		guard !contains(id) else { return }

		let leaf = Node(windows: [id])
		leafByWindow[id] = leaf

		guard let root else {
			self.root = leaf
			return
		}

		let anchor = target.flatMap { leafByWindow[$0] } ?? leaves.last ?? root
		let rect = nodeRects(in: area, gap: gap)[ObjectIdentifier(anchor)] ?? area
		split(anchor, with: leaf, axis: rect.width >= rect.height ? .columns : .rows, newFirst: false)
	}

	/// Takes a window out; its sibling takes over the parent's whole area.
	func remove(_ id: UInt32) {
		guard let leaf = leafByWindow.removeValue(forKey: id), let index = leaf.windows.firstIndex(of: id) else {
			return
		}

		zoomed[id] = nil
		leaf.windows.remove(at: index)

		if !leaf.windows.isEmpty {
			if leaf.active >= index { leaf.active = max(0, leaf.active - 1) }
			return
		}

		guard let parent = leaf.parent else {
			root = nil
			return
		}

		let sibling = parent.first === leaf ? parent.second! : parent.first!
		replace(parent, with: sibling)
	}

	/// Puts `new` where `old` is, in its stack and with its zoom. A tab coming in front of another
	/// takes its place like this, and nothing around it moves.
	func substitute(_ old: UInt32, with new: UInt32) {
		guard !contains(new), let leaf = leafByWindow.removeValue(forKey: old), let index = leaf.windows.firstIndex(of: old)
		else { return }

		leaf.windows[index] = new
		leafByWindow[new] = leaf
		zoomed[new] = zoomed.removeValue(forKey: old)
	}

	// MARK: - Geometry

	/// Where every window goes, stacked windows included (they share their leaf's rectangle).
	func frames(in area: CGRect, gap: Double) -> [UInt32: CGRect] {
		let rects = nodeRects(in: area, gap: gap)
		var result: [UInt32: CGRect] = [:]

		for (id, leaf) in leafByWindow {
			switch zoomed[id] {
			case .fullscreen:
				result[id] = area
			case .parent:
				result[id] = leaf.parent.flatMap { rects[ObjectIdentifier($0)] } ?? rects[ObjectIdentifier(leaf)]
			case nil:
				result[id] = rects[ObjectIdentifier(leaf)]
			}
		}

		return result
	}

	private func nodeRects(in area: CGRect, gap: Double) -> [ObjectIdentifier: CGRect] {
		var result: [ObjectIdentifier: CGRect] = [:]

		func walk(_ node: Node, _ rect: CGRect) {
			result[ObjectIdentifier(node)] = rect
			guard let first = node.first, let second = node.second else { return }

			let (a, b) = divide(rect, axis: node.axis, ratio: node.ratio, gap: gap)
			walk(first, a)
			walk(second, b)
		}

		if let root { walk(root, area) }
		return result
	}

	/// Splits a rectangle in two with `gap` between them, on whole points so that neighbours meet
	/// exactly instead of overlapping by a fraction.
	private func divide(_ rect: CGRect, axis: Axis, ratio: Double, gap: Double) -> (CGRect, CGRect) {
		switch axis {
		case .columns:
			let width = ((rect.width - gap) * ratio).rounded()
			let first = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
			let second = CGRect(
				x: rect.minX + width + gap, y: rect.minY, width: rect.width - width - gap, height: rect.height
			)
			return (first, second)
		case .rows:
			let height = ((rect.height - gap) * ratio).rounded()
			let first = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
			let second = CGRect(
				x: rect.minX, y: rect.minY + height + gap, width: rect.width, height: rect.height - height - gap
			)
			return (first, second)
		}
	}

	// MARK: - Moving windows

	/// Moves `id` next to `target`, on the side facing where it came from, so a window travels one
	/// step at a time. Two windows that are each other's sibling just trade places.
	func warp(_ id: UInt32, to target: UInt32, direction: Direction) {
		guard
			id != target,
			let leaf = leafByWindow[id], let targetLeaf = leafByWindow[target],
			leaf !== targetLeaf
		else { return }

		if leaf.parent != nil, leaf.parent === targetLeaf.parent, leaf.windows.count == 1, targetLeaf.windows.count == 1 {
			swap(id, target)
			return
		}

		let zoom = zoomed[id]
		remove(id)

		let moved = Node(windows: [id])
		leafByWindow[id] = moved
		zoomed[id] = zoom

		let anchor = leafByWindow[target]!
		split(anchor, with: moved, axis: direction.axis, newFirst: direction.opposite.isFirstSide)
	}

	/// Two windows trade places; everything else about the layout stays.
	func swap(_ a: UInt32, _ b: UInt32) {
		guard
			a != b,
			let leafA = leafByWindow[a], let leafB = leafByWindow[b],
			let indexA = leafA.windows.firstIndex(of: a), let indexB = leafB.windows.firstIndex(of: b)
		else { return }

		leafA.windows[indexA] = b
		leafB.windows[indexB] = a
		leafByWindow[a] = leafB
		leafByWindow[b] = leafA
	}

	/// Every window in one stack over the whole area, in the order the leaves had them, with
	/// `active` in front, else the stack's first. For a workspace switched to the stack layout;
	/// a zoom has nothing left to cover and is dropped.
	func collapse(active: UInt32?) {
		let windows = allWindows
		guard !windows.isEmpty else { return }
		let leaf = Node(windows: windows)
		leaf.active = active.flatMap(windows.firstIndex) ?? 0
		root = leaf
		leafByWindow = Dictionary(uniqueKeysWithValues: windows.map { ($0, leaf) })
		zoomed = [:]
	}

	/// Moves whole leaves, a stack with all its windows and the one in front: leaf `i` gets
	/// what leaf `order[i]` held. The splits and their ratios stay where they are. Anything but
	/// a reordering of every leaf is ignored.
	func permuteLeaves(_ order: [Int]) {
		let leaves = leaves
		guard order.count == leaves.count, Set(order) == Set(leaves.indices) else { return }
		let held = leaves.map { (windows: $0.windows, active: $0.active) }
		for (leaf, source) in zip(leaves, order) {
			leaf.windows = held[source].windows
			leaf.active = held[source].active
			for id in leaf.windows {
				leafByWindow[id] = leaf
			}
		}
	}

	// MARK: - Sizes

	/// Moves one edge of a window by `delta` points (positive is right or down). Fails when that
	/// edge is the edge of the whole area, so a caller can try the opposite edge instead.
	@discardableResult
	func resize(_ id: UInt32, edge: Direction, by delta: Double, in area: CGRect, gap: Double) -> Bool {
		guard var child = leafByWindow[id] else { return false }
		let rects = nodeRects(in: area, gap: gap)

		while let parent = child.parent {
			let childIsFirst = parent.first === child

			if parent.axis == edge.axis, childIsFirst != edge.isFirstSide, let rect = rects[ObjectIdentifier(parent)] {
				let size = (edge.axis == .columns ? rect.width : rect.height) - gap
				guard size > 0 else { return false }
				parent.ratio = clamp(parent.ratio + delta / size)
				return true
			}

			child = parent
		}

		return false
	}

	/// Gives a window `size` of the split it is in: its part of the area it shares with its
	/// neighbour, not of the screen.
	@discardableResult
	func setSize(_ id: UInt32, _ size: Double) -> Bool {
		guard let leaf = leafByWindow[id], let parent = leaf.parent else { return false }
		parent.ratio = clamp(parent.first === leaf ? size : 1 - size)
		return true
	}

	/// Every leaf gets the same area along each split.
	func balance() {
		func count(_ node: Node?) -> Int {
			guard let node else { return 0 }
			guard !node.isLeaf else { return 1 }

			let first = count(node.first)
			let second = count(node.second)
			node.ratio = Double(first) / Double(first + second)
			return first + second
		}

		_ = count(root)
	}

	// MARK: - Whole-tree transforms

	/// Turns the layout clockwise by 90, 180 or 270 degrees.
	func rotate(_ degrees: Int) {
		let turns = ((degrees / 90) % 4 + 4) % 4

		for _ in 0..<turns {
			forEachSplit { node in
				// Clockwise, the left column goes to the top and the top row goes to the right.
				if node.axis == .columns {
					node.axis = .rows
				} else {
					node.axis = .columns
					flipChildren(node)
				}
			}
		}
	}

	/// Mirrors the layout: `.columns` swaps left and right, `.rows` swaps top and bottom.
	func mirror(_ axis: Axis) {
		forEachSplit { node in
			if node.axis == axis { flipChildren(node) }
		}
	}

	// MARK: - Zoom

	/// Turns the zoom on, or off when the window already has this zoom. Returns the new state.
	@discardableResult
	func toggleZoom(_ id: UInt32, _ zoom: Zoom) -> Zoom? {
		guard contains(id) else { return nil }
		zoomed[id] = zoomed[id] == zoom ? nil : zoom
		return zoomed[id]
	}

	// MARK: - Stacks

	/// Moves `id` into the leaf of `target`, on top.
	func stack(_ id: UInt32, onto target: UInt32) {
		guard let targetLeaf = leafByWindow[target], leafByWindow[id] !== targetLeaf, contains(id) else { return }

		remove(id)
		targetLeaf.windows.append(id)
		targetLeaf.active = targetLeaf.windows.count - 1
		leafByWindow[id] = targetLeaf
	}

	/// Takes a window out of its stack into a leaf of its own, next to the stack.
	@discardableResult
	func unstack(_ id: UInt32, in area: CGRect, gap: Double) -> Bool {
		guard let leaf = leafByWindow[id], leaf.windows.count > 1 else { return false }

		remove(id)
		insert(id, near: leaf.activeWindow, in: area, gap: gap)
		return true
	}

	/// Brings the next (`by: 1`) or previous (`by: -1`) window of a stack to the front, wrapping
	/// around. Returns the window now in front.
	func cycleStack(of id: UInt32, by step: Int) -> UInt32? {
		guard let leaf = leafByWindow[id], leaf.windows.count > 1 else { return nil }

		let count = leaf.windows.count
		leaf.active = ((leaf.active + step) % count + count) % count
		return leaf.activeWindow
	}

	/// Makes a stacked window the one in front, for when it got focus some other way.
	func activate(_ id: UInt32) {
		guard let leaf = leafByWindow[id], let index = leaf.windows.firstIndex(of: id) else { return }
		leaf.active = index
	}

	// MARK: - Plumbing

	/// Puts a split of `anchor` and `newLeaf` where `anchor` was.
	private func split(_ anchor: Node, with newLeaf: Node, axis: Axis, newFirst: Bool) {
		let parent = anchor.parent
		let node = newFirst
			? Node(axis: axis, first: newLeaf, second: anchor)
			: Node(axis: axis, first: anchor, second: newLeaf)

		attach(node, at: parent, replacing: anchor)
	}

	private func replace(_ old: Node, with new: Node) {
		attach(new, at: old.parent, replacing: old)
	}

	private func attach(_ node: Node, at parent: Node?, replacing old: Node) {
		node.parent = parent

		if let parent {
			if parent.first === old { parent.first = node } else { parent.second = node }
		} else {
			root = node
		}
	}

	private func forEachSplit(_ body: (Node) -> Void) {
		func walk(_ node: Node?) {
			guard let node, !node.isLeaf else { return }
			body(node)
			walk(node.first)
			walk(node.second)
		}
		walk(root)
	}

	private func flipChildren(_ node: Node) {
		Swift.swap(&node.first, &node.second)
		node.ratio = 1 - node.ratio
	}

	private func clamp(_ ratio: Double) -> Double {
		min(Self.maxRatio, max(Self.minRatio, ratio))
	}
}
