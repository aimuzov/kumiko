import CoreGraphics

extension CGRect {
	/// Whether the user got from `old` to this frame by pulling an edge rather than by moving the
	/// window: a resize leaves the opposite edge where it was, a move takes both along. A size the
	/// app nudges by a few points during a move does not make it a resize, whichever axis it is on.
	func isResized(from old: CGRect) -> Bool {
		func axis(_ edges: (CGFloat, CGFloat), old oldEdges: (CGFloat, CGFloat)) -> (resized: Bool, held: Bool) {
			let minHeld = abs(edges.0 - oldEdges.0) <= 2
			let maxHeld = abs(edges.1 - oldEdges.1) <= 2
			let resized = abs((edges.1 - edges.0) - (oldEdges.1 - oldEdges.0)) > 2
			// An axis that kept its size must also have stayed in place: one that moved is a drag.
			return (resized, resized ? minHeld || maxHeld : minHeld)
		}

		let x = axis((minX, maxX), old: (old.minX, old.maxX))
		let y = axis((minY, maxY), old: (old.minY, old.maxY))
		return (x.resized || y.resized) && x.held && y.held
	}
}
