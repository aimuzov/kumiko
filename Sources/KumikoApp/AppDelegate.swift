import AppKit
import KumikoBar
import KumikoBorders
import KumikoCore
import KumikoHotkeys
import KumikoVim
import KumikoWM

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	let paths: Paths
	let bus = EventBus()

	private(set) var config = Config()
	/// The reason the last reload failed; the previous config stays in force until it is fixed.
	private(set) var configError: ConfigError?

	private(set) var tracker: WindowTracker?
	private(set) var manager: WindowManager?
	private(set) var hotkeys: Hotkeys?
	private var borders: Borders?
	private(set) var bar: Bar?
	private var vim: Vim?
	private var windowServer: WindowServerEvents?

	private var server: IPCServer?
	private var watcher: ConfigWatcher?
	private var statusMenu: StatusMenu?
	private lazy var settings = SettingsWindow(app: self)

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
		let borders = Borders(bus: bus, config: config.borders, focused: nil) { tracker.windows[$0] }
		let windowServer = WindowServerEvents(bus: bus)
		let bar = Bar(bus: bus, tracker: tracker, manager: manager, config: config.bar)
		// Vim gets the keys the hotkeys leave alone, so a hotkey still works inside a text field.
		let vim = Vim(bus: bus, config: config.vim)
		hotkeys.passthrough = { event, isDown in vim.handle(event, isDown: isDown) }
		self.windowServer = windowServer
		self.bar = bar
		self.vim = vim
		self.hotkeys = hotkeys
		self.borders = borders

		bus.subscribe { event in
			if case let .configReloaded(config) = event {
				tracker.apply(config.wm)
				manager.apply(config)
				hotkeys.apply(config.hotkeys)
				borders.apply(config.borders)
				bar.apply(config.bar)
				vim.apply(config.vim)
			}
		}

		// The manager listens before the tracker starts, so it sees the windows that are already open.
		manager.start()
		borders.start()
		windowServer.start()
		bar.start()
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
		tracker?.stop()
		hotkeys?.stop()
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
