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
	// No Dock icon and no app menu: kumiko lives in the status bar.
	app.setActivationPolicy(.accessory)
	app.run()
}
