import CoreFoundation
import Foundation
import KumikoCore

/// The Dock's magnification for a row of icons: how much each one grows and where it moves, from
/// where the pointer is along the row as it is laid out unmagnified.
///
/// The row's layout never changes, so nothing around it moves; the icons spread out to both sides
/// of the pointer instead, and the point under the pointer stays under it, so a click still lands on
/// the icon that looks to be there.
struct Magnifier {
	/// An icon's size and the space between two, unmagnified.
	let size: Double
	let spacing: Double
	/// The size of an icon right under the pointer.
	let largest: Double

	/// Scale and horizontal shift of each of `count` icons, with the pointer at `x` from the row's
	/// leading edge.
	func layout(count: Int, pointer x: Double) -> [(scale: Double, offset: Double)] {
		guard count > 0 else { return [] }

		let slot = size + spacing
		// How far from the pointer icons still grow: about as far as the Dock's do, two and a half
		// icons to each side.
		let reach = slot * 2.5

		let scales = (0..<count).map { index in
			let distance = abs(x - (Double(index) * slot + size / 2))
			guard distance < reach else { return 1.0 }
			let falloff = cos(distance / reach * .pi / 2)
			return 1 + (largest / size - 1) * falloff * falloff
		}
		let widths = scales.map { $0 * size + spacing }

		let pointer = min(max(x, 0), Double(count) * slot)
		let index = min(Int(pointer / slot), count - 1)
		let fraction = (pointer - Double(index) * slot) / slot
		let shift = pointer - (widths[..<index].reduce(0, +) + fraction * widths[index])

		var leading = 0.0
		return scales.indices.map { index in
			let center = leading + scales[index] * size / 2 + shift
			leading += widths[index]
			return (scales[index], center - (Double(index) * slot + size / 2))
		}
	}

	/// The size an icon of `size` grows to under the pointer, or nil when the bar does not magnify:
	/// turned off, or left to a Dock that does not magnify.
	static func largest(for config: Config.Bar, size: Double) -> Double? {
		let dock = Dock.magnification()

		switch config.magnification {
		case .off: return nil
		case .dock where !dock.isOn: return nil
		case .dock, .on: break
		}

		let wanted = config.magnificationSize > 0 ? config.magnificationSize : size * dock.ratio
		let largest = min(wanted, maximum)
		return largest > size ? largest : nil
	}

	/// The Dock's own largest icon, and as far as the magnifier reaches above the bar.
	static let maximum = 128.0

	/// How long icons take to grow when the pointer comes in and to settle back when it leaves.
	static let settle = 0.12
}

/// What the Dock itself is set to, from its own preferences.
enum Dock {
	/// Whether the Dock magnifies, and by how much: its largest icon against its icon size. Read
	/// afresh each time, so a change in System Settings counts with the next hover.
	static func magnification() -> (isOn: Bool, ratio: Double) {
		let domain = "com.apple.dock" as CFString
		CFPreferencesAppSynchronize(domain)

		func value(_ key: String) -> NSNumber? {
			CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber
		}

		// Dock's own defaults, for keys it has not written yet.
		let tile = value("tilesize")?.doubleValue ?? 64
		let large = value("largesize")?.doubleValue ?? 128
		return (value("magnification")?.boolValue ?? false, max(1, large / max(tile, 1)))
	}
}
