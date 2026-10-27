import CoreGraphics
import Testing

@testable import KumikoWM

struct DisplayTests {
	private let area = CGRect(x: 0, y: 30, width: 1000, height: 700)

	@Test func leavesAWindowInsideAlone() {
		let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
		#expect(Display.clamped(frame, into: area) == frame)
	}

	@Test func pullsBackAWindowPastTheRightAndBottomEdges() {
		let frame = CGRect(x: 800, y: 600, width: 400, height: 300)
		#expect(Display.clamped(frame, into: area) == CGRect(x: 600, y: 430, width: 400, height: 300))
	}

	@Test func pullsBackAWindowPastTheLeftAndTopEdges() {
		let frame = CGRect(x: -150, y: 0, width: 400, height: 300)
		#expect(Display.clamped(frame, into: area) == CGRect(x: 0, y: 30, width: 400, height: 300))
	}

	/// No place fits it, so the title bar and the left edge stay on screen.
	@Test func pinsAWindowLargerThanTheAreaToTheTopLeft() {
		let frame = CGRect(x: 300, y: 200, width: 1200, height: 900)
		#expect(Display.clamped(frame, into: area) == CGRect(x: 0, y: 30, width: 1200, height: 900))
	}
}
