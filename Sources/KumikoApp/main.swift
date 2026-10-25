import AppKit
import KumikoCore

let paths = Paths.standard()

// A second copy would fight the first over every window; hand over to the running one instead.
if IPCServer.isRunning(at: paths.socket) {
	FileHandle.standardError.write(Data("kumiko is already running\n".utf8))
	exit(0)
}

MainActor.assumeIsolated {
	let app = NSApplication.shared
	let delegate = AppDelegate(paths: paths)

	app.delegate = delegate
	// No Dock icon: kumiko lives in the status bar. Its app menu shows only on an empty
	// workspace, where kumiko takes focus so the menu bar is not left blank.
	app.setActivationPolicy(.accessory)
	app.mainMenu = appMenu()
	app.run()
}

@MainActor
private func appMenu() -> NSMenu {
	let menu = NSMenu()
	let item = NSMenuItem()
	item.submenu = NSMenu(title: "kumiko")
	item.submenu?.addItem(withTitle: "About kumiko", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
	item.submenu?.addItem(.separator())
	// Sent up the responder chain to the app delegate.
	item.submenu?.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
	item.submenu?.addItem(.separator())
	item.submenu?.addItem(withTitle: "Quit kumiko", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
	menu.addItem(item)

	// AppKit hands Cmd-W and the editing keys only to menu items that carry them, so the settings
	// window needs these two menus for them to work in it.
	let edit = NSMenuItem()
	edit.submenu = NSMenu(title: "Edit")
	edit.submenu?.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
	edit.submenu?.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
	edit.submenu?.addItem(.separator())
	edit.submenu?.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
	edit.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
	edit.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
	edit.submenu?.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
	menu.addItem(edit)

	let window = NSMenuItem()
	window.submenu = NSMenu(title: "Window")
	window.submenu?.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
	window.submenu?.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
	menu.addItem(window)
	NSApplication.shared.windowsMenu = window.submenu

	return menu
}
