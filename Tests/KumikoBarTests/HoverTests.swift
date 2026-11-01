import Foundation
import Testing

@testable import KumikoBar

@MainActor
struct HoverTests {
	@Test func leavingBarClearsMagnifiedIconsAndTooltips() {
		let model = BarModel()
		model.pointer = BarModel.Pointer(workspace: "1", x: 10, largest: 64, isOver: true)
		model.hoveredWorkspace = "1"
		model.hoveredItem = "1 battery"
		model.hoveredPlus = 1
		model.hoveredBar = 1
		model.tooltip = Tooltip(key: "1:workspace:1", display: 1, frame: .zero)

		model.resetHover()

		#expect(model.pointer == nil)
		#expect(model.hoveredWorkspace == nil)
		#expect(model.hoveredItem == nil)
		#expect(model.hoveredPlus == nil)
		#expect(model.hoveredBar == nil)
		#expect(model.tooltip == nil)
	}

	@Test func switchingWorkspaceKeepsAddButtonVisibleWhilePointerIsOnBar() {
		let model = BarModel()
		model.hoveredBar = 1
		model.pointer = BarModel.Pointer(workspace: "1", x: 10, largest: 64, isOver: true)
		model.hoveredWorkspace = "1"
		model.hoveredItem = "1 battery"
		model.hoveredPlus = 1
		let tooltip = Tooltip(key: "1:battery", display: 1, frame: .zero)
		model.tooltip = tooltip

		model.resetWorkspaceHover()

		#expect(model.hoveredBar == 1)
		#expect(model.pointer == nil)
		#expect(model.hoveredWorkspace == nil)
		#expect(model.hoveredItem == "1 battery")
		#expect(model.hoveredPlus == 1)
		#expect(model.tooltip == tooltip)
	}

	@Test func switchingWorkspaceClearsItsTooltip() {
		let model = BarModel()
		model.tooltip = Tooltip(key: "1:workspace:1", display: 1, frame: .zero)
		model.resetWorkspaceHover()
		#expect(model.tooltip == nil)
	}
}
