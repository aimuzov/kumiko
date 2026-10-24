import Foundation
import KumikoCore

/// Moves the battery, the input menu and the clock's time out of the macOS menu bar while
/// `take_from_menu_bar` is on, and puts them back as they were when it goes off.
@MainActor
final class MenuBarTakeover {
	/// The preferences as they were before kumiko changed them; kept across restarts, so a switch
	/// turned off after one still puts back the user's own.
	private static let savedKey = "MenuBarBeforeTakeover"

	/// Brings the menu bar in line with the switch. Nothing is written or restarted when it is
	/// already there, so starting kumiko or reloading the config leaves the menu bar alone.
	func update(on: Bool) {
		let current = MenuBarPreferences.read()

		if on {
			let target = current.withoutBarItems
			guard target != current else { return }
			if saved == nil { saved = current }
			apply(target, over: current)
		} else if let before = saved {
			saved = nil
			if before != current { apply(before, over: current) }
		}
	}

	private func apply(_ preferences: MenuBarPreferences, over current: MenuBarPreferences) {
		preferences.write()

		// They read the preferences only when they start, and macOS starts them again at once.
		var restart: [String] = []
		if preferences.battery != current.battery || preferences.analogClock != current.analogClock {
			restart.append("ControlCenter")
		}
		if preferences.inputMenu != current.inputMenu {
			restart.append("TextInputMenuAgent")
		}
		guard !restart.isEmpty else { return }

		let killall = Process()
		killall.executableURL = URL(filePath: "/usr/bin/killall")
		killall.arguments = restart
		try? killall.run()
	}

	private var saved: MenuBarPreferences? {
		get {
			UserDefaults.standard.data(forKey: Self.savedKey)
				.flatMap { try? JSONDecoder().decode(MenuBarPreferences.self, from: $0) }
		}
		set {
			UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.savedKey)
		}
	}
}
