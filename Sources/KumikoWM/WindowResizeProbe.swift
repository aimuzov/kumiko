import CoreGraphics
import KumikoCore

enum WindowResizeProbe {
	static func measure(
		read: () -> CGSize?, write: (CGSize) -> Bool, cancelled: () -> Bool = { false },
		restoreAllowed: () -> Bool = { true }
	) -> WindowResizeAxes? {
		guard !cancelled(), let original = read(), original.width > 0, original.height > 0 else { return nil }
		defer { if restoreAllowed() { _ = write(original) } }

		func axis(_ key: WritableKeyPath<CGSize, CGFloat>) -> Bool? {
			var rejected = false
			for delta: CGFloat in [1, -1, 64, -64] {
				guard !cancelled() else { return nil }
				var requested = original
				requested[keyPath: key] = max(1, requested[keyPath: key] + delta)
				// At a display edge an app can reject growth while still allowing shrinkage.
				if !write(requested) {
					guard !cancelled(), read() == original else { return nil }
					rejected = true
					continue
				}
				guard !cancelled(), let actual = read() else { return nil }
				let changed = abs(actual[keyPath: key] - original[keyPath: key]) > 0.5
				guard !cancelled(), restoreAllowed(), write(original), let restored = read(),
				      abs(restored.width - original.width) < 1, abs(restored.height - original.height) < 1
				else { return nil }
				if changed { return true }
			}
			return rejected ? nil : false
		}

		guard let width = axis(\.width), let height = axis(\.height) else { return nil }
		return WindowResizeAxes(width: width, height: height)
	}
}
