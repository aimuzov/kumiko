import AppKit
import KumikoCore
import KumikoWM
import SwiftUI

/// The status bar module: one bar window per display, replacing sketchybar. It reads the window
/// manager directly and refreshes on the bus, so there are no queries or events to wire up.
@MainActor
public final class Bar {
	private let bus: EventBus
	private let tracker: WindowTracker
	private let manager: WindowManager
	private let model = BarModel()
	private let caffeine = Caffeine()
	private let takeover = MenuBarTakeover()

	private var config: Config.Bar
	private var windows: [UInt32: BarWindow] = [:]
	/// Over each bar and the windows above it, for the magnified app icons.
	private var magnifiers: [UInt32: MagnifierWindow] = [:]
	private var timers: [Timer] = []
	private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
	private var batteryObserver: AnyObject?
	private var refreshScheduled = false
	/// The menu bar's look, the fallback when the desktop cannot be read.
	private var menuBarIsDark = true

	public init(bus: EventBus, tracker: WindowTracker, manager: WindowManager, config: Config.Bar) {
		self.bus = bus
		self.tracker = tracker
		self.manager = manager
		self.config = config
	}

	public func start() {
		model.focusWorkspace = { [weak self] name in
			_ = self?.manager.handle(["workspace", "focus", name])
		}
		model.focusApp = { [weak self] pid, workspace in
			self?.manager.focus(app: pid, on: workspace)
		}
		model.toggleCaffeine = { [weak self] in
			guard let self else { return }
			self.caffeine.toggle()
			self.model.isCaffeinated = self.caffeine.isOn
		}
		// The item follows on its own: macOS posts `InputSource.changed` for this switch too.
		model.switchInputSource = { InputSource.selectNext() }

		bus.subscribe { [weak self] event in self?.handle(event) }

		observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
			self?.layoutWindows()
		}
		observe(DistributedNotificationCenter.default(), InputSource.changed) { [weak self] in
			self?.model.inputSource = InputSource.current()
			self?.model.inputLanguage = InputSource.languageCode()
		}
		observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in
			self?.tick()
			self?.matchDesktop()
		}
		observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
			self?.matchDesktop()
		}

		batteryObserver = Battery.observe { [weak self] in self?.model.battery = Battery.read() }
		observe(NotificationCenter.default, .NSProcessInfoPowerStateDidChange) { [weak self] in
			self?.model.battery = Battery.read()
		}

		apply(config)
	}

	public func apply(_ config: Config.Bar) {
		self.config = config
		model.config = config
		// Only with its item on screen, where it can be turned off again.
		if config.enabled && (config.left + config.right).contains("caffeinate") {
			caffeine.restore()
		}
		takeover.update(on: config.enabled && config.takeFromMenuBar)
		layoutWindows()
		scheduleTimers()
		tick()
		refresh()
	}

	// MARK: - Windows

	/// One bar per screen, at the edge the config names, inside the menu bar and the Dock.
	private func layoutWindows() {
		guard config.enabled else {
			windows.values.forEach { $0.orderOut(nil) }
			windows = [:]
			magnifiers.values.forEach { $0.orderOut(nil) }
			magnifiers = [:]
			return
		}

		var seen = Set<UInt32>()

		for screen in NSScreen.screens {
			guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
				continue
			}
			let id = number.uint32Value
			seen.insert(id)

			let visible = screen.visibleFrame
			let frame = CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: config.height)

			let window = windows[id] ?? BarWindow(rootView: BarView(model: model, display: id))
			windows[id] = window
			window.setFrame(frame, display: true)
			window.orderFrontRegardless()

			let magnifier = magnifiers[id]
				?? MagnifierWindow(rootView: MagnifierView(model: model, display: id, lift: Magnifier.maximum))
			magnifiers[id] = magnifier
			magnifier.setFrame(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + Magnifier.maximum), display: true)
			magnifier.orderFrontRegardless()
		}

		for id in windows.keys where !seen.contains(id) {
			windows.removeValue(forKey: id)?.orderOut(nil)
		}
		for id in magnifiers.keys where !seen.contains(id) {
			magnifiers.removeValue(forKey: id)?.orderOut(nil)
		}

		matchDesktop()
	}

	/// Records the menu bar's light or dark look, which macOS picks from the desktop under it.
	/// The bar uses it only when it cannot read the desktop under itself (the menu bar looks at the
	/// top of the screen, the bar at the bottom), but a change in it means the desktop
	/// changed, so the bars look again.
	public func followMenuBar(_ appearance: NSAppearance) {
		menuBarIsDark = appearance.bestMatch(from: [.vibrantDark, .vibrantLight, .darkAqua, .aqua]).map {
			$0 == .vibrantDark || $0 == .darkAqua
		} ?? true
		matchDesktop()
	}

	/// Where the light or dark look of each bar came from, for `kumiko status`.
	public private(set) var toneDescription = "not set"

	/// Gives each bar light text on a dark desktop and dark text on a light one, from the desktop
	/// right under that bar. A text colour set in the config still wins; this only picks the
	/// appearance the default colours follow.
	private func matchDesktop() {
		var descriptions: [String] = []
		let height = NSScreen.screens.first?.frame.height ?? 0

		for window in windows.values {
			let rect = CGRect(
				x: window.frame.minX, y: height - window.frame.maxY, width: window.frame.width, height: window.frame.height
			)

			let dark: Bool
			if let brightness = Desktop.brightness(under: rect) {
				// White reads on mid tones too; black only on light ones.
				dark = brightness < 0.6
				descriptions.append("\(dark ? "dark" : "light") (desktop \(String(format: "%.2f", brightness)))")
			} else {
				dark = menuBarIsDark
				descriptions.append("\(dark ? "dark" : "light") (menu bar)")
			}

			window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		}

		toneDescription = descriptions.joined(separator: ", ")
	}

	// MARK: - State

	private func handle(_ event: Event) {
		switch event {
		case let .hotkeyModeChanged(mode):
			model.mode = mode
		case let .vimModeChanged(mode, commandLine):
			model.vimMode = mode
			model.vimCommandLine = commandLine
		case .windowFrameChanged:
			break
		default:
			scheduleRefresh()
		}
	}

	/// Window events come in bursts; the bar redraws once after them.
	private func scheduleRefresh() {
		guard !refreshScheduled else { return }
		refreshScheduled = true

		DispatchQueue.main.async { [weak self] in
			MainActor.assumeIsolated {
				self?.refreshScheduled = false
				self?.refresh()
			}
		}
	}

	private func refresh() {
		model.showsNumbers = manager.usesWorkspaces
		model.workspaces = manager.workspaceStates.map { state in
			var apps: [BarModel.App] = []
			for id in state.windows {
				guard let info = tracker.windows[id], !apps.contains(where: { $0.pid == info.pid }) else { continue }
				apps.append(BarModel.App(name: info.app, pid: info.pid))
			}
			return BarModel.Workspace(
				name: state.name, index: state.index, display: state.display, isVisible: state.isVisible, apps: apps
			)
		}

		model.window = windowState()
	}

	/// What the window item shows for the focused window, the way the sketchybar item read it from
	/// yabai: floating first, then zoom, then the place in a stack.
	private func windowState() -> BarModel.WindowState {
		guard let id = tracker.focusedWindowID, let info = tracker.windows[id], info.subrole == "AXStandardWindow" else {
			return .none
		}

		let state = manager.state(of: id)

		if state.isFloating { return .floating }
		if state.zoom == "fullscreen" { return .fullscreenZoom }
		if state.zoom == "parent" { return .parentZoom }
		if let stack = manager.stackPosition(of: id) { return .stacked(index: stack.index, count: stack.count) }
		return .none
	}

	private func tick() {
		model.now = Date()
		model.battery = Battery.read()
		model.inputSource = InputSource.current()
		model.inputLanguage = InputSource.languageCode()
		model.isCaffeinated = caffeine.isOn
		readMenuBar()
	}

	/// Assigned only when it changed, so a read that finds nothing new redraws nothing.
	private func readMenuBar() {
		let menuBar = SystemMenuBar.read()
		if menuBar != model.menuBar { model.menuBar = menuBar }
	}

	private func scheduleTimers() {
		timers.forEach { $0.invalidate() }
		timers = []
		guard config.enabled else { return }

		// The clock ticks on the minute, so the time changes when the minute does.
		let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(second: 0), matchingPolicy: .nextTime)
		let clock = Timer(fire: next ?? Date(), interval: 60, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.model.now = Date() }
		}
		RunLoop.main.add(clock, forMode: .common)
		timers.append(clock)

		// Live wallpapers move and pictures change with the time of day; reading a 36-point strip
		// of the desktop is cheap.
		let desktop = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.matchDesktop() }
		}
		RunLoop.main.add(desktop, forMode: .common)
		timers.append(desktop)

		// System Settings posts nothing when an item leaves the menu bar; three preference reads every
		// two seconds catch it soon enough.
		if config.followMenuBar {
			let menuBar = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
				MainActor.assumeIsolated { self?.readMenuBar() }
			}
			RunLoop.main.add(menuBar, forMode: .common)
			timers.append(menuBar)
		}

		for item in config.shell {
			let run: @MainActor () -> Void = { [weak self] in
				Shell.firstLine(of: item.command) { line in self?.model.shell[item.name] = line }
			}
			run()
			let timer = Timer(timeInterval: max(1, item.interval), repeats: true) { _ in
				MainActor.assumeIsolated { run() }
			}
			RunLoop.main.add(timer, forMode: .common)
			timers.append(timer)
		}
	}

	private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
		let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
			MainActor.assumeIsolated { action() }
		}
		observers.append((center, token))
	}
}

/// A borderless panel under all windows but over the desktop, on every Space. It takes clicks
/// without activating kumiko, so clicking a workspace does not steal focus from the app in front.
private final class BarWindow: NSPanel {
	init(rootView: BarView) {
		super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

		isOpaque = false
		backgroundColor = .clear
		hasShadow = false
		// Set explicitly, the whole bar takes clicks. Left at the default, clicks on its clear parts
		// fall through to the desktop and bring Finder back.
		ignoresMouseEvents = false
		isReleasedWhenClosed = false
		hidesOnDeactivate = false
		// Below ordinary windows, as sketchybar with topmost off: the layout leaves room for the
		// bar, and a floating window dragged over it covers it.
		level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.backstopMenu)))
		collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

		contentView = ClickThroughHostingView(rootView: rootView)
	}

	override var canBecomeKey: Bool { false }
	override var canBecomeMain: Bool { false }

	override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
		frameRect
	}
}

/// A clear panel over the bar and the windows above it, which draws the magnified app icons. Every
/// click and every move of the pointer goes through it to what is under it.
private final class MagnifierWindow: NSPanel {
	init(rootView: MagnifierView) {
		super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

		isOpaque = false
		backgroundColor = .clear
		hasShadow = false
		ignoresMouseEvents = true
		isReleasedWhenClosed = false
		hidesOnDeactivate = false
		// Over ordinary and floating windows, as the Dock's magnified icons are; under menus.
		level = .statusBar
		collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

		contentView = NSHostingView(rootView: rootView)
	}

	override var canBecomeKey: Bool { false }
	override var canBecomeMain: Bool { false }

	override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
		frameRect
	}
}

/// Takes the first click even though the bar never becomes key.
private final class ClickThroughHostingView: NSHostingView<BarView> {
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
