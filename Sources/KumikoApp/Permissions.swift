import AppKit
import ApplicationServices

/// The two TCC permissions kumiko needs: Accessibility to move other apps' windows, Input
/// Monitoring for the hotkey event tap.
enum Permission: CaseIterable {
	case accessibility
	case inputMonitoring

	var title: String {
		switch self {
		case .accessibility: "Accessibility"
		case .inputMonitoring: "Input Monitoring"
		}
	}

	/// Why kumiko asks, in the warning on a settings page that needs it.
	var reason: String {
		switch self {
		case .accessibility: "Allow kumiko to use Accessibility to see, move and focus the windows of other apps."
		case .inputMonitoring: "Allow kumiko to use Input Monitoring to hear the hotkeys and Vim keys you press."
		}
	}

	var isGranted: Bool {
		switch self {
		case .accessibility: AXIsProcessTrusted()
		case .inputMonitoring: CGPreflightListenEventAccess()
		}
	}

	static var missing: [Permission] {
		allCases.filter { !$0.isGranted }
	}

	/// Puts kumiko into the list in System Settings and opens the right pane. macOS only adds an
	/// app to these lists after it has asked once, so the request comes before the pane.
	func request() {
		switch self {
		case .accessibility:
			let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
			_ = AXIsProcessTrustedWithOptions(options)
		case .inputMonitoring:
			_ = CGRequestListenEventAccess()
		}

		NSWorkspace.shared.open(settingsURL)
	}

	private var settingsURL: URL {
		let anchor = switch self {
		case .accessibility: "Privacy_Accessibility"
		case .inputMonitoring: "Privacy_ListenEvent"
		}

		return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
	}
}
