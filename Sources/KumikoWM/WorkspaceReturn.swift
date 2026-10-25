/// Where to come back to after a trip to another app's workspace, as the bar clock's second click
/// does: what each display showed, and which workspace had focus.
public struct WorkspaceReturn: Equatable, Sendable {
	let shown: [UInt32: String]
	let focused: String?

	public init(_ states: [WorkspaceState]) {
		shown = Dictionary(states.filter(\.isVisible).map { ($0.display, $0.name) }) { first, _ in first }
		focused = states.first(where: \.isFocused)?.name
	}

	/// The workspaces to focus, in order, to get back: those of the displays that show another
	/// workspace now, then the one that had focus, so focus ends where it was.
	public func steps(from states: [WorkspaceState]) -> [String] {
		let now = WorkspaceReturn(states)
		var steps = shown.filter { now.shown[$0.key] != $0.value && $0.value != focused }.map(\.value).sorted()
		if let focused, now.focused != focused || shown.contains(where: { now.shown[$0.key] != $0.value }) {
			steps.append(focused)
		}
		return steps
	}
}
