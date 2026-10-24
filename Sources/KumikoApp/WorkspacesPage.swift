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

	/// Main and External, and the names of the external screens when there are several of them:
	/// with one, its name says no more than External. Built-in is left out, since it is Main unless
	/// the menu bar was moved to a monitor; a workspace that already says `builtin`, or part of a
	/// name, keeps it, so opening the menu changes nothing.
	@MainActor
	static func all(current: String) -> [DisplayChoice] {
		var choices = [DisplayChoice(value: "main", title: "Main"), DisplayChoice(value: "external", title: "External")]
		if current == "builtin" {
			choices.append(DisplayChoice(value: "builtin", title: "Built-in"))
		}
		let externals = NSScreen.screens.filter { screen in
			let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
			return number.map { CGDisplayIsBuiltin($0.uint32Value) == 0 } ?? true
		}
		// Two screens of one model share a name, and the menu takes each value once.
		for name in (externals.count > 1 ? externals.map(\.localizedName) : []) + [current]
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

	func addWorkspace() {
		let names = Set(workspaces.map(\.name))
		let name = ((workspaces.count + 1)...).lazy.map { "Workspace \($0)" }.first { !names.contains($0) }!
		change([EntryEdit.insert("workspace", fields: Config.Workspace(name: name).tomlFields)])
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

/// An island lifted by its header and carried up or down the page, the others making
/// way. Only the stack of islands watches it: the rest of the window does not draw again
/// with every move.
@MainActor
final class IslandDrag: ObservableObject {
	/// The pointer moves this far before a press stops being a click.
	static let threshold = 4.0
	static let spring = Animation.spring(duration: 0.3, bounce: 0.15)

	@Published private(set) var dragged: String?
	@Published private(set) var translation = 0.0
	/// The place the island lands in if let go now, counted with it out of the list.
	@Published private(set) var target: Int?
	/// The island gliding into its place, kept above the ones it passes over until it is
	/// there.
	@Published private(set) var settling: String?
	/// Where each island is laid out in the stack. Written when the layout changes, not
	/// observed: the islands make way with offsets, which leave the layout as it is.
	var frames: [String: CGRect] = [:]
	let autoScroll = IslandAutoScroll()

	/// What the lift saw, so a move only compares numbers: the order, the islands' middles
	/// and how far the lifted one can go before it leaves the first or the last behind.
	private var order: [String] = []
	private var middles: [Double] = []
	private var from = 0
	private var lifted = CGRect.zero
	private var reach = 0.0...0.0
	/// The pointer's own part of the translation, and what the page scrolled since it last
	/// moved: held at the edge, the island goes along with the page under a still pointer.
	private var pointer = 0.0
	private var scrolled = 0.0
	private var cancelled = false
	/// The press went past the threshold, lifted or not, and is no click when let go.
	private var moved = false
	private var escape: Any?

	/// How far an island moves aside: the lifted one's height and the space after it.
	func shift(of index: Int, spacing: Double) -> Double {
		guard dragged != nil, let target, index != from else { return 0 }
		if from < index, index <= target { return -(lifted.height + spacing) }
		if target <= index, index < from { return lifted.height + spacing }
		return 0
	}

	/// The order is read once, when the island lifts. A lift left over from a press whose
	/// end never came, the view gone under it, gives way to the new one.
	func move(_ name: String, by translation: CGSize, names: @autoclosure () -> [String]) {
		guard !cancelled else { return }
		if dragged != name {
			guard hypot(translation.width, translation.height) >= Self.threshold else { return }
			moved = true
			// The island still settling moves the frames once more: the lift waits for them.
			guard settling == nil else { return }
			lift(name, in: names())
		}
		guard dragged == name else { return }

		// Measured in the stack, the gesture's translation has the scrolling in it already.
		pointer = translation.height
		scrolled = 0
		place()
	}

	private func place() {
		translation = min(max(pointer + scrolled, reach.lowerBound), reach.upperBound)
		let centre = lifted.midY + self.translation
		let slot = middles.indices.count { $0 != from && middles[$0] < centre }
		if slot != target { target = slot }
	}

	/// Lets go of the island, writing its new place with `write` in the same animation that
	/// brings it there: the file reorders the islands at once, and the offset going back to
	/// zero then carries the island from where it was let go into its place. True when the
	/// pointer never went past the threshold: a press that did is no click, even one that
	/// could not lift.
	func end(_ name: String, write: (_ target: String) -> Void) -> Bool {
		defer {
			cancelled = false
			moved = false
		}
		guard dragged == name else { return !moved }
		let target = target
		settle(name) {
			if let target, target != from { write(order[target]) }
		}
		return false
	}

	private func lift(_ name: String, in names: [String]) {
		guard let frame = frames[name], let index = names.firstIndex(of: name) else { return }
		order = names
		// An island not measured yet sorts after every place, which leaves it where it is.
		middles = names.map { frames[$0]?.midY ?? .infinity }
		from = index
		lifted = frame
		let laidOut = names.compactMap { frames[$0] }
		let top = laidOut.map(\.minY).min() ?? frame.minY
		let bottom = laidOut.map(\.maxY).max() ?? frame.maxY
		reach = (top - frame.minY)...(bottom - frame.maxY)
		watchEscape()
		autoScroll.start { [weak self] distance in
			self?.scrolled += distance
			self?.place()
		} lost: { [weak self] in
			self?.abandon()
		}
		withAnimation(Self.spring) {
			dragged = name
			target = index
		}
	}

	/// Puts the island back where it was lifted from, and the rest of the press moves nothing:
	/// for Escape, and for a reload that changes the islands under the lift.
	func cancel() {
		guard let name = dragged else { return }
		cancelled = true
		settle(name) {}
	}

	/// Puts the island back for a press that will never end, whose gesture is gone: no end
	/// comes to clear the press, and the next one elsewhere would be taken for its rest.
	func abandon() {
		cancel()
		cancelled = false
		moved = false
	}

	/// Drops everything at once, for a page that is gone: there is nothing left to animate.
	func reset() {
		unwatchEscape()
		autoScroll.stop()
		dragged = nil
		target = nil
		translation = 0
		settling = nil
		cancelled = false
		moved = false
	}

	private func settle(_ name: String, _ write: () -> Void) {
		unwatchEscape()
		autoScroll.stop()
		settling = name
		withAnimation(Self.spring, completionCriteria: .logicallyComplete) {
			write()
			dragged = nil
			translation = 0
			target = nil
		} completion: { [weak self] in
			if self?.settling == name { self?.settling = nil }
		}
	}

	private func watchEscape() {
		unwatchEscape()
		escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			let code = event.keyCode
			let handled = MainActor.assumeIsolated {
				guard code == 53, let self, self.dragged != nil else { return false }
				self.cancel()
				return true
			}
			return handled ? nil : event
		}
	}

	private func unwatchEscape() {
		if let escape { NSEvent.removeMonitor(escape) }
		escape = nil
	}
}

/// Scrolls the page while a lifted island is held at its top or bottom, so a place out of
/// sight can be reached: twelve workspaces do not fit the window.
@MainActor
final class IslandAutoScroll {
	/// How near the edge the pointer starts the scrolling, and the most a tick scrolls, right
	/// at the edge or past it.
	static let edge = 40.0
	static let fastest = 20.0

	/// The page's own scroll view, found from inside it: SwiftUI hands out no way to scroll it
	/// by a distance.
	weak var scrollView: NSScrollView?
	private var timer: Timer?
	private var scrolled: (Double) -> Void = { _ in }
	private var lost: () -> Void = {}
	/// Ticks since the button came up. A real release reaches the gesture well within them.
	private var released = 0

	/// `scrolled` gets the distance of every tick that moved the page, down positive. `lost`
	/// is for a press whose end the gesture never hears: the window closed under it, or the
	/// button came up and the gesture did not end.
	func start(scrolled: @escaping (Double) -> Void, lost: @escaping () -> Void) {
		stop()
		self.scrolled = scrolled
		self.lost = lost
		released = 0
		let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.tick() }
		}
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	func stop() {
		timer?.invalidate()
		timer = nil
	}

	private func tick() {
		released = NSEvent.pressedMouseButtons & 1 == 0 ? released + 1 : 0
		if released > 10 || scrollView.map({ $0.window?.isVisible != true }) == true {
			stop()
			lost()
			return
		}

		// SwiftUI's document view is flipped, which the distances below count on.
		guard let scrollView, let window = scrollView.window, let document = scrollView.documentView,
		      document.isFlipped else { return }
		let point = scrollView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
		let height = scrollView.bounds.height
		let insets = scrollView.contentInsets
		let fromTop = (scrollView.isFlipped ? point.y : height - point.y) - insets.top
		let fromBottom = height - insets.top - insets.bottom - fromTop

		// Faster the deeper in, slow at first so a pointer passing by barely moves the page.
		let depth = fromTop < Self.edge ? -(Self.edge - fromTop) / Self.edge
			: fromBottom < Self.edge ? (Self.edge - fromBottom) / Self.edge : 0
		guard depth != 0 else { return }
		let step = min(max(depth * abs(depth), -1), 1) * Self.fastest

		let clip = scrollView.contentView
		let bottom = max(-insets.top, document.frame.height - clip.bounds.height + insets.bottom)
		let next = min(max(clip.bounds.origin.y + step, -insets.top), bottom)
		let distance = next - clip.bounds.origin.y
		guard distance != 0 else { return }
		clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: next))
		scrollView.reflectScrolledClipView(clip)
		scrolled(distance)
	}
}

/// Hands the scroll view around the page to the auto-scroll once it is in a window.
private struct ScrollViewProbe: NSViewRepresentable {
	let found: (NSScrollView?) -> Void

	func makeNSView(context: Context) -> Probe { Probe(found: found) }

	func updateNSView(_ view: Probe, context: Context) {}

	final class Probe: NSView {
		let found: (NSScrollView?) -> Void

		init(found: @escaping (NSScrollView?) -> Void) {
			self.found = found
			super.init(frame: .zero)
		}

		required init?(coder: NSCoder) { nil }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			found(enclosingScrollView)
		}

		// Behind the islands, and never what a click lands on.
		override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
}

/// The islands in their own stack, the one view that watches a drag: the lifted island
/// follows the pointer above the others, which slide aside to open the place it would
/// land in.
private struct IslandStack: View {
	/// Close, as Raycast keeps its islands. The drag counts it into how far the others make way.
	static let spacing = 8.0
	nonisolated static let space = "islands"

	@ObservedObject var model: SettingsModel
	@ObservedObject var drag: IslandDrag

	private var islands: [(id: UUID, index: Int, workspace: Config.Workspace)] {
		model.workspaces.enumerated().map { (model.islandID(for: $1.name), $0, $1) }
	}

	var body: some View {
		VStack(spacing: Self.spacing) {
			// By an identity that outlives the name: a field being typed in stays with its workspace when
			// the order changes, and when the name does.
			ForEach(islands, id: \.id) { island in
				let (index, workspace) = (island.index, island.workspace)
				let lifted = drag.dragged == workspace.name
				WorkspaceIsland(
						model: model, workspace: workspace, number: index + 1, dragging: drag.dragged != nil
					)
					.scaleEffect(lifted ? 1.02 : 1)
					.shadow(color: .black.opacity(lifted ? 0.18 : 0), radius: lifted ? 12 : 0, y: lifted ? 4 : 0)
					.offset(y: drag.shift(of: index, spacing: Self.spacing))
					.animation(IslandDrag.spring, value: drag.target)
					// Outside the spring: the lifted island keeps up with the pointer.
					.offset(y: lifted ? drag.translation : 0)
					.zIndex(lifted || drag.settling == workspace.name ? 1 : 0)
					// After the offsets, so they measure the place in the layout and not the one shown.
					.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
						drag.frames[workspace.name] = frame
					}
			}
		}
		.coordinateSpace(.named(Self.space))
		.background(ScrollViewProbe { [weak drag] in drag?.autoScroll.scrollView = $0 })
		.onDisappear {
			drag.reset()
			// A window closed under the pointer sends no exit, and the island would stay lit.
			if model.workspacesPointer.hoveredIsland != nil { model.workspacesPointer.hoveredIsland = nil }
			if model.workspacesPointer.hoveredApp != nil { model.workspacesPointer.hoveredApp = nil }
		}
		// The snapshot counts places by index, which a reload with other names would shift.
		.onChange(of: model.workspaces.map(\.name)) { _, names in
			guard let lifted = drag.dragged else { return }
			if names.contains(lifted) { drag.cancel() } else { drag.abandon() }
		}
		// Over Add Workspace too, which a dragged island passes on its way to the bottom.
		.zIndex(1)
	}
}

/// A workspace as one of Raycast's collapsible groups: the header alone while closed, its settings
/// and its apps under it while open. Islands come in file order, which is the order
/// `workspace focus <n>` counts them in, and the header is what is dragged to change it.
private struct WorkspaceIsland: View {
	@ObservedObject var model: SettingsModel
	let workspace: Config.Workspace
	let number: Int
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
				model.islandDrag.move(workspace.name, by: value.translation, names: model.workspaces.map(\.name))
			}
			.onEnded { _ in
				let click = model.islandDrag.end(workspace.name) { model.moveWorkspace(workspace.name, to: $0) }
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
			HeaderApps(
				title: DisplayChoice.title(of: workspace.display), apps: workspace.apps, isDefault: workspace.isDefault
			)
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
			Button("Move Up") { move(by: -1) }
				.disabled(neighbour(-1) == nil)
			Button("Move Down") { move(by: 1) }
				.disabled(neighbour(1) == nil)
		}
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(.isButton)
		.accessibilityValue(expanded ? "Expanded" : "Collapsed")
		.accessibilityAction { model.toggleExpanded(workspace.name) }
		.accessibilityAction(named: "Move Up") { move(by: -1) }
		.accessibilityAction(named: "Move Down") { move(by: 1) }
	}

	/// What a drag does, for the keyboard and VoiceOver: a step towards the top or the bottom.
	private func move(by offset: Int) {
		if let target = neighbour(offset) { model.moveWorkspace(workspace.name, to: target) }
	}

	private func neighbour(_ offset: Int) -> String? {
		let index = number - 1 + offset
		return model.workspaces.indices.contains(index) ? model.workspaces[index].name : nil
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
			.fill(.primary.opacity(lit ? 0.06 : 0.035))
			.animation(.easeOut(duration: 0.15), value: lit)
	}
}

/// What the header says on its right: the display, then the apps that open here as icons, so the
/// island tells what is in it without being opened.
private struct HeaderApps: View {
	static let size = 16.0
	static let limit = 7

	let title: String
	let apps: [String]
	let isDefault: Bool

	var body: some View {
		HStack(spacing: 8) {
			Text(title)
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
		return ([title] + names + (isDefault ? ["default"] : [])).joined(separator: ", ")
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
