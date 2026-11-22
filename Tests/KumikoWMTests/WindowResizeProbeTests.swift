import CoreGraphics
import KumikoCore
@testable import KumikoWM
import Testing

struct WindowResizeProbeTests {
	@Test(arguments: [true, false])
	func fixedWidth(_ atMinimum: Bool) {
		var size = CGSize(width: 700, height: atMinimum ? 500 : 900)
		let original = size
		let axes = WindowResizeProbe.measure(
			read: { size },
			write: { requested in
				size.height = min(max(requested.height, 500), 900)
				return true
			}
		)
		#expect(axes == WindowResizeAxes(width: false, height: true))
		#expect(size == original)
	}

	@Test func fixedHeight() {
		var size = CGSize(width: 700, height: 500)
		let original = size
		let axes = WindowResizeProbe.measure(read: { size }, write: { size.width = $0.width; return true })
		#expect(axes == WindowResizeAxes(width: true, height: false))
		#expect(size == original)
	}

	@Test func bothAxes() {
		var size = CGSize(width: 700, height: 500)
		let original = size
		let axes = WindowResizeProbe.measure(read: { size }, write: { size = $0; return true })
		#expect(axes == WindowResizeAxes(width: true, height: true))
		#expect(size == original)
	}

	@Test func neitherAxis() {
		let size = CGSize(width: 700, height: 500)
		#expect(WindowResizeProbe.measure(read: { size }, write: { _ in true }) == WindowResizeAxes(width: false, height: false))
	}

	@Test func resizeIncrementsAreNotAFixedAxis() {
		var size = CGSize(width: 704, height: 504)
		let original = size
		let axes = WindowResizeProbe.measure(read: { size }, write: { requested in
			size.width = (requested.width / 8).rounded() * 8
			size.height = (requested.height / 8).rounded() * 8
			return true
		})
		#expect(axes == WindowResizeAxes(width: true, height: true))
		#expect(size == original)
	}

	@Test func windowAtMaximumSizeRejectsGrowthButAcceptsShrinkage() {
		let original = CGSize(width: 1453, height: 897)
		var size = original
		let axes = WindowResizeProbe.measure(read: { size }, write: { requested in
			guard requested.width <= original.width, requested.height <= original.height else { return false }
			size = requested
			return true
		})
		#expect(axes == WindowResizeAxes(width: true, height: true))
		#expect(size == original)
	}

	@Test func diaAppliesProbeAndRestoreDespiteReportingWriteErrors() {
		let original = CGSize(width: 1169, height: 757)
		var size = original
		let axes = WindowResizeProbe.measure(read: { size }, write: { requested in
			var next: CGSize?
			return WindowResizeProbe.write(requested, set: { next = $0; return false }, read: { size }, wait: {
				if let next { size = next }
			})
		})
		#expect(axes == WindowResizeAxes(width: true, height: true))
		#expect(size == original)
	}

	@Test func rejectedSizeThatNeverArrivesIsStillUnknown() {
		let original = CGSize(width: 1169, height: 757)
		let axes = WindowResizeProbe.measure(read: { original }, write: { requested in
			WindowResizeProbe.write(requested, set: { _ in false }, read: { original }, wait: {})
		})
		#expect(axes == nil)
	}

	@Test func failedWriteIsUnknown() {
		var size = CGSize(width: 700, height: 500)
		let original = size
		let axes = WindowResizeProbe.measure(read: { size }, write: { requested in
			if requested.height != original.height { return false }
			size = requested
			return true
		})
		#expect(axes == nil)
		#expect(size == original)
	}

	@Test func failedReadRestoresSize() {
		var size = CGSize(width: 700, height: 500)
		let original = size
		let axes = WindowResizeProbe.measure(read: { size == original ? size : nil }, write: { size = $0; return true })
		#expect(axes == nil)
		#expect(size == original)
	}

	@Test func cancelledCheckDoesNotResize() {
		var writes = 0
		let result = WindowResizeProbe.measure(
			read: { CGSize(width: 700, height: 500) },
			write: { _ in writes += 1; return true },
			cancelled: { true }
		)
		#expect(result == nil)
		#expect(writes == 0)
	}

	@Test func cancellationAfterResizeRestoresOriginalSize() {
		var size = CGSize(width: 700, height: 500)
		let original = size
		var cancelled = false
		let result = WindowResizeProbe.measure(
			read: { size },
			write: { size = $0; cancelled = true; return true },
			cancelled: { cancelled }
		)
		#expect(result == nil)
		#expect(size == original)
	}

	@Test func userResizeTakesOwnershipOfTheFrame() {
		var size = CGSize(width: 700, height: 500)
		let userSize = CGSize(width: 800, height: 600)
		var intervened = false
		let result = WindowResizeProbe.measure(
			read: { size },
			write: { _ in size = userSize; intervened = true; return true },
			cancelled: { intervened },
			restoreAllowed: { !intervened }
		)
		#expect(result == nil)
		#expect(size == userSize)
	}

	@Test func unrelatedClickStillRestoresTheProbeSize() {
		var size = CGSize(width: 700, height: 500)
		let original = size
		var clicked = false
		let result = WindowResizeProbe.measure(
			read: { size },
			write: { size = $0; clicked = true; return true },
			cancelled: { clicked },
			restoreAllowed: { size == CGSize(width: 701, height: 500) }
		)
		#expect(result == nil)
		#expect(size == original)
	}
}
