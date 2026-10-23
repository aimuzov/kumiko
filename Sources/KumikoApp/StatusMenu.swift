import AppKit
import KumikoCore

/// The status bar icon and its menu. The menu is rebuilt each time it opens, so permission and
/// login item states are always current without polling.
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

		menu.addItem(disabled("kumiko \(Kumiko.version)"))
		menu.addItem(.separator())

		for permission in Permission.allCases {
			if permission.isGranted {
				let entry = disabled(permission.title)
				entry.state = .on
				menu.addItem(entry)
			} else {
				let entry = action("Grant \(permission.title)…", #selector(grant(_:)))
				entry.representedObject = permission
				menu.addItem(entry)
			}
		}

		menu.addItem(.separator())

		if let error = app.configError {
			menu.addItem(disabled("Config error: \(error.description)"))
		}

		let settings = NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
		settings.target = app
		menu.addItem(settings)
		menu.addItem(action("Reload Config", #selector(reloadConfig)))
		menu.addItem(action("Open Config Folder", #selector(openConfigFolder)))

		if LoginItem.isAvailable {
			let login = action("Launch at Login", #selector(toggleLoginItem))
			login.state = LoginItem.isEnabled ? .on : .off
			menu.addItem(login)
		}

		menu.addItem(.separator())
		menu.addItem(NSMenuItem(title: "Quit kumiko", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
	}

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

	@objc private func grant(_ sender: NSMenuItem) {
		(sender.representedObject as? Permission)?.request()
	}

	@objc private func reloadConfig() {
		app.reloadConfig()
	}

	@objc private func openConfigFolder() {
		NSWorkspace.shared.open(app.paths.configDirectory)
	}

	@objc private func toggleLoginItem() {
		do {
			try LoginItem.setEnabled(!LoginItem.isEnabled)
		} catch {
			Log.app.error("login item: \(error.localizedDescription, privacy: .public)")
			NSAlert(error: error).runModal()
		}
	}
}
