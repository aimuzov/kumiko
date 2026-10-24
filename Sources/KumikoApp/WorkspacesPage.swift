import AppKit
import KumikoCore
import SwiftUI
import UniformTypeIdentifiers

/// The lists of a workspace the app table writes. `stack` is the Window Rules page's.
enum AppList: String, CaseIterable {
	case apps, last

	var keyPath: KeyPath<Config.Workspace, [String]> {
		switch self {
		case .apps: \.apps
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

	/// `bsp` is the default and leaves the file.
	func setLayout(_ name: String, _ layout: Config.Workspace.Layout) {
		setWorkspace(name, "layout", layout == .bsp ? nil : .string(layout.rawValue))
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

	/// The app table's rows: the `apps` entries in layout order, then an app with only a size,
	/// so the size can still be cleared. One named only by `stack` or `last` has no row: the
	/// Window Rules page is where windows are stacked.
	func apps(of workspace: Config.Workspace) -> [String] {
		let ordered = orderedAppRows(of: workspace)
		return ordered + workspace.size.keys.sorted().filter { !ordered.contains($0) }
	}

	func setApp(_ app: String, _ list: AppList, _ on: Bool, in name: String) {
		guard let index = index(of: name) else { return }
		change([listEdit(index, list, on: on, app)])
	}

	func setSize(_ app: String, _ size: Double?, in name: String) {
		guard let index = index(of: name) else { return }
		var sizes = workspaces[index].size
		sizes[app] = size
		change([sizeEdit(index, sizes)])
	}

	/// The rows a drag reorders: the `apps` entries, by the names their rows carry, in layout
	/// order. A row with only a size comes after them and stays put.
	func orderedAppRows(of workspace: Config.Workspace) -> [String] {
		workspace.orderedApps.map { Config.Workspace.name(of: $0) ?? $0 }
	}

	/// The app goes to `drop.slot` of the ordered rows, in one write with the `last` entries the
	/// order now covers: kept, they would go on pulling their apps to the end whatever the order
	/// says. Folded in, such an app takes the last of the listed apps' places rather than the very
	/// last place. A `last` app that `apps` does not name stays in `last`.
	func dropApp(_ app: String, at drop: IslandDrag.Drop, in name: String) {
		guard let index = index(of: name) else { return }
		let workspace = workspaces[index]
		var order = workspace.orderedApps
		guard let from = order.firstIndex(where: { (Config.Workspace.name(of: $0) ?? $0) == app }) else { return }
		order.insert(order.remove(at: from), at: min(drop.slot, order.count))
		let last = workspace.last.filter { !workspace.listsInApps($0) }
		var changes: [any ConfigChange] = []
		if order != workspace.apps {
			changes.append(ConfigEdit(
				target: .entry("workspace", index), key: "apps", value: .array(order.map(TOMLValue.string))
			))
		}
		if last != workspace.last {
			changes.append(ConfigEdit(
				target: .entry("workspace", index), key: "last",
				value: last.isEmpty ? nil : .array(last.map(TOMLValue.string))
			))
		}
		change(changes)
	}

	/// Out of `apps`, `last` and `size`, in one write. `stack` is the Window Rules page's, which
	/// the app may still be in after it no longer opens here.
	func removeApp(_ app: String, from name: String) {
		guard let index = index(of: name) else { return }
		let workspace = workspaces[index]
		var changes: [any ConfigChange] = AppList.allCases
			.filter { $0 == .apps ? workspace.listsInApps(app) : workspace[keyPath: $0.keyPath].contains(app) }
			.map { listEdit(index, $0, on: false, app) }
		if workspace.size[app] != nil {
			var sizes = workspace.size
			sizes[app] = nil
			changes.append(sizeEdit(index, sizes))
		}
		change(changes)
	}

	/// Into an area, at its end; without areas, at the end of the file.
	func addWorkspace(to area: Config.Workspace.Area? = nil) {
		endTyping()
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

	/// Ends the typing in the name field first: its edit is written when the field is left,
	/// and the detail it is in goes away with the pick. The field's setter holds the name it
	/// was drawn with, so the edit renames the workspace it was typed for.
	func pickWorkspace(_ name: String) {
		endTyping()
		selectedWorkspace = name
	}

	/// Only while a field editor has the keyboard: taken from anything else, it would take the
	/// list's focus, and the arrow keys with it.
	private func endTyping() {
		guard let window = NSApp.keyWindow, window.firstResponder is NSText else { return }
		window.makeFirstResponder(nil)
	}

	/// The workspace whose settings show: the one picked, else the first in the list.
	var shownWorkspace: Config.Workspace? {
		if let picked = workspaces.first(where: { $0.name == selectedWorkspace }) { return picked }
		let first = workspaceSections.lazy.compactMap(\.names.first).first
		return workspaces.first { $0.name == first }
	}

	/// For the arrow keys: the row above or below the shown one, across the areas.
	func selectWorkspace(by offset: Int) {
		endTyping()
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

	/// Written as `size`, in place of an older file's `share` when it has one.
	private func sizeEdit(_ index: Int, _ sizes: [String: Double]) -> ConfigEdit {
		ConfigEdit(
			target: .entry("workspace", index), key: "size", value: sizes.isEmpty ? nil : Config.Workspace.sizeValue(
				sizes, order: workspaces[index].apps.map { Config.Workspace.name(of: $0) ?? $0 }
			), replacing: "share"
		)
	}
}

/// An app's size while the edge of its split is dragged.
struct DraggedSize: Equatable {
	let workspace: String
	let app: String
	let value: Double
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
			// Gone before the page shows again, which then looks for the icons afresh.
			.onDisappear { AppIcon.forgetMissing() }
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
	case add(Config.Workspace.Area)
	case end(Config.Workspace.Area)

	var id: String {
		switch self {
		case let .label(area, _): "label-\(area.rawValue)"
		case let .workspace(id, _): id.uuidString
		case let .empty(area): "empty-\(area.rawValue)"
		case let .add(area): "add-\(area.rawValue)"
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
				+ [.add(group.area), .end(group.area)]
		}
	}

	/// The room between two areas' islands, outside both.
	static let areaGap = 12.0
	/// How far an area's rows stand in from its island's edges.
	static let inset = 6.0

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
							.padding(.horizontal, areas ? Self.inset : 0)
					case let .empty(area):
						AreaDropZone(drag: drag, area: area.rawValue)
							.padding(.horizontal, Self.inset)
							.offset(y: drag.shift(ofArea: area.rawValue).top)
							.animation(IslandDrag.spring, value: drag.target)
					case let .add(area):
						// Goes along with the island's bottom, which a drag moves.
						AddWorkspaceRow { model.addWorkspace(to: area) }
							.padding(.horizontal, Self.inset)
							.offset(y: drag.shift(ofArea: area.rawValue).bottom)
							.animation(IslandDrag.spring, value: drag.target)
					case let .end(area):
						end(area)
					}
				}
			}
			.coordinateSpace(.named(Self.space))
			// Each display its own island, drawn behind the one stack the rows share.
			.background(alignment: .top) { if areas { AreaIslands(areas: drag.areas, drag: drag) } }
			.background(ScrollViewProbe { [weak drag] in drag?.autoScroll.scrollView = $0 })
			.padding(areas ? 0 : 6)
			// Over the buttons too, which a row dragged to the bottom passes.
			.zIndex(1)

			// Without areas, the one list is the island, and its plus closes it.
			if !areas {
				AddWorkspaceRow { model.addWorkspace() }
					.padding([.horizontal, .bottom], 6)
			}
		}
		.background {
			if !areas { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.02)) }
		}
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

	/// The top of the area's island, with the room above the label inside it; the gap from the
	/// island above comes after the measuring, so it stays outside both.
	private func label(_ area: Config.Workspace.Area, first: Bool) -> some View {
		Text(model.screens.label(of: area))
			.font(.system(size: 11, weight: .medium))
			.foregroundStyle(.secondary)
			.lineLimit(1)
			.truncationMode(.tail)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 8 + Self.inset)
			.padding(.top, 8)
			.padding(.bottom, 2)
			.offset(y: drag.shift(ofArea: area.rawValue).top)
			.animation(IslandDrag.spring, value: drag.target)
			.onGeometryChange(for: Double.self) { $0.frame(in: .named(Self.space)).minY } action: { top in
				drag.areas.top(of: area.rawValue, at: top)
			}
			.padding(.top, first ? 0 : Self.areaGap)
	}

	/// The bottom of the area's island: nothing to see but the room under its last row.
	private func end(_ area: Config.Workspace.Area) -> some View {
		SwiftUI.Color.clear
			.frame(height: Self.inset - IslandDrag.spacing)
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

	/// Not watched: what a row shows comes in from the list, so a pick draws the list once and
	/// not every row with it.
	let model: SettingsModel
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
			Spacer(minLength: 4)
			// Only for the layouts that are not the usual one, so most rows stay as they were.
			if let symbol = workspace.layout.symbol {
				Image(systemName: symbol)
					.font(.system(size: 10))
					.foregroundStyle(.secondary)
					.help(workspace.layout.title)
			}
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
		.accessibilityAction { model.pickWorkspace(workspace.name) }
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
				if !selected, model.islandDrag.dragged == nil { model.pickWorkspace(workspace.name) }
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

/// What a row says on its right: "default", then up to three app icons, two beside "default",
/// so the list tells the workspaces apart without opening them. It keeps its size: the name
/// is what truncates.
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

/// An island per display, from the top of its label to the room under its last row, the way
/// the list's rows measured them. A drag moves the edges with the rows: the island a row leaves
/// gets shorter, the one it is carried over taller.
private struct AreaIslands: View {
	@ObservedObject var areas: AreaLayout
	@ObservedObject var drag: IslandDrag

	var body: some View {
		ZStack(alignment: .top) {
			ForEach(areas.spans.sorted { $0.key < $1.key }, id: \.key) { id, span in
				let shift = drag.shift(ofArea: id)
				let top = span.lowerBound + shift.top
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.fill(.primary.opacity(0.02))
					.frame(height: max(span.upperBound + shift.bottom - top, 0))
					.offset(y: top)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.animation(IslandDrag.spring, value: drag.target)
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

/// The last line of an island, a row in looks so it reads as where the next workspace goes. It
/// has no minus beside it: a workspace is removed from its own panel or its row's menu.
private struct AddWorkspaceRow: View {
	let add: () -> Void

	var body: some View {
		Button(action: add) {
			HStack(spacing: 6) {
				Image(systemName: "plus")
					.font(.system(size: 11, weight: .semibold))
				Text("Add Workspace")
				Spacer(minLength: 0)
			}
			.foregroundStyle(.secondary)
			.padding(.horizontal, 8)
			.frame(height: WorkspaceRow.height)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}
}

/// What the Layout row and the list say about a layout.
extension Config.Workspace.Layout {
	var title: String {
		switch self {
		case .bsp: "BSP"
		case .stack: "Stack"
		case .float: "Float"
		}
	}

	var detail: String {
		switch self {
		case .bsp: "Windows split the screen."
		case .stack: "One window at a time, the rest stacked behind."
		case .float: "Windows stay where you put them."
		}
	}

	/// Nil for BSP, which most workspaces are.
	var symbol: String? {
		switch self {
		case .bsp: nil
		case .stack: "square.stack"
		case .float: "macwindow"
		}
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
				Row(title: "Layout", detail: workspace.layout.detail) {
					Picker(
						"",
						selection: Binding(get: { workspace.layout }, set: { model.setLayout(workspace.name, $0) })
					) {
						ForEach(Config.Workspace.Layout.allCases, id: \.self) { layout in
							Text(layout.title).tag(layout)
						}
					}
					.pickerStyle(.segmented)
					.labelsHidden()
					.fixedSize()
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

/// Widths the header and every row of the app table share, so the columns line up. Narrow
/// enough for the detail beside the list: the name keeps about 190 points of the 380.
private enum AppColumn {
	static let handle = 14.0
	static let icon = 18.0
	static let size = 104.0
	static let remove = 20.0
	static let spacing = 8.0
}

/// The apps as Raycast lays out its extensions: column titles, then a row per app, under a
/// title that carries the button to add one.
private struct AppsCard: View {
	@ObservedObject var model: SettingsModel
	let workspace: Config.Workspace

	var body: some View {
		// Laid out as `Card`'s own title, with the button beside it.
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .center, spacing: 8) {
				VStack(alignment: .leading, spacing: 2) {
					Text("Apps")
						.font(.system(size: 13, weight: .medium))
					Text("Windows of these apps open on this workspace, laid out in this order.")
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
				}
				Spacer(minLength: 8)
				AddAppButton(model: model, workspace: workspace)
			}
			.padding(.horizontal, 12)
			.padding(.bottom, 4)

			Card {
				if model.apps(of: workspace).isEmpty {
					Text("No apps yet")
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(.vertical, 10)
				} else {
					AppTable(model: model, drag: model.appDrag, workspace: workspace)
					if workspace.layout != .bsp {
						Text("\(workspace.layout.title) has no splits: the order and sizes apply in BSP only.")
							.font(.system(size: 11))
							.foregroundStyle(.secondary)
							.frame(maxWidth: .infinity, alignment: .leading)
							.padding(.vertical, 8)
					}
				}
			}
		}
	}
}

/// The column titles and the rows, the one view that watches a row being dragged: the lifted
/// row follows the pointer, the others slide aside, and letting go writes the new order.
private struct AppTable: View {
	nonisolated static let space = "apps"

	@ObservedObject var model: SettingsModel
	@ObservedObject var drag: IslandDrag
	let workspace: Config.Workspace

	var body: some View {
		let ordered = model.orderedAppRows(of: workspace)
		VStack(spacing: 0) {
			HStack(spacing: AppColumn.spacing) {
				Spacer().frame(width: AppColumn.handle)
				Text("App")
					.frame(maxWidth: .infinity, alignment: .leading)
				Text("Size")
					.frame(width: AppColumn.size)
				Spacer().frame(width: AppColumn.remove)
			}
			.font(.system(size: 11))
			.foregroundStyle(.secondary)
			.lineLimit(1)
			.padding(.top, 10)
			.padding(.bottom, 6)

			ForEach(model.apps(of: workspace), id: \.self) { app in
				row(app, movable: ordered.contains(app))
			}
		}
		.coordinateSpace(.named(Self.space))
		.background(ScrollViewProbe { [weak drag] in drag?.autoScroll.scrollView = $0 })
		// The frames stay: the next workspace's rows may be laid out already, and each row writes
		// its own frame when it is.
		.onDisappear {
			drag.reset()
			if model.draggedSize != nil { model.draggedSize = nil }
		}
		.onChange(of: ordered) { _, ordered in
			guard let lifted = drag.dragged else { return }
			if ordered.contains(lifted) { drag.cancel() } else { drag.abandon() }
		}
	}

	/// Its divider goes with it, so the rows touch and a gap is a row's height.
	private func row(_ app: String, movable: Bool) -> some View {
		let lifted = drag.dragged == app
		let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
		return VStack(spacing: 0) {
			Divider().opacity(lifted ? 0 : 1)
			AppRow(model: model, workspace: workspace, app: app, movable: movable)
		}
		// The page under the lifted row, or the rows it passes would show through.
		.background(shape.fill(SwiftUI.Color(nsColor: .textBackgroundColor)).opacity(lifted ? 1 : 0))
		.shadow(color: .black.opacity(lifted ? 0.15 : 0), radius: lifted ? 6 : 0, y: lifted ? 2 : 0)
		.offset(y: lifted ? 0 : drag.shift(of: app))
		.animation(IslandDrag.spring, value: drag.target)
		// Outside the spring: the lifted row keeps up with the pointer.
		.offset(y: lifted ? drag.translation : 0)
		.zIndex(lifted || drag.settling == app ? 1 : 0)
		// After the offsets, so they measure the place in the layout and not the one shown.
		.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
			drag.frames[app] = frame
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
	/// One of `apps`, which a drag reorders; a row with only a size has no order.
	let movable: Bool

	private static let patternHelp =
		"A pattern only chooses where windows open and their order: the other settings match exact app names."

	var body: some View {
		HStack(spacing: AppColumn.spacing) {
			if movable {
				handle
					.disabled(workspace.layout != .bsp)
					.opacity(workspace.layout != .bsp ? 0.4 : 1)
			} else {
				Spacer().frame(width: AppColumn.handle)
			}

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
					ForEach(notes, id: \.self) { note in
						Text(note)
							.font(.caption)
							.foregroundStyle(.secondary)
							.lineLimit(1)
							.truncationMode(.tail)
							.help(note)
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			SizeControl(model: model, workspace: workspace, app: app)
				.frame(width: AppColumn.size)
				.disabled(workspace.isPattern(app) || workspace.layout != .bsp)
				.help(workspace.isPattern(app) ? Self.patternHelp : SizeControl.help)

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
			if movable {
				Button("Move Up") { step(by: -1) }
					.disabled(!canStep(by: -1))
				Button("Move Down") { step(by: 1) }
					.disabled(!canStep(by: 1))
				Divider()
			}
			if !workspace.listsInApps(app) {
				Button("Open Here") { model.setApp(app, .apps, true, in: workspace.name) }
			}
			Button("Remove from Workspace") { model.removeApp(app, from: workspace.name) }
		}
	}

	/// What is dragged, and only it: the controls of the row take their own clicks, and a press
	/// that never moves is no drag.
	private var handle: some View {
		Image(systemName: "line.3.horizontal")
			.foregroundStyle(.tertiary)
			.frame(width: AppColumn.handle, height: 24)
			.contentShape(Rectangle())
			.gesture(
				DragGesture(minimumDistance: 0, coordinateSpace: .named(AppTable.space))
					.onChanged { value in
						model.appDrag.move(app, by: value.translation, sections: [
							IslandDrag.Section(id: "", names: model.orderedAppRows(of: workspace)),
						])
					}
					.onEnded { _ in
						_ = model.appDrag.end(app) { model.dropApp(app, at: $0, in: workspace.name) }
					}
			)
			.help("Drag to change where its windows go in the layout")
			.accessibilityLabel("Reorder \(app)")
			.accessibilityAction(named: "Move Up") { step(by: -1) }
			.accessibilityAction(named: "Move Down") { step(by: 1) }
	}

	/// What a drag does, for the menu and VoiceOver: a step up or down the ordered rows.
	private func step(by offset: Int) {
		guard canStep(by: offset), let place = model.orderedAppRows(of: workspace).firstIndex(of: app) else { return }
		model.dropApp(app, at: IslandDrag.Drop(section: "", slot: place + offset), in: workspace.name)
	}

	private func canStep(by offset: Int) -> Bool {
		let ordered = model.orderedAppRows(of: workspace)
		return ordered.firstIndex(of: app).map { ordered.indices.contains($0 + offset) } ?? false
	}

	/// What the row would not say otherwise, a line each: they are too long to share one in a
	/// column this narrow. A row is an app that opens here; one with only a size, written in the
	/// file by hand, keeps its row so the size can be cleared, and says it doesn't open here.
	private var notes: [String] {
		let opens = workspace.listsInApps(app)
			? earlierWorkspace.map { "Opens in \($0), which comes first" }
			: "Doesn't open here"
		return [opens, floats ? "Floats: no window rule tiles it" : nil].compactMap(\.self)
	}

	/// The size and the order mean nothing to a window that is not tiled. Only while the rules
	/// are what decides: with the window manager or its rules off, the row has nothing to add.
	private var floats: Bool {
		let wm = model.config.wm
		return wm.enabled && wm.useRules && !workspace.isPattern(app) && !wm.tiles(app)
	}

	/// The first workspace before this one whose `apps` also match the app, and so wins it.
	private var earlierWorkspace: String? {
		guard workspace.listsInApps(app), !workspace.isPattern(app) else { return nil }
		return model.workspaces.prefix { $0.name != workspace.name }.first { $0.opens(app) }?.name
	}
}

/// An app's size as a picture of the split it makes: its window, tinted, beside its neighbour,
/// and the edge between them dragged. No numbers: what the size does is how the two look.
/// Without a size the split is even and drawn faded with a dashed edge, so it reads as unset
/// rather than as a half someone chose. A drag snaps to the middle near it, which takes the
/// key out, and is written once on release: every step would rewrite the file and lay out the
/// windows.
private struct SizeControl: View {
	static let help = "How much of the split with its neighbour this app's window takes when it joins "
		+ "the layout, and when this changes. Drag the edge; the middle splits evenly."
	static let range = 0.1...0.9
	static let height = 16.0

	@ObservedObject var model: SettingsModel
	let workspace: Config.Workspace
	let app: String
	@Environment(\.isEnabled) private var isEnabled

	private var dragged: Double? {
		model.draggedSize.flatMap { $0.workspace == workspace.name && $0.app == app ? $0.value : nil }
	}

	private var set: Double? { workspace.size[app] }

	var body: some View {
		let value = dragged ?? set ?? 0.5
		let chosen = dragged.map { $0 != 0.5 } ?? (set != nil)

		GeometryReader { geometry in
			let width = geometry.size.width
			let edge = width * value
			let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
			ZStack(alignment: .leading) {
				HStack(spacing: 2) {
					shape.fill(SwiftUI.Color.accentColor.opacity(chosen ? 0.55 : 0.25))
						.frame(width: max(edge - 1, 0))
					shape.fill(SwiftUI.Color.primary.opacity(chosen ? 0.15 : 0.08))
				}
				// The edge, wider than it looks so it is easy to take.
				Path { path in
					path.move(to: CGPoint(x: edge, y: 0))
					path.addLine(to: CGPoint(x: edge, y: Self.height))
				}
				.stroke(
					SwiftUI.Color.primary.opacity(chosen ? 0.7 : 0.35),
					style: StrokeStyle(lineWidth: 1.5, dash: chosen ? [] : [2, 2])
				)
			}
			.contentShape(Rectangle())
			.gesture(drag(width: width))
		}
		.frame(height: Self.height)
		.opacity(isEnabled ? 1 : 0.4)
		.focusable(isEnabled)
		.onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
			step(by: press.key == .leftArrow ? -0.05 : 0.05)
			return .handled
		}
		.contextMenu {
			Button("Reset Size") { write(0.5) }
				.disabled(set == nil || !isEnabled)
		}
		.accessibilityElement()
		.accessibilityLabel("Size")
		.accessibilityValue(set.map { "\(Int(($0 * 100).rounded())) percent of its split" } ?? "Even")
		.accessibilityAdjustableAction { direction in
			step(by: direction == .increment ? 0.05 : -0.05)
		}
	}

	/// A press that does not move is no drag, so a stray click writes nothing.
	private func drag(width: Double) -> some Gesture {
		DragGesture(minimumDistance: 2)
			.onChanged { value in
				guard isEnabled, width > 0 else { return }
				let size = Self.snap(value.location.x / width)
				model.draggedSize = DraggedSize(workspace: workspace.name, app: app, value: size)
			}
			.onEnded { _ in
				guard let size = dragged else { return }
				model.draggedSize = nil
				write(size)
			}
	}

	private func step(by offset: Double) {
		guard isEnabled else { return }
		write(min(max((set ?? 0.5) + offset, Self.range.lowerBound), Self.range.upperBound))
	}

	/// The middle is no size, so the key leaves the file. Rounded to twentieths, which a double
	/// misses by a hair.
	private func write(_ value: Double) {
		let rounded = (value * 20).rounded() / 20
		let size = rounded == 0.5 ? nil : rounded
		if size != set { model.setSize(app, size, in: workspace.name) }
	}

	/// Within the range, to twentieths, and to the middle near it.
	static func snap(_ value: Double) -> Double {
		let value = min(max(value, range.lowerBound), range.upperBound)
		return abs(value - 0.5) < 0.06 ? 0.5 : (value * 20).rounded() / 20
	}
}

/// An app's icon by the name kumiko knows it by: a running app's, else one installed in the usual
/// folders. A pattern like `Arc|Dia` has none.
@MainActor
enum AppIcon {
	private static var cache: [String: NSImage] = [:]
	/// Names with no icon, so a pattern or an app not installed is not looked for with every
	/// draw. Forgotten when the page goes and when the window comes forward: an app launched
	/// or installed since gets its icon.
	private static var missing: Set<String> = []
	/// The menu's copies, made once: the menu is drawn with every draw of the detail.
	private static var sized: [String: NSImage] = [:]
	private static let folders = [
		"/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications",
	]

	static func image(for name: String) -> NSImage? {
		if let cached = cache[name] { return cached }
		guard !missing.contains(name) else { return nil }

		let running = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.icon
		let installed = folders.lazy
			.map { URL(filePath: $0).appending(path: "\(name).app").path(percentEncoded: false) }
			.first { FileManager.default.fileExists(atPath: $0) }
			.map { NSWorkspace.shared.icon(forFile: $0) }

		guard let image = running ?? installed else {
			missing.insert(name)
			return nil
		}
		cache[name] = image
		return image
	}

	static func forgetMissing() {
		missing = []
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
