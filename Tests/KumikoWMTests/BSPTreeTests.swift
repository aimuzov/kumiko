import CoreGraphics
import Testing

@testable import KumikoWM

/// A 1000×600 area with no gap unless a test asks for one, so expected rectangles are easy to read.
private let area = CGRect(x: 0, y: 0, width: 1000, height: 600)

private func tree(_ ids: UInt32..., gap: Double = 0) -> BSPTree {
	let tree = BSPTree()
	for id in ids {
		tree.insert(id, near: nil, in: area, gap: gap)
	}
	return tree
}

private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CGRect {
	CGRect(x: x, y: y, width: width, height: height)
}

struct BSPTreeInsertTests {
	@Test func firstWindowTakesTheWholeArea() {
		#expect(tree(1).frames(in: area, gap: 0) == [1: area])
	}

	@Test func secondWindowSplitsTheLongerSideAndGoesSecond() {
		let frames = tree(1, 2).frames(in: area, gap: 0)
		#expect(frames[1] == rect(0, 0, 500, 600))
		#expect(frames[2] == rect(500, 0, 500, 600))
	}

	@Test func thirdWindowSplitsTheLastLeafAcrossItsLongerSide() {
		// The right half is 500×600, taller than wide, so it splits into rows.
		let frames = tree(1, 2, 3).frames(in: area, gap: 0)
		#expect(frames[2] == rect(500, 0, 500, 300))
		#expect(frames[3] == rect(500, 300, 500, 300))
	}

	@Test func insertNearTargetSplitsThatWindow() {
		let tree = tree(1, 2)
		tree.insert(3, near: 1, in: area, gap: 0)

		let frames = tree.frames(in: area, gap: 0)
		#expect(frames[1] == rect(0, 0, 500, 300))
		#expect(frames[3] == rect(0, 300, 500, 300))
		#expect(frames[2] == rect(500, 0, 500, 600))
	}

	@Test func gapSeparatesNeighbours() {
		let frames = tree(1, 2, gap: 10).frames(in: area, gap: 10)
		#expect(frames[1] == rect(0, 0, 495, 600))
		#expect(frames[2] == rect(505, 0, 495, 600))
	}

	@Test func insertingTwiceIsIgnored() {
		let tree = tree(1, 2)
		tree.insert(2, near: 1, in: area, gap: 0)
		#expect(tree.allWindows == [1, 2])
	}
}

struct BSPTreeRemoveTests {
	@Test func siblingTakesOverTheParentArea() {
		let tree = tree(1, 2, 3)
		tree.remove(2)

		let frames = tree.frames(in: area, gap: 0)
		#expect(frames[3] == rect(500, 0, 500, 600))
		#expect(frames[1] == rect(0, 0, 500, 600))
	}

	@Test func removingTheLastWindowEmptiesTheTree() {
		let tree = tree(1)
		tree.remove(1)
		#expect(tree.isEmpty)
	}

	@Test func removingAnUnknownWindowChangesNothing() {
		let tree = tree(1, 2)
		tree.remove(9)
		#expect(tree.allWindows == [1, 2])
	}
}

struct BSPTreeMoveTests {
	@Test func siblingsSwapOnWarp() {
		let tree = tree(1, 2)
		tree.warp(2, to: 1, direction: .west)
		#expect(tree.visibleWindows == [2, 1])
	}

	/// [1 | [2 / 3]]: moving 3 west lands it in the left column, on the side facing where it came
	/// from, instead of jumping past 1.
	@Test func warpLandsOnTheSideFacingTheOrigin() {
		let tree = tree(1, 2, 3)
		tree.warp(3, to: 1, direction: .west)

		let frames = tree.frames(in: area, gap: 0)
		#expect(tree.visibleWindows == [1, 3, 2])
		#expect(frames[2] == rect(500, 0, 500, 600))
		#expect(frames[1] == rect(0, 0, 250, 600))
		#expect(frames[3] == rect(250, 0, 250, 600))
	}

	@Test func swapKeepsTheShape() {
		let tree = tree(1, 2, 3)
		let before = tree.frames(in: area, gap: 0)
		tree.swap(1, 3)
		let after = tree.frames(in: area, gap: 0)

		#expect(after[3] == before[1])
		#expect(after[1] == before[3])
		#expect(after[2] == before[2])
	}
}

struct BSPTreeSizeTests {
	@Test func resizingTheInnerEdgeMovesTheSplit() {
		let tree = tree(1, 2)
		#expect(tree.resize(1, edge: .east, by: 100, in: area, gap: 0))
		#expect(tree.frames(in: area, gap: 0)[1] == rect(0, 0, 600, 600))
	}

	@Test func resizingTheOuterEdgeFails() {
		let tree = tree(1, 2)
		#expect(!tree.resize(1, edge: .west, by: 100, in: area, gap: 0))
		#expect(!tree.resize(2, edge: .east, by: 100, in: area, gap: 0))
	}

	@Test func resizeFindsTheNearestSplitOnThatAxis() {
		// 3 is the bottom right; its west edge belongs to the root split, two levels up.
		let tree = tree(1, 2, 3)
		#expect(tree.resize(3, edge: .west, by: -100, in: area, gap: 0))
		#expect(tree.frames(in: area, gap: 0)[1] == rect(0, 0, 400, 600))
	}

	@Test func ratioIsClamped() {
		let tree = tree(1, 2)
		tree.resize(1, edge: .east, by: 10_000, in: area, gap: 0)
		#expect(tree.frames(in: area, gap: 0)[1] == rect(0, 0, 900, 600))
	}

	@Test func sizeIsTheWindowsOwnPart() {
		let tree = tree(1, 2)
		tree.setSize(2, 0.7)
		#expect(tree.frames(in: area, gap: 0)[2] == rect(300, 0, 700, 600))
	}

	@Test func balanceGivesEveryLeafTheSameArea() {
		let tree = tree(1, 2)
		tree.insert(3, near: 2, in: area, gap: 0)
		tree.insert(4, near: 1, in: area, gap: 0)
		tree.setSize(1, 0.2)
		tree.resize(2, edge: .east, by: 200, in: area, gap: 0)
		tree.balance()

		// Two columns of two rows each: every window a quarter.
		let frames = tree.frames(in: area, gap: 0)
		#expect(frames.values.allSatisfy { $0.size == CGSize(width: 500, height: 300) })
	}
}

struct BSPTreeTransformTests {
	@Test func rotatingClockwiseTurnsColumnsIntoRows() {
		let tree = tree(1, 2)
		tree.rotate(90)

		let frames = tree.frames(in: area, gap: 0)
		#expect(frames[1] == rect(0, 0, 1000, 300))
		#expect(frames[2] == rect(0, 300, 1000, 300))
	}

	@Test func rotatingRowsClockwisePutsTheTopOnTheRight() {
		let tree = tree(1, 2)
		tree.rotate(90)
		tree.rotate(90)

		let frames = tree.frames(in: area, gap: 0)
		#expect(frames[2] == rect(0, 0, 500, 600))
		#expect(frames[1] == rect(500, 0, 500, 600))
	}

	@Test func fourQuarterTurnsAreTheSameLayout() {
		let tree = tree(1, 2, 3)
		tree.setSize(1, 0.3)
		let before = tree.frames(in: area, gap: 0)

		tree.rotate(270)
		tree.rotate(90)
		#expect(tree.frames(in: area, gap: 0) == before)
	}

	@Test func mirrorColumnsSwapsLeftAndRight() {
		let tree = tree(1, 2)
		tree.setSize(1, 0.3)
		tree.mirror(.columns)

		let frames = tree.frames(in: area, gap: 0)
		#expect(frames[2] == rect(0, 0, 700, 600))
		#expect(frames[1] == rect(700, 0, 300, 600))
	}

	@Test func mirrorRowsLeavesColumnsAlone() {
		let tree = tree(1, 2, 3)
		tree.mirror(.rows)

		let frames = tree.frames(in: area, gap: 0)
		#expect(frames[1] == rect(0, 0, 500, 600))
		#expect(frames[3] == rect(500, 0, 500, 300))
		#expect(frames[2] == rect(500, 300, 500, 300))
	}
}

struct BSPTreeZoomTests {
	@Test func fullscreenZoomCoversTheArea() {
		let tree = tree(1, 2, 3)
		tree.toggleZoom(3, .fullscreen)
		#expect(tree.frames(in: area, gap: 0)[3] == area)
	}

	@Test func parentZoomCoversTheParentSplit() {
		let tree = tree(1, 2, 3)
		tree.toggleZoom(3, .parent)
		#expect(tree.frames(in: area, gap: 0)[3] == rect(500, 0, 500, 600))
	}

	@Test func togglingTheSameZoomTurnsItOff() {
		let tree = tree(1, 2)
		tree.toggleZoom(1, .fullscreen)
		#expect(tree.toggleZoom(1, .fullscreen) == nil)
		#expect(tree.frames(in: area, gap: 0)[1] == rect(0, 0, 500, 600))
	}

	@Test func anotherZoomReplacesTheFirst() {
		let tree = tree(1, 2)
		tree.toggleZoom(1, .fullscreen)
		#expect(tree.toggleZoom(1, .parent) == .parent)
	}
}

struct BSPTreeStackTests {
	@Test func stackedWindowsShareTheLeaf() {
		let tree = tree(1, 2, 3)
		tree.stack(3, onto: 1)

		let frames = tree.frames(in: area, gap: 0)
		#expect(frames[1] == rect(0, 0, 500, 600))
		#expect(frames[3] == frames[1])
		#expect(frames[2] == rect(500, 0, 500, 600))
		#expect(tree.visibleWindows == [3, 2])
	}

	@Test func stackIndexCountsFromOne() {
		let tree = tree(1, 2, 3)
		tree.stack(2, onto: 1)

		#expect(tree.stackIndex(of: 1) == 1)
		#expect(tree.stackIndex(of: 2) == 2)
		#expect(tree.stackIndex(of: 3) == 0)
		#expect(tree.stackCount(of: 1) == 2)
	}

	/// Three windows in one stack: the case the dotfiles script had to work around in yabai.
	@Test func stackGrowsPastTwo() {
		let tree = tree(1, 2, 3, 4)
		tree.stack(2, onto: 1)
		tree.stack(3, onto: 1)

		#expect(tree.stackCount(of: 1) == 3)
		#expect(tree.visibleWindows == [3, 4])
	}

	@Test func cyclingWrapsAround() {
		let tree = tree(1, 2)
		tree.stack(2, onto: 1)

		#expect(tree.cycleStack(of: 1, by: 1) == 1)
		#expect(tree.cycleStack(of: 1, by: 1) == 2)
		#expect(tree.cycleStack(of: 1, by: -1) == 1)
	}

	@Test func unstackGivesTheWindowItsOwnLeaf() {
		let tree = tree(1, 2)
		tree.stack(2, onto: 1)
		#expect(tree.unstack(2, in: area, gap: 0))

		#expect(tree.stackIndex(of: 2) == 0)
		#expect(Set(tree.visibleWindows) == [1, 2])
	}

	@Test func removingTheFrontWindowShowsAnotherOne() {
		let tree = tree(1, 2, 3)
		tree.stack(2, onto: 1)
		tree.stack(3, onto: 1)
		tree.remove(3)

		#expect(tree.visibleWindows == [2])
	}

	@Test func activateBringsAStackedWindowForward() {
		let tree = tree(1, 2)
		tree.stack(2, onto: 1)
		tree.activate(1)
		#expect(tree.visibleWindows == [1])
	}
}

struct BSPTreePermuteTests {
	@Test func movesAStackWhole() {
		// Two Slack windows stacked on the left, Code on the right; Code goes first.
		let tree = tree(1, 3)
		tree.insert(2, near: nil, in: area, gap: 0)
		tree.stack(2, onto: 1)
		#expect(tree.leaves.map(\.windows) == [[1, 2], [3]])

		tree.permuteLeaves([1, 0])
		#expect(tree.leaves.map(\.windows) == [[3], [1, 2]])
		#expect(tree.visibleWindows == [3, 2])
		#expect(tree.stackIndex(of: 1) == 1)
		let frames = tree.frames(in: area, gap: 0)
		#expect(frames[3] == rect(0, 0, 500, 600))
		#expect(frames[2] == rect(500, 0, 500, 600))
	}

	@Test func takesAnyOrderAndKeepsTheSplits() {
		let tree = tree(1, 2, 3, 4)
		let before = tree.frames(in: area, gap: 0)
		tree.permuteLeaves([2, 3, 0, 1])
		#expect(tree.visibleWindows == [3, 4, 1, 2])
		let after = tree.frames(in: area, gap: 0)
		#expect(after[3] == before[1])
		#expect(after[1] == before[3])
		tree.remove(1)
		#expect(!tree.contains(1))
		#expect(tree.visibleWindows == [3, 4, 2])
	}

	@Test func ignoresAnOrderThatIsNotAPermutation() {
		let tree = tree(1, 2)
		tree.permuteLeaves([0, 0])
		#expect(tree.visibleWindows == [1, 2])
	}
}

struct BSPTreeCollapseTests {
	@Test func putsEveryWindowInOneStackOverTheArea() {
		let tree = tree(1, 2, 3)
		tree.stack(3, onto: 2)
		tree.collapse(active: 2)
		#expect(tree.leaves.map(\.windows) == [[1, 2, 3]])
		#expect(tree.visibleWindows == [2])
		#expect(tree.frames(in: area, gap: 0) == [1: area, 2: area, 3: area])
	}

	@Test func keepsWorkingAsAStackAfterwards() {
		let tree = tree(1, 2)
		tree.collapse(active: nil)
		#expect(tree.visibleWindows == [1])
		tree.remove(1)
		#expect(tree.visibleWindows == [2])
		tree.insert(3, near: nil, in: area, gap: 0)
		tree.stack(3, onto: 2)
		#expect(tree.leaves.map(\.windows) == [[2, 3]])
	}
}
