extension Config.Workspace {
	/// The two places the settings window puts workspaces in while a monitor is attached.
	/// Only `external` says the monitor. `main` and `builtin` live on their own screens,
	/// and part of a screen's name on the screen it names, a monitor too; the page still
	/// groups all of them under Main, since none of them follows the monitor.
	public enum Area: String, Sendable, CaseIterable {
		case external, main

		/// What `display` says once a workspace is carried into the area.
		public var display: String { rawValue }
	}

	public var area: Area { display == Area.external.display ? .external : .main }
}

/// The workspaces as the settings window shows them with a monitor attached: one area
/// per display, each holding its entries in file order. The file keeps every area's
/// entries together, so the `workspace focus <n>` numbers run down the page without a
/// gap.
public enum WorkspaceAreas {
	public struct Group: Equatable, Sendable {
		public let area: Config.Workspace.Area
		/// Indices into the workspaces, in file order.
		public let entries: [Int]
	}

	/// Both areas, in the order the file first names them; one it does not name comes last,
	/// empty, so there is somewhere to drop a workspace into it.
	public static func groups(of workspaces: [Config.Workspace]) -> [Group] {
		var order: [Config.Workspace.Area] = []
		for workspace in workspaces where !order.contains(workspace.area) {
			order.append(workspace.area)
		}
		order += Config.Workspace.Area.allCases.filter { !order.contains($0) }
		return order.map { area in
			Group(area: area, entries: workspaces.indices.filter { workspaces[$0].area == area })
		}
	}

	/// Carries `entry` into `area`, before the area's `slot`-th other entry, or after its
	/// last one when `slot` is past them all. Into an empty area it goes to the end of the
	/// file, the way that area is shown last. `display` changes only when the area does: a
	/// `builtin` or a screen's name moved within Main keeps what it says. Nothing when the
	/// entry is where it was asked to go.
	public static func move(
		_ entry: Int, to area: Config.Workspace.Area, slot: Int, in workspaces: [Config.Workspace]
	) -> [any ConfigChange] {
		guard workspaces.indices.contains(entry) else { return [] }
		let others = workspaces.indices.filter { $0 != entry && workspaces[$0].area == area }
		// Indices once the entry is out of the list, which is what `EntryEdit.move` takes.
		func without(_ index: Int) -> Int { index > entry ? index - 1 : index }
		let to = if others.isEmpty {
			workspaces.count - 1
		} else if slot < others.count {
			without(others[max(slot, 0)])
		} else {
			without(others[others.count - 1]) + 1
		}

		var changes: [any ConfigChange] = []
		if workspaces[entry].area != area {
			changes.append(ConfigEdit(target: .entry("workspace", entry), key: "display", value: .string(area.display)))
		}
		if to != entry {
			changes.append(EntryEdit.move("workspace", from: entry, to: to))
		}
		return changes
	}

	/// A new entry, written at the end of its area: an insert lands after the file's last
	/// entry, and a move then brings it back to the area's last.
	public static func add(_ workspace: Config.Workspace, to workspaces: [Config.Workspace]) -> [any ConfigChange] {
		let insert = EntryEdit.insert("workspace", fields: workspace.tomlFields)
		var appended = workspaces
		appended.append(workspace)
		return [insert] + move(appended.count - 1, to: workspace.area, slot: .max, in: appended)
	}
}
