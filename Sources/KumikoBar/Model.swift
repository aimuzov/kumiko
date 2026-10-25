import Foundation
import KumikoCore
import Observation

/// Everything the bars show, kept current by `Bar`; the views only read it.
@MainActor
@Observable
final class BarModel {
	struct Workspace: Identifiable, Equatable {
		var name: String
		var index: Int
		var display: UInt32
		var isVisible: Bool
		/// The apps of its windows, each once, in the order they were first seen.
		var apps: [App]
		var id: String { name }
	}

	struct App: Equatable, Identifiable {
		var name: String
		var pid: pid_t
		var id: pid_t { pid }
	}

	enum WindowState: Equatable {
		case none
		case floating
		case fullscreenZoom
		case parentZoom
		case stacked(index: Int, count: Int)
	}

	var config = Config.Bar()
	var workspaces: [Workspace] = []
	/// Off with workspaces off: a display's only workspace has no other to be told from, so it
	/// shows its apps alone.
	var showsNumbers = true
	var mode = "default"
	var window = WindowState.none
	var now = Date()
	var battery: Battery.State?
	var isCaffeinated = false
	var inputSource: String?
	/// "EN", "RU": what the layout item shows when the config has no glyph for the source.
	var inputLanguage: String?
	/// The Vim mode of the focused text field, nil outside one, and the command being typed.
	var vimMode: String?
	var vimCommandLine: String?
	var shell: [String: String] = [:]
	/// What the macOS menu bar shows already, which the bar then leaves out.
	var menuBar = SystemMenuBar()

	/// The items of one side, without those the menu bar shows itself while the config follows it.
	func items(_ names: [String]) -> [String] {
		config.followMenuBar ? names.filter { !menuBar.shows($0) } : names
	}

	/// Called when a workspace entry is clicked.
	var focusWorkspace: (String) -> Void = { _ in }
	/// Whether the bar offers a plus after the workspaces; see `WindowManager.canAddWorkspace`.
	var canAddWorkspace = false
	/// The display whose plus is under the pointer. Here and not in @State, as `pointer` is.
	var hoveredPlus: UInt32?
	/// The display whose bar is under the pointer: the plus shows only there.
	var hoveredBar: UInt32?
	/// Called with the bar's display when its plus is clicked.
	var addWorkspace: (UInt32) -> Void = { _ in }
	/// Called when an empty workspace is clicked.
	var showWorkspace: (String) -> Void = { _ in }
	/// The pointer over a workspace's icons. The icon under it shows in colour on a hidden workspace
	/// too. Here and not in @State, which needs a plugin only Xcode ships.
	struct Pointer: Equatable {
		var workspace: String
		/// How far along the row it is, from the row's leading edge.
		var x: Double
		/// How large the icon right under it grows; nil when the icons do not magnify.
		var largest: Double?
		/// False while magnified icons grow from or settle back to their own size: just in, before
		/// they start growing, and just out, until they are back.
		var isOver: Bool
	}

	var pointer: Pointer?
	/// The workspace the pointer is over, number and icons alike.
	var hoveredWorkspace: String?
	/// The item on the right the pointer is over, as `ItemHover` names it.
	var hoveredItem: String?
	/// Where each workspace's row of icons sits in its bar, in the bar's coordinates; magnified
	/// icons are drawn over the windows from there.
	var iconRows: [String: CGRect] = [:]
	/// Called when an app's icon is clicked, with the workspace it was clicked in.
	var focusApp: (pid_t, String) -> Void = { _, _ in }
	var toggleCaffeine: () -> Void = {}
	/// Called when the input source item is clicked.
	var switchInputSource: () -> Void = {}
	/// The battery's percentage shown next to it.
	var showsBatteryPercent = false
	var toggleBatteryPercent: () -> Void = {}
	/// The label over the bar for the item under the pointer.
	var tooltip: Tooltip?
	/// What each item's label says, made afresh each time the label is drawn.
	var tooltipTexts: [String: @MainActor () -> String?] = [:]
	/// How far each item's label goes up above its usual place.
	var tooltipRaises: [String: @MainActor () -> Double] = [:]
	/// Where each item with a tooltip sits in its bar, by the item's key.
	var itemFrames: [String: CGRect] = [:]
	/// The label's own width, to keep it inside the screen.
	var tooltipWidth = 0.0
}
