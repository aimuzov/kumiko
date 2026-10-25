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
	public typealias Area = Config.Workspace.Area

	public struct Group: Equatable, Sendable {
		public let area: Area
		/// Indices into the workspaces, in file order.
		public let entries: [Int]
	}

	/// The order the areas are shown in. Decided once, from the order the file first names
	/// them, an area it does not name last. After that `previous` is kept, so emptying the
	/// top area or carrying a workspace there and back does not swap the areas under the
	/// pointer; only a file that has both areas, each in one run, the other way round,
	/// says otherwise, the way a hand edit would.
	public static func order(of workspaces: [Config.Workspace], keeping previous: [Area]? = nil) -> [Area] {
		var named: [Area] = []
		for workspace in workspaces where !named.contains(workspace.area) {
			named.append(workspace.area)
		}
		let fresh = named + Area.allCases.filter { !named.contains($0) }
		guard let previous, Set(previous) == Set(Area.allCases), previous.count == Area.allCases.count else {
			return fresh
		}
		let runs = zip(workspaces, workspaces.dropFirst()).count { $0.area != $1.area } + 1
		return named.count == Area.allCases.count && runs == named.count ? fresh : previous
	}

	/// Both areas in `order`, an empty one too, so there is somewhere to drop a workspace
	/// into it.
	public static func groups(of workspaces: [Config.Workspace], order: [Area]? = nil) -> [Group] {
		(order ?? self.order(of: workspaces)).map { area in
			Group(area: area, entries: workspaces.indices.filter { workspaces[$0].area == area })
		}
	}

	/// Carries `entry` into `area`, before the area's `slot`-th other entry, or after its
	/// last one when `slot` is past them all. Into an empty area it goes to the start or the
	/// end of the file, wherever that area is shown in `order`. `display` changes only when
	/// the area does: a `builtin` or a screen's name moved within Main keeps what it says.
	/// Nothing when the entry is where it was asked to go.
	public static func move(
		_ entry: Int, to area: Area, slot: Int, in workspaces: [Config.Workspace], order: [Area]? = nil
	) -> [any ConfigChange] {
		guard workspaces.indices.contains(entry) else { return [] }
		let others = workspaces.indices.filter { $0 != entry && workspaces[$0].area == area }
		// Indices once the entry is out of the list, which is what `EntryEdit.move` takes.
		func without(_ index: Int) -> Int { index > entry ? index - 1 : index }
		let to = if others.isEmpty {
			(order ?? self.order(of: workspaces)).first == area ? 0 : workspaces.count - 1
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
	public static func add(
		_ workspace: Config.Workspace, to workspaces: [Config.Workspace], order: [Area]? = nil
	) -> [any ConfigChange] {
		let order = order ?? self.order(of: workspaces)
		let insert = EntryEdit.insert("workspace", fields: workspace.tomlFields)
		var appended = workspaces
		appended.append(workspace)
		return [insert] + move(appended.count - 1, to: workspace.area, slot: .max, in: appended, order: order)
	}

	/// A workspace of its own: "Workspace <n>", the first name free from one past the count. On
	/// `display` it goes to the end of that display's area; without one, on the main display at
	/// the end of the file. What the settings window's "Add Workspace" and the bar's plus both write.
	public static func addNew(
		on display: String?, in workspaces: [Config.Workspace], order: [Area]? = nil
	) -> (name: String, changes: [any ConfigChange]) {
		let names = Set(workspaces.map(\.name))
		let name = ((workspaces.count + 1)...).lazy.map { "Workspace \($0)" }.first { !names.contains($0) }!
		let workspace = Config.Workspace(name: name, display: display ?? "main")
		let changes = display == nil
			? [EntryEdit.insert("workspace", fields: workspace.tomlFields)]
			: add(workspace, to: workspaces, order: order)
		return (name, changes)
	}
}
