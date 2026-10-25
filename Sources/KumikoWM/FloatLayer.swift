import AppKit
import KumikoCore

/// `[wm] float_on_top`: keeps the windows the layout leaves floating above the tiled ones, the way
/// yabai's `--layer above` does, so a click on the layout does not bury them. Only Dock may change
/// the level of another app's window: without the payload nothing changes.
@MainActor
public final class FloatLayer {
	private let bus: EventBus
	private let manager: WindowManager
	private var enabled: Bool
	/// Windows kumiko keeps above, so turning the option off or quitting lowers only those.
	private var raised: Set<UInt32> = []
	// Each request is a socket round trip; they stay off the main thread.
	private let queue = DispatchQueue(label: "\(Kumiko.bundleIdentifier).float-layer")

	public init(bus: EventBus, manager: WindowManager, config: Config.WM) {
		self.bus = bus
		self.manager = manager
		enabled = config.floatOnTop
	}

	public func start() {
		bus.subscribe { [weak self] event in
			if case let .windowDestroyed(id) = event { self?.raised.remove(id) }
		}
		manager.onArrange = { [weak self] in self?.update() }
		update()
	}

	public func apply(_ config: Config.WM) {
		enabled = config.floatOnTop
		update()
	}

	/// Puts every window kumiko raised back among the others. Runs on quit, and waits, so none is
	/// left above.
	public func restore() {
		for id in raised {
			ScriptingAddition.setAbove(id, false)
		}
		raised = []
	}

	private func update() {
		let wanted = enabled ? manager.floatingWindows : []
		let up = wanted.subtracting(raised)
		let down = raised.subtracting(wanted)
		guard !up.isEmpty || !down.isEmpty else { return }
		raised = wanted

		queue.async {
			// A window the payload did not take is not above: the next pass asks for it again.
			let missed = up.filter { !ScriptingAddition.setAbove($0, true) }
			for id in down { ScriptingAddition.setAbove(id, false) }
			guard !missed.isEmpty else { return }
			DispatchQueue.main.async { [weak self] in
				MainActor.assumeIsolated { self?.raised.subtract(missed) }
			}
		}
	}
}
