import CoreGraphics
import Testing

@testable import KumikoWM

struct FrameChangeTests {
	private let old = CGRect(x: 100, y: 100, width: 400, height: 300)

	@Test func aMoveIsNotAResize() {
		#expect(!CGRect(x: 250, y: 180, width: 400, height: 300).isResized(from: old))
	}

	/// The app answers the move with a slightly different size; the splits must not follow it.
	@Test func aMoveWithTheSizeNudgedIsNotAResize() {
		#expect(!CGRect(x: 250, y: 180, width: 405, height: 296).isResized(from: old))
	}

	@Test func pullingEachEdgeIsAResize() {
		#expect(CGRect(x: 60, y: 100, width: 440, height: 300).isResized(from: old))
		#expect(CGRect(x: 100, y: 100, width: 460, height: 300).isResized(from: old))
		#expect(CGRect(x: 100, y: 70, width: 400, height: 330).isResized(from: old))
		#expect(CGRect(x: 100, y: 100, width: 400, height: 350).isResized(from: old))
	}

	@Test func pullingACornerIsAResize() {
		#expect(CGRect(x: 80, y: 100, width: 420, height: 340).isResized(from: old))
	}
}
