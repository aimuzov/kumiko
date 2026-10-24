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
}
