import ServiceManagement

/// Launch at login through `SMAppService`, which only works from inside an app bundle: a bare
/// binary from `swift run` has no bundle to register.
enum LoginItem {
	static var isAvailable: Bool {
		Bundle.main.bundleURL.pathExtension == "app"
	}

	static var isEnabled: Bool {
		SMAppService.mainApp.status == .enabled
	}

	static func setEnabled(_ enabled: Bool) throws {
		if enabled {
			try SMAppService.mainApp.register()
		} else {
			try SMAppService.mainApp.unregister()
		}
	}
}
