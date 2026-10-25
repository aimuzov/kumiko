import AppKit
import KumikoCore
import SwiftUI

/// The titles of the app's windows open right now, to pick one instead of typing it. Windows that
/// go the other way already are left out.
struct OpenWindowsMenu: View {
	let app: AppRules.App
	let pick: (String) -> Void

	var body: some View {
		let titles = OpenWindows.titles(of: app.name).filter { title in
			!app.exceptions.contains { title.localizedCaseInsensitiveContains($0) }
		}
		Menu {
			ForEach(titles, id: \.self) { title in
				Button(title) { pick(title) }
			}
		} label: {
			Image(systemName: "macwindow")
		}
		.menuStyle(.button)
		.buttonStyle(.bordered)
		.fixedSize()
		.disabled(titles.isEmpty)
		.help(titles.isEmpty ? "\(app.name) has no other windows open" : "Pick one of the windows \(app.name) has open")
	}
}

/// What Accessibility tells about the windows an app has open.
@MainActor
enum OpenWindows {
	/// By title, each once, in the order the app lists its windows. An app that does not answer
	/// within a moment has none: the page must not hang on it.
	static func titles(of app: String) -> [String] {
		var seen = Set<String>()
		return NSWorkspace.shared.runningApplications.filter { $0.localizedName == app }.flatMap { running in
			let element = AXUIElementCreateApplication(running.processIdentifier)
			AXUIElementSetMessagingTimeout(element, 0.2)
			var windows: CFTypeRef?
			guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
			      let windows = windows as? [AXUIElement]
			else { return [String]() }
			return windows.compactMap { window -> String? in
				var title: CFTypeRef?
				AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
				return title as? String
			}
		}
		.filter { !$0.isEmpty && seen.insert($0).inserted }
	}
}
