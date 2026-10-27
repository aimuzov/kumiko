import AppKit
import KumikoBar
import KumikoBorders
import KumikoCore
import KumikoHotkeys
import KumikoMenuBar
import KumikoVim
import KumikoWM

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	let paths: Paths
	let bus = EventBus()

	private(set) var config = Config()
	/// The reason the last reload failed; the previous config stays in force until it is fixed.
	private(set) var configError: ConfigError?
	/// Stopped from the status menu until resumed. Not in kumiko.toml: a restart brings kumiko back.
	private(set) var isPaused = false

	private(set) var tracker: WindowTracker?
	private(set) var manager: WindowManager?
	private(set) var hotkeys: Hotkeys?
	private var borders: Borders?
	private(set) var shadows: Shadows?
	private var floatLayer: FloatLayer?
	private(set) var bar: Bar?
	private(set) var menuBar: MenuBarHider?
	private var vim: Vim?
	private var windowServer: WindowServerEvents?

	private var server: IPCServer?
	private var watcher: ConfigWatcher?
	private var statusMenu: StatusMenu?
	/// Made on first show, so asking whether it is open makes nothing.
	private var settingsWindow: SettingsWindow?

	private var settings: SettingsWindow {
		if let settingsWindow { return settingsWindow }
		let window = SettingsWindow(app: self)
		settingsWindow = window
		return window
	}

	init(paths: Paths) {
		self.paths = paths
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		reloadConfig()

		let watcher = ConfigWatcher(directory: paths.configDirectory) { [weak self] in
			self?.reloadConfig()
		}

		do {
			try watcher.start()
			self.watcher = watcher
		} catch {
			Log.config.error("cannot watch \(self.paths.configDirectory.path, privacy: .public): \(error)")
		}

		let commands = Commands(app: self)
		let server = IPCServer(socket: paths.socket) { commands.handle($0) }

		do {
			try server.start()
			self.server = server
		} catch {
			Log.ipc.fault("cannot listen on \(self.paths.socket.path, privacy: .public): \(error, privacy: .public)")
		}

		let tracker = WindowTracker(bus: bus, config: config.wm)
		let manager = WindowManager(bus: bus, tracker: tracker, config: config, stateFile: paths.state)
		// Hotkeys run commands exactly as the CLI would, without the socket in between.
		let hotkeys = Hotkeys(bus: bus, config: config.hotkeys) { commands.handle($0) }
		self.tracker = tracker
		self.manager = manager
		tracker.keepsDockIcon = { [weak self] in self?.settingsWindow?.isOpen == true }
		let borders = Borders(bus: bus, config: config.borders, palette: config.bar.colors, focused: nil) {
			tracker.windows[$0]
		}
		let shadows = Shadows(bus: bus, tracker: tracker, config: config.wm)
		self.shadows = shadows
		let floatLayer = FloatLayer(bus: bus, manager: manager, config: config.wm)
		self.floatLayer = floatLayer
		let windowServer = WindowServerEvents(bus: bus)
		borders.onOwnWindow = { windowServer.own = $0 }
		let bar = Bar(bus: bus, tracker: tracker, manager: manager, config: config.bar)
		bar.onAddWorkspace = { [weak self] display in self?.addWorkspace(on: display) }
		bar.onShowWorkspace = { [weak self] name in self?.settings.show(workspace: name) }
		let menuBar = MenuBarHider(config: config.menuBar)
		// Vim gets the keys the hotkeys leave alone, so a hotkey still works inside a text field.
		let vim = Vim(bus: bus, config: config.vim)
		hotkeys.passthrough = { event, isDown in vim.handle(event, isDown: isDown) }
		self.windowServer = windowServer
		self.bar = bar
		self.menuBar = menuBar
		self.vim = vim
		self.hotkeys = hotkeys
		self.borders = borders

		bus.subscribe { [weak self] event in
			if case let .configReloaded(loaded) = event, let self {
				let config = self.running(loaded)
				tracker.apply(config.wm)
				manager.apply(config)
				hotkeys.apply(config.hotkeys)
				borders.apply(config.borders, palette: config.bar.colors)
				shadows.apply(config.wm)
				// After the manager, which has the new layouts and rules by then.
				floatLayer.apply(config.wm)
				bar.apply(config.bar)
				menuBar.apply(config.menuBar)
				vim.apply(config.vim)
			}
		}

		// The manager listens before the tracker starts, so it sees the windows that are already open.
		manager.start()
		borders.start()
		shadows.start()
		floatLayer.start()
		windowServer.start()
		bar.start()
		menuBar.start()
		vim.start()
		tracker.start()
		hotkeys.start()

		let statusMenu = StatusMenu(app: self)
		// The bar takes the menu bar's light or dark look, the one macOS picks from the desktop.
		statusMenu.onAppearanceChange = { bar.followMenuBar($0) }
		self.statusMenu = statusMenu
		Onboarding.runIfNeeded()

		Log.app.info("kumiko \(Kumiko.version, privacy: .public) started")
	}

	/// Sent by "Settings…" in the status menu and in the app menu.
	@objc func showSettings(_ sender: Any?) {
		settings.show()
	}

	/// `kumiko settings [pane]`; false when there is no pane by that name.
	func showSettings(pane: String?) -> Bool {
		settings.show(pane: pane)
	}

	func applicationWillTerminate(_ notification: Notification) {
		server?.stop()
		watcher?.stop()
		// Windows of hidden workspaces sit in a screen corner; quitting must not leave them there.
		manager?.showEverything()
		shadows?.restore()
		floatLayer?.restore()
		tracker?.stop()
		hotkeys?.stop()
	}

	/// The modules take the change the way they take a module switched off in the file: the window
	/// manager puts the windows of hidden workspaces back on screen.
	func setPaused(_ paused: Bool) {
		guard paused != isPaused else { return }
		isPaused = paused
		bus.publish(.configReloaded(config))
	}

	/// The config the modules run on: the file's, with what a pause stops turned off. The bar
	/// stays, with the clock and the battery on it.
	private func running(_ config: Config) -> Config {
		guard isPaused else { return config }
		var config = config
		config.wm.enabled = false
		config.wm.floatOnTop = false
		config.hotkeys.enabled = false
		config.vim.enabled = false
		config.borders.enabled = false
		return config
	}

	/// The bar's plus: a workspace like the settings window's "Add Workspace" on that bar's display,
	/// then shown, since the bar leaves out an empty workspace that is not on screen.
	private func addWorkspace(on display: UInt32) {
		guard let manager else { return }
		let (name, changes) = WorkspaceAreas.addNew(on: manager.displaySetting(for: display), in: config.workspaces)

		do throws(ConfigError) {
			_ = try ConfigWriter.write(changes, to: paths.configFile)
		} catch {
			Log.config.error("cannot add a workspace: \(error.description, privacy: .public)")
			return
		}

		// Now rather than when the watcher notices, so the workspace is there to show.
		guard case .success = reloadConfig() else { return }
		// The manager takes the new workspaces on its next pass, which is already queued.
		DispatchQueue.main.async {
			MainActor.assumeIsolated { _ = manager.handle(["workspace", "focus", name]) }
		}
	}

	/// Rereads the config file. A broken file keeps the previous config: a typo while editing must
	/// not throw every window around.
	@discardableResult
	func reloadConfig() -> Result<Config, ConfigError> {
		do throws(ConfigError) {
			let loaded = try Config.load(from: paths.configFile)
			configError = nil

			if loaded != config {
				config = loaded
				bus.publish(.configReloaded(loaded))
			}

			Log.config.info("config loaded")
			return .success(loaded)
		} catch {
			configError = error
			Log.config.error("\(error.description, privacy: .public)")
			return .failure(error)
		}
	}
}
