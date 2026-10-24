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

	public init(_ preferences: MenuBarPreferences) {
		self.init(battery: preferences.battery, inputMenu: preferences.inputMenu, analogClock: preferences.analogClock)
	}

	public static func read() -> SystemMenuBar {
		SystemMenuBar(MenuBarPreferences.read())
	}
}

/// The three preferences behind the menu bar items the bar can show, as stored: nil for one that
/// was never set. kumiko writes them to move those items out, and keeps the old ones to put back.
public struct MenuBarPreferences: Codable, Equatable, Sendable {
	public var battery: Int?
	public var inputMenu: Bool?
	public var analogClock: Bool?

	public init(battery: Int? = nil, inputMenu: Bool? = nil, analogClock: Bool? = nil) {
		self.battery = battery
		self.inputMenu = inputMenu
		self.analogClock = analogClock
	}

	/// With the bar's items out of the menu bar: the battery off there but still in Control Center,
	/// no input menu, and an analog clock, the one item the menu bar cannot do without.
	public var withoutBarItems: MenuBarPreferences {
		MenuBarPreferences(battery: (battery ?? 18) & ~2 | 8, inputMenu: false, analogClock: true)
	}

	/// Read fresh: System Settings writes them from another process, and a cached value would miss
	/// a change made a moment ago.
	public static func read() -> MenuBarPreferences {
		MenuBarPreferences(
			battery: Key.battery.read(), inputMenu: Key.inputMenu.read(), analogClock: Key.analogClock.read()
		)
	}

	/// Stores them, nil as no key at all. What shows them, Control Center or the input menu agent,
	/// reads them only when it starts.
	public func write() {
		Key.battery.write(battery)
		Key.inputMenu.write(inputMenu)
		Key.analogClock.write(analogClock)
	}

	private enum Key {
		case battery, inputMenu, analogClock

		private var place: (key: String, domain: String, host: CFString) {
			switch self {
			case .battery: ("Battery", "com.apple.controlcenter", kCFPreferencesCurrentHost)
			case .inputMenu: ("visible", "com.apple.TextInputMenu", kCFPreferencesAnyHost)
			case .analogClock: ("IsAnalog", "com.apple.menuextra.clock", kCFPreferencesAnyHost)
			}
		}

		func read<T>() -> T? {
			let (key, domain, host) = place
			CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, host)
			return CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, host) as? T
		}

		func write(_ value: (some Any)?) {
			let (key, domain, host) = place
			CFPreferencesSetValue(
				key as CFString, value.map { $0 as AnyObject }, domain as CFString, kCFPreferencesCurrentUser, host
			)
			CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, host)
		}
	}
}
