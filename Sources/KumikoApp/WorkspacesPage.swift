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
		let id = islandID(for: name)
		setWorkspace(name, "name", .string(new))
		guard writeError == nil else { return }
		if expandedWorkspaces.remove(name) != nil { expandedWorkspaces.insert(new) }
		carryIsland(from: name, to: new, id: id)
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
		if writeError == nil { workspacesPointer.forget(WorkspaceApp(workspace: name, app: app)) }
	}

	/// Into an area, at its end; without areas, at the end of the file.
	func addWorkspace(to area: Config.Workspace.Area? = nil) {
		let names = Set(workspaces.map(\.name))
		let name = ((workspaces.count + 1)...).lazy.map { "Workspace \($0)" }.first { !names.contains($0) }!
		let workspace = Config.Workspace(name: name, display: area?.display ?? "main")
		change(area == nil
			? [EntryEdit.insert("workspace", fields: workspace.tomlFields)]
			: WorkspaceAreas.add(workspace, to: workspaces, order: areaOrder()))
		if writeError == nil { expandedWorkspaces.insert(name) }
	}

	func removeWorkspace(_ name: String) {
		guard let index = index(of: name) else { return }
		change([EntryEdit.remove("workspace", index)])
		if writeError == nil {
			expandedWorkspaces.remove(name)
			workspacesPointer.forget(name)
		}
	}

	/// The areas top to bottom: the order they were shown in, unless the file now clearly
	/// says the other one. See `WorkspaceAreas.order`.
	func areaOrder() -> [Config.Workspace.Area] {
		let order = WorkspaceAreas.order(of: workspaces, keeping: shownAreaOrder)
		if order != shownAreaOrder { shownAreaOrder = order }
		return order
	}

	/// The islands as the stack lays them out: all in one list, or each area's in its own.
	var islandSections: [IslandDrag.Section] {
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
		guard let section = islandSections.first(where: { $0.names.contains(name) }),
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

/// An app row of one workspace, for the row under the pointer.
struct WorkspaceApp: Hashable {
	let workspace: String
	let app: String
}

/// What the pointer is over on the Workspaces page. Rows and islands write here without watching
/// it, so a hover draws one button again and not the whole page.
@MainActor
final class WorkspacesPointer: ObservableObject {
	/// The app row whose remove button shows.
	@Published var hoveredApp: WorkspaceApp?
	/// The island last pressed with the mouse, which takes the focus without showing its
	/// ring: the ring is for finding the focus from the keyboard.
	@Published var clicked: String?
	/// The island under the pointer, which lights up. Only its background watches this.
	@Published var hoveredIsland: String?

	/// The island keeps its view through a rename, which sends no hover to set these again.
	func rename(_ workspace: String, to new: String) {
		if let app = hoveredApp, app.workspace == workspace {
			hoveredApp = WorkspaceApp(workspace: new, app: app.app)
		}
		if clicked == workspace { clicked = new }
		if hoveredIsland == workspace { hoveredIsland = new }
	}

	func forget(_ app: WorkspaceApp) {
		if hoveredApp == app { hoveredApp = nil }
	}

	func forget(_ workspace: String) {
		keep { $0 != workspace }
	}

	func keep(_ workspaces: Set<String>) {
		keep(workspaces.contains)
	}

	/// Set only when it changes: every set draws the watching views again, nil over nil too.
	private func keep(_ kept: (String) -> Bool) {
		if let app = hoveredApp, !kept(app.workspace) { hoveredApp = nil }
		if let island = clicked, !kept(island) { clicked = nil }
		if let island = hoveredIsland, !kept(island) { hoveredIsland = nil }
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
			// One block, so the button sits as near the last island as the islands sit to each other.
			VStack(spacing: IslandStack.spacing) {
				IslandStack(model: model, drag: model.islandDrag)

				// With areas, each has its own.
				if !model.screens.showsAreas {
					AddWorkspaceButton { model.addWorkspace() }
				}
			}
			// One dialog for the page, on what stays when the island it asks about is gone.
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

/// A ghost row under the islands.
private struct AddWorkspaceButton: View {
	let add: () -> Void

	var body: some View {
		Button(action: add) {
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
	}
}

/// One line of the stack. With areas, each area is its label, its islands, and its Add
/// Workspace row, or a place to drop into while it has no islands.
private enum StackRow {
	case label(Config.Workspace.Area, first: Bool)
	case island(UUID, index: Int, Config.Workspace)
	case empty(Config.Workspace.Area)
	case add(Config.Workspace.Area)

	var id: String {
		switch self {
		case let .label(area, _): "label-\(area.rawValue)"
		case let .island(id, _, _): id.uuidString
		case let .empty(area): "empty-\(area.rawValue)"
		case let .add(area): "add-\(area.rawValue)"
		}
	}
}

/// The islands in their own stack, the one view that watches a drag: the lifted island
/// follows the pointer above the others, which slide aside to open the place it would
/// land in. The areas are rows of the same stack, not stacks of their own: an island
/// carried from one to the other stays the same view and glides into its place.
private struct IslandStack: View {
	static let spacing = IslandDrag.spacing
	/// How far an area's islands sit in from its edges, and the space between two areas.
	static let inset = 8.0
	static let areaGap = 12.0
	nonisolated static let space = "islands"

	@ObservedObject var model: SettingsModel
	@ObservedObject var drag: IslandDrag

	private var rows: [StackRow] {
		let workspaces = model.workspaces
		func island(_ index: Int) -> StackRow {
			.island(model.islandID(for: workspaces[index].name), index: index, workspaces[index])
		}
		guard model.screens.showsAreas else { return workspaces.indices.map(island) }
		return WorkspaceAreas.groups(of: workspaces, order: model.areaOrder()).enumerated().flatMap { place, group in
			[.label(group.area, first: place == 0)]
				+ (group.entries.isEmpty ? [.empty(group.area)] : group.entries.map(island))
				+ [.add(group.area)]
		}
	}

	var body: some View {
		let areas = model.screens.showsAreas
		VStack(spacing: Self.spacing) {
			// By an identity that outlives the name: a field being typed in stays with its workspace when
			// the order changes, and when the name does.
			ForEach(rows, id: \.id) { row in
				switch row {
				case let .label(area, first):
					label(area)
						.padding(.top, first ? 0 : Self.areaGap)
				case let .island(_, index, workspace):
					island(workspace, number: index + 1, area: areas ? workspace.area : nil)
						.padding(.horizontal, areas ? Self.inset : 0)
				case let .empty(area):
					AreaDropZone(drag: drag, area: area.rawValue)
						.padding(.horizontal, Self.inset)
						.offset(y: drag.shift(ofArea: area.rawValue).top)
						.animation(IslandDrag.spring, value: drag.target)
				case let .add(area):
					addRow(area)
				}
			}
		}
		.background(alignment: .top) {
			if areas { AreaBackdrop(drag: drag, layout: drag.areas) }
		}
		.coordinateSpace(.named(Self.space))
		.background(ScrollViewProbe { [weak drag] in drag?.autoScroll.scrollView = $0 })
		.onDisappear {
			drag.reset()
			drag.areas.forget()
			model.shownAreaOrder = nil
			// A window closed under the pointer sends no exit, and the island would stay lit.
			if model.workspacesPointer.hoveredIsland != nil { model.workspacesPointer.hoveredIsland = nil }
			if model.workspacesPointer.hoveredApp != nil { model.workspacesPointer.hoveredApp = nil }
		}
		// The snapshot counts places by section and index, which a reload with other names or
		// displays would shift, and so would a monitor coming or going.
		.onChange(of: model.islandSections) { _, sections in
			guard let lifted = drag.dragged else { return }
			if sections.contains(where: { $0.names.contains(lifted) }) { drag.cancel() } else { drag.abandon() }
		}
		.onChange(of: areas) { if !areas { drag.areas.forget() } }
		// Over Add Workspace too, which a dragged island passes on its way to the bottom.
		.zIndex(1)
	}

	private func island(_ workspace: Config.Workspace, number: Int, area: Config.Workspace.Area?) -> some View {
		let lifted = drag.dragged == workspace.name
		return WorkspaceIsland(
				model: model, workspace: workspace, number: number, area: area, dragging: drag.dragged != nil
			)
			.scaleEffect(lifted ? 1.02 : 1)
			.shadow(color: .black.opacity(lifted ? 0.18 : 0), radius: lifted ? 12 : 0, y: lifted ? 4 : 0)
			.offset(y: lifted ? 0 : drag.shift(of: workspace.name))
			.animation(IslandDrag.spring, value: drag.target)
			// Outside the spring: the lifted island keeps up with the pointer.
			.offset(y: lifted ? drag.translation : 0)
			.zIndex(lifted || drag.settling == workspace.name ? 1 : 0)
			// After the offsets, so they measure the place in the layout and not the one shown.
			.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
				drag.frames[workspace.name] = frame
			}
	}

	/// The area's top edge, with the room above the label inside the area.
	private func label(_ area: Config.Workspace.Area) -> some View {
		Text(model.screens.label(of: area))
			.font(.system(size: 11, weight: .medium))
			.foregroundStyle(.secondary)
			.lineLimit(1)
			.truncationMode(.tail)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, Self.inset + 4)
			.padding(.top, Self.inset + 2)
			.offset(y: drag.shift(ofArea: area.rawValue).top)
			.animation(IslandDrag.spring, value: drag.target)
			.onGeometryChange(for: Double.self) { $0.frame(in: .named(Self.space)).minY } action: { top in
				drag.areas.top(of: area.rawValue, at: top)
			}
	}

	/// The area's bottom edge, with the room under the button inside the area.
	private func addRow(_ area: Config.Workspace.Area) -> some View {
		AddWorkspaceButton { model.addWorkspace(to: area) }
			.padding(.horizontal, Self.inset)
			.padding(.bottom, Self.inset)
			.offset(y: drag.shift(ofArea: area.rawValue).bottom)
			.animation(IslandDrag.spring, value: drag.target)
			.onGeometryChange(for: Double.self) { $0.frame(in: .named(Self.space)).maxY } action: { bottom in
				drag.areas.bottom(of: area.rawValue, at: bottom)
			}
	}
}

/// The areas' fills, a level under the islands: a touch darker than the page, with a
/// hairline edge. They stretch and shrink with a drag the way the islands in them move.
private struct AreaBackdrop: View {
	static let radius = 14.0

	@ObservedObject var drag: IslandDrag
	@ObservedObject var layout: AreaLayout

	var body: some View {
		ZStack(alignment: .top) {
			ForEach(layout.spans.keys.sorted(), id: \.self) { area in
				if let span = layout.spans[area] {
					let shift = drag.shift(ofArea: area)
					let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
					shape
						.fill(.black.opacity(0.035))
						.overlay(shape.strokeBorder(.primary.opacity(0.07), lineWidth: 1))
						.frame(height: max(span.upperBound - span.lowerBound + shift.bottom - shift.top, 0))
						.offset(y: span.lowerBound + shift.top)
						.animation(IslandDrag.spring, value: drag.target)
				}
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.animation(IslandDrag.spring, value: layout.spans)
		.allowsHitTesting(false)
	}
}

/// What an area shows while it has no islands, lit while one is carried over it.
private struct AreaDropZone: View {
	@ObservedObject var drag: IslandDrag
	let area: String

	var body: some View {
		let lit = drag.dragged != nil && drag.target?.section == area
		let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
		Text("Drag a workspace here")
			.foregroundStyle(.tertiary)
			.frame(maxWidth: .infinity, minHeight: 40)
			.background(shape.fill(.primary.opacity(lit ? 0.05 : 0)))
			.overlay(shape.strokeBorder(SwiftUI.Color.accentColor.opacity(lit ? 0.7 : 0), lineWidth: 1.5))
			.animation(.easeOut(duration: 0.15), value: lit)
	}
}

/// A workspace as one of Raycast's collapsible groups: the header alone while closed, its settings
/// and its apps under it while open. Islands come in file order, which is the order
/// `workspace focus <n>` counts them in, and the header is what is dragged to change it.
private struct WorkspaceIsland: View {
	@ObservedObject var model: SettingsModel
	let workspace: Config.Workspace
	let number: Int
	/// The area it is shown in, nil while there are none.
	let area: Config.Workspace.Area?
	/// Some island is lifted: none lights up then, the lifted one keeps its lifted look.
	let dragging: Bool

	private var expanded: Bool { model.expandedWorkspaces.contains(workspace.name) }
	private var pointer: WorkspacesPointer { model.workspacesPointer }

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
		.background(IslandBackground(pointer: pointer, name: workspace.name, dragging: dragging))
		// The whole island, the gaps between its rows too.
		.contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
		.onHover { inside in
			if inside {
				if pointer.hoveredIsland != workspace.name { pointer.hoveredIsland = workspace.name }
			} else if pointer.hoveredIsland == workspace.name {
				pointer.hoveredIsland = nil
			}
		}
	}

	/// One gesture for the click and the drag, so the two never both happen: a press let go
	/// before the pointer moved opens or closes the island, one that moved lifts it.
	private var press: some Gesture {
		DragGesture(minimumDistance: 0, coordinateSpace: .named(IslandStack.space))
			.onChanged { value in
				if pointer.clicked != workspace.name { pointer.clicked = workspace.name }
				model.islandDrag.move(workspace.name, by: value.translation, sections: model.islandSections)
			}
			.onEnded { _ in
				let click = model.islandDrag.end(workspace.name) { model.dropWorkspace(workspace.name, at: $0) }
				if click { model.toggleExpanded(workspace.name) }
			}
	}

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
				// The summary gives way first.
				.layoutPriority(1)
			Image(systemName: expanded ? "chevron.down" : "chevron.right")
				.font(.system(size: 10, weight: .semibold))
				.foregroundStyle(.secondary)
			Spacer(minLength: 16)
			HeaderApps(title: displayTitle, apps: workspace.apps, isDefault: workspace.isDefault)
		}
		.padding(.vertical, 10)
		.contentShape(Rectangle())
		.gesture(press)
		.overlay(FocusRing(pointer: pointer, name: workspace.name))
		.focusable(interactions: .activate)
		.focusEffectDisabled()
		.onKeyPress(keys: [.space, .return]) { _ in
			// The lift measured the island as it is: opened under it, it would land by old sizes.
			if model.islandDrag.dragged == nil { model.toggleExpanded(workspace.name) }
			return .handled
		}
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
		}
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(.isButton)
		.accessibilityValue(expanded ? "Expanded" : "Collapsed")
		.accessibilityAction { model.toggleExpanded(workspace.name) }
		.accessibilityAction(named: "Move Up") { model.stepWorkspace(workspace.name, by: -1) }
		.accessibilityAction(named: "Move Down") { model.stepWorkspace(workspace.name, by: 1) }
	}

	private var other: Config.Workspace.Area? {
		area.map { $0 == .main ? .external : .main }
	}

	/// Only with areas, and only what the area does not say already: `builtin`, or part of a
	/// screen's name. Grouped under Main, it would not show anywhere else on the page.
	private var displayTitle: String? {
		let said = Config.Workspace.Area.allCases.map(\.display)
		guard area != nil, !said.contains(workspace.display) else { return nil }
		return workspace.display == "builtin" ? "Built-in" : workspace.display
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
	private var pointer: WorkspacesPointer { model.workspacesPointer }

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

			RemoveAppButton(pointer: pointer, id: id) { model.removeApp(app, from: workspace.name) }
		}
		.padding(.vertical, 8)
		.contentShape(Rectangle())
		.onHover { inside in
			if inside {
				pointer.hoveredApp = id
			} else {
				pointer.forget(id)
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

/// The island's fill, slightly stronger under the pointer. The one view of the island that watches
/// the pointer, so a hover does not draw its content again.
private struct IslandBackground: View {
	@ObservedObject var pointer: WorkspacesPointer
	let name: String
	let dragging: Bool

	var body: some View {
		let lit = !dragging && pointer.hoveredIsland == name
		RoundedRectangle(cornerRadius: 10, style: .continuous)
			.fill(.primary.opacity(lit ? 0.045 : 0.02))
			.animation(.easeOut(duration: 0.15), value: lit)
	}
}

/// What the header says on its right: a display its area does not say, then the apps that
/// open here as icons, so the island tells what is in it without being opened.
private struct HeaderApps: View {
	static let size = 16.0
	static let limit = 7

	let title: String?
	let apps: [String]
	let isDefault: Bool

	var body: some View {
		HStack(spacing: 8) {
			if let title { Text(title) }
			if !apps.isEmpty {
				HStack(spacing: 4) {
					ForEach(Array(apps.prefix(Self.limit).enumerated()), id: \.offset) { _, entry in
						icon(entry)
					}
					if apps.count > Self.limit {
						Text("+\(apps.count - Self.limit)").font(.caption)
					}
				}
			}
			if isDefault { Text("default").font(.caption) }
		}
		.foregroundStyle(.secondary)
		.lineLimit(1)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(label)
	}

	/// The icons say nothing to VoiceOver: the names come from the entries.
	private var label: String {
		let names = apps.map { Config.Workspace.name(of: $0) ?? $0 }
		return ([title].compactMap(\.self) + names + (isDefault ? ["default"] : [])).joined(separator: ", ")
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
		Image(systemName: symbol).frame(width: Self.size, height: Self.size)
	}
}

/// The header's own focus ring, in place of the system's, which shows on a mouse click
/// too. Left with the focus, the island shows it again when the keyboard comes back to
/// it.
private struct FocusRing: View {
	@ObservedObject var pointer: WorkspacesPointer
	@Environment(\.isFocused) private var focused
	let name: String

	var body: some View {
		RoundedRectangle(cornerRadius: 6, style: .continuous)
			.strokeBorder(SwiftUI.Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
			.padding(.horizontal, -6)
			.opacity(focused && pointer.clicked != name ? 1 : 0)
			.allowsHitTesting(false)
			.onChange(of: focused) {
				if !focused, pointer.clicked == name { pointer.clicked = nil }
			}
	}
}

/// Shown on the row under the pointer only, the one view a hover draws again.
private struct RemoveAppButton: View {
	@ObservedObject var pointer: WorkspacesPointer
	let id: WorkspaceApp
	let remove: () -> Void

	var body: some View {
		Button(action: remove) { Image(systemName: "minus.circle") }
			.buttonStyle(.borderless)
			.foregroundStyle(.secondary)
			.help("Take \(id.app) out of this workspace")
			.frame(width: AppColumn.remove)
			// Kept in the layout while hidden, so the columns stay where they are.
			.opacity(pointer.hoveredApp == id ? 1 : 0)
	}
}

/// An app's icon by the name kumiko knows it by: a running app's, else one installed in the usual
/// folders. A pattern like `Arc|Dia` has none.
@MainActor
enum AppIcon {
	/// Found icons only: an app launched or installed later gets its icon on the next look.
	private static var cache: [String: NSImage] = [:]
	/// The menu's copies, made once: the menu is drawn with every draw of an open island.
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
