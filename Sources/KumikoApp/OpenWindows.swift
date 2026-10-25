import AppKit
import KumikoCore
import SwiftUI

/// The app's windows open right now, to pick one instead of typing it: by title, or by what the
/// app calls the window, which is all a window with no title has. Windows that go the other way
/// already are left out.
struct OpenWindowsMenu: View {
	/// What a pick adds to the exceptions.
	enum Pick {
		case title(String)
		case id(String)
	}

	let app: AppRules.App
	let pick: (Pick) -> Void

	var body: some View {
		let windows = OpenWindows.windows(of: app.name).filter { window in
			!app.exceptions.contains { window.title.localizedCaseInsensitiveContains($0) }
				&& !app.idExceptions.contains { window.id?.localizedCaseInsensitiveContains($0) == true }
		}
		let titled = windows.filter { !$0.title.isEmpty }
		let identified = windows.filter { $0.id != nil }

		Menu {
			if !titled.isEmpty {
				Section("By Title") {
					ForEach(titled, id: \.self) { window in
						Button(window.title) { pick(.title(window.title)) }
					}
				}
			}
			if !identified.isEmpty {
				Section("By Window ID") {
					ForEach(identified, id: \.self) { window in
						Button("\(window.id ?? "") — \(window.title.isEmpty ? "no title" : window.title)") {
							if let id = window.id { pick(.id(id)) }
						}
					}
				}
			}
		} label: {
			Image(systemName: "macwindow")
		}
		.menuStyle(.button)
		.buttonStyle(.bordered)
		.fixedSize()
		.disabled(windows.isEmpty)
		.help(windows.isEmpty ? "\(app.name) has no other windows open" : "Pick one of the windows \(app.name) has open")
	}
}

/// What Accessibility tells about the windows an app has open.
@MainActor
enum OpenWindows {
	struct Window: Hashable {
		var title: String
		/// `AXIdentifier`, what the app calls the window.
		var id: String?
	}

	/// Each once, in the order the app lists its windows. An app that does not answer within a
	/// moment has none: the page must not hang on it.
	static func windows(of app: String) -> [Window] {
		var seen = Set<Window>()
		return NSWorkspace.shared.runningApplications.filter { $0.localizedName == app }.flatMap { running in
			let element = AXUIElementCreateApplication(running.processIdentifier)
			AXUIElementSetMessagingTimeout(element, 0.2)
			var windows: CFTypeRef?
			guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
			      let windows = windows as? [AXUIElement]
			else { return [Window]() }
			return windows.map { window in
				Window(title: string(window, kAXTitleAttribute) ?? "", id: string(window, kAXIdentifierAttribute))
			}
		}
		.filter { (!$0.title.isEmpty || $0.id != nil) && seen.insert($0).inserted }
	}

	private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
		var value: CFTypeRef?
		AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
		return (value as? String).flatMap { $0.isEmpty ? nil : $0 }
	}
}
