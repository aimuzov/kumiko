import CoreGraphics
import KumikoCore

/// A virtual desktop: its own layout tree and the windows assigned to it. Only one workspace per
/// display is shown at a time; the windows of the others wait in a corner of the screen.
@MainActor
final class Workspace {
	var config: Config.Workspace
	/// Resolved from `config.display` on every pass, since screens come and go.
	var display: Display
	let tree = BSPTree()
	/// The window to focus when the workspace is shown again.
	var lastFocused: UInt32?

	var name: String { config.name }

	init(config: Config.Workspace, display: Display) {
		self.config = config
		self.display = display
	}
}

/// What `query workspaces` prints.
public struct WorkspaceState: Encodable, Sendable {
	public let name: String
	/// 1-based, the number `workspace focus <n>` takes.
	public let index: Int
	public let display: UInt32
	/// Shown on its display.
	public let isVisible: Bool
	/// Holds the focused window (or is the one shown where focus is, when no window has it).
	public let isFocused: Bool
	public let windows: [UInt32]
}

/// What `query displays` prints.
public struct DisplayState: Encodable, Sendable {
	public let id: UInt32
	public let name: String
	public let isBuiltin: Bool
	public let frame: CGRect
	/// The workspace shown on it.
	public let workspace: String?
}
