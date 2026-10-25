import AppKit
import Combine
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
	private var fullScreenObservers: [any NSObjectProtocol] = []
	private var paneObserver: AnyCancellable?
	private let bringForward: () -> Void
	/// Hands the window to the tracker, which lays it out with the others; and whether it did.
	private let tile: (NSWindow) -> Void
	private let isTiled: (NSWindow) -> Bool
	/// From show until the window is closed, minimized and hidden included: all that time kumiko
	/// keeps its Dock icon, the way back to the window.
	private(set) var isOpen = false

	init(app: AppDelegate) {
		model = SettingsModel(configFile: app.paths.configFile, config: app.config, error: app.configError?.description) {
			[weak app] in app?.menuBar?.items()
		}
		bringForward = { [weak app] in app?.tracker?.bringKumikoForward() }
		tile = { [weak app] window in app?.tracker?.track(own: window) }
		isTiled = { [weak app] window in
			app?.tracker?.windows[UInt32(max(window.windowNumber, 0))]?.isManaged == true
		}
		model.onRenameWorkspace = { [weak app] old, new in app?.manager?.rename(old, to: new) }
		model.pauseHotkeys = { [weak app] paused in app?.hotkeys?.isPaused = paused }
		// Sent before the page changes, so the window is wide enough by the time it is drawn.
		paneObserver = model.$pane.sink { [weak self] pane in self?.fit(pane) }

		app.bus.subscribe { [weak self, unowned app] event in
			guard case .configReloaded = event else { return }
			self?.model.update(app.config, error: app.configError?.description)
			self?.matchShadows()
		}
	}

	/// Wider for a page that needs it, once on the way in: the Workspaces page's two columns
	/// do not fit the window's first size. Grown about its middle and kept on its screen; a
	/// window that is wide enough already is left as the user made it, and one in the layout as the
	/// layout made it.
	private func fit(_ pane: Pane) {
		guard let window, !isTiled(window) else { return }
		let width = SettingsView.minWidth(for: pane)
		let missing = width - window.contentLayoutRect.width
		guard missing > 0 else { return }
		var frame = window.frame
		frame.origin.x -= missing / 2
		frame.size.width += missing
		if let screen = window.screen?.visibleFrame {
			frame.size.width = min(frame.width, screen.width)
			frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX - frame.width)
		}
		window.setFrame(frame, display: true, animate: window.isVisible)
	}

	/// Without a shadow like every other window while shadows are off. kumiko may take its own away
	/// without the payload, but then no other window has lost one and this would be the odd one out.
	private func matchShadows() {
		window?.hasShadow = model.config.wm.shadows || model.payloadVersion == nil
	}

	/// The Workspaces page with this workspace's settings: a click on an empty one in the bar.
	func show(workspace name: String) {
		model.pickWorkspace(name)
		show(pane: Pane.workspaces.rawValue)
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
			// lights come down into the sidebar's corner. The toolbar itself stays empty, and it is
			// what moves the window: moved by its background, the window would take every drag on
			// the page, a workspace row's among them.
			window.toolbar = NSToolbar(identifier: "kumiko.settings")
			window.toolbarStyle = .unified
			window.isReleasedWhenClosed = false
			window.setContentSize(NSSize(width: 860, height: 600))
			window.center()
			window.setFrameAutosaveName("kumiko.settings")
			self.window = window
			fit(model.pane)

			closeObserver = NotificationCenter.default.addObserver(
				forName: NSWindow.willCloseNotification, object: window, queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated {
					self?.isOpen = false
					_ = NSApp.setActivationPolicy(.accessory)
				}
			}
			// In full screen the empty toolbar would stand over the page as a bar of its own, and
			// there are no traffic lights to make room for.
			for (name, on) in [
				(NSWindow.willEnterFullScreenNotification, true), (NSWindow.willExitFullScreenNotification, false),
			] {
				fullScreenObservers.append(NotificationCenter.default.addObserver(
					forName: name, object: window, queue: .main
				) { [weak self, weak window] _ in
					MainActor.assumeIsolated {
						window?.toolbar?.isVisible = !on
						self?.model.isFullScreen = on
					}
				})
			}
			// Coming back from System Settings with a permission granted: the warning goes away.
			keyObserver = NotificationCenter.default.addObserver(
				forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated {
					self?.model.refresh()
					self?.matchShadows()
				}
			}
		}

		model.refresh()
		matchShadows()

		// kumiko has no Dock icon, and an app without one gets no menu bar and no place in cmd-tab;
		// it has one while the window is open.
		isOpen = true
		NSApp.setActivationPolicy(.regular)
		// Closed on a hidden workspace, it was saved where those wait, in a corner off the screen.
		if let window, !NSScreen.screens.contains(where: { $0.visibleFrame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) }) {
			window.center()
		}
		window?.makeKeyAndOrderFront(nil)
		// On screen it has a window number, which the layout knows it by.
		if let window { tile(window) }

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
	/// The page shown. Every change of it is a step the header's arrows walk back.
	@Published var pane = Pane.general {
		didSet {
			showsPaneInfo = false
			guard pane != oldValue, !walking else { return }
			backward.append(oldValue)
			forward.removeAll()
		}
	}
	/// The pages left behind, the nearest last, and the pages gone back from.
	@Published private(set) var backward: [Pane] = []
	@Published private(set) var forward: [Pane] = []
	private var walking = false
	/// The header's info button shows what the page's module does.
	@Published var showsPaneInfo = false
	/// The window in native full screen: no traffic lights, and a whole screen of width.
	@Published var isFullScreen = false
	@Published private(set) var opensAtLogin = LoginItem.isEnabled
	@Published private(set) var payloadVersion: String?
	@Published private(set) var sipAllowsPayload = ScriptingAddition.isAllowedBySIP
	@Published private(set) var missing = Permission.missing
	@Published var search = ""
	/// The padding's sides are set one by one even while they are all the same.
	@Published var paddingPerSide = false
	/// The workspace the Workspaces page shows the settings of, by name: a rename takes its name
	/// along, a removal hands it to a neighbour. Nil, or a name the file no longer has, is the first.
	@Published var selectedWorkspace: String?
	/// An identity per workspace that outlives its name, so a rename does not rebuild its row and
	/// detail and take the keyboard from the field it was typed in. Not published: the list adds
	/// ids while it draws, which sends no change.
	private var workspaceIDs: [String: UUID] = [:]
	/// Not published: a dragged row moves with the pointer, and only the list follows it.
	let islandDrag = IslandDrag()
	/// The same for the shown workspace's app rows, which touch: a divider is part of each.
	let appDrag = IslandDrag(spacing: 0)
	/// An app's size while the edge of its split is dragged; written to the file when it is let go.
	@Published var draggedSize: DraggedSize?
	/// The screens behind the Workspaces page's areas. Without a monitor there are no areas,
	/// and the page says nothing about displays.
	@Published private(set) var screens = AreaScreens.current()
	private var screensObserver: (any NSObjectProtocol)?
	/// The order the areas were last shown in, kept while the page is open so a drop never
	/// swaps them under the pointer. Not published: the list sets it while it draws.
	var shownAreaOrder: [Config.Workspace.Area]?
	/// The workspace the Remove dialog asks about, named when it opened.
	@Published var workspacePendingRemoval: String?
	/// The app or pattern the Window Rules page shows; nil, or one the file no longer has, is the first.
	@Published var selectedRule: RuleSelection?
	/// The app or pattern the Remove dialog of the Window Rules page asks about.
	@Published var rulePendingRemoval: RuleSelection?
	/// The title typed into the exceptions' last row, not yet added.
	@Published var newExceptionTitle = ""
	/// The mode the Hotkeys page shows; nil, or one the file no longer has, is the default mode.
	@Published var selectedHotkeyMode: HotkeyBindings.ModeID?
	/// The binding whose shortcut is being recorded, by its key in the file; "" for a new one.
	/// kumiko's own hotkeys are off meanwhile, or the shortcut pressed would run instead.
	@Published var recordingHotkey: String? {
		didSet { if (recordingHotkey == nil) != (oldValue == nil) { pauseHotkeys(recordingHotkey != nil) } }
	}
	var pauseHotkeys: (Bool) -> Void = { _ in }
	/// The shortcut just pressed in the recorder, before it is written.
	@Published var recordedHotkey: KeyCombo?
	/// The binding whose action popover is open, by its key in the file.
	@Published var editingHotkeyAction: String?
	/// Recorded shortcuts keep the side of ⌘, ⌥, ⌃ and ⇧ that was pressed.
	@Published var recordsHotkeySide = false
	/// The action popover waits for the key a shortcut presses instead.
	@Published var recordingSentKey = false
	/// The name typed for a new mode while its dialog is open.
	@Published var newHotkeyMode: String?
	/// The mode the Remove dialog of the Hotkeys page asks about.
	@Published var hotkeyModePendingRemoval: String?
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
		screensObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				let screens = AreaScreens.current()
				guard screens != self.screens else { return }
				self.screens = screens
				self.shownAreaOrder = nil
			}
		}
	}

	/// Called from the list's `body`, so a name seen for the first time gets its id there.
	func workspaceID(for name: String) -> UUID {
		if let id = workspaceIDs[name] { return id }
		let id = UUID()
		workspaceIDs[name] = id
		return id
	}

	/// Moves the identity and what is kept by name to the new name, once the file has it.
	func carryWorkspace(from name: String, to new: String, id: UUID) {
		workspaceIDs[name] = nil
		workspaceIDs[new] = id
		if selectedWorkspace == name { selectedWorkspace = new }
		if let frame = islandDrag.frames.removeValue(forKey: name) { islandDrag.frames[new] = frame }
	}

	private func forgetGoneWorkspaces() {
		let names = Set(config.workspaces.map(\.name))
		workspaceIDs = workspaceIDs.filter { names.contains($0.key) }
	}

	func update(_ config: Config, error: String?) {
		self.config = config
		self.error = error
		writeError = nil
		// A broken file may come back with none of its workspaces: the selection waits for a good one.
		if error == nil, let selected = selectedWorkspace, !config.workspaces.contains(where: { $0.name == selected }) {
			selectedWorkspace = nil
		}
		forgetGoneWorkspaces()

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
			forgetGoneWorkspaces()
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
		AppIcon.forgetMissing()
		opensAtLogin = LoginItem.isEnabled
		payloadVersion = ScriptingAddition.handshake()
		sipAllowsPayload = ScriptingAddition.isAllowedBySIP
		missing = Permission.missing
		menuBarItems = readMenuBar()
	}

	func goBack() {
		guard let previous = backward.popLast() else { return }
		forward.append(pane)
		walk(to: previous)
	}

	func goForward() {
		guard let next = forward.popLast() else { return }
		backward.append(pane)
		walk(to: next)
	}

	/// A step through the history is no new step in it.
	private func walk(to page: Pane) {
		walking = true
		pane = page
		walking = false
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

	/// The Workspaces page's list and detail side by side, with the apps table's name column
	/// still readable: 248 of sidebar, 48 of margins, 210 of list, 16 between and about 380 of
	/// detail.
	static func minWidth(for pane: Pane) -> Double { pane == .workspaces ? 900 : 780 }

	var body: some View {
		HStack(spacing: 0) {
			Sidebar(model: model)
				.frame(width: 232)
				.padding(8)

			ScrollView {
				Page(model: model)
					.padding(.horizontal, 24)
					.padding(.top, PageBar.height + 8)
					.padding(.bottom, 24)
					// The workspaces' list and the settings beside it need the room of two columns. A
					// full screen gives a little more, short of rows too long to read across.
					.frame(maxWidth: (model.pane == .workspaces ? 880 : 600) + (model.isFullScreen ? 160 : 0))
					.frame(maxWidth: .infinity)
			}
			.overlay(alignment: .top) { PageBar(model: model) }
		}
		.frame(minWidth: Self.minWidth(for: model.pane), minHeight: 500)
		.background(SwiftUI.Color(nsColor: .textBackgroundColor))
		// Up under the transparent title bar, so the traffic lights sit inside the sidebar.
		.ignoresSafeArea()
	}
}

/// Raycast's header over a settings page: the way back and forth through the pages seen, the
/// page's title, what its module does, and its switch. It keeps to the line of the traffic lights
/// while the page scrolls under it and fades out into it. Its empty parts are the title bar's,
/// so the window still moves by them.
private struct PageBar: View {
	static let height = 52.0

	@ObservedObject var model: SettingsModel
	@Environment(\.controlActiveState) private var activeState
	@Environment(\.colorScheme) private var colorScheme

	private var isActive: Bool { activeState != .inactive }

	var body: some View {
		let page = SwiftUI.Color(nsColor: .textBackgroundColor)

		HStack(spacing: 12) {
			arrows
			Text(model.pane.title)
				.font(.system(size: 15, weight: .semibold))
				.foregroundStyle(isActive ? .primary : .secondary)
				.lineLimit(1)
			Spacer(minLength: 8)
			Button { model.showsPaneInfo.toggle() } label: {
				Image(systemName: "info.circle").font(.system(size: 15))
			}
			.buttonStyle(.borderless)
			.foregroundStyle(.secondary)
			.help("About this page")
			.popover(isPresented: $model.showsPaneInfo, arrowEdge: .bottom) {
				Text(model.pane.subtitle)
					.fixedSize(horizontal: false, vertical: true)
					.frame(width: 240, alignment: .leading)
					.padding(12)
			}
			if let setting = model.pane.enabledSetting {
				Toggle("", isOn: model.binding(setting.keyPath, setting.table, setting.key))
					.toggleStyle(.switch)
					.controlSize(.mini)
					.labelsHidden()
					.help("\(setting.table).\(setting.key) in kumiko.toml")
			}
		}
		.padding(.horizontal, 16)
		.frame(height: Self.height)
		.frame(maxWidth: .infinity)
		.background(alignment: .top) {
			// Solid behind the header, then gone: what scrolls up fades out instead of being cut.
			LinearGradient(
				stops: [
					.init(color: page, location: 0), .init(color: page, location: 0.6),
					.init(color: page.opacity(0), location: 1),
				],
				startPoint: .top, endPoint: .bottom
			)
			.frame(height: Self.height + 24)
			.allowsHitTesting(false)
		}
	}

	/// The back and forward capsule floats over the page with a shadow, and lies flat with the
	/// window in the back, like the sidebar.
	private var arrows: some View {
		let shape = Capsule()

		return HStack(spacing: 0) {
			arrow("chevron.left", "Back", enabled: !model.backward.isEmpty, key: "[") { model.goBack() }
			Divider().frame(height: 14)
			arrow("chevron.right", "Forward", enabled: !model.forward.isEmpty, key: "]") { model.goForward() }
		}
		.background {
			if isActive {
				shape.fill(SwiftUI.Color(nsColor: .textBackgroundColor))
					.overlay(shape.strokeBorder(.primary.opacity(colorScheme == .dark ? 0.12 : 0.06)))
					.shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 6, y: 1)
			} else {
				shape.fill(.primary.opacity(0.04))
			}
		}
	}

	private func arrow(
		_ symbol: String, _ title: String, enabled: Bool, key: KeyEquivalent, action: @escaping () -> Void
	) -> some View {
		Button(action: action) {
			Image(systemName: symbol)
				.font(.system(size: 12, weight: .semibold))
				.frame(width: 32, height: 28)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.foregroundStyle(enabled ? .primary : .tertiary)
		.disabled(!enabled)
		.keyboardShortcut(key, modifiers: .command)
		.help(title)
		.accessibilityLabel(title)
	}
}

/// Raycast's sidebar: a panel inset from the window's edges, with the traffic lights in its
/// corner, a search field and the pages. While the window is in front the panel stands over the
/// page, lighter than the cards and with a shadow; behind other windows it lies flat and grey.
private struct Sidebar: View {
	@ObservedObject var model: SettingsModel
	@Environment(\.controlActiveState) private var activeState
	@Environment(\.colorScheme) private var colorScheme

	private var isRaised: Bool { activeState != .inactive }

	var body: some View {
		VStack(alignment: .leading, spacing: 1) {
			// Room for the traffic lights, which full screen has none of.
			Spacer().frame(height: model.isFullScreen ? 12 : 40)

			HStack(spacing: 6) {
				Image(systemName: "magnifyingglass")
					.foregroundStyle(.secondary)
				TextField("Search settings…", text: $model.search)
					.textFieldStyle(.plain)
			}
			.padding(.horizontal, 10)
			.frame(height: 32)
			.background(Capsule().fill(.primary.opacity(isRaised ? 0.08 : 0.02)))
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
		.background {
			// Concentric with the window's corners, 8 pt inside them.
			let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
			if isRaised {
				// Opaque underneath, or the shadow would show through the tint.
				shape.fill(SwiftUI.Color(nsColor: .textBackgroundColor))
					.overlay(shape.fill(.primary.opacity(0.016)))
					.overlay(shape.strokeBorder(.white.opacity(colorScheme == .dark ? 0.08 : 0.9), lineWidth: 1))
					.shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.08), radius: 8)
			} else {
				shape.fill(.primary.opacity(0.043))
			}
		}
	}
}

private struct SidebarRow: View {
	let pane: Pane
	@ObservedObject var model: SettingsModel
	@Environment(\.controlActiveState) private var activeState

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
					.fill(SwiftUI.Color.primary.opacity(model.pane != pane ? 0 : activeState == .inactive ? 0.03 : 0.085))
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
			case .hotkeys: HotkeysPage(model: model)
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

/// How a card sits its rows: a row that reaches the card's edges, like one lifted by a drag, needs
/// both.
enum CardMetrics {
	static let inset = 12.0
	static let radius = 10.0
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
			.padding(.horizontal, CardMetrics.inset)
			.background(
				RoundedRectangle(cornerRadius: CardMetrics.radius, style: .continuous).fill(.primary.opacity(0.02))
			)
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

		Card(title: "Through Dock") {
			SwitchRow(
				title: "Window shadows",
				on: model.binding(\.wm.shadows, "wm", "shadows"),
				disabled: !model.sipAllowsPayload,
				reset: model.reset(\.wm.shadows, "wm", "shadows")
			)
			SwitchRow(
				title: "Floating windows on top",
				detail: "Windows left out of the layout stay above the tiled ones.",
				on: model.binding(\.wm.floatOnTop, "wm", "float_on_top"),
				disabled: !model.sipAllowsPayload,
				reset: model.reset(\.wm.floatOnTop, "wm", "float_on_top")
			)
			Row(
				"Scripting addition",
				value: model.payloadVersion.map { "Loaded, version \($0)" } ?? "Not loaded",
				detail: payloadDetail,
				last: true
			)
		}

		if !model.sipAllowsPayload {
			SIPNote()
		}
	}

	/// What the scripting addition needs: to be loaded, or a payload this kumiko can talk to. One
	/// older than this build takes the new requests and does nothing with them.
	private var payloadDetail: String? {
		guard model.sipAllowsPayload else { return nil }
		guard let version = model.payloadVersion else { return "Both need it: sudo kumiko sa load" }
		guard version == ScriptingAddition.version else {
			return "This kumiko needs version \(ScriptingAddition.version): sudo kumiko sa install, killall Dock, then sudo kumiko sa load"
		}
		return nil
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
			Row("Right", value: list(bar.right))
			SwitchRow(
				title: "Leave out what the menu bar shows",
				detail: "The time while its clock is digital, the battery and the input source while they are in it.",
				on: model.binding(\.bar.followMenuBar, "bar", "follow_menu_bar"),
				reset: model.reset(\.bar.followMenuBar, "bar", "follow_menu_bar")
			)
			SwitchRow(
				title: "Move what it can out of the menu bar",
				detail: "Turns the battery and the input menu off there and makes its clock analog, so the bar shows "
					+ "them. Off puts back what was there.",
				on: model.binding(\.bar.takeFromMenuBar, "bar", "take_from_menu_bar"),
				last: true,
				reset: model.reset(\.bar.takeFromMenuBar, "bar", "take_from_menu_bar")
			)
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
