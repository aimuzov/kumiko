import AppKit
import KumikoCore
import KumikoWM

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	let paths: Paths
	let bus = EventBus()

	private(set) var config = Config()
	/// The reason the last reload failed; the previous config stays in force until it is fixed.
	private(set) var configError: ConfigError?

	private(set) var tracker: WindowTracker?

	private var server: IPCServer?
	private var watcher: ConfigWatcher?
	private var statusMenu: StatusMenu?

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
		self.tracker = tracker
		tracker.start()

		bus.subscribe { event in
			if case let .configReloaded(config) = event {
				tracker.apply(config.wm)
			}
		}

		statusMenu = StatusMenu(app: self)
		Onboarding.runIfNeeded()

		Log.app.info("kumiko \(Kumiko.version, privacy: .public) started")
	}

	func applicationWillTerminate(_ notification: Notification) {
		server?.stop()
		watcher?.stop()
		tracker?.stop()
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
