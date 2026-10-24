import AppKit
import KumikoCore
import KumikoMenuBar
import SwiftUI

/// The settings window, laid out the way Raycast lays out its own: a sidebar of the app's own pages
/// and of its modules, and a page for each with the module's switch in its top right corner.
/// kumiko.toml stays the source of every module value: the pages show what the file says, and a
/// control changed here rewrites only its own line of the file.
@MainActor
final class SettingsWindow {
	private let model: SettingsModel
	private var window: NSWindow?
	private var closeObserver: (any NSObjectProtocol)?
	private var keyObserver: (any NSObjectProtocol)?
	private let bringForward: () -> Void
	/// From show until the window is closed, minimized and hidden included: all that time kumiko
	/// keeps its Dock icon, the way back to the window.
	private(set) var isOpen = false

	init(app: AppDelegate) {
		model = SettingsModel(configFile: app.paths.configFile, config: app.config, error: app.configError?.description) {
			[weak app] in app?.menuBar?.items()
		}
		bringForward = { [weak app] in app?.tracker?.bringKumikoForward() }
		model.onRenameWorkspace = { [weak app] old, new in app?.manager?.rename(old, to: new) }

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
			) { [weak self] _ in
				MainActor.assumeIsolated {
					self?.isOpen = false
					_ = NSApp.setActivationPolicy(.accessory)
				}
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
		// it has one while the window is open.
		isOpen = true
		NSApp.setActivationPolicy(.regular)
		window?.makeKeyAndOrderFront(nil)

		// The new policy takes hold on the next pass of the run loop. Activated before that, kumiko
		// stays where cmd-tab put a newcomer, last.
		DispatchQueue.main.async { [weak self] in
			MainActor.assumeIsolated {
				NSApp.activate()
				self?.bringForward()
				self?.window?.makeKeyAndOrderFront(nil)
			}
		}
		return true
	}
}

@MainActor
final class SettingsModel: ObservableObject {
	let configFile: URL
	@Published private(set) var config: Config
	@Published private(set) var error: String?
	/// Why the last change made here was not written.
	@Published private(set) var writeError: String?
	// In the model rather than in @State: the State macro needs a plugin only Xcode ships.
	@Published var pane = Pane.general
	@Published private(set) var opensAtLogin = LoginItem.isEnabled
	@Published private(set) var payloadVersion: String?
	@Published private(set) var sipAllowsPayload = ScriptingAddition.isAllowedBySIP
	@Published private(set) var missing = Permission.missing
	@Published var search = ""
	/// The padding's sides are set one by one even while they are all the same.
	@Published var paddingPerSide = false
	/// The workspaces shown open, by name: a rename takes its name along, a removal drops it.
	@Published var expandedWorkspaces: Set<String> = []
	/// Not published from here: the pointer moves often, and only what it lights up is drawn again.
	let workspacesPointer = WorkspacesPointer()
	/// The workspace the Remove dialog asks about, named when it opened.
	@Published var workspacePendingRemoval: String?
	/// Tells the window manager a rename is coming, before the file has it.
	var onRenameWorkspace: (String, String) -> Void = { _, _ in }
	/// The bar's scale while its slider is dragged; written to the file when it is let go.
	@Published var draggedBarScale: Double?
	/// The colour panel's own last pick, kept while the file holds it. The panel works in the
	/// display's wide gamut and the file in sRGB: handed the clipped colour back, the panel would
	/// pull its cursor in from the edge of the wheel on every step of a drag.
	@Published private(set) var pickedBorderColor: SwiftUI.Color?
	private var pendingBorderColor: DispatchWorkItem?
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
		writeError = nil
		// A broken file may come back with none of its workspaces, and they would all close.
		if error == nil { expandedWorkspaces.formIntersection(config.workspaces.map(\.name)) }
		workspacesPointer.keep(Set(config.workspaces.map(\.name)))

		// A colour changed in the file by hand is no longer the panel's pick.
		if let picked = pickedBorderColor, pendingBorderColor == nil,
		   KumikoCore.Color(NSColor(picked))?.hex != config.borders.color?.hex
		{
			pickedBorderColor = nil
		}
	}

	/// Writes one key to kumiko.toml. The page shows the new value at once: the reload that applies
	/// it to the modules comes after the watcher's pause and brings back the same config.
	func set(_ table: String, _ key: String, _ value: TOMLValue?) {
		change([ConfigEdit(table: table, key: key, value: value)])
	}

	/// Writes several changes as one, so a control that touches more than one key never lands halfway.
	func change(_ changes: [any ConfigChange]) {
		guard !changes.isEmpty else { return }
		do throws(ConfigError) {
			config = try ConfigWriter.write(changes, to: configFile)
			writeError = nil
		} catch {
			writeError = error.description
		}
	}

	/// Takes the key out of the file, which puts it back to its default; nil while it has the default
	/// already, so a row shows no reset it has no use for.
	func reset<Value: Equatable>(_ keyPath: KeyPath<Config, Value>, _ table: String, _ key: String) -> (() -> Void)? {
		config[keyPath: keyPath] == Config()[keyPath: keyPath] ? nil : { self.set(table, key, nil) }
	}

	func binding<Value>(
		_ keyPath: KeyPath<Config, Value>, _ table: String, _ key: String, as value: @escaping (Value) -> TOMLValue
	) -> Binding<Value> {
		Binding(get: { self.config[keyPath: keyPath] }, set: { self.set(table, key, value($0)) })
	}

	func binding(_ keyPath: KeyPath<Config, Bool>, _ table: String, _ key: String) -> Binding<Bool> {
		binding(keyPath, table, key, as: TOMLValue.bool)
	}

	func binding(_ keyPath: KeyPath<Config, Int>, _ table: String, _ key: String) -> Binding<Int> {
		binding(keyPath, table, key, as: TOMLValue.int)
	}

	func binding(_ keyPath: KeyPath<Config, Double>, _ table: String, _ key: String) -> Binding<Double> {
		binding(keyPath, table, key, as: TOMLValue.double)
	}

	/// The colour panel reports every step of a drag. The file gets the colour once it has rested for
	/// a moment, not dozens of times a second, each of them a reload of the whole config.
	func pickBorderColor(_ color: SwiftUI.Color) {
		pickedBorderColor = color
		pendingBorderColor?.cancel()

		let write = DispatchWorkItem { [weak self] in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.pendingBorderColor = nil
				guard let picked = self.pickedBorderColor, let color = KumikoCore.Color(NSColor(picked)) else { return }
				self.set("borders", "color", .string(color.hex))
			}
		}
		pendingBorderColor = write
		DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: write)
	}

	/// Back to the frame's own colour; nil while it has that colour or follows the accent, where a
	/// reset has nothing to give back.
	var resetBorderColor: (() -> Void)? {
		guard let color = config.borders.color, color != Config.Borders.ownColor else { return nil }
		return { self.setBorderColor(Config.Borders.ownColor) }
	}

	/// Off, the frame gets its own colour back, which the picker then starts from.
	func useAccentBorderColor(_ on: Bool) {
		setBorderColor(on ? nil : Config.Borders.ownColor)
	}

	/// nil is the accent. A colour the picker has not written yet is dropped, so it does not land
	/// after this one.
	private func setBorderColor(_ color: KumikoCore.Color?) {
		pendingBorderColor?.cancel()
		pendingBorderColor = nil
		pickedBorderColor = nil
		set("borders", "color", .string(color?.hex ?? "accent"))
	}

	/// What lives outside the config and may have changed while the window was closed.
	func refresh() {
		opensAtLogin = LoginItem.isEnabled
		payloadVersion = ScriptingAddition.handshake()
		sipAllowsPayload = ScriptingAddition.isAllowedBySIP
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

	/// The module switch in the page's corner and the key of the file it writes; nil for the app's
	/// own pages.
	var enabledSetting: (keyPath: KeyPath<Config, Bool>, table: String, key: String)? {
		switch self {
		case .general, .advanced, .about: nil
		case .windows: (\.wm.enabled, "wm", "enabled")
		case .workspaces: (\.wm.useWorkspaces, "wm", "workspaces")
		case .rules: (\.wm.useRules, "wm", "rules")
		case .hotkeys: (\.hotkeys.enabled, "hotkeys", "enabled")
		case .bar: (\.bar.enabled, "bar", "enabled")
		case .borders: (\.borders.enabled, "borders", "enabled")
		case .menubar: (\.menuBar.enabled, "menubar", "enabled")
		case .vim: (\.vim.enabled, "vim", "enabled")
		}
	}

	func isEnabled(in config: Config) -> Bool? {
		enabledSetting.map { config[keyPath: $0.keyPath] }
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
				if let setting = model.pane.enabledSetting {
					// On the line of the traffic lights, where Raycast keeps a page's own switch.
					Toggle("", isOn: model.binding(setting.keyPath, setting.table, setting.key))
						.toggleStyle(.switch)
						.controlSize(.small)
						.labelsHidden()
						.help("\(setting.table).\(setting.key) in kumiko.toml")
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

			// A broken file refuses every write with its own error, which is already shown above.
			if let writeError = model.writeError, writeError != model.error {
				Card {
					Label(writeError, systemImage: "exclamationmark.triangle.fill")
						.foregroundStyle(.red)
						.padding(.vertical, 10)
				}
			}

			switch model.pane {
			case .general: GeneralPage(model: model)
			case .advanced: AdvancedPage(model: model)
			case .about: AboutPage()
			case .windows: WindowsPage(model: model)
			case .workspaces: WorkspacesPage(model: model)
			case .rules: RulesPage(model: model)
			case .hotkeys: HotkeysPage(hotkeys: model.config.hotkeys)
			case .bar: BarPage(model: model)
			case .borders: BordersPage(model: model)
			case .menubar: MenuBarPage(model: model)
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

/// What turning shadows off asks of SIP, in the same amber as a missing permission. The steps are
/// yabai's, whose scripting addition gets into Dock the same way.
private struct SIPNote: View {
	#if arch(arm64)
		private static let startup =
			"Shut down the Mac, then hold the power button until the startup options appear and choose Options."
		private static let command = "csrutil enable --without fs --without debug --without nvram"
	#else
		private static let startup = "Shut down the Mac, then hold Cmd-R while it starts."
		private static let command = "csrutil disable --with kext --with dtrace --with nvram --with basesystem"
	#endif

	var body: some View {
		HStack(alignment: .top, spacing: 10) {
			Image(systemName: "exclamationmark.triangle")
				.foregroundStyle(.orange)
			VStack(alignment: .leading, spacing: 8) {
				Text(
					"Turning shadows off needs System Integrity Protection partly disabled: only Dock may change "
						+ "other apps' windows, and kumiko gets into Dock through a scripting addition."
				)
				step(1, Self.startup)
				step(2, "In Recovery, open Utilities › Terminal and run:", command: Self.command)
				#if arch(arm64)
					step(3, "Restart, then in Terminal run this and restart again:", command: "sudo nvram boot-args=-arm64e_preview_abi")
					step(4, "Load the scripting addition:", command: "sudo kumiko sa load")
				#else
					step(3, "Restart and load the scripting addition:", command: "sudo kumiko sa load")
				#endif
				Link(
					"Full instructions in yabai's wiki",
					destination: URL(string: "https://github.com/koekeishiya/yabai/wiki/Disabling-System-Integrity-Protection")!
				)
			}
			.font(.callout)
			.fixedSize(horizontal: false, vertical: true)
			Spacer(minLength: 0)
		}
		.padding(14)
		.background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.orange.opacity(0.07)))
		.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.orange.opacity(0.35)))
	}

	private func step(_ number: Int, _ text: String, command: String? = nil) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text("\(number). \(text)")
			if let command {
				Text(command)
					.font(.system(.callout, design: .monospaced))
					.textSelection(.enabled)
					.padding(.horizontal, 8)
					.padding(.vertical, 4)
					.background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.05)))
			}
		}
	}
}

/// A rounded group of rows, Raycast's way of grouping settings.
struct Card<Content: View>: View {
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
struct Row<Trailing: View>: View {
	let title: String
	var detail: String?
	var last = false
	/// Puts the setting back to its default; the row shows a button for it when given one.
	var reset: (() -> Void)?
	@ViewBuilder var trailing: Trailing

	var body: some View {
		VStack(spacing: 0) {
			// Centred, as System Settings has it: a control with no text of its own, a switch or a
			// colour well, has no baseline to sit on and would ride up to the top of the row.
			HStack(alignment: .center) {
				VStack(alignment: .leading, spacing: 2) {
					Text(title)
					if let detail {
						Text(detail)
							.font(.system(size: 11))
							.foregroundStyle(.secondary)
					}
				}
				Spacer(minLength: 16)
				if let reset {
					Button(action: reset) {
						Image(systemName: "arrow.counterclockwise")
					}
					.buttonStyle(.borderless)
					.foregroundStyle(.secondary)
					.help("Back to the default")
				}
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

struct SwitchRow: View {
	let title: String
	var detail: String?
	let on: Binding<Bool>
	var disabled = false
	var last = false
	var reset: (() -> Void)?

	var body: some View {
		Row(title: title, detail: detail, last: last, reset: disabled ? nil : reset) {
			Toggle("", isOn: on)
				.toggleStyle(.switch)
				.labelsHidden()
				.disabled(disabled)
		}
	}
}

/// A number typed in or set a step at a time, its unit after it. A typed number is written when
/// the field is left or return is pressed, not with every key, and kept within the range.
private struct StepperRow: View {
	let title: String
	var detail: String?
	let value: Binding<Double>
	let range: ClosedRange<Double>
	var step = 1.0
	/// Whole numbers only, for keys the file reads as integers.
	var whole = false
	var unit = "pt"
	/// What 0 stands for, written in place of the unit: "Never".
	var zero: String?
	var last = false
	var reset: (() -> Void)?

	var body: some View {
		let clamped = Binding(
			get: { value.wrappedValue },
			set: { value.wrappedValue = min(max(whole ? $0.rounded() : $0, range.lowerBound), range.upperBound) }
		)

		Row(title: title, detail: detail, last: last, reset: reset) {
			HStack(spacing: 6) {
				TextField("", value: clamped, format: .number.precision(.fractionLength(whole ? 0...0 : 0...1)))
					.textFieldStyle(.roundedBorder)
					.multilineTextAlignment(.trailing)
					.monospacedDigit()
					.frame(width: 56)
				Text(value.wrappedValue == 0 ? zero ?? unit : unit)
					.foregroundStyle(.secondary)
				Stepper("", value: clamped, in: range, step: step)
					.labelsHidden()
			}
		}
	}
}

extension Binding where Value == Int {
	/// For a field that edits numbers as Doubles.
	var asDouble: Binding<Double> {
		Binding<Double>(get: { Double(wrappedValue) }, set: { wrappedValue = Int($0.rounded()) })
	}
}

private func points(_ value: Double) -> String {
	value == value.rounded() ? "\(Int(value)) pt" : String(format: "%.1f pt", value)
}

private func list(_ items: [String]) -> String {
	items.isEmpty ? "None" : items.joined(separator: ", ")
}

extension KumikoCore.Color {
	/// The accent colour of System Settings, what a frame with no colour of its own is drawn in.
	static var accent: KumikoCore.Color {
		KumikoCore.Color(NSColor.controlAccentColor) ?? KumikoCore.Color(red: 0, green: 0.48, blue: 1)
	}

	/// nil for a colour sRGB has no components for, like a pattern.
	init?(_ color: NSColor) {
		guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
		self.init(
			red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent),
			alpha: Double(srgb.alphaComponent)
		)
	}

	var view: SwiftUI.Color {
		SwiftUI.Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
	}
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
				detail: "Every module setting lives in this file. A change made in this window rewrites its own line; "
					+ "what the window has no control for is changed in the file. Saving it applies the change at once.",
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
	@ObservedObject var model: SettingsModel

	private var wm: Config.WM { model.config.wm }

	var body: some View {
		Card(title: "Layout") {
			StepperRow(
				title: "Gap", value: model.binding(\.wm.gap, "wm", "gap").asDouble, range: 0...64, whole: true,
				reset: model.reset(\.wm.gap, "wm", "gap")
			)

			// Each side's reset puts the whole padding back: the file has one key for all four.
			let resetPadding = model.reset(\.wm.padding, "wm", "padding")

			if perSide {
				StepperRow(title: "Top", value: side(\.top).asDouble, range: 0...200, whole: true, reset: resetPadding)
				StepperRow(title: "Bottom", value: side(\.bottom).asDouble, range: 0...200, whole: true, reset: resetPadding)
				StepperRow(title: "Left", value: side(\.left).asDouble, range: 0...200, whole: true, reset: resetPadding)
				StepperRow(title: "Right", value: side(\.right).asDouble, range: 0...200, whole: true, reset: resetPadding)
			} else {
				StepperRow(
					title: "Padding",
					detail: "Space between the windows and the screen edges.",
					value: Binding(get: { wm.padding.top }, set: { setPadding(Insets(all: $0)) }).asDouble,
					range: 0...200,
					whole: true,
					reset: resetPadding
				)
			}

			SwitchRow(
				title: "Padding per side",
				detail: perSide ? nil : "Top, bottom, left and right one by one, for room under a bar or a notch.",
				on: Binding(
					get: { perSide },
					set: { on in
						model.paddingPerSide = on
						// Back to one number: every side takes the top's.
						if !on && !isUniform { setPadding(Insets(all: wm.padding.top)) }
					}
				),
				last: true
			)
		}

		Card(title: "Hidden Workspaces") {
			SwitchRow(
				title: "Hide apps with no window on screen",
				detail: "An app whose windows are all on hidden workspaces is hidden, like cmd-h.",
				on: model.binding(\.wm.hideApps, "wm", "hide_apps"),
				last: true,
				reset: model.reset(\.wm.hideApps, "wm", "hide_apps")
			)
		}

		Card(title: "Shadows") {
			SwitchRow(
				title: "Window shadows",
				on: model.binding(\.wm.shadows, "wm", "shadows"),
				disabled: !model.sipAllowsPayload,
				reset: model.reset(\.wm.shadows, "wm", "shadows")
			)
			Row(
				"Scripting addition",
				value: model.payloadVersion.map { "Loaded, version \($0)" } ?? "Not loaded",
				detail: model.payloadVersion == nil && model.sipAllowsPayload
					? "Turning shadows off needs it: sudo kumiko sa load" : nil,
				last: true
			)
		}

		if !model.sipAllowsPayload {
			SIPNote()
		}
	}

	private var isUniform: Bool { wm.padding == Insets(all: wm.padding.top) }

	/// Sides that differ in the file can only be shown one by one.
	private var perSide: Bool { model.paddingPerSide || !isUniform }

	private func setPadding(_ padding: Insets) {
		model.set("wm", "padding", padding.tomlValue)
	}

	private func side(_ keyPath: WritableKeyPath<Insets, Int>) -> Binding<Int> {
		Binding(
			get: { wm.padding[keyPath: keyPath] },
			set: { value in
				var padding = wm.padding
				padding[keyPath: keyPath] = value
				setPadding(padding)
			}
		)
	}
}

private struct RulesPage: View {
	@ObservedObject var model: SettingsModel

	private var wm: Config.WM { model.config.wm }

	var body: some View {
		Card {
			SwitchRow(
				title: "Manage windows by default",
				detail: "For windows no rule below speaks about.",
				on: model.binding(\.wm.manage, "wm", "manage"),
				last: true,
				reset: model.reset(\.wm.manage, "wm", "manage")
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
	@ObservedObject var model: SettingsModel

	private var bar: Config.Bar { model.config.bar }

	/// The height goes along with the scale, as the items in the bar do, so the file keeps the height
	/// the bar really has.
	private func setScale(_ scale: Double) {
		// A twelfth has no end in decimals; four places keep the file readable and the height whole.
		let scale = (scale * 10_000).rounded() / 10_000
		var scaled = bar
		scaled.scale = scale
		let height = max((bar.height * scale / bar.scale).rounded(), scaled.minimumHeight)
		model.set("bar", "scale", .double(scale))
		model.set("bar", "height", .double(height))
	}

	var body: some View {
		Card(title: "Size") {
			Row(title: "Scale", detail: "Text and icons. The bar grows with them.") {
				let scale = model.draggedBarScale ?? bar.scale

				HStack(spacing: 8) {
					// Written once on release: every step of a drag would rewrite the file and lay the
					// windows out again. Arrow keys move it without a drag, and write at once.
					Slider(
						value: Binding(
							get: { scale },
							set: { model.draggedBarScale != nil ? (model.draggedBarScale = $0) : setScale($0) }
						),
						in: 1...2,
						// A twelfth is 3 points of the bar's 36, so every step is a whole height.
						step: 1.0 / 12
					) { dragging in
						if dragging {
							model.draggedBarScale = bar.scale
						} else if let dragged = model.draggedBarScale {
							model.draggedBarScale = nil
							if dragged != bar.scale { setScale(dragged) }
						}
					}
					.frame(width: 160)

					Text("\(Int((scale * 100).rounded()))%")
						.foregroundStyle(.secondary)
						.monospacedDigit()
						.frame(width: 40, alignment: .trailing)
				}
			}
			StepperRow(
				title: "Height",
				detail: "At least \(points(bar.minimumHeight)) at this scale.",
				value: model.binding(\.bar.height, "bar", "height"),
				range: bar.minimumHeight...(80 * bar.scale).rounded(),
				last: true,
				reset: model.reset(\.bar.height, "bar", "height")
			)
		}

		Card(title: "Items") {
			Row("Left", value: list(bar.left))
			Row("Right", value: list(bar.right), last: true)
		}

		Card(title: "Magnification") {
			Row(
				title: "Magnify app icons", detail: "Under the pointer, the way the Dock does.",
				reset: model.reset(\.bar.magnification, "bar", "magnification")
			) {
				Picker("", selection: model.binding(\.bar.magnification, "bar", "magnification") { .string($0.rawValue) }) {
					Text("Like the Dock").tag(Config.Bar.Magnification.dock)
					Text("On").tag(Config.Bar.Magnification.on)
					Text("Off").tag(Config.Bar.Magnification.off)
				}
				.pickerStyle(.segmented)
				.labelsHidden()
				.fixedSize()
			}
			StepperRow(
				title: "Size",
				detail: "Up to 128 pt, over the windows above the bar.",
				value: model.binding(\.bar.magnificationSize, "bar", "magnification_size"),
				range: 0...128,
				step: 2,
				zero: "Like the Dock",
				last: true,
				reset: model.reset(\.bar.magnificationSize, "bar", "magnification_size")
			)
			.disabled(bar.magnification == .off)
		}
	}
}

private struct BordersPage: View {
	@ObservedObject var model: SettingsModel

	private var borders: Config.Borders { model.config.borders }

	/// What the well shows: the panel's own pick while it stands, else the frame's colour, the
	/// accent included.
	private var color: SwiftUI.Color { model.pickedBorderColor ?? (borders.color ?? .accent).view }

	var body: some View {
		Card(title: "Look") {
			StepperRow(
				title: "Width", value: model.binding(\.borders.width, "borders", "width"), range: 1...20,
				reset: model.reset(\.borders.width, "borders", "width")
			)
			SwitchRow(
				title: "Use accent color",
				detail: "The one chosen in System Settings › Appearance. The frame follows when it changes.",
				on: Binding(get: { borders.color == nil }, set: { model.useAccentBorderColor($0) })
			)
			Row(
				title: "Color", detail: "Corners follow each window's own radius.", last: true,
				reset: model.resetBorderColor
			) {
				ColorPicker("", selection: Binding(get: { color }, set: model.pickBorderColor), supportsOpacity: true)
					.labelsHidden()
					.disabled(borders.color == nil)
			}
		}

		Card(title: "Exceptions") {
			Row("No border for", value: list(borders.blacklist), last: true)
		}
	}
}

private struct MenuBarPage: View {
	@ObservedObject var model: SettingsModel

	var body: some View {
		if let items = model.menuBarItems {
			ItemsCard(title: "Always Shown", items: items.shown, empty: "No items right of the divider.")
			ItemsCard(
				title: "Hidden",
				items: items.hidden,
				empty: "Cmd-drag items to the left of the divider to hide them."
			)
		}

		Card(title: "Hiding") {
			StepperRow(
				title: "Hide again after",
				detail: "Cmd-drag an item across the divider to move it between the lists.",
				value: model.binding(\.menuBar.rehide, "menubar", "rehide"),
				range: 0...120,
				step: 5,
				unit: "s",
				zero: "Never",
				last: true,
				reset: model.reset(\.menuBar.rehide, "menubar", "rehide")
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
