import CoreGraphics
import Foundation
import KumikoCore

struct WindowResizeState {
	var axes: WindowResizeAxes?
	private(set) var needsCheck = false
	private var settable: Bool?
	private var title: String?
	private var identifier: String?
	private var rejectedSize: CGSize?
	private var recheckAfter = Date.distantFuture
	private var measuredBaseline: CGSize?
	private var observed = WindowResizeAxes(width: false, height: false)
	private var skipProbeFrame = false

	mutating func rejected(_ requested: CGSize, actual: CGSize, at now: Date = Date()) -> Bool {
		guard axes?.isResizable == true, requested != rejectedSize || now >= recheckAfter,
		      abs(requested.width - actual.width) > 1 || abs(requested.height - actual.height) > 1
		else { return false }
		rejectedSize = requested
		recheckAfter = now.addingTimeInterval(30)
		needsCheck = true
		return true
	}

	mutating func record(_ measured: WindowResizeAxes?, baseline: CGSize? = nil, at now: Date = Date()) {
		skipProbeFrame = measured == nil && baseline != nil
		if let measured {
			axes = measured
			needsCheck = false
			measuredBaseline = baseline
			if rejectedSize != nil { recheckAfter = now.addingTimeInterval(30) }
		}
	}

	mutating func update(
		settable current: Bool?, title: String, identifier: String?, previous: CGSize?, size: CGSize, at now: Date = Date()
	) {
		let previous = measuredBaseline ?? previous
		measuredBaseline = nil
		if axes?.isResizable == true, rejectedSize != nil, now >= recheckAfter { needsCheck = true }
		let capabilityChanged = current != nil && settable != nil && current != settable
		let modeChanged = axes?.isResizable != true && self.title != nil && (self.title != title || self.identifier != identifier)
		if capabilityChanged || modeChanged {
			axes = nil
			observed = WindowResizeAxes(width: false, height: false)
			rejectedSize = nil
		}
		self.title = title
		self.identifier = identifier
		if let current { settable = current }
		if current == false {
			axes = WindowResizeAxes(width: false, height: false)
		} else if !capabilityChanged, !modeChanged, !skipProbeFrame, let previous {
			// Until both axes have moved, the untouched one could still be fixed.
			var measured = axes ?? observed
			if abs(size.width - previous.width) > 0.5 { measured.width = true }
			if abs(size.height - previous.height) > 0.5 { measured.height = true }
			observed = measured
			if axes != nil || measured.isResizable { axes = measured }
		}
		skipProbeFrame = false
	}
}
