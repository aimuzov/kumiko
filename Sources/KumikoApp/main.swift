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
	item.submenu?.addItem(withTitle: "Quit kumiko", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
	menu.addItem(item)
	return menu
}
