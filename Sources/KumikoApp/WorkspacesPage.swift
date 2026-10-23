import AppKit
import KumikoCore
import SwiftUI
import UniformTypeIdentifiers

/// The lists of a workspace an app can be in.
enum AppList: String, CaseIterable {
	case apps, stack, last

	var keyPath: KeyPath<Config.Workspace, [String]> {
		switch self {
		case .apps: \.apps
		case .stack: \.stack
		case .last: \.last
		}
	}
}

/// A value `display` can say, with what the menu calls it.
struct DisplayChoice: Hashable {
	let value: String
	let title: String

	/// The keywords and the screens attached now. A value none of them is, part of a name, is
	/// kept as written, so opening the menu changes nothing.
	@MainActor
	static func all(current: String) -> [DisplayChoice] {
		var choices = [
			DisplayChoice(value: "main", title: "Main"), DisplayChoice(value: "builtin", title: "Built-in"),
			DisplayChoice(value: "external", title: "External"),
		] + NSScreen.screens.map { DisplayChoice(value: $0.localizedName, title: $0.localizedName) }
		if !choices.contains(where: { $0.value == current }) {
			choices.append(DisplayChoice(value: current, title: current))
		}
		return choices
	}

	@MainActor
	static func title(of value: String) -> String {
		all(current: value).first { $0.value == value }?.title ?? value
	}
}

extension SettingsModel {
	var workspaces: [Config.Workspace] { config.workspaces }

	var selected: Config.Workspace? {
		workspaces.indices.contains(selectedWorkspace) ? workspaces[selectedWorkspace] : nil
	}

	func setWorkspace(_ index: Int, _ key: String, _ value: TOMLValue?) {
		change([ConfigEdit(target: .entry("workspace", index), key: key, value: value)])
	}

	/// An empty or taken name is refused by the config check and shows as the write's error.
	func renameWorkspace(_ index: Int, to name: String) {
		let name = name.trimmingCharacters(in: .whitespaces)
		let old = workspaces[index].name
		guard name != old else { return }
		onRenameWorkspace(old, name)
		setWorkspace(index, "name", .string(name))
	}

	/// Only the first default counts, so turning one on turns the others off.
	func setDefault(_ index: Int, _ on: Bool) {
		var changes: [any ConfigChange] = [
			ConfigEdit(target: .entry("workspace", index), key: "default", value: on ? .bool(true) : nil),
		]
		if on {
			for (other, workspace) in workspaces.enumerated() where other != index && workspace.isDefault {
				changes.append(ConfigEdit(target: .entry("workspace", other), key: "default", value: nil))
			}
		}
		change(changes)
	}

	/// Every app a workspace names, in the order they first come up.
	func apps(of workspace: Config.Workspace) -> [String] {
		var seen: [String] = []
		for app in workspace.apps + workspace.stack + workspace.last + workspace.share.keys.sorted()
		where !seen.contains(app) {
			seen.append(app)
		}
		return seen
	}

	func setApp(_ app: String, _ list: AppList, _ on: Bool, of index: Int) {
		change([listEdit(index, list, on: on, app)])
	}

	func setShare(_ app: String, _ share: Double?, of index: Int) {
		var shares = workspaces[index].share
		shares[app] = share
		change([shareEdit(index, shares)])
	}

	/// Out of all four, in one write.
	func removeApp(_ app: String, of index: Int) {
		let workspace = workspaces[index]
		var changes: [any ConfigChange] = AppList.allCases
			.filter { workspace[keyPath: $0.keyPath].contains(app) }
			.map { listEdit(index, $0, on: false, app) }
		if workspace.share[app] != nil {
			var shares = workspace.share
			shares[app] = nil
			changes.append(shareEdit(index, shares))
		}
		change(changes)
	}

	func addWorkspace() {
		let names = Set(workspaces.map(\.name))
		let name = ((workspaces.count + 1)...).lazy.map { "Workspace \($0)" }.first { !names.contains($0) }!
		change([EntryEdit.insert("workspace", fields: Config.Workspace(name: name).tomlFields)])
		selectedWorkspace = workspaces.count - 1
	}

	func removeWorkspace(_ index: Int) {
		change([EntryEdit.remove("workspace", index)])
		selectedWorkspace = min(selectedWorkspace, max(workspaces.count - 1, 0))
	}

	/// What `onMove` gives: the rows taken and the place before which they go, counted before they
	/// are taken out. The list moves one row at a time.
	func moveWorkspaces(from source: IndexSet, to offset: Int) {
		guard let from = source.first else { return }
		let to = offset > from ? offset - 1 : offset
		guard to != from else { return }

		let name = selected?.name
		change([EntryEdit.move("workspace", from: from, to: to)])
		if let name, let index = workspaces.firstIndex(where: { $0.name == name }) {
			selectedWorkspace = index
		}
	}

	/// The built-in nine, written out so they can be changed.
	func customizeWorkspaces() {
		change((1...9).map { EntryEdit.insert("workspace", fields: Config.Workspace(name: String($0)).tomlFields) })
		selectedWorkspace = 0
	}

	/// An empty list leaves the file: no key and an empty array mean the same.
	private func listEdit(_ index: Int, _ list: AppList, on: Bool, _ app: String) -> ConfigEdit {
		let current = workspaces[index][keyPath: list.keyPath]
		let apps = on ? (current.contains(app) ? current : current + [app]) : current.filter { $0 != app }
		return ConfigEdit(
			target: .entry("workspace", index), key: list.rawValue,
			value: apps.isEmpty ? nil : .array(apps.map(TOMLValue.string))
		)
	}

	private func shareEdit(_ index: Int, _ shares: [String: Double]) -> ConfigEdit {
		ConfigEdit(
			target: .entry("workspace", index), key: "share",
			value: shares.isEmpty ? nil : Config.Workspace.shareValue(shares, order: workspaces[index].apps)
		)
	}
}

struct WorkspacesPage: View {
	@ObservedObject var model: SettingsModel

	var body: some View {
		if model.workspaces.isEmpty {
			Card {
				Row(
					title: "1…9 on the main display",
					detail: "The built-in workspaces. Customize writes them to kumiko.toml, where they can be changed.",
					last: true
				) {
					Button("Customize") { model.customizeWorkspaces() }
				}
			}
		} else {
			WorkspaceList(model: model)

			if let workspace = model.selected {
				Group {
					WorkspaceCard(model: model, index: model.selectedWorkspace, workspace: workspace)
					AppsCard(model: model, index: model.selectedWorkspace, workspace: workspace)
				}
				// A field being typed in belongs to its own workspace, not to the next one selected.
				.id(model.selectedWorkspace)
			}
		}
	}
}

/// The workspaces in file order, which is the order `workspace focus <n>` counts them in.
private struct WorkspaceList: View {
	@ObservedObject var model: SettingsModel

	private static let rowHeight = 28.0

	var body: some View {
		Card(title: "Workspaces") {
			List(selection: selection) {
				ForEach(Array(model.workspaces.enumerated()), id: \.offset) { index, workspace in
					HStack {
						Text("\(index + 1)")
							.monospacedDigit()
							.foregroundStyle(.secondary)
							.frame(width: 20, alignment: .trailing)
						Text(workspace.name)
						Spacer()
						Text(DisplayChoice.title(of: workspace.display))
							.foregroundStyle(.secondary)
						Text(appCount(workspace))
							.foregroundStyle(.secondary)
							.frame(width: 64, alignment: .trailing)
					}
					.frame(height: Self.rowHeight)
					.tag(index)
				}
				.onMove { model.moveWorkspaces(from: $0, to: $1) }
			}
			.listStyle(.plain)
			.scrollContentBackground(.hidden)
			.scrollDisabled(true)
			// A list inside the page's scroll view has no height of its own.
			.frame(height: Double(model.workspaces.count) * (Self.rowHeight + 4) + 8)

			HStack {
				Spacer()
				Button { model.addWorkspace() } label: { Image(systemName: "plus") }
				Button { model.confirmingWorkspaceRemoval = true } label: { Image(systemName: "minus") }
					.disabled(model.selected == nil)
			}
			.buttonStyle(.borderless)
			.padding(.vertical, 8)
		}
		.confirmationDialog("Remove \(model.selected?.name ?? "")?", isPresented: $model.confirmingWorkspaceRemoval) {
			Button("Remove", role: .destructive) { model.removeWorkspace(model.selectedWorkspace) }
		} message: {
			Text("Its windows are placed on the other workspaces again.")
		}
	}

	private var selection: Binding<Int?> {
		Binding(get: { model.selectedWorkspace }, set: { model.selectedWorkspace = $0 ?? 0 })
	}

	private func appCount(_ workspace: Config.Workspace) -> String {
		if workspace.isDefault { return "default" }
		return workspace.apps.count == 1 ? "1 app" : "\(workspace.apps.count) apps"
	}
}

private struct WorkspaceCard: View {
	@ObservedObject var model: SettingsModel
	let index: Int
	let workspace: Config.Workspace

	var body: some View {
		Card(title: workspace.name) {
			Row(title: "Name") {
				TextField(
					"",
					value: Binding(get: { workspace.name }, set: { model.renameWorkspace(index, to: $0) }),
					format: Verbatim()
				)
				.textFieldStyle(.roundedBorder)
				.frame(width: 200)
			}
			Row(title: "Display") {
				Picker(
					"",
					selection: Binding(
						get: { workspace.display }, set: { model.setWorkspace(index, "display", .string($0)) }
					)
				) {
					ForEach(DisplayChoice.all(current: workspace.display), id: \.self) { Text($0.title).tag($0.value) }
				}
				.labelsHidden()
				.fixedSize()
			}
			SwitchRow(
				title: "Default",
				detail: "Windows of apps no workspace names open here.",
				on: Binding(get: { workspace.isDefault }, set: { model.setDefault(index, $0) }),
				last: true
			)
		}
	}
}

private struct AppsCard: View {
	@ObservedObject var model: SettingsModel
	let index: Int
	let workspace: Config.Workspace

	var body: some View {
		Card(title: "Apps") {
			ForEach(model.apps(of: workspace), id: \.self) { app in
				AppRow(model: model, index: index, workspace: workspace, app: app)
			}

			HStack {
				Menu("Add App…") {
					ForEach(Self.running(excluding: model.apps(of: workspace)), id: \.self) { app in
						Button { model.setApp(app, .apps, true, of: index) } label: {
							if let icon = AppIcon.image(for: app, size: 16) {
								Label { Text(app) } icon: { Image(nsImage: icon) }
							} else {
								Text(app)
							}
						}
					}
					Divider()
					Button("Choose…") {
						if let app = Self.chooseApp() { model.setApp(app, .apps, true, of: index) }
					}
				}
				.fixedSize()
				Spacer()
			}
			.padding(.vertical, 10)
		}
	}

	/// Apps with a Dock icon, the ones whose windows kumiko arranges, that the workspace does not name yet.
	private static func running(excluding listed: [String]) -> [String] {
		let names = NSWorkspace.shared.runningApplications
			.filter { $0.activationPolicy == .regular }
			.compactMap(\.localizedName)
		return Array(Set(names)).filter { !listed.contains($0) }.sorted()
	}

	/// An app picked in /Applications, by the name its windows carry.
	private static func chooseApp() -> String? {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.application]
		panel.directoryURL = URL(filePath: "/Applications")
		guard panel.runModal() == .OK, let url = panel.url else { return nil }
		let name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
		return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
	}
}

private struct AppRow: View {
	@ObservedObject var model: SettingsModel
	let index: Int
	let workspace: Config.Workspace
	let app: String

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 10) {
				if let icon = AppIcon.image(for: app) {
					Image(nsImage: icon).resizable().frame(width: 18, height: 18)
				} else {
					Spacer().frame(width: 18)
				}
				Text(app)
					.lineLimit(1)
					.truncationMode(.tail)
				Spacer(minLength: 8)
				toggle("Opens here", .apps)
				toggle("One stack", .stack)
				toggle("Last", .last)
				TextField(
					"Share",
					value: Binding(
						get: { workspace.share[app] },
						set: { model.setShare(app, $0.map { min(max($0, 0.1), 0.9) }, of: index) }
					),
					format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
				)
				.textFieldStyle(.roundedBorder)
				.frame(width: 52)
				.help("The share of its split the app's window gets, 0.1 to 0.9")
				Button { model.removeApp(app, of: index) } label: { Image(systemName: "minus.circle") }
					.buttonStyle(.borderless)
					.foregroundStyle(.secondary)
					.help("Take \(app) out of this workspace")
			}
			.controlSize(.small)
			.padding(.vertical, 8)

			Divider()
		}
	}

	private func toggle(_ title: String, _ list: AppList) -> some View {
		Toggle(
			title,
			isOn: Binding(
				get: { workspace[keyPath: list.keyPath].contains(app) },
				set: { model.setApp(app, list, $0, of: index) }
			)
		)
		.toggleStyle(.checkbox)
	}
}

/// An app's icon by the name kumiko knows it by: a running app's, else one installed in the usual
/// folders. A pattern like `Arc|Dia` has none.
@MainActor
enum AppIcon {
	private static var cache: [String: NSImage?] = [:]
	private static let folders = [
		"/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications",
	]

	static func image(for name: String) -> NSImage? {
		if let cached = cache[name] { return cached }

		let running = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.icon
		let installed = folders.lazy
			.map { URL(filePath: $0).appending(path: "\(name).app").path(percentEncoded: false) }
			.first { FileManager.default.fileExists(atPath: $0) }
			.map { NSWorkspace.shared.icon(forFile: $0) }

		let image = running ?? installed
		cache[name] = image
		return image
	}

	/// A menu draws an image at its own size, which for an app icon is twice a menu line.
	static func image(for name: String, size: Double) -> NSImage? {
		guard let image = image(for: name)?.copy() as? NSImage else { return nil }
		image.size = NSSize(width: size, height: size)
		return image
	}
}

/// Text kept as typed until the field is left or return is pressed, the way the number fields
/// hold their numbers, so a rename is written once and not with every key.
private struct Verbatim: ParseableFormatStyle {
	var parseStrategy: Strategy { Strategy() }

	func format(_ value: String) -> String { value }

	struct Strategy: ParseStrategy {
		func parse(_ value: String) throws -> String { value }
	}
}
