import AppKit
import KumikoCore

/// `[wm] shadows`: takes window shadows away through the scripting addition, and gives them back.
/// Without the payload in Dock nothing changes and windows keep the shadow macOS gives them.
@MainActor
public final class Shadows {
	private let bus: EventBus
	private let tracker: WindowTracker
	private var enabled: Bool
	/// Windows kumiko took the shadow from, so turning shadows on again restores only those.
	private var stripped: Set<UInt32> = []
	private var dockObserver: (any NSObjectProtocol)?
	// Each request is a socket round trip; they stay off the main thread.
	private let queue = DispatchQueue(label: "\(Kumiko.bundleIdentifier).shadows")

	/// The version of the payload in Dock, nil when none answered the last handshake.
	public private(set) var payloadVersion: String?

	public init(bus: EventBus, tracker: WindowTracker, config: Config.WM) {
		self.bus = bus
		self.tracker = tracker
		enabled = config.shadows
	}

	public func start() {
		bus.subscribe { [weak self] event in self?.handle(event) }

		// A new Dock comes without the payload. Window tags live in the window server, so the
		// shadows already taken stay off; only new windows need the payload back.
		dockObserver = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
		) { [weak self] notification in
			let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
			guard app?.bundleIdentifier == "com.apple.dock" else { return }
			MainActor.assumeIsolated { self?.connect(loading: true) }
		}

		connect(loading: true)
	}

	public func apply(_ config: Config.WM) {
		enabled = config.shadows
		connect(loading: true)
	}

	/// Gives back every shadow kumiko took. Runs on quit, and waits, so none is left off.
	public func restore() {
		for id in stripped {
			ScriptingAddition.setShadow(id, true)
		}
		stripped = []
	}

	public var statusDescription: String {
		let payload = payloadVersion.map { "scripting addition loaded, version \($0)" }
			?? "scripting addition not loaded: sudo kumiko sa load"
		return "\(enabled ? "on" : "off") (\(payload))"
	}

	private func handle(_ event: Event) {
		switch event {
		case let .windowCreated(info):
			guard !enabled, payloadVersion != nil else { return }
			take(from: [info.id])
		case let .windowDestroyed(id):
			stripped.remove(id)
		default:
			break
		}
	}

	/// Asks Dock for the payload and brings every window in line once it answers. With `loading`,
	/// a missing payload is loaded through sudo when that needs no password (a sudoers entry from
	/// `kumiko sa sudoers`); otherwise it waits for `sudo kumiko sa load`.
	private func connect(loading: Bool) {
		// Shadows on and none taken: there is nothing for the payload to do.
		guard !enabled || !stripped.isEmpty else { return }

		let cli = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "kumiko")

		queue.async { [weak self] in
			var version = ScriptingAddition.handshake()

			if version == nil, loading, let cli, FileManager.default.isExecutableFile(atPath: cli.path(percentEncoded: false)) {
				let sudo = Process()
				sudo.executableURL = URL(filePath: "/usr/bin/sudo")
				sudo.arguments = ["-n", cli.path(percentEncoded: false), "sa", "load"]
				sudo.standardOutput = FileHandle.nullDevice
				sudo.standardError = FileHandle.nullDevice
				try? sudo.run()
				sudo.waitUntilExit()
				version = ScriptingAddition.handshake()
			}

			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					guard let self else { return }
					self.payloadVersion = version
					if version != nil { self.sync() }
				}
			}
		}
	}

	private func sync() {
		if enabled {
			let ids = stripped
			stripped = []
			queue.async {
				for id in ids { ScriptingAddition.setShadow(id, true) }
			}
		} else {
			take(from: tracker.windows.keys.filter { !stripped.contains($0) })
		}
	}

	private func take(from ids: [UInt32]) {
		stripped.formUnion(ids)
		queue.async {
			for id in ids { ScriptingAddition.setShadow(id, false) }
		}
	}
}
