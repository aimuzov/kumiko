import Foundation

/// The system's light or dark look, through the private SkyLight calls Control Center uses;
/// none needs SIP. With Automatic appearance on, a switch lasts until the next scheduled change
/// and Automatic stays on, which `defaults write AppleInterfaceStyle` would not give.
public enum Appearance {
	private typealias Get = @convention(c) () -> Bool
	private typealias Set = @convention(c) (Bool) -> Void

	private static let functions: (get: Get, set: Set)? = {
		guard
			let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
			let get = dlsym(lib, "SLSGetAppearanceThemeLegacy"),
			let set = dlsym(lib, "SLSSetAppearanceThemeLegacy")
		else { return nil }
		return (unsafeBitCast(get, to: Get.self), unsafeBitCast(set, to: Set.self))
	}()

	/// Nil when SkyLight does not have the calls.
	public static var isDark: Bool? { functions?.get() }

	@discardableResult
	public static func set(dark: Bool) -> Bool {
		guard let functions else { return false }
		functions.set(dark)
		return true
	}

	/// Answers `kumiko appearance [toggle|dark|light]`; with no argument, the current look.
	public static func handle(_ args: [String]) -> Response {
		guard let dark = isDark else { return .failure("this macOS has no appearance calls in SkyLight") }
		switch args.first {
		case nil: return .success(dark ? "dark" : "light")
		case "toggle": set(dark: !dark)
		case "dark": set(dark: true)
		case "light": set(dark: false)
		case let other?: return .failure("unknown appearance \(other): toggle, dark or light")
		}
		return .success()
	}
}
