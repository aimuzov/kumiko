import CoreGraphics

extension CGRect {
	/// Whether the user got from `old` to this frame by pulling an edge rather than by moving the
	/// window: a resize leaves the opposite edge where it was, a move takes both along. A size the
	/// app nudges by a few points during a move does not make it a resize.
	func isResized(from old: CGRect) -> Bool {
		func pulled(_ size: CGFloat, _ oldSize: CGFloat, edges: (CGFloat, CGFloat), old oldEdges: (CGFloat, CGFloat)) -> Bool {
			abs(size - oldSize) > 2 && (abs(edges.0 - oldEdges.0) <= 2 || abs(edges.1 - oldEdges.1) <= 2)
		}

		return pulled(width, old.width, edges: (minX, maxX), old: (old.minX, old.maxX))
			|| pulled(height, old.height, edges: (minY, maxY), old: (old.minY, old.maxY))
	}
}
