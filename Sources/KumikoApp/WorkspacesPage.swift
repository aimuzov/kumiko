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

extension SettingsModel {
	var workspaces: [Config.Workspace] { config.workspaces }

	func setWorkspace(_ name: String, _ key: String, _ value: TOMLValue?) {
		guard let index = index(of: name) else { return }
		change([ConfigEdit(target: .entry("workspace", index), key: key, value: value)])
	}

	/// An empty or taken name is refused by the config check and shows as the write's error.
	func renameWorkspace(_ name: String, to new: String) {
		let new = new.trimmingCharacters(in: .whitespaces)
		guard new != name, index(of: name) != nil else { return }
		onRenameWorkspace(name, new)
		let id = workspaceID(for: name)
		setWorkspace(name, "name", .string(new))
		guard writeError == nil else { return }
		carryWorkspace(from: name, to: new, id: id)
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

	/// Into an area, at its end; without areas, at the end of the file.
	func addWorkspace(to area: Config.Workspace.Area? = nil) {
		let names = Set(workspaces.map(\.name))
		let name = ((workspaces.count + 1)...).lazy.map { "Workspace \($0)" }.first { !names.contains($0) }!
		let workspace = Config.Workspace(name: name, display: area?.display ?? "main")
		change(area == nil
			? [EntryEdit.insert("workspace", fields: workspace.tomlFields)]
			: WorkspaceAreas.add(workspace, to: workspaces, order: areaOrder()))
		if writeError == nil { selectedWorkspace = name }
	}

	/// The one shown goes to the row under it, or above it for the last: the list keeps its
	/// place, as System Settings' lists do.
	func removeWorkspace(_ name: String) {
		guard let index = index(of: name) else { return }
		let order = workspaceSections.flatMap(\.names)
		let neighbour = order.firstIndex(of: name).flatMap { place in
			order.indices.contains(place + 1) ? order[place + 1] : place > 0 ? order[place - 1] : nil
		}
		let shown = shownWorkspace?.name == name
		change([EntryEdit.remove("workspace", index)])
		if writeError == nil, shown { selectedWorkspace = neighbour }
	}

	/// The workspace whose settings show: the one picked, else the first in the list.
	var shownWorkspace: Config.Workspace? {
		if let picked = workspaces.first(where: { $0.name == selectedWorkspace }) { return picked }
		let first = workspaceSections.lazy.compactMap(\.names.first).first
		return workspaces.first { $0.name == first }
	}

	/// For the arrow keys: the row above or below the shown one, across the areas.
	func selectWorkspace(by offset: Int) {
		let order = workspaceSections.flatMap(\.names)
		guard let shown = shownWorkspace?.name, let place = order.firstIndex(of: shown),
		      order.indices.contains(place + offset) else { return }
		selectedWorkspace = order[place + offset]
	}

	/// The areas top to bottom: the order they were shown in, unless the file now clearly
	/// says the other one. See `WorkspaceAreas.order`.
	func areaOrder() -> [Config.Workspace.Area] {
		let order = WorkspaceAreas.order(of: workspaces, keeping: shownAreaOrder)
		if order != shownAreaOrder { shownAreaOrder = order }
		return order
	}

	/// The rows as the list lays them out: all in one section, or each area's in its own.
	var workspaceSections: [IslandDrag.Section] {
		guard screens.showsAreas else { return [IslandDrag.Section(id: "", names: workspaces.map(\.name))] }
		return WorkspaceAreas.groups(of: workspaces, order: areaOrder()).map { group in
			IslandDrag.Section(id: group.area.rawValue, names: group.entries.map { workspaces[$0].name })
		}
	}

	/// The workspace goes to `drop.slot` of its section, counted without it; an area's section
	/// carries it into that area. A name the file no longer has, gone in a reload while it was
	/// dragged, moves nothing.
	func dropWorkspace(_ name: String, at drop: IslandDrag.Drop) {
		guard let from = index(of: name) else { return }
		if let area = Config.Workspace.Area(rawValue: drop.section) {
			change(WorkspaceAreas.move(from, to: area, slot: drop.slot, in: workspaces, order: areaOrder()))
		} else if workspaces.indices.contains(drop.slot), drop.slot != from {
			change([EntryEdit.move("workspace", from: from, to: drop.slot)])
		}
	}

	/// What a drag does, for the keyboard and VoiceOver: a step up or down its own section.
	func stepWorkspace(_ name: String, by offset: Int) {
		guard let drop = step(name, by: offset) else { return }
		dropWorkspace(name, at: drop)
	}

	func canStep(_ name: String, by offset: Int) -> Bool { step(name, by: offset) != nil }

	private func step(_ name: String, by offset: Int) -> IslandDrag.Drop? {
		guard let section = workspaceSections.first(where: { $0.names.contains(name) }),
		      let place = section.names.firstIndex(of: name) else { return nil }
		let slot = place + offset
		return section.names.indices.contains(slot) ? IslandDrag.Drop(section: section.id, slot: slot) : nil
	}

	/// To the end of the other area.
	func moveWorkspace(_ name: String, to area: Config.Workspace.Area) {
		guard let from = index(of: name) else { return }
		change(WorkspaceAreas.move(from, to: area, slot: .max, in: workspaces, order: areaOrder()))
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
			// System Settings' list and detail: the workspaces on the left, the picked one's settings
			// on the right.
			HStack(alignment: .top, spacing: 16) {
				WorkspaceList(model: model, drag: model.islandDrag)
					.frame(width: WorkspaceList.width)

				if let workspace = model.shownWorkspace {
					// By an identity that outlives the name, so the name field keeps the keyboard
					// through a rename.
					WorkspaceDetail(model: model, workspace: workspace)
						.id(model.workspaceID(for: workspace.name))
				}
			}
			// One dialog for the page, on what stays when the workspace it asks about is gone.
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

/// One line of the list. With areas, each area is its label, its workspaces, or a place to
/// drop into while it has none, and its end, which tells the drag where the area stops.
private enum ListRow {
	case label(Config.Workspace.Area, first: Bool)
	case workspace(UUID, Config.Workspace)
	case empty(Config.Workspace.Area)
	case end(Config.Workspace.Area)

	var id: String {
		switch self {
		case let .label(area, _): "label-\(area.rawValue)"
		case let .workspace(id, _): id.uuidString
		case let .empty(area): "empty-\(area.rawValue)"
		case let .end(area): "end-\(area.rawValue)"
		}
	}
}

/// The workspaces in file order, the order `workspace focus <n>` counts them in, and the one
/// view that watches a drag: the lifted row follows the pointer above the others, which slide
/// aside to open the place it would land in. The areas are rows of the same stack, not stacks
/// of their own: a row carried from one to the other stays the same view and glides there.
private struct WorkspaceList: View {
	static let width = 210.0
	nonisolated static let space = "workspaces"

	@ObservedObject var model: SettingsModel
	@ObservedObject var drag: IslandDrag

	private var rows: [ListRow] {
		let workspaces = model.workspaces
		func row(_ index: Int) -> ListRow {
			.workspace(model.workspaceID(for: workspaces[index].name), workspaces[index])
		}
		guard model.screens.showsAreas else { return workspaces.indices.map(row) }
		return WorkspaceAreas.groups(of: workspaces, order: model.areaOrder()).enumerated().flatMap { place, group in
			[.label(group.area, first: place == 0)]
				+ (group.entries.isEmpty ? [.empty(group.area)] : group.entries.map(row))
				+ [.end(group.area)]
		}
	}

	var body: some View {
		let areas = model.screens.showsAreas
		let shown = model.shownWorkspace?.name
		VStack(spacing: 0) {
			VStack(spacing: IslandDrag.spacing) {
				ForEach(rows, id: \.id) { row in
					switch row {
					case let .label(area, first):
						label(area, first: first)
					case let .workspace(_, workspace):
						self.row(workspace, area: areas ? workspace.area : nil, selected: workspace.name == shown)
					case let .empty(area):
						AreaDropZone(drag: drag, area: area.rawValue)
							.offset(y: drag.shift(ofArea: area.rawValue).top)
							.animation(IslandDrag.spring, value: drag.target)
					case let .end(area):
						end(area)
					}
				}
			}
			.coordinateSpace(.named(Self.space))
			.background(ScrollViewProbe { [weak drag] in drag?.autoScroll.scrollView = $0 })
			.padding(6)
			// Over the buttons too, which a row dragged to the bottom passes.
			.zIndex(1)

			Divider()
			ListButtons(
				add: { model.addWorkspace(to: areas ? model.shownWorkspace?.area ?? model.areaOrder().first : nil) },
				remove: shown.map { name in { model.workspacePendingRemoval = name } }
			)
		}
		.background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.02)))
		// Takes the keyboard when clicked, for the arrow keys; the selection shows where it is.
		.focusable(interactions: .edit)
		.focusEffectDisabled()
		.onKeyPress(keys: [.upArrow, .downArrow]) { press in
			if drag.dragged == nil { model.selectWorkspace(by: press.key == .upArrow ? -1 : 1) }
			return .handled
		}
		.onDisappear {
			drag.reset()
			drag.areas.forget()
			model.shownAreaOrder = nil
		}
		// The snapshot counts places by section and index, which a reload with other names or
		// displays would shift, and so would a monitor coming or going.
		.onChange(of: model.workspaceSections) { _, sections in
			guard let lifted = drag.dragged else { return }
			if sections.contains(where: { $0.names.contains(lifted) }) { drag.cancel() } else { drag.abandon() }
		}
		.onChange(of: areas) { if !areas { drag.areas.forget() } }
	}

	/// A light lift for a row: no growing, only a shadow, as a row picked up in Finder.
	private func row(_ workspace: Config.Workspace, area: Config.Workspace.Area?, selected: Bool) -> some View {
		let lifted = drag.dragged == workspace.name
		return WorkspaceRow(model: model, workspace: workspace, area: area, selected: selected, lifted: lifted)
			.shadow(color: .black.opacity(lifted ? 0.15 : 0), radius: lifted ? 6 : 0, y: lifted ? 2 : 0)
			.offset(y: lifted ? 0 : drag.shift(of: workspace.name))
			.animation(IslandDrag.spring, value: drag.target)
			// Outside the spring: the lifted row keeps up with the pointer.
			.offset(y: lifted ? drag.translation : 0)
			.zIndex(lifted || drag.settling == workspace.name ? 1 : 0)
			// After the offsets, so they measure the place in the layout and not the one shown.
			.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
				drag.frames[workspace.name] = frame
			}
	}

	/// The area's top edge, with the room above the label inside the area.
	private func label(_ area: Config.Workspace.Area, first: Bool) -> some View {
		Text(model.screens.label(of: area))
			.font(.system(size: 11, weight: .medium))
			.foregroundStyle(.secondary)
			.lineLimit(1)
			.truncationMode(.tail)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 8)
			.padding(.top, first ? 4 : 12)
			.padding(.bottom, 2)
			.offset(y: drag.shift(ofArea: area.rawValue).top)
			.animation(IslandDrag.spring, value: drag.target)
			.onGeometryChange(for: Double.self) { $0.frame(in: .named(Self.space)).minY } action: { top in
				drag.areas.top(of: area.rawValue, at: top)
			}
	}

	/// The area's bottom edge: nothing to see, only where the area stops.
	private func end(_ area: Config.Workspace.Area) -> some View {
		SwiftUI.Color.clear
			.frame(height: 0)
			.onGeometryChange(for: Double.self) { $0.frame(in: .named(Self.space)).maxY } action: { bottom in
				drag.areas.bottom(of: area.rawValue, at: bottom)
			}
	}
}

/// A workspace in the list: its name, and on the right what tells it apart without opening it.
/// One gesture for the click and the drag, so the two never both happen: the press picks the
/// row, a press that moved lifts it.
private struct WorkspaceRow: View {
	static let height = 28.0

	@ObservedObject var model: SettingsModel
	let workspace: Config.Workspace
	/// The area it is shown in, nil while there are none.
	let area: Config.Workspace.Area?
	let selected: Bool
	let lifted: Bool
	@Environment(\.controlActiveState) private var activeState

	var body: some View {
		HStack(spacing: 6) {
			Text(workspace.name)
				.lineLimit(1)
				.truncationMode(.tail)
				// The summary gives way first.
				.layoutPriority(1)
			Spacer(minLength: 4)
			RowSummary(apps: workspace.apps, isDefault: workspace.isDefault)
		}
		.padding(.horizontal, 8)
		.frame(height: Self.height)
		.background(background)
		.contentShape(Rectangle())
		.gesture(press)
		.contextMenu {
			Button("Move Up") { model.stepWorkspace(workspace.name, by: -1) }
				.disabled(!model.canStep(workspace.name, by: -1))
			Button("Move Down") { model.stepWorkspace(workspace.name, by: 1) }
				.disabled(!model.canStep(workspace.name, by: 1))
			if let other {
				Divider()
				Button("Move to \(other == .main ? "Main" : "External")") {
					model.moveWorkspace(workspace.name, to: other)
				}
			}
			Divider()
			Button("Remove…") { model.workspacePendingRemoval = workspace.name }
		}
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
		.accessibilityAction { model.selectedWorkspace = workspace.name }
		.accessibilityAction(named: "Move Up") { model.stepWorkspace(workspace.name, by: -1) }
		.accessibilityAction(named: "Move Down") { model.stepWorkspace(workspace.name, by: 1) }
	}

	/// The sidebar's grey for the picked row. Lifted, the row gets the page under it, or the
	/// rows it passes would show through.
	private var background: some View {
		let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
		let tint = selected ? (activeState == .inactive ? 0.03 : 0.085) : 0
		return shape
			.fill(SwiftUI.Color(nsColor: .textBackgroundColor).opacity(lifted ? 1 : 0))
			.overlay(shape.fill(SwiftUI.Color.primary.opacity(tint)))
	}

	private var press: some Gesture {
		DragGesture(minimumDistance: 0, coordinateSpace: .named(WorkspaceList.space))
			.onChanged { value in
				// On the press, as a list picks a row, and once: every pick draws the detail again.
				if !selected, model.islandDrag.dragged == nil { model.selectedWorkspace = workspace.name }
				model.islandDrag.move(workspace.name, by: value.translation, sections: model.workspaceSections)
			}
			.onEnded { _ in
				_ = model.islandDrag.end(workspace.name) { model.dropWorkspace(workspace.name, at: $0) }
			}
	}

	private var other: Config.Workspace.Area? {
		area.map { $0 == .main ? .external : .main }
	}
}

/// What a row says on its right: "default", then as many app icons as fit beside it, so the
/// list tells the workspaces apart without opening them.
private struct RowSummary: View {
	static let size = 14.0

	let apps: [String]
	let isDefault: Bool

	var body: some View {
		HStack(spacing: 4) {
			if isDefault { Text("default").font(.system(size: 11)) }
			ForEach(Array(apps.prefix(isDefault ? 2 : 3).enumerated()), id: \.offset) { _, entry in
				icon(entry)
			}
		}
		.foregroundStyle(.secondary)
		.lineLimit(1)
		.fixedSize()
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(label)
	}

	/// The icons say nothing to VoiceOver: the names come from the entries.
	private var label: String {
		let names = apps.map { Config.Workspace.name(of: $0) ?? $0 }
		return ((isDefault ? ["default"] : []) + names).joined(separator: ", ")
	}

	/// A pattern has no icon to show, and an app not found has none yet: both get a stand-in.
	@ViewBuilder
	private func icon(_ entry: String) -> some View {
		if let name = Config.Workspace.name(of: entry) {
			if let image = AppIcon.image(for: name, size: Self.size) {
				Image(nsImage: image).help(name)
			} else {
				glyph("app.dashed").help(name)
			}
		} else {
			glyph("square.dashed").help(entry)
		}
	}

	private func glyph(_ symbol: String) -> some View {
		Image(systemName: symbol)
			.font(.system(size: 11))
			.frame(width: Self.size, height: Self.size)
	}
}

/// What an area shows while it has no workspaces, lit while one is carried over it.
private struct AreaDropZone: View {
	@ObservedObject var drag: IslandDrag
	let area: String

	var body: some View {
		let lit = drag.dragged != nil && drag.target?.section == area
		let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
		Text("Drag a workspace here")
			.font(.system(size: 11))
			.foregroundStyle(.tertiary)
			.frame(maxWidth: .infinity, minHeight: WorkspaceRow.height)
			.background(shape.fill(.primary.opacity(lit ? 0.05 : 0)))
			.overlay(shape.strokeBorder(SwiftUI.Color.accentColor.opacity(lit ? 0.7 : 0), lineWidth: 1.5))
			.animation(.easeOut(duration: 0.15), value: lit)
	}
}

/// The plus and minus System Settings puts under a list, joined into one control so they read
/// as buttons and not as two loose symbols.
private struct ListButtons: View {
	let add: () -> Void
	/// Nil while nothing is picked, which leaves minus disabled.
	let remove: (() -> Void)?

	var body: some View {
		HStack {
			ControlGroup {
				Button(action: add) {
					Image(systemName: "plus").accessibilityLabel("Add Workspace")
				}
				.help("Add Workspace")
				Button { remove?() } label: {
					Image(systemName: "minus").accessibilityLabel("Remove Workspace")
				}
				.disabled(remove == nil)
				.help("Remove Workspace")
			}
			.controlSize(.small)
			.fixedSize()
			Spacer(minLength: 0)
		}
		.padding(6)
	}
}

/// The picked workspace's settings, and its apps under them.
private struct WorkspaceDetail: View {
	@ObservedObject var model: SettingsModel
	let workspace: Config.Workspace

	var body: some View {
		VStack(alignment: .leading, spacing: 20) {
			Card {
				Row(title: "Name") {
					TextField(
						"",
						value: Binding(get: { workspace.name }, set: { model.renameWorkspace(workspace.name, to: $0) }),
						format: Verbatim()
					)
					.textFieldStyle(.roundedBorder)
					.frame(maxWidth: 200)
				}
				if let displayTitle {
					Row(title: "Display") {
						Text(displayTitle).foregroundStyle(.secondary)
					}
				}
				SwitchRow(
					title: "Default",
					detail: "Every other app opens here.",
					on: Binding(get: { workspace.isDefault }, set: { model.setDefault(workspace.name, $0) }),
					last: true
				)
			}

			AppsCard(model: model, workspace: workspace)

			// Spelled out under the settings, not only as the list's minus: that one says nothing
			// about what it takes away.
			HStack {
				Spacer()
				Button("Remove Workspace…", role: .destructive) {
					model.workspacePendingRemoval = workspace.name
				}
				.buttonStyle(.bordered)
				.foregroundStyle(.red)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	/// Only with areas, and only what the area does not say already: `builtin`, or part of a
	/// screen's name. Grouped under Main, it would not show anywhere else on the page.
	private var displayTitle: String? {
		let said = Config.Workspace.Area.allCases.map(\.display)
		guard model.screens.showsAreas, !said.contains(workspace.display) else { return nil }
		return workspace.display == "builtin" ? "Built-in" : workspace.display
	}
}

/// Widths the header and every row of the app table share, so the columns line up.
private enum AppColumn {
	static let icon = 18.0
	static let share = 44.0
	static let check = 64.0
	static let remove = 24.0
	static let spacing = 8.0
}

/// The apps as Raycast lays out its extensions: column titles, then a row per app, under a
/// title that carries the button to add one.
private struct AppsCard: View {
	@ObservedObject var model: SettingsModel
	let workspace: Config.Workspace

	var body: some View {
		let apps = model.apps(of: workspace)
		// Laid out as `Card`'s own title, with the button beside it.
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .center, spacing: 8) {
				VStack(alignment: .leading, spacing: 2) {
					Text("Apps")
						.font(.system(size: 13, weight: .medium))
					Text("Windows of these apps open on this workspace.")
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
				}
				Spacer(minLength: 8)
				AddAppButton(model: model, workspace: workspace)
			}
			.padding(.horizontal, 12)
			.padding(.bottom, 4)

			Card {
				if apps.isEmpty {
					Text("No apps yet")
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(.vertical, 10)
				} else {
					HStack(spacing: AppColumn.spacing) {
						Text("App")
							.frame(maxWidth: .infinity, alignment: .leading)
						Text("Share")
							.frame(width: AppColumn.share, alignment: .leading)
						Text("One stack")
							.frame(width: AppColumn.check)
						Text("Always last")
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
	}
}

/// A bordered pull-down with its own words, so it reads as the button it is: the running apps,
/// and a way to pick one in /Applications.
private struct AddAppButton: View {
	@ObservedObject var model: SettingsModel
	let workspace: Config.Workspace

	var body: some View {
		Menu {
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
		} label: {
			Label("Add App", systemImage: "plus")
		}
		.menuStyle(.button)
		.buttonStyle(.bordered)
		.controlSize(.small)
		.fixedSize()
	}

	/// Apps with a Dock icon, the ones whose windows kumiko arranges, that the workspace does not name yet.
	static func running(excluding listed: [String]) -> [String] {
		let names = NSWorkspace.shared.runningApplications
			.filter { $0.activationPolicy == .regular }
			.compactMap(\.localizedName)
		return Array(Set(names)).filter { !listed.contains($0) }.sorted()
	}

	/// An app picked in /Applications, by the name its windows carry.
	static func chooseApp() -> String? {
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
	let workspace: Config.Workspace
	let app: String

	private static let patternHelp =
		"A pattern only chooses where windows open: the other settings match exact app names."

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
					if let note {
						Text(note)
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

			// Always there: one shown on hover only was found by chance. The red circle is how macOS
			// marks taking a row out of a list; a bordered button this small flattens into a pill.
			Button { model.removeApp(app, from: workspace.name) } label: {
				Image(systemName: "minus.circle.fill")
					.symbolRenderingMode(.palette)
					.foregroundStyle(.white, .red)
					.font(.system(size: 14))
					.accessibilityLabel("Remove \(app)")
			}
			.buttonStyle(.borderless)
			.help("Take \(app) out of this workspace")
			.frame(width: AppColumn.remove)
		}
		.padding(.vertical, 8)
		.contentShape(Rectangle())
		.contextMenu {
			if !workspace.listsInApps(app) {
				Button("Open Here") { model.setApp(app, .apps, true, in: workspace.name) }
			}
			Button("Remove from Workspace") { model.removeApp(app, from: workspace.name) }
		}
	}

	/// A row is an app that opens here. One named only by `stack`, `last` or `share`, written in
	/// the file by hand, keeps its row so nothing is lost, and says it doesn't open here.
	private var note: String? {
		guard workspace.listsInApps(app) else { return "Doesn't open here" }
		return earlierWorkspace.map { "Opens in \($0), which comes first" }
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
				get: { workspace[keyPath: list.keyPath].contains(app) },
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
	/// The menu's copies, made once: the menu is drawn with every draw of the detail.
	private static var sized: [String: NSImage] = [:]
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
		let key = "\(name)@\(size)"
		if let cached = sized[key] { return cached }
		guard let image = image(for: name)?.copy() as? NSImage else { return nil }
		image.size = NSSize(width: size, height: size)
		sized[key] = image
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
