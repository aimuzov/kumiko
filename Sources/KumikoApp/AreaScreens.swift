import AppKit
import KumikoCore

/// The screens the two areas stand for, by the names macOS gives them, picked the way
/// the window manager places a workspace: Main is the screen with the menu bar, External
/// the first monitor, which is Main itself when the menu bar was moved onto it. Areas
/// show only with more than one screen and a monitor among them: a Mac mini with one
/// monitor or a closed laptop would get two areas for the same screen.
struct AreaScreens: Equatable {
	var main: String?
	var external: String?

	/// A monitor that isn't there, for looking at the areas on a laptop alone:
	/// `defaults write online.aimuzov.kumiko DebugExternalScreen "Fake Monitor"`. Only the
	/// settings page sees it; the window manager still places workspaces on real screens.
	static let debugExternalKey = "DebugExternalScreen"

	@MainActor
	static func current() -> AreaScreens {
		let screens = NSScreen.screens
		if let fake = UserDefaults.standard.string(forKey: debugExternalKey), !fake.isEmpty {
			return AreaScreens(main: screens.first?.localizedName, external: fake)
		}
		let monitors = screens.filter { screen in
			let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
			return number.map { CGDisplayIsBuiltin($0.uint32Value) == 0 } ?? true
		}
		let external = screens.count > 1 ? monitors.first : nil
		return AreaScreens(main: screens.first?.localizedName, external: external?.localizedName)
	}

	var showsAreas: Bool { external != nil }

	func label(of area: Config.Workspace.Area) -> String {
		let (title, screen) = area == .main ? ("Main", main) : ("External", external)
		return screen.map { "\(title) · \($0)" } ?? title
	}
}
