import Testing

@testable import KumikoWM

struct WorkspaceReturnTests {
	private func state(_ name: String, display: UInt32, visible: Bool = false, focused: Bool = false) -> WorkspaceState {
		WorkspaceState(name: name, index: 1, display: display, isVisible: visible, isFocused: focused, windows: [])
	}

	/// Calendar's workspace on the same display as the one that had focus.
	@Test func bringsBackTheWorkspaceOfTheSameDisplay() {
		let before = WorkspaceReturn([state("System", display: 1, visible: true, focused: true), state("Plan", display: 1)])
		let after = [state("System", display: 1), state("Plan", display: 1, visible: true, focused: true)]

		#expect(before.steps(from: after) == ["System"])
	}

	/// The click came from the external display, Calendar opened on the main one: both come back,
	/// and focus ends on the display it came from.
	@Test func bringsBackEachDisplayAndEndsWhereFocusWas() {
		let before = WorkspaceReturn([
			state("Code", display: 2, visible: true, focused: true),
			state("System", display: 1, visible: true),
			state("Plan", display: 1),
		])
		let after = [
			state("Code", display: 2, visible: true),
			state("System", display: 1),
			state("Plan", display: 1, visible: true, focused: true),
		]

		#expect(before.steps(from: after) == ["System", "Code"])
	}

	/// Calendar was on a workspace already shown on another display: only focus moves back.
	@Test func onlyFocusComesBackWhenNothingWasReplaced() {
		let before = WorkspaceReturn([state("Code", display: 2, visible: true, focused: true), state("Plan", display: 1, visible: true)])
		let after = [state("Code", display: 2, visible: true), state("Plan", display: 1, visible: true, focused: true)]

		#expect(before.steps(from: after) == ["Code"])
	}

	@Test func nothingToDoWhenNothingChanged() {
		let states = [state("Code", display: 2, visible: true, focused: true), state("Plan", display: 1, visible: true)]
		#expect(WorkspaceReturn(states).steps(from: states).isEmpty)
	}
}
