import AppKit
import KumikoCore
import KumikoMenuBar
import SwiftUI

/// The settings window, laid out the way Raycast lays out its own: a sidebar of the app's own pages
/// and of its modules, and a page for each with the module's switch in its top right corner.
/// kumiko.toml stays the source of every module value. For now the pages show what the file says;
/// changing values from here waits for a writer that keeps the file as the user wrote it.
@MainActor
final class SettingsWindow {
	private let model: SettingsModel
	private var window: NSWindow?
	private var closeObserver: (any NSObjectProtocol)?
	private var keyObserver: (any NSObjectProtocol)?

	init(app: AppDelegate) {
		model = SettingsModel(configFile: app.paths.configFile, config: app.config, error: app.configError?.description) {
			[weak app] in app?.menuBar?.items()
		}

		app.bus.subscribe { [weak self, unowned app] event in
			guard case .configReloaded = event else { return }
			self?.model.update(app.config, error: app.configError?.description)
		}
	}

	/// Shows the window, on the page named (its id, like `borders`) when one is.
	@discardableResult
	func show(pane name: String? = nil) -> Bool {
		if let name {
			guard let pane = Pane(rawValue: name.lowercased()) else { return false }
			model.pane = pane
		}

		if window == nil {
			let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
			window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
			window.title = "kumiko Settings"
			window.titleVisibility = .hidden
			window.titlebarAppearsTransparent = true
			// A window with a toolbar gets the larger corner radius Raycast's has, and its traffic
			// lights come down into the sidebar's corner. The toolbar itself stays empty.
			window.toolbar = NSToolbar(identifier: "kumiko.settings")
			window.toolbarStyle = .unified
			window.isMovableByWindowBackground = true
			window.isReleasedWhenClosed = false
			window.setContentSize(NSSize(width: 860, height: 600))
			window.center()
			window.setFrameAutosaveName("kumiko.settings")
			self.window = window

			closeObserver = NotificationCenter.default.addObserver(
				forName: NSWindow.willCloseNotification, object: window, queue: .main
			) { _ in
				MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
			}
			// Coming back from System Settings with a permission granted: the warning goes away.
			keyObserver = NotificationCenter.default.addObserver(
				forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.model.refresh() }
			}
		}

		model.refresh()

		// kumiko has no Dock icon, and an app without one gets no menu bar and no place in cmd-tab;
		// it has one while the window is in front, as on an empty workspace.
		NSApp.setActivationPolicy(.regular)
		NSApp.activate()
		window?.makeKeyAndOrderFront(nil)
		return true
	}
}

@MainActor
final class SettingsModel: ObservableObject {
	let configFile: URL
	@Published private(set) var config: Config
	@Published private(set) var error: String?
	// In the model rather than in @State: the State macro needs a plugin only Xcode ships.
	@Published var pane = Pane.general
	@Published private(set) var opensAtLogin = LoginItem.isEnabled
	@Published private(set) var payloadVersion: String?
	@Published private(set) var missing = Permission.missing
	@Published var search = ""
	/// The menu bar items either side of the divider, nil while menu bar hiding is off.
	@Published private(set) var menuBarItems: (hidden: [MenuBarHider.Item], shown: [MenuBarHider.Item])?
	private let readMenuBar: () -> (hidden: [MenuBarHider.Item], shown: [MenuBarHider.Item])?

	init(
		configFile: URL, config: Config, error: String?,
		menuBar: @escaping () -> (hidden: [MenuBarHider.Item], shown: [MenuBarHider.Item])?
	) {
		self.configFile = configFile
		self.config = config
		self.error = error
		readMenuBar = menuBar
	}

	func update(_ config: Config, error: String?) {
		self.config = config
		self.error = error
	}

	/// What lives outside the config and may have changed while the window was closed.
	func refresh() {
		opensAtLogin = LoginItem.isEnabled
		payloadVersion = ScriptingAddition.handshake()
		missing = Permission.missing
		menuBarItems = readMenuBar()
	}

	/// The pages the search leaves, in the order given.
	func matching(_ panes: [Pane]) -> [Pane] {
		let query = search.trimmingCharacters(in: .whitespaces)
		return query.isEmpty ? panes : panes.filter { $0.title.localizedCaseInsensitiveContains(query) }
	}

	func setOpensAtLogin(_ on: Bool) {
		try? LoginItem.setEnabled(on)
		opensAtLogin = LoginItem.isEnabled
	}

	func openInEditor() {
		NSWorkspace.shared.open(configFile)
	}

	func revealInFinder() {
		NSWorkspace.shared.activateFileViewerSelecting([configFile])
	}
}

/// A page of the window. The raw value is what `kumiko settings <page>` takes.
enum Pane: String, CaseIterable, Identifiable {
	case general, advanced, about
	case windows, workspaces, rules, hotkeys, bar, borders, menubar, vim

	static let app: [Pane] = [.general, .advanced, .about]
	static let modules: [Pane] = [.windows, .workspaces, .rules, .hotkeys, .bar, .borders, .menubar, .vim]

	var id: Self { self }

	var title: String {
		switch self {
		case .general: "General"
		case .advanced: "Advanced"
		case .about: "About"
		case .windows: "Window Manager"
		case .workspaces: "Workspaces"
		case .rules: "Window Rules"
		case .hotkeys: "Hotkeys"
		case .bar: "Bar"
		case .borders: "Borders"
		case .menubar: "Menu Bar"
		case .vim: "Vim"
		}
	}

	var subtitle: String {
		switch self {
		case .general: "kumiko as a whole"
		case .advanced: "The config file and what only it can change"
		case .about: "kumiko \(Kumiko.version)"
		case .windows: "Tiles windows into workspaces of their own"
		case .workspaces: "Virtual desktops, and the apps that open on each"
		case .rules: "Which windows are tiled and which are left alone"
		case .hotkeys: "Key bindings, modes and remaps"
		case .bar: "Workspaces and status along the screen edge"
		case .borders: "A frame around the focused window"
		case .menubar: "Hides the menu bar items you rarely need"
		case .vim: "Vim modes in every text field"
		}
	}

	var symbol: String {
		switch self {
		case .general: "gearshape.fill"
		case .advanced: "wrench.and.screwdriver.fill"
		case .about: "info.circle.fill"
		case .windows: "rectangle.split.2x1.fill"
		case .workspaces: "square.grid.2x2.fill"
		case .rules: "list.bullet.rectangle.fill"
		case .hotkeys: "command"
		case .bar: "menubar.rectangle"
		case .borders: "square.dashed"
		case .menubar: "menubar.arrow.up.rectangle"
		case .vim: "character.cursor.ibeam"
		}
	}

	var tint: SwiftUI.Color {
		switch self {
		case .general, .advanced, .about: .gray
		case .windows: .blue
		case .workspaces: .cyan
		case .rules: .purple
		case .hotkeys: .indigo
		case .bar: .orange
		case .borders: .pink
		case .menubar: .teal
		case .vim: .green
		}
	}

	/// What the module cannot work without; General asks for everything.
	var permissions: [Permission] {
		switch self {
		case .general: Permission.allCases
		case .windows, .workspaces, .rules, .borders: [.accessibility]
		case .hotkeys, .vim: [.accessibility, .inputMonitoring]
		case .advanced, .about, .bar, .menubar: []
		}
	}

	/// The module switch in the page's corner; nil for the app's own pages.
	func isEnabled(in config: Config) -> Bool? {
		switch self {
		case .general, .advanced, .about: nil
		case .windows: config.wm.enabled
		case .workspaces: config.wm.useWorkspaces
		case .rules: config.wm.useRules
		case .hotkeys: config.hotkeys.enabled
		case .bar: config.bar.enabled
		case .borders: config.borders.enabled
		case .menubar: config.menuBar.enabled
		case .vim: config.vim.enabled
		}
	}
}

// MARK: - Layout

private struct SettingsView: View {
	@ObservedObject var model: SettingsModel

	var body: some View {
		HStack(spacing: 0) {
			Sidebar(model: model)
				.frame(width: 232)
				.padding(8)

			ScrollView {
				Page(model: model)
					.padding(.horizontal, 24)
					.padding(.top, 44)
					.padding(.bottom, 24)
					.frame(maxWidth: 600)
					.frame(maxWidth: .infinity)
			}
			.overlay(alignment: .topTrailing) {
				if let enabled = model.pane.isEnabled(in: model.config) {
					// On the line of the traffic lights, where Raycast keeps a page's own switch.
					Toggle("", isOn: .constant(enabled))
						.toggleStyle(.switch)
						.controlSize(.small)
						.labelsHidden()
						.disabled(true)
						.help(enabled ? "On in kumiko.toml" : "Off in kumiko.toml")
						.padding(.top, 19)
						.padding(.trailing, 18)
				}
			}
		}
		.frame(minWidth: 780, minHeight: 500)
		.background(SwiftUI.Color(nsColor: .textBackgroundColor))
		// Up under the transparent title bar, so the traffic lights sit inside the sidebar.
		.ignoresSafeArea()
	}
}

/// Raycast's sidebar: a panel inset from the window's edges, with the traffic lights in its
/// corner, a search field and the pages.
private struct Sidebar: View {
	@ObservedObject var model: SettingsModel

	var body: some View {
		VStack(alignment: .leading, spacing: 1) {
			Spacer().frame(height: 40)

			HStack(spacing: 6) {
				Image(systemName: "magnifyingglass")
					.foregroundStyle(.secondary)
				TextField("Search settings…", text: $model.search)
					.textFieldStyle(.plain)
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 6)
			.background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.05)))
			.padding(.bottom, 12)

			ForEach(model.matching(Pane.app)) { SidebarRow(pane: $0, model: model) }

			if !model.matching(Pane.app).isEmpty && !model.matching(Pane.modules).isEmpty {
				Spacer().frame(height: 14)
			}

			ForEach(model.matching(Pane.modules)) { SidebarRow(pane: $0, model: model) }

			Spacer()
		}
		.padding(.horizontal, 10)
		.frame(maxHeight: .infinity)
		.background(
			// Concentric with the window's corners, 8 pt inside them.
			RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.primary.opacity(0.035))
		)
	}
}

private struct SidebarRow: View {
	let pane: Pane
	@ObservedObject var model: SettingsModel

	var body: some View {
		Button {
			model.pane = pane
		} label: {
			HStack(spacing: 8) {
				Tile(pane: pane, size: 20)
				Text(pane.title)
				Spacer()
				if pane.isEnabled(in: model.config) == false {
					Text("Off")
						.font(.caption)
						.foregroundStyle(.tertiary)
				}
			}
			.padding(.horizontal, 8)
			.frame(height: 30)
			.contentShape(Rectangle())
			.background(
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.fill(SwiftUI.Color.primary.opacity(model.pane == pane ? 0.07 : 0))
			)
		}
		.buttonStyle(.plain)
	}
}

/// A pane's symbol on a tile of its color, the way app icons sit in Raycast's lists.
private struct Tile: View {
	let pane: Pane
	let size: CGFloat

	var body: some View {
		RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
			.fill(pane.tint.gradient)
			.frame(width: size, height: size)
			.overlay(
				Image(systemName: pane.symbol)
					.font(.system(size: size * 0.5, weight: .semibold))
					.foregroundStyle(.white)
			)
	}
}

private struct Page: View {
	@ObservedObject var model: SettingsModel

	var body: some View {
		VStack(spacing: 20) {
			Header(pane: model.pane)

			ForEach(model.pane.permissions.filter(model.missing.contains), id: \.title) { permission in
				PermissionWarning(permission: permission) { model.refresh() }
			}

			if let error = model.error {
				Card {
					Label(error, systemImage: "exclamationmark.triangle.fill")
						.foregroundStyle(.red)
						.padding(.vertical, 10)
				}
			}

			switch model.pane {
			case .general: GeneralPage(model: model)
			case .advanced: AdvancedPage(model: model)
			case .about: AboutPage()
			case .windows: WindowsPage(wm: model.config.wm, payloadVersion: model.payloadVersion)
			case .workspaces: WorkspacesPage(workspaces: model.config.workspaces)
			case .rules: RulesPage(wm: model.config.wm)
			case .hotkeys: HotkeysPage(hotkeys: model.config.hotkeys)
			case .bar: BarPage(bar: model.config.bar)
			case .borders: BordersPage(borders: model.config.borders)
			case .menubar: MenuBarPage(menuBar: model.config.menuBar, items: model.menuBarItems)
			case .vim: VimPage(vim: model.config.vim)
			}
		}
	}
}

/// The page's tile, title and the line under it.
private struct Header: View {
	let pane: Pane

	var body: some View {
		VStack(spacing: 6) {
			Tile(pane: pane, size: 56)
				.padding(.bottom, 6)
			Text(pane.title)
				.font(.system(size: 24, weight: .bold))
			Text(pane.subtitle)
				.foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity)
		.padding(.bottom, 16)
	}
}

/// Raycast's warning for a permission the page needs: an amber note with the button that asks.
private struct PermissionWarning: View {
	let permission: Permission
	let requested: () -> Void

	var body: some View {
		HStack(alignment: .top, spacing: 10) {
			Image(systemName: "exclamationmark.triangle")
				.foregroundStyle(.orange)
			VStack(alignment: .leading, spacing: 8) {
				Text(permission.reason)
					.font(.callout)
					.fixedSize(horizontal: false, vertical: true)
				Button("Request Permission") {
					permission.request()
					requested()
				}
				.controlSize(.small)
			}
			Spacer(minLength: 0)
		}
		.padding(14)
		.background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.orange.opacity(0.07)))
		.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.orange.opacity(0.35)))
	}
}

/// A rounded group of rows, Raycast's way of grouping settings.
private struct Card<Content: View>: View {
	var title: String?
	@ViewBuilder var content: Content

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			if let title {
				Text(title)
					.font(.system(size: 13, weight: .medium))
					.padding(.horizontal, 12)
					.padding(.bottom, 4)
			}

			VStack(spacing: 0) {
				content
			}
			.padding(.horizontal, 12)
			.background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.035)))
		}
	}
}

/// One line of a card: a title on the left, its value or control on the right.
private struct Row<Trailing: View>: View {
	let title: String
	var detail: String?
	var last = false
	@ViewBuilder var trailing: Trailing

	var body: some View {
		VStack(spacing: 0) {
			HStack(alignment: .firstTextBaseline) {
				VStack(alignment: .leading, spacing: 2) {
					Text(title)
					if let detail {
						Text(detail)
							.font(.system(size: 11))
							.foregroundStyle(.secondary)
					}
				}
				Spacer(minLength: 16)
				trailing
			}
			.padding(.vertical, 10)

			if !last {
				Divider()
			}
		}
	}
}

extension Row where Trailing == Text {
	init(_ title: String, value: String, detail: String? = nil, last: Bool = false) {
		self.init(title: title, detail: detail, last: last) {
			Text(value).foregroundStyle(.secondary)
		}
	}
}

/// A setting that is on or off, shown as the switch it will become once the window can write.
private struct SwitchRow: View {
	let title: String
	var detail: String?
	let on: Bool
	var last = false

	var body: some View {
		Row(title: title, detail: detail, last: last) {
			Toggle("", isOn: .constant(on))
				.toggleStyle(.switch)
				.labelsHidden()
				.disabled(true)
		}
	}
}

private func points(_ value: Double) -> String {
	value == value.rounded() ? "\(Int(value)) pt" : String(format: "%.1f pt", value)
}

private func list(_ items: [String]) -> String {
	items.isEmpty ? "None" : items.joined(separator: ", ")
}

// MARK: - App pages

private struct GeneralPage: View {
	@ObservedObject var model: SettingsModel

	var body: some View {
		Card {
			Row(title: "Open at Login", detail: "Start kumiko when you log in.", last: true) {
				Toggle("", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
					.toggleStyle(.switch)
					.labelsHidden()
					.disabled(!LoginItem.isAvailable)
			}
		}
	}
}

/// The config file, and what only the file can change: shown so it can be checked at a glance.
private struct AdvancedPage: View {
	@ObservedObject var model: SettingsModel

	var body: some View {
		Card(title: "Config File") {
			Row(title: "Location", detail: model.configFile.path(percentEncoded: false).replacingOccurrences(
				of: NSHomeDirectory(), with: "~"
			)) {
				HStack {
					Button("Reveal in Finder") { model.revealInFinder() }
					Button("Open in Editor") { model.openInEditor() }
				}
			}
			Row(
				"Changes",
				value: "",
				detail: "Every module setting lives in this file. Saving it applies the change at once.",
				last: true
			)
		}
	}
}

private struct AboutPage: View {
	var body: some View {
		Card {
			Row("Version", value: Kumiko.version)
			Row("Command line", value: "kumiko --help", last: true)
		}
	}
}

// MARK: - Module pages

private struct WindowsPage: View {
	let wm: Config.WM
	let payloadVersion: String?

	var body: some View {
		Card(title: "Layout") {
			Row("Gap", value: "\(wm.gap) pt")
			Row("Padding", value: Self.describe(wm.padding), last: true)
		}

		Card(title: "Hidden Workspaces") {
			SwitchRow(
				title: "Hide apps with no window on screen",
				detail: "An app whose windows are all on hidden workspaces is hidden, like cmd-h.",
				on: wm.hideApps,
				last: true
			)
		}

		Card(title: "Shadows") {
			SwitchRow(title: "Window shadows", on: wm.shadows)
			Row(
				"Scripting addition",
				value: payloadVersion.map { "Loaded, version \($0)" } ?? "Not loaded",
				detail: payloadVersion == nil ? "Turning shadows off needs it: sudo kumiko sa load" : nil,
				last: true
			)
		}
	}

	private static func describe(_ padding: Insets) -> String {
		let sides = [padding.top, padding.bottom, padding.left, padding.right]
		if Set(sides).count == 1 { return "\(padding.top) pt" }
		return "\(padding.top) · \(padding.bottom) · \(padding.left) · \(padding.right) pt"
	}
}

private struct WorkspacesPage: View {
	let workspaces: [Config.Workspace]

	var body: some View {
		if workspaces.isEmpty {
			Card {
				Row("Workspaces", value: "1…9 on the main display", last: true)
			}
		}

		ForEach(Array(workspaces.enumerated()), id: \.offset) { index, workspace in
			Card(title: "\(index + 1). \(workspace.name)") {
				Row("Display", value: workspace.display.capitalized)
				Row(
					"Apps",
					value: workspace.isDefault ? list(workspace.apps + ["every other app"]) : list(workspace.apps),
					last: workspace.stack.isEmpty && workspace.last.isEmpty
				)
				if !workspace.stack.isEmpty {
					Row("Kept in one stack", value: list(workspace.stack), last: workspace.last.isEmpty)
				}
				if !workspace.last.isEmpty {
					Row("Always last", value: list(workspace.last), last: true)
				}
			}
		}
	}
}

private struct RulesPage: View {
	let wm: Config.WM

	var body: some View {
		Card {
			SwitchRow(
				title: "Manage windows by default",
				detail: "For windows no rule below speaks about.",
				on: wm.manage,
				last: true
			)
		}

		Card(title: "Rules") {
			if wm.rules.isEmpty {
				Row("Rules", value: "None", last: true)
			}
			ForEach(Array(wm.rules.enumerated()), id: \.offset) { index, rule in
				Row(
					rule.app.map(Self.readable) ?? "Any app",
					value: rule.manage ? "Managed" : "Left alone",
					detail: rule.title.map { "Title: \(Self.readable($0))" },
					last: index == wm.rules.count - 1
				)
			}
		}
	}

	/// `Arc|Claude|Code` written the way people write a list.
	private static func readable(_ pattern: String) -> String {
		pattern.replacingOccurrences(of: "|", with: ", ")
	}
}

private struct HotkeysPage: View {
	let hotkeys: Config.Hotkeys

	var body: some View {
		Card(title: "Bindings") {
			Row("Default mode", value: "\(hotkeys.bindings.count)")
			Row("Every mode", value: "\(hotkeys.global.count)")
			Row("Modes", value: list(hotkeys.modes.keys.sorted()), last: true)
		}

		Card(title: "Exceptions") {
			Row("No hotkeys in", value: list(hotkeys.blacklist), last: true)
		}
	}
}

private struct BarPage: View {
	let bar: Config.Bar

	var body: some View {
		Card(title: "Placement") {
			Row("Position", value: bar.position.rawValue.capitalized)
			Row("Height", value: points(bar.height), last: true)
		}

		Card(title: "Items") {
			Row("Left", value: list(bar.left))
			Row("Right", value: list(bar.right), last: true)
		}
	}
}

private struct BordersPage: View {
	let borders: Config.Borders

	var body: some View {
		Card(title: "Look") {
			Row("Width", value: points(borders.width))
			Row(title: "Color", detail: "Corners follow each window's own radius.", last: true) {
				RoundedRectangle(cornerRadius: 5)
					.fill(SwiftUI.Color(
						.sRGB, red: borders.color.red, green: borders.color.green, blue: borders.color.blue,
						opacity: borders.color.alpha
					))
					.frame(width: 44, height: 22)
					.overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
			}
		}

		Card(title: "Exceptions") {
			Row("No border for", value: list(borders.blacklist), last: true)
		}
	}
}

private struct MenuBarPage: View {
	let menuBar: Config.MenuBar
	let items: (hidden: [MenuBarHider.Item], shown: [MenuBarHider.Item])?

	var body: some View {
		if let items {
			ItemsCard(title: "Always Shown", items: items.shown, empty: "No items right of the divider.")
			ItemsCard(
				title: "Hidden",
				items: items.hidden,
				empty: "Cmd-drag items to the left of the divider to hide them."
			)
		}

		Card(title: "Hiding") {
			Row(
				"Hide again after",
				value: menuBar.rehide == 0 ? "Never" : "\(Int(menuBar.rehide)) s",
				detail: "Cmd-drag an item across the divider to move it between the lists.",
				last: true
			)
		}
	}
}

/// Menu bar items as rows, each with its app's icon.
private struct ItemsCard: View {
	let title: String
	let items: [MenuBarHider.Item]
	let empty: String

	var body: some View {
		Card(title: title) {
			if items.isEmpty {
				Row(title: empty, last: true) { EmptyView() }
			}
			ForEach(Array(items.enumerated()), id: \.offset) { index, item in
				VStack(spacing: 0) {
					HStack(spacing: 8) {
						if let icon = NSRunningApplication(processIdentifier: item.pid)?.icon {
							Image(nsImage: icon)
								.resizable()
								.frame(width: 18, height: 18)
						}
						Text(item.name)
						Spacer()
					}
					.padding(.vertical, 10)

					if index < items.count - 1 {
						Divider()
					}
				}
			}
		}
	}
}

private struct VimPage: View {
	let vim: Config.Vim

	var body: some View {
		Card(title: "Exceptions") {
			Row("Off in", value: list(vim.blacklist), last: true)
		}

		Card(title: "Startup") {
			Row("Commands", value: vim.commands.isEmpty ? "None" : "\(vim.commands.count)", last: true)
		}
	}
}
