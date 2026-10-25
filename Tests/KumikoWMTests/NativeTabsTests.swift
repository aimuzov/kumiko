import CoreGraphics
import Testing

@testable import KumikoWM

/// MacPass with two databases open as tabs: 1 is `pswds.kdbx`, 2 is `secrets.kdbx`.
struct NativeTabsTests {
	private typealias Replacement = NativeTabs.Replacement

	@Test func switchingTabsHandsThePlaceOver() {
		let changes = NativeTabs.changes(windows: [1: false, 2: true], listed: [2], showsTabs: true)
		#expect(changes.background == [1: true, 2: false])
		#expect(changes.replaced == [Replacement(old: 1, new: 2)])
	}

	@Test func nothingChangesWhileTheSameTabIsInFront() {
		let changes = NativeTabs.changes(windows: [1: false, 2: true], listed: [1], showsTabs: true)
		#expect(changes == NativeTabs.Changes())
	}

	/// cmd-T: the new tab is new to kumiko too.
	@Test func aNewTabTakesThePlaceOfTheOneInFront() {
		let changes = NativeTabs.changes(windows: [1: false, 2: false], listed: [2], showsTabs: true, appeared: 2)
		#expect(changes.background == [1: true])
		#expect(changes.replaced == [Replacement(old: 1, new: 2)])
	}

	@Test func aNewWindowWithoutTabsTakesNoPlace() {
		let changes = NativeTabs.changes(windows: [1: false, 2: false], listed: [1, 2], showsTabs: false, appeared: 2)
		#expect(changes == NativeTabs.Changes())
	}

	@Test func closingTheTabInFrontHandsThePlaceToTheNextOne() {
		let changes = NativeTabs.changes(windows: [1: false, 2: true], listed: [2], showsTabs: false, gone: 1)
		#expect(changes.background == [2: false])
		#expect(changes.replaced == [Replacement(old: 1, new: 2)])
	}

	@Test func closingATabBehindChangesNothing() {
		let changes = NativeTabs.changes(windows: [1: false, 2: true], listed: [1], showsTabs: false, gone: 2)
		#expect(changes == NativeTabs.Changes())
	}

	/// The tab dragged out stays where it was in front of, and takes a place of its own.
	@Test func aTabDraggedOutIsAWindowOfItsOwn() {
		let changes = NativeTabs.changes(windows: [1: false, 2: true], listed: [1, 2], showsTabs: false)
		#expect(changes.background == [2: false])
		#expect(changes.replaced.isEmpty)
	}

	/// Merge All Windows: the other windows go behind and leave their places.
	@Test func windowsMergedIntoTabsLeaveTheirPlaces() {
		let changes = NativeTabs.changes(windows: [1: false, 2: false], listed: [1], showsTabs: true)
		#expect(changes.background == [2: true])
		#expect(changes.replaced.isEmpty)
	}

	/// No tab bar, no tabs: a window the app does not list is on another Space, not behind a tab.
	@Test func anUnlistedWindowIsNoTabWithoutATabBar() {
		let changes = NativeTabs.changes(windows: [1: false, 2: false], listed: [1], showsTabs: false)
		#expect(changes == NativeTabs.Changes())
	}
}

struct BSPTreeSubstituteTests {
	private let area = CGRect(x: 0, y: 0, width: 1000, height: 600)

	@Test func theNewWindowGetsTheOldOnesFrame() {
		let tree = BSPTree()
		tree.insert(1, near: nil, in: area, gap: 0)
		tree.insert(2, near: nil, in: area, gap: 0)
		let before = tree.frames(in: area, gap: 0)

		tree.substitute(1, with: 3)

		#expect(!tree.contains(1))
		#expect(tree.frames(in: area, gap: 0) == [3: before[1]!, 2: before[2]!])
	}

	@Test func theNewWindowKeepsItsPlaceInAStack() {
		let tree = BSPTree()
		tree.insert(1, near: nil, in: area, gap: 0)
		tree.insert(2, near: nil, in: area, gap: 0)
		tree.stack(2, onto: 1)

		tree.substitute(2, with: 3)

		#expect(tree.allWindows == [1, 3])
		#expect(tree.stackIndex(of: 3) == 2)
	}

	@Test func aWindowAlreadyInTheLayoutIsNotPutInTwice() {
		let tree = BSPTree()
		tree.insert(1, near: nil, in: area, gap: 0)
		tree.insert(2, near: nil, in: area, gap: 0)

		tree.substitute(1, with: 2)

		#expect(tree.allWindows == [1, 2])
	}
}
