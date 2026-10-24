import CoreGraphics
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

	@Test func panelsAndDialogsKeepTheirs() {
		#expect(!Shadows.losesShadow(window("AXSystemDialog")))
		#expect(!Shadows.losesShadow(window("AXDialog")))
		#expect(!Shadows.losesShadow(window(nil)))
	}
}
