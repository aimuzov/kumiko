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
	var mode = "default"
	var window = WindowState.none
	var now = Date()
	var battery: Battery.State?
	var isCaffeinated = false
	var inputSource: String?
	/// The Vim mode of the focused text field, nil outside one, and the command being typed.
	var vimMode: String?
	var vimCommandLine: String?
	var shell: [String: String] = [:]
	/// Called when a workspace entry is clicked.
	var focusWorkspace: (String) -> Void = { _ in }
	var toggleCaffeine: () -> Void = {}
}
