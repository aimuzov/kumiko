import AppKit
import KumikoCore
import KumikoWM

/// The status bar icon and its menu. The menu is rebuilt each time it opens, so the workspaces,
/// the permissions and the config's state are always current without polling.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
	private unowned let app: AppDelegate
	private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
	private let menu = NSMenu()
	private var appearanceObservation: NSKeyValueObservation?

	/// Called with the look macOS gives the menu bar, light or dark after the desktop under it,
	/// now and whenever it changes.
	var onAppearanceChange: ((NSAppearance) -> Void)? {
		didSet {
			appearanceObservation = item.button?.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] button, _ in
				// AppKit changes a view's appearance on the main thread, so that is where this runs.
				MainActor.assumeIsolated { self?.onAppearanceChange?(button.effectiveAppearance) }
			}
		}
	}

	init(app: AppDelegate) {
		self.app = app
		super.init()

		item.button?.image = NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: "kumiko")
		menu.delegate = self
		item.menu = menu
	}

	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()

		// What is wrong comes first, and only when something is.
		var problems: [NSMenuItem] = []
		if let error = app.configError {
			problems.append(warning("Config error: \(error.description)", #selector(editConfig)))
		}
		for permission in Permission.allCases where !permission.isGranted {
			let entry = warning("Grant \(permission.title)…", #selector(grant(_:)))
			entry.representedObject = permission
			problems.append(entry)
		}
		add(problems)

		add(workspaceItems() + hotkeyModeItems())

		let pause = action(app.isPaused ? "Resume kumiko" : "Pause kumiko", #selector(togglePause))
		pause.image = Self.symbol(app.isPaused ? "play.circle" : "pause.circle")
		add([pause])

		let settings = NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
		settings.target = app
		settings.image = Self.symbol("gearshape")
		add([settings])

		add([NSMenuItem(title: "Quit kumiko", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")])
	}

	/// A group of items, set apart from the one before it; an empty group leaves no separator.
	private func add(_ items: [NSMenuItem]) {
		guard !items.isEmpty else { return }
		if !menu.items.isEmpty { menu.addItem(.separator()) }
		items.forEach(menu.addItem)
	}

	// MARK: - Workspaces

	/// A line per display with the workspace it shows, and that display's workspaces under it.
	/// None while the window manager or its workspaces are off, or kumiko is paused.
	private func workspaceItems() -> [NSMenuItem] {
		guard
			let manager = app.manager, !app.isPaused, app.config.wm.enabled, manager.usesWorkspaces
		else { return [] }

		let workspaces = manager.workspaceStates
		let shortcuts = workspaceShortcuts()

		return manager.displayStates.compactMap { display in
			let own = workspaces.filter { $0.display == display.id }
			guard !own.isEmpty else { return nil }

			let setting = manager.displaySetting(for: display.id)
			let entry = NSMenuItem(title: "\(Self.displayLabel(setting)): \(display.workspace ?? "—")", action: nil, keyEquivalent: "")
			entry.image = Self.symbol(setting == nil ? "square.grid.2x2" : display.isBuiltin ? "laptopcomputer" : "display")
			let submenu = NSMenu()
			for workspace in own {
				let row = action(workspace.name, #selector(showWorkspace(_:)))
				row.representedObject = workspace.name
				row.state = workspace.isVisible ? .on : .off
				if let combo = shortcuts[workspace.name] ?? shortcuts[String(workspace.index)] {
					row.badge = NSMenuItemBadge(string: HotkeyCatalog.symbols(combo))
				}
				submenu.addItem(row)
			}
			entry.submenu = submenu
			return entry
		}
	}

	/// "Main" and "External" as the settings window names them; the screen's own name for one
	/// matched by name, and "Workspace" with a single display.
	private static func displayLabel(_ setting: String?) -> String {
		switch setting {
		case nil: "Workspace"
		case "main": "Main"
		case "external": "External"
		case "builtin": "Built-in"
		case let name?: name
		}
	}

	/// The hotkey that shows each workspace, by the name or number its `workspace focus` takes.
	private func workspaceShortcuts() -> [String: KeyCombo] {
		let hotkeys = app.config.hotkeys
		guard hotkeys.enabled else { return [:] }

		var shortcuts: [String: KeyCombo] = [:]
		for (combo, action) in hotkeys.bindings.merging(hotkeys.global, uniquingKeysWith: { first, _ in first }) {
			let words = action.run?.split(separator: " ").map(String.init) ?? []
			guard words.count == 3, words[0] == "workspace", words[1] == "focus" else { continue }
			// Of two shortcuts for one workspace, the same one each time.
			if let other = shortcuts[words[2]], HotkeyCatalog.symbols(other) < HotkeyCatalog.symbols(combo) { continue }
			shortcuts[words[2]] = combo
		}
		return shortcuts
	}

	private func hotkeyModeItems() -> [NSMenuItem] {
		guard !app.isPaused, app.config.hotkeys.enabled, let hotkeys = app.hotkeys, hotkeys.isRunning else { return [] }
		let entry = disabled("Hotkeys: \(HotkeyCatalog.modeTitle(hotkeys.mode))")
		entry.image = Self.symbol("command")
		return [entry]
	}

	/// The icons at the left of the items, as the system gives Quit one of its own.
	private static func symbol(_ name: String) -> NSImage? {
		NSImage(systemSymbolName: name, accessibilityDescription: nil)
	}

	// MARK: - Items

	private func disabled(_ title: String) -> NSMenuItem {
		let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
		entry.isEnabled = false
		return entry
	}

	private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
		let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
		entry.target = self
		return entry
	}

	private func warning(_ title: String, _ selector: Selector) -> NSMenuItem {
		let entry = action(title, selector)
		entry.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
			.withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
		return entry
	}

	// MARK: - Actions

	@objc private func grant(_ sender: NSMenuItem) {
		(sender.representedObject as? Permission)?.request()
	}

	@objc private func showWorkspace(_ sender: NSMenuItem) {
		guard let name = sender.representedObject as? String else { return }
		_ = app.manager?.handle(["workspace", "focus", name])
	}

	@objc private func togglePause() {
		app.setPaused(!app.isPaused)
		// Dimmed while paused, the way macOS shows a menu bar item that is off.
		item.button?.appearsDisabled = app.isPaused
	}

	/// An empty file is a valid config, so one that is not there yet is made to open it.
	@objc private func editConfig() {
		let file = app.paths.configFile
		if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
			try? FileManager.default.createDirectory(at: app.paths.configDirectory, withIntermediateDirectories: true)
			FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil)
		}
		NSWorkspace.shared.open(file)
	}
}
