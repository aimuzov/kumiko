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
		]
		// Two screens of one model share a name, and the menu takes each value once.
		for name in NSScreen.screens.map(\.localizedName) + [current]
		where !choices.contains(where: { $0.value == name }) {
			choices.append(DisplayChoice(value: name, title: name))
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

	func toggleExpanded(_ name: String) {
		if expandedWorkspaces.remove(name) == nil { expandedWorkspaces.insert(name) }
	}

	func setWorkspace(_ name: String, _ key: String, _ value: TOMLValue?) {
		guard let index = index(of: name) else { return }
		change([ConfigEdit(target: .entry("workspace", index), key: key, value: value)])
	}

	/// An empty or taken name is refused by the config check and shows as the write's error.
	func renameWorkspace(_ name: String, to new: String) {
		let new = new.trimmingCharacters(in: .whitespaces)
		guard new != name, index(of: name) != nil else { return }
		onRenameWorkspace(name, new)
		setWorkspace(name, "name", .string(new))
		if writeError == nil, expandedWorkspaces.remove(name) != nil { expandedWorkspaces.insert(new) }
	}

	/// Only the first default counts, so turning one on turns the others off.
	func setDefault(_ name: String, _ on: Bool) {
		guard let index = index(of: name) else { return }
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
	func apps(of workspace: Config.Workspace) -> [String] { workspace.appRows }

	func setApp(_ app: String, _ list: AppList, _ on: Bool, in name: String) {
		guard let index = index(of: name) else { return }
		change([listEdit(index, list, on: on, app)])
	}

	func setShare(_ app: String, _ share: Double?, in name: String) {
		guard let index = index(of: name) else { return }
		var shares = workspaces[index].share
		shares[app] = share
		change([shareEdit(index, shares)])
	}

	/// Out of all four, in one write.
	func removeApp(_ app: String, from name: String) {
		guard let index = index(of: name) else { return }
		let workspace = workspaces[index]
		var changes: [any ConfigChange] = AppList.allCases
			.filter { $0 == .apps ? workspace.listsInApps(app) : workspace[keyPath: $0.keyPath].contains(app) }
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
		if writeError == nil { expandedWorkspaces.insert(name) }
	}

	func removeWorkspace(_ name: String) {
		guard let index = index(of: name) else { return }
		change([EntryEdit.remove("workspace", index)])
		if writeError == nil { expandedWorkspaces.remove(name) }
	}

	/// The workspace takes the place of the target, which moves aside towards where it came from.
	/// A name the file no longer has, gone in a reload while it was dragged, moves nothing.
	@discardableResult
	func moveWorkspace(_ name: String, to target: String) -> Bool {
		guard let from = index(of: name), let to = index(of: target), from != to else { return false }
		change([EntryEdit.move("workspace", from: from, to: to)])
		return writeError == nil
	}

	/// The built-in nine, written out so they can be changed.
	func customizeWorkspaces() {
		change(Config.Workspace.builtIn.map { EntryEdit.insert("workspace", fields: $0.tomlFields) })
	}

	/// Looked up when the change is written: the file may have changed since the page was drawn.
	private func index(of name: String) -> Int? {
		workspaces.firstIndex { $0.name == name }
	}

	/// An empty list leaves the file: no key and an empty array mean the same. `apps` takes patterns,
	/// so a name goes in escaped and comes out by the name it spells.
	private func listEdit(_ index: Int, _ list: AppList, on: Bool, _ app: String) -> ConfigEdit {
		let workspace = workspaces[index]
		let current = workspace[keyPath: list.keyPath]
		let apps: [String]
		if list == .apps {
			let entry = workspace.isPattern(app) ? app : Config.Workspace.pattern(for: app)
			let others = current.filter { (Config.Workspace.name(of: $0) ?? $0) != app }
			apps = on ? (workspace.listsInApps(app) ? current : current + [entry]) : others
		} else {
			apps = on ? (current.contains(app) ? current : current + [app]) : current.filter { $0 != app }
		}
		return ConfigEdit(
			target: .entry("workspace", index), key: list.rawValue,
			value: apps.isEmpty ? nil : .array(apps.map(TOMLValue.string))
		)
	}

	private func shareEdit(_ index: Int, _ shares: [String: Double]) -> ConfigEdit {
		ConfigEdit(
			target: .entry("workspace", index), key: "share",
			value: shares.isEmpty ? nil : Config.Workspace.shareValue(
				shares, order: workspaces[index].apps.map { Config.Workspace.name(of: $0) ?? $0 })
		)
	}
}

extension UTType {
	static let kumikoWorkspace = UTType(exportedAs: "online.aimuzov.kumiko.workspace")
}

/// An island on the move. A type of its own, not the name as text: a text field it passes over
/// would take text in, and nothing outside kumiko has a use for it.
struct DraggedWorkspace: Codable, Transferable {
	let name: String

	static var transferRepresentation: some TransferRepresentation {
		CodableRepresentation(contentType: .kumikoWorkspace).visibility(.ownProcess)
	}
}

/// An app row of one workspace, for the row under the pointer.
struct WorkspaceApp: Hashable {
	let workspace: String
	let app: String
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
			// By name: a field being typed in stays with its workspace when the order changes.
			ForEach(Array(model.workspaces.enumerated()), id: \.element.name) { index, workspace in
				WorkspaceIsland(model: model, workspace: workspace, number: index + 1)
			}

			Button { model.addWorkspace() } label: {
				Label("Add Workspace", systemImage: "plus")
					.padding(.horizontal, 12)
					.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.foregroundStyle(.secondary)
			.overlay(
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.strokeBorder(.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
			)
			.confirmationDialog(
				"Remove \(model.workspacePendingRemoval ?? "")?",
				isPresented: Binding(
					get: { model.workspacePendingRemoval != nil },
					set: { if !$0 { model.workspacePendingRemoval = nil } }
				),
				presenting: model.workspacePendingRemoval
			) { name in
				Button("Remove", role: .destructive) { model.removeWorkspace(name) }
			} message: { _ in
				Text("Its windows are placed on the other workspaces again.")
			}
		}
	}
}

/// A workspace as one of Raycast's collapsible groups: the header alone while closed, its settings
/// and its apps under it while open. Islands come in file order, which is the order
/// `workspace focus <n>` counts them in, and the header is what is dragged to change it.
private struct WorkspaceIsland: View {
	@ObservedObject var model: SettingsModel
	let workspace: Config.Workspace
	let number: Int

	private var expanded: Bool { model.expandedWorkspaces.contains(workspace.name) }
	private var targeted: Bool { model.workspaceDropTarget == workspace.name }

	var body: some View {
		VStack(spacing: 0) {
			header

			if expanded {
				Divider()
				settings
				AppTable(model: model, workspace: workspace)
				Divider()
				footer
			}
		}
		.padding(.horizontal, 12)
		.background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.035)))
		.overlay(
			RoundedRectangle(cornerRadius: 10, style: .continuous)
				.strokeBorder(SwiftUI.Color.accentColor, lineWidth: 2)
				.opacity(targeted ? 1 : 0)
		)
		.dropDestination(for: DraggedWorkspace.self) { dragged, _ in
			model.workspaceDropTarget = nil
			guard let name = dragged.first?.name else { return false }
			return model.moveWorkspace(name, to: workspace.name)
		} isTargeted: { inside in
			// Leaving one island and entering the next come in either order.
			if inside {
				model.workspaceDropTarget = workspace.name
			} else if targeted {
				model.workspaceDropTarget = nil
			}
		}
	}

	/// A tap opens or closes the island and a drag moves it: a drag starts only once the pointer
	/// moves, and a tap is a press let go where it began, so the two never both happen.
	private var header: some View {
		HStack(spacing: 8) {
			Image(systemName: "line.3.horizontal")
				.foregroundStyle(.tertiary)
			// Past nine there is no key to name.
			Text(number <= 9 ? "alt-\(number)" : "\(number)")
				.font(.system(.body, design: .monospaced))
				.foregroundStyle(.secondary)
			Text(workspace.name)
				.lineLimit(1)
				.truncationMode(.tail)
			Image(systemName: expanded ? "chevron.down" : "chevron.right")
				.font(.system(size: 10, weight: .semibold))
				.foregroundStyle(.secondary)
			Spacer(minLength: 16)
			Text(summary)
				.foregroundStyle(.secondary)
				.lineLimit(1)
		}
		.padding(.vertical, 10)
		.contentShape(Rectangle())
		.onTapGesture { model.toggleExpanded(workspace.name) }
		.draggable(DraggedWorkspace(name: workspace.name))
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(.isButton)
		.accessibilityAction { model.toggleExpanded(workspace.name) }
	}

	private var summary: String {
		let count = workspace.apps.count
		let apps = workspace.isDefault ? "default" : count == 1 ? "1 app" : "\(count) apps"
		return "\(DisplayChoice.title(of: workspace.display)) · \(apps)"
	}

	@ViewBuilder
	private var settings: some View {
		Row(title: "Name") {
			TextField(
				"",
				value: Binding(get: { workspace.name }, set: { model.renameWorkspace(workspace.name, to: $0) }),
				format: Verbatim()
			)
			.textFieldStyle(.roundedBorder)
			.frame(width: 200)
		}
		Row(title: "Display") {
			Picker(
				"",
				selection: Binding(
					get: { workspace.display }, set: { model.setWorkspace(workspace.name, "display", .string($0)) }
				)
			) {
				ForEach(DisplayChoice.all(current: workspace.display), id: \.self) { Text($0.title).tag($0.value) }
			}
			.labelsHidden()
			.fixedSize()
		}
		SwitchRow(
			title: "Default",
			detail: "Every other app opens here.",
			on: Binding(get: { workspace.isDefault }, set: { model.setDefault(workspace.name, $0) }),
			last: model.apps(of: workspace).isEmpty
		)
	}

	private var footer: some View {
		HStack {
			Menu("Add App…") {
				ForEach(Self.running(excluding: model.apps(of: workspace)), id: \.self) { app in
					Button { model.setApp(app, .apps, true, in: workspace.name) } label: {
						if let icon = AppIcon.image(for: app, size: 16) {
							Label { Text(app) } icon: { Image(nsImage: icon) }
						} else {
							Text(app)
						}
					}
				}
				Divider()
				Button("Choose…") {
					if let app = Self.chooseApp() { model.setApp(app, .apps, true, in: workspace.name) }
				}
			}
			.menuStyle(.borderlessButton)
			.fixedSize()
			Spacer()
			Button("Remove Workspace…", role: .destructive) { model.workspacePendingRemoval = workspace.name }
				.buttonStyle(.borderless)
				.foregroundStyle(.secondary)
		}
		.padding(.vertical, 10)
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

/// Widths the header and every row of the app table share, so the columns line up.
private enum AppColumn {
	static let icon = 18.0
	static let share = 52.0
	static let check = 72.0
	static let remove = 16.0
	static let spacing = 8.0
}

/// The apps as Raycast lays out its extensions: column titles, then a row per app.
private struct AppTable: View {
	@ObservedObject var model: SettingsModel
	let workspace: Config.Workspace

	var body: some View {
		let apps = model.apps(of: workspace)
		if !apps.isEmpty {
			HStack(spacing: AppColumn.spacing) {
				Text("App")
					.frame(maxWidth: .infinity, alignment: .leading)
				Text("Share")
					.frame(width: AppColumn.share, alignment: .leading)
				Text("One stack")
					.frame(width: AppColumn.check)
				Text("Always last")
					.frame(width: AppColumn.check)
				Text("Opens here")
					.frame(width: AppColumn.check)
				Spacer().frame(width: AppColumn.remove)
			}
			.font(.system(size: 11))
			.foregroundStyle(.secondary)
			.lineLimit(1)
			.padding(.top, 10)
			.padding(.bottom, 6)

			ForEach(apps, id: \.self) { app in
				Divider()
				AppRow(model: model, workspace: workspace, app: app)
			}
		}
	}
}

private struct AppRow: View {
	@ObservedObject var model: SettingsModel
	let workspace: Config.Workspace
	let app: String

	private static let patternHelp =
		"A pattern only chooses where windows open: the other settings match exact app names."

	private var id: WorkspaceApp { WorkspaceApp(workspace: workspace.name, app: app) }

	var body: some View {
		HStack(spacing: AppColumn.spacing) {
			HStack(spacing: 10) {
				if let icon = AppIcon.image(for: app) {
					Image(nsImage: icon).resizable().frame(width: AppColumn.icon, height: AppColumn.icon)
				} else {
					Spacer().frame(width: AppColumn.icon)
				}
				VStack(alignment: .leading, spacing: 2) {
					Text(app)
						.lineLimit(1)
						.truncationMode(.tail)
					if let earlier = earlierWorkspace {
						Text("Opens in \(earlier), which comes first")
							.font(.caption)
							.foregroundStyle(.secondary)
							.lineLimit(1)
							.truncationMode(.tail)
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			TextField(
				"Share",
				value: Binding(
					get: { workspace.share[app] },
					set: { model.setShare(app, $0.map { min(max($0, 0.1), 0.9) }, in: workspace.name) }
				),
				format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
			)
			.textFieldStyle(.plain)
			.frame(width: AppColumn.share)
			.disabled(workspace.isPattern(app))
			.help(
				workspace.isPattern(app) ? Self.patternHelp : "The share of its split the app's window gets, 0.1 to 0.9"
			)

			checkbox(.stack, exact: true)
			checkbox(.last, exact: true)
			checkbox(.apps)

			Button { model.removeApp(app, from: workspace.name) } label: { Image(systemName: "minus.circle") }
				.buttonStyle(.borderless)
				.foregroundStyle(.secondary)
				.help("Take \(app) out of this workspace")
				.frame(width: AppColumn.remove)
				// Kept in the layout while hidden, so the columns stay where they are.
				.opacity(model.hoveredWorkspaceApp == id ? 1 : 0)
		}
		.padding(.vertical, 8)
		.contentShape(Rectangle())
		.onHover { inside in
			if inside {
				model.hoveredWorkspaceApp = id
			} else if model.hoveredWorkspaceApp == id {
				model.hoveredWorkspaceApp = nil
			}
		}
		.contextMenu {
			Button("Remove from Workspace") { model.removeApp(app, from: workspace.name) }
		}
	}

	/// The first workspace before this one whose `apps` also match the app, and so wins it.
	private var earlierWorkspace: String? {
		guard workspace.listsInApps(app), !workspace.isPattern(app) else { return nil }
		return model.workspaces.prefix { $0.name != workspace.name }.first { $0.opens(app) }?.name
	}

	/// `exact` lists compare app names as they are, which a pattern row never is.
	private func checkbox(_ list: AppList, exact: Bool = false) -> some View {
		Toggle(
			"",
			isOn: Binding(
				get: { list == .apps ? workspace.listsInApps(app) : workspace[keyPath: list.keyPath].contains(app) },
				set: { model.setApp(app, list, $0, in: workspace.name) }
			)
		)
		.toggleStyle(.checkbox)
		.labelsHidden()
		.frame(width: AppColumn.check)
		.disabled(exact && workspace.isPattern(app))
		.help(exact && workspace.isPattern(app) ? Self.patternHelp : "")
	}
}

/// An app's icon by the name kumiko knows it by: a running app's, else one installed in the usual
/// folders. A pattern like `Arc|Dia` has none.
@MainActor
enum AppIcon {
	/// Found icons only: an app launched or installed later gets its icon on the next look.
	private static var cache: [String: NSImage] = [:]
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

		guard let image = running ?? installed else { return nil }
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
