import AppKit
import KumikoCore

/// The screens the two areas stand for, by the names macOS gives them, picked the way
/// the window manager places a workspace (`Display.matching`): Main is the screen with the
/// menu bar, as System Settings calls it, and External the other one, a monitor first and
/// the laptop's own screen when the menu bar sits on the monitor. Areas show only with two
/// screens: a Mac mini with one monitor or a closed laptop has nothing to tell apart.
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
		func isBuiltin(_ screen: NSScreen) -> Bool {
			let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
			return number.map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
		}
		let others = screens.dropFirst()
		let external = others.first { !isBuiltin($0) } ?? others.first
		return AreaScreens(main: screens.first?.localizedName, external: external?.localizedName)
	}

	var showsAreas: Bool { external != nil }

	func label(of area: Config.Workspace.Area) -> String {
		let (title, screen) = area == .main ? ("Main", main) : ("External", external)
		return screen.map { "\(title) · \($0)" } ?? title
	}
}
