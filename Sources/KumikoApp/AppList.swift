import AppKit
import SwiftUI

/// A card of apps something stays out of, like Vim's or the borders' exceptions: a row per app
/// with a button to take it out, and a menu to add one.
struct AppListCard: View {
	let title: String
	/// What the card says while the list is empty.
	let empty: String
	let apps: [String]
	/// The help of an app's remove button, given the app.
	let removeHelp: (String) -> String
	let set: ([String]) -> Void

	var body: some View {
		Card(title: title) {
			if apps.isEmpty {
				Row(title: empty, last: false) { EmptyView() }
			}
			ForEach(apps, id: \.self) { app in
				AppListRow(app: app, help: removeHelp(app)) { set(apps.filter { $0 != app }) }
			}
			HStack {
				Spacer()
				AddAppMenu(listed: apps) { set(apps + [$0]) }
			}
			.padding(.vertical, 10)
		}
	}
}

/// An app in the list, with its icon, as the Workspaces and Window Rules pages show apps.
private struct AppListRow: View {
	let app: String
	let help: String
	let remove: () -> Void

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				if let icon = AppIcon.image(for: app, size: 20) {
					Image(nsImage: icon)
				} else {
					Image(systemName: "app.dashed")
						.foregroundStyle(.secondary)
						.frame(width: 20, height: 20)
				}
				Text(app)
				Spacer()
				RemoveButton(name: app, help: help, remove: remove)
			}
			.padding(.vertical, 8)
			Divider()
		}
	}
}

struct RemoveButton: View {
	/// What VoiceOver says is removed; just "Remove" without it.
	var name: String?
	let help: String
	let remove: () -> Void

	var body: some View {
		Button(action: remove) {
			Image(systemName: "minus.circle.fill")
				.symbolRenderingMode(.palette)
				.foregroundStyle(.white, .red)
				.accessibilityLabel(name.map { "Remove \($0)" } ?? "Remove")
		}
		.buttonStyle(.borderless)
		.help(help)
	}
}

/// The running apps not listed yet, and a way to pick one in /Applications.
private struct AddAppMenu: View {
	let listed: [String]
	let add: (String) -> Void

	var body: some View {
		Menu {
			ForEach(AddAppButton.running(excluding: listed), id: \.self) { app in
				Button { add(app) } label: {
					if let icon = AppIcon.image(for: app, size: 16) {
						Label { Text(app) } icon: { Image(nsImage: icon) }
					} else {
						Text(app)
					}
				}
			}
			Divider()
			Button("Choose…") {
				if let app = AddAppButton.chooseApp(), !listed.contains(app) { add(app) }
			}
		} label: {
			Label("Add App", systemImage: "plus")
		}
		.menuStyle(.button)
		.buttonStyle(.bordered)
		.controlSize(.small)
		.fixedSize()
	}
}
