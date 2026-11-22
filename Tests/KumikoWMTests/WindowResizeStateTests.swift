import CoreGraphics
import Foundation
import KumikoCore
@testable import KumikoWM
import Testing

struct WindowResizeStateTests {
	private let size = CGSize(width: 700, height: 500)

	@Test func newlyResizableWindowIsCheckedAgain() {
		var state = WindowResizeState()
		state.update(settable: false, title: "Main", identifier: nil, previous: nil, size: size)
		#expect(state.axes == WindowResizeAxes(width: false, height: false))
		state.update(settable: true, title: "Main", identifier: nil, previous: size, size: size)
		#expect(state.axes == nil)
	}

	@Test func missingAXAnswerPreservesTheMeasurement() {
		var state = WindowResizeState()
		state.update(settable: true, title: "Main", identifier: nil, previous: nil, size: size)
		state.axes = WindowResizeAxes(width: false, height: true)
		state.update(settable: nil, title: "Main", identifier: nil, previous: size, size: size)
		#expect(state.axes == WindowResizeAxes(width: false, height: true))
	}

	@Test func changingWindowModeInvalidatesTheMeasurement() {
		var state = WindowResizeState()
		state.update(settable: true, title: "Main", identifier: "main", previous: nil, size: size)
		state.axes = WindowResizeAxes(width: false, height: true)
		state.update(settable: true, title: "Main", identifier: "preferences", previous: size, size: size)
		#expect(state.axes == nil)
	}

	@Test func observedResizeUpdatesTheAxis() {
		var state = WindowResizeState()
		state.update(settable: true, title: "Main", identifier: nil, previous: nil, size: size)
		state.axes = WindowResizeAxes(width: false, height: true)
		state.update(settable: true, title: "Main", identifier: nil, previous: size, size: CGSize(width: 750, height: 500))
		#expect(state.axes == WindowResizeAxes(width: true, height: true))
	}

	@Test func observedResizeResolvesAnInconclusiveProbe() {
		var state = WindowResizeState()
		let wider = CGSize(width: 800, height: 500)
		let taller = CGSize(width: 800, height: 600)
		state.update(settable: true, title: "Dia", identifier: nil, previous: nil, size: size)
		state.record(nil, baseline: size)
		state.update(settable: true, title: "Dia", identifier: nil, previous: size, size: size)
		state.update(settable: true, title: "Dia", identifier: nil, previous: size, size: wider)
		#expect(state.axes == nil)
		state.update(settable: true, title: "Dia", identifier: nil, previous: wider, size: taller)
		#expect(state.axes == WindowResizeAxes(width: true, height: true))
	}

	@Test func failedProbeCannotSupplyEvidenceForAManualResize() {
		var state = WindowResizeState()
		let wider = CGSize(width: 800, height: 500)
		state.record(nil, baseline: size)
		state.update(settable: true, title: "Dia", identifier: nil, previous: size, size: wider)
		state.update(settable: true, title: "Dia", identifier: nil, previous: wider, size: CGSize(width: 800, height: 600))
		#expect(state.axes == nil)
	}

	@Test func rejectedLayoutSizeTriggersOneRecheck() {
		var state = WindowResizeState()
		state.axes = WindowResizeAxes(width: true, height: true)
		let requested = CGSize(width: 900, height: 600)
		let recheck = state.rejected(requested, actual: size)
		#expect(recheck)
		#expect(state.needsCheck)
		#expect(state.axes == WindowResizeAxes(width: true, height: true))
		state.record(WindowResizeAxes(width: true, height: true))
		let repeated = state.rejected(requested, actual: size)
		#expect(!repeated)
	}

	@Test func acceptedLayoutSizeKeepsTheMeasurement() {
		var state = WindowResizeState()
		state.axes = WindowResizeAxes(width: true, height: true)
		let recheck = state.rejected(size, actual: size)
		#expect(!recheck)
		#expect(state.axes == WindowResizeAxes(width: true, height: true))
	}

	@Test func ordinaryTitleChangesKeepTheLayout() {
		var state = WindowResizeState()
		state.update(settable: true, title: "First page", identifier: nil, previous: nil, size: size)
		state.record(WindowResizeAxes(width: true, height: true))
		state.update(settable: true, title: "Second page", identifier: nil, previous: size, size: size)
		#expect(state.axes == WindowResizeAxes(width: true, height: true))
		#expect(!state.needsCheck)
	}

	@Test func failedRecheckKeepsTheKnownAxes() {
		var state = WindowResizeState()
		state.record(WindowResizeAxes(width: true, height: true))
		let recheck = state.rejected(CGSize(width: 900, height: 600), actual: size)
		#expect(recheck)
		state.record(nil)
		#expect(state.axes == WindowResizeAxes(width: true, height: true))
		#expect(state.needsCheck)
	}

	@Test func repeatedRejectionEventuallyChecksForNewConstraints() {
		var state = WindowResizeState()
		let now = Date(timeIntervalSince1970: 1000)
		state.record(WindowResizeAxes(width: true, height: true))
		let requested = CGSize(width: 900, height: 600)
		let first = state.rejected(requested, actual: size, at: now)
		#expect(first)
		state.record(WindowResizeAxes(width: true, height: true), at: now)
		let immediate = state.rejected(requested, actual: size, at: now.addingTimeInterval(1))
		#expect(!immediate)
		state.update(settable: true, title: "Main", identifier: nil, previous: size, size: size, at: now.addingTimeInterval(31))
		#expect(state.needsCheck)
	}

	@Test func measuredBaselineDoesNotPromoteAFixedAxis() {
		var state = WindowResizeState()
		let measured = CGSize(width: 800, height: 500)
		state.record(WindowResizeAxes(width: false, height: true), baseline: measured)
		state.update(settable: true, title: "Main", identifier: nil, previous: size, size: measured)
		#expect(state.axes == WindowResizeAxes(width: false, height: true))
	}
}
