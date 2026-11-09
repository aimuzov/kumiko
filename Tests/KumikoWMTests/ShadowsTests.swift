import CoreGraphics
import Foundation
import KumikoCore
import Testing

@testable import KumikoWM

struct ShadowsTests {
	private func window(_ subrole: String?) -> WindowInfo {
		WindowInfo(
			id: 1, pid: 1, app: "Raycast", bundleID: nil, title: "", subrole: subrole, frame: .zero,
			isMinimized: false, isHidden: false, isFullscreen: false, isManaged: false
		)
	}

	@Test func standardWindowsLoseTheirShadow() {
		#expect(Shadows.losesShadow(window("AXStandardWindow")))
	}

	@Test func kumikosOwnWindowsKeepTheirs() {
		var settings = window("AXStandardWindow")
		settings.pid = ProcessInfo.processInfo.processIdentifier
		#expect(!Shadows.losesShadow(settings))
	}

	@Test func panelsAndDialogsKeepTheirs() {
		#expect(!Shadows.losesShadow(window("AXSystemDialog")))
		#expect(!Shadows.losesShadow(window("AXDialog")))
		#expect(!Shadows.losesShadow(window(nil)))
	}
}

struct ShadowChangesTests {
	@Test func retriesAfterTheServerDropsTheTag() {
		var changes = ShadowChanges()
		var suppressed = false
		var writes = 0

		for tag in [false, true, false] {
			suppressed = tag
			changes.reconcile([1: true], read: { _ in suppressed }, write: { _, suppress in
				writes += 1
				suppressed = suppress
				return true
			})
			#expect(suppressed)
		}

		#expect(writes == 2)
	}

	@Test func retriesWhenTheTagWasNeverSet() {
		var changes = ShadowChanges()
		var suppressed = false

		changes.reconcile([1: true], read: { _ in suppressed }, write: { _, _ in true })
		#expect(!suppressed)

		changes.reconcile([1: true], read: { _ in suppressed }, write: { _, suppress in
			suppressed = suppress
			return true
		})
		#expect(suppressed)
	}

	@Test func restoresOnlyShadowsKumikoTook() {
		var changes = ShadowChanges()
		var tags = [1: false, 2: true]
		let read: (UInt32) -> Bool? = { tags[Int($0)] }
		let write: (UInt32, Bool) -> Bool = { id, suppress in
			tags[Int(id)] = suppress
			return true
		}

		changes.reconcile([1: true, 2: true], read: read, write: write)
		changes.reconcile([1: false, 2: false], read: read, write: write)

		#expect(tags == [1: false, 2: true])
	}
}
