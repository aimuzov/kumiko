import CoreGraphics

/// Which of an app's windows are native tabs behind another, and which tab took whose place.
///
/// Each native tab is a window of its own, but the app lists only the tab in front among its
/// windows; the ones behind stay alive off screen. So a window kumiko knows that the app no longer
/// lists, while it shows a tab bar, is a tab gone behind. A switch is one tab going behind and
/// another coming in front at once: the new one takes the old one's place.
enum NativeTabs {
	/// The tab in front before, and the one in front now.
	struct Replacement: Equatable {
		var old: UInt32
		var new: UInt32
	}

	struct Changes: Equatable {
		/// Each window whose state changed, and whether it is a tab behind now.
		var background: [UInt32: Bool] = [:]
		var replaced: [Replacement] = []
	}

	/// - Parameters:
	///   - windows: the app's windows kumiko tracks, and whether each was a tab behind.
	///   - listed: the windows the app lists now.
	///   - showsTabs: whether one of them has a tab bar with more than one tab.
	///   - appeared: a window just seen, which may be a new tab taking the place of the one in front.
	///   - gone: a window just closed; a tab in front that closes hands its place over too.
	static func changes(
		windows: [UInt32: Bool], listed: Set<UInt32>, showsTabs: Bool, appeared: UInt32? = nil, gone: UInt32? = nil
	) -> Changes {
		var changes = Changes()
		var behind: [UInt32] = []
		var inFront: [UInt32] = []

		for (id, wasBehind) in windows.sorted(by: { $0.key < $1.key }) {
			if id == gone {
				if !wasBehind { behind.append(id) }
				continue
			}

			let isBehind = showsTabs && !listed.contains(id)
			// New to kumiko, it counts as having come from behind: it takes a place, not a new one.
			let cameForward = (wasBehind || id == appeared) && !isBehind

			if isBehind != wasBehind { changes.background[id] = isBehind }
			if isBehind && !wasBehind { behind.append(id) }
			if cameForward { inFront.append(id) }
		}

		changes.replaced = zip(behind, inFront).map(Replacement.init)
		return changes
	}
}
