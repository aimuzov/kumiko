import AppKit

/// Explains, once per launch, which permissions are missing and why. kumiko keeps running without
/// them; the status menu shows what is still missing.
@MainActor
enum Onboarding {
	static func runIfNeeded() {
		let missing = Permission.missing
		guard !missing.isEmpty else { return }

		let alert = NSAlert()
		alert.messageText = "kumiko needs permissions"
		alert.informativeText = """
			\(missing.map(\.title).joined(separator: " and ")) — \
			Accessibility lets kumiko arrange windows of other apps, Input Monitoring lets it listen \
			for hotkeys. Turn kumiko on in System Settings; the status menu shows what is still missing.
			"""
		alert.addButton(withTitle: "Open System Settings")
		alert.addButton(withTitle: "Later")

		NSApp.activate()
		guard alert.runModal() == .alertFirstButtonReturn else { return }

		for permission in missing {
			permission.request()
		}
	}
}
