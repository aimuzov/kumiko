import Foundation

/// What the macOS menu bar shows of what the bar can show too, read from the preferences System
/// Settings writes. The bar leaves those items out, so nothing sits on screen twice.
public struct SystemMenuBar: Equatable, Sendable {
	public var showsBattery: Bool
	public var showsInputMenu: Bool
	/// An analog clock's hands can't be read to the minute, so only a digital one shows the time.
	public var showsDigitalClock: Bool

	public init(showsBattery: Bool = true, showsInputMenu: Bool = true, showsDigitalClock: Bool = true) {
		self.showsBattery = showsBattery
		self.showsInputMenu = showsInputMenu
		self.showsDigitalClock = showsDigitalClock
	}

	/// From the preference values as stored; a missing one is what macOS shows by default.
	public init(battery: Int?, inputMenu: Bool?, analogClock: Bool?) {
		// Control Center keeps one number per item: 2 is on in the menu bar, 8 off, 16 in Control
		// Center, so 18 shows the battery and 24 keeps it in Control Center only.
		self.init(
			showsBattery: battery.map { $0 & 2 != 0 } ?? true,
			showsInputMenu: inputMenu ?? true,
			showsDigitalClock: !(analogClock ?? false)
		)
	}

	/// Whether the menu bar already shows what the bar item of this name would.
	public func shows(_ item: String) -> Bool {
		switch item {
		case "battery": showsBattery
		case "input": showsInputMenu
		case "datetime": showsDigitalClock
		default: false
		}
	}

	/// Reads the preferences fresh: System Settings writes them from another process, and a cached
	/// value would miss a change made a moment ago.
	public static func read() -> SystemMenuBar {
		SystemMenuBar(
			battery: value("Battery", in: "com.apple.controlcenter", host: kCFPreferencesCurrentHost),
			inputMenu: value("visible", in: "com.apple.TextInputMenu", host: kCFPreferencesAnyHost),
			analogClock: value("IsAnalog", in: "com.apple.menuextra.clock", host: kCFPreferencesAnyHost)
		)
	}

	private static func value<T>(_ key: String, in domain: String, host: CFString) -> T? {
		CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, host)
		return CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, host) as? T
	}
}
