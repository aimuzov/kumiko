import AppKit
import KumikoCore
import os

/// `[wm] shadows`: takes window shadows away through the scripting addition, and gives them back.
/// Without the payload in Dock nothing changes and windows keep the shadow macOS gives them.
///
/// Only standard windows lose theirs. A panel floats over the windows, like Raycast's launcher, and
/// without a shadow it has no edge against what is under it.
@MainActor
public final class Shadows {
	private let bus: EventBus
	private let tracker: WindowTracker
	private var enabled: Bool
	private var dockObserver: (any NSObjectProtocol)?
	private var timer: Timer?
	private var connecting = false
	private var syncing = false
	private var hasChanges = false
	private let changes = OSAllocatedUnfairLock(initialState: ShadowChanges())
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

		let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.checkShadows() }
		}
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
		connect(loading: true)
	}

	public func apply(_ config: Config.WM) {
		enabled = config.shadows
		connect(loading: true)
	}

	/// Gives back every shadow kumiko took. Runs on quit, and waits, so none is left off.
	public func restore() {
		timer?.invalidate()
		queue.sync { [changes] in
			changes.withLock { state in
				for id in state.changed {
					ScriptingAddition.setShadow(id, true)
				}
			}
		}
	}

	public var statusDescription: String {
		let payload = payloadVersion.map { "scripting addition loaded, version \($0)" }
			?? "scripting addition not loaded: sudo kumiko sa load"
		return "\(enabled ? "on" : "off") (\(payload))"
	}

	private func handle(_ event: Event) {
		switch event {
		case .windowCreated, .windowChanged, .windowDestroyed:
			sync()
		default:
			break
		}
	}

	private func checkShadows() {
		if payloadVersion == nil {
			connect(loading: false)
		} else {
			sync()
		}
	}

	/// Asks Dock for the payload and brings every window in line once it answers. With `loading`,
	/// a missing payload is loaded through sudo when that needs no password (a sudoers entry from
	/// `kumiko sa sudoers`); otherwise it waits for `sudo kumiko sa load`.
	private func connect(loading: Bool) {
		guard !connecting, !enabled || hasChanges || syncing else { return }
		connecting = true

		let cli = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "kumiko")

		queue.async { [weak self] in
			var version = ScriptingAddition.handshake()

			if version == nil, loading, let cli, FileManager.default.isExecutableFile(atPath: cli.path(percentEncoded: false)) {
				let sudo = Process()
				sudo.executableURL = URL(filePath: "/usr/bin/sudo")
				sudo.arguments = ["-n", cli.path(percentEncoded: false), "sa", "load"]
				sudo.standardOutput = FileHandle.nullDevice
				sudo.standardError = FileHandle.nullDevice
				if (try? sudo.run()) != nil {
					sudo.waitUntilExit()
					version = ScriptingAddition.handshake()
				}
			}

			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					guard let self else { return }
					self.connecting = false
					self.payloadVersion = version
					if version != nil { self.sync() }
				}
			}
		}
	}

	private func sync() {
		guard !syncing, !connecting, payloadVersion != nil, !enabled || hasChanges else { return }
		syncing = true
		let windows = tracker.windows.mapValues { !enabled && Self.losesShadow($0) }

		queue.async { [weak self, changes] in
			let hasChanges = changes.withLock { state in
				state.reconcile(windows, read: WindowServer.suppressesShadow, write: { id, suppress in
					ScriptingAddition.setShadow(id, !suppress)
				})
				return !state.changed.isEmpty
			}
			DispatchQueue.main.async {
				self?.syncing = false
				self?.hasChanges = hasChanges
			}
		}
	}

	/// kumiko's own windows see to their shadow themselves, through AppKit.
	nonisolated static func losesShadow(_ info: WindowInfo) -> Bool {
		info.subrole == kAXStandardWindowSubrole as String && info.pid != ProcessInfo.processInfo.processIdentifier
	}
}

struct ShadowChanges: Sendable {
	// Only windows kumiko asked to suppress after observing that they had a shadow.
	private(set) var changed: Set<UInt32> = []

	mutating func reconcile(
		_ windows: [UInt32: Bool], read: (UInt32) -> Bool?, write: (UInt32, Bool) -> Bool
	) {
		changed.formIntersection(windows.keys)
		for (id, suppress) in windows where suppress || changed.contains(id) {
			guard let suppressed = read(id) else { continue }

			if suppress {
				if !suppressed, write(id, true) { changed.insert(id) }
			} else if !suppressed || (write(id, false) && read(id) == false) {
				changed.remove(id)
			}
		}
	}
}
