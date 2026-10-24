import KumikoCore
import Testing

struct SystemMenuBarTests {
	@Test func controlCenterNumbersSayWhetherTheBatteryIsInTheMenuBar() {
		#expect(SystemMenuBar(battery: 18, inputMenu: nil, analogClock: nil).showsBattery)
		#expect(SystemMenuBar(battery: 2, inputMenu: nil, analogClock: nil).showsBattery)
		#expect(!SystemMenuBar(battery: 24, inputMenu: nil, analogClock: nil).showsBattery)
		#expect(!SystemMenuBar(battery: 8, inputMenu: nil, analogClock: nil).showsBattery)
	}

	@Test func missingPreferencesAreWhatMacOSShowsByDefault() {
		#expect(SystemMenuBar(battery: nil, inputMenu: nil, analogClock: nil) == SystemMenuBar())
	}

	@Test func onlyADigitalClockShowsTheTime() {
		#expect(SystemMenuBar(battery: nil, inputMenu: nil, analogClock: true).shows("datetime") == false)
		#expect(SystemMenuBar(battery: nil, inputMenu: nil, analogClock: false).shows("datetime"))
	}

	@Test func itemsTheMenuBarCannotShowAreNeverItsOwn() {
		let menuBar = SystemMenuBar()
		#expect(menuBar.shows("input"))
		#expect(!menuBar.shows("workspaces"))
		#expect(!menuBar.shows("caffeinate"))
	}

	@Test func followingTheMenuBarIsOnUnlessTurnedOff() throws {
		#expect(try Config.parse("").bar.followMenuBar)
		#expect(try Config.parse("[bar]\nfollow_menu_bar = false").bar.followMenuBar == false)
	}

	@Test func takingFromTheMenuBarIsOffUnlessTurnedOn() throws {
		#expect(try Config.parse("").bar.takeFromMenuBar == false)
		#expect(try Config.parse("[bar]\ntake_from_menu_bar = true").bar.takeFromMenuBar)
	}

	@Test func withoutBarItemsKeepsTheBatteryInControlCenter() {
		#expect(MenuBarPreferences(battery: 18).withoutBarItems.battery == 24)
		#expect(MenuBarPreferences(battery: 2).withoutBarItems.battery == 8)
		#expect(MenuBarPreferences(battery: 24).withoutBarItems.battery == 24)
		#expect(MenuBarPreferences().withoutBarItems.battery == 24)
	}

	@Test func withoutBarItemsLeavesTheMenuBarNothingTheBarShows() {
		let preferences = MenuBarPreferences(battery: 18, inputMenu: true, analogClock: false).withoutBarItems
		#expect(preferences == MenuBarPreferences(battery: 24, inputMenu: false, analogClock: true))
		#expect(!["battery", "input", "datetime"].contains(where: SystemMenuBar(preferences).shows))
		#expect(preferences.withoutBarItems == preferences)
	}
}
