import AppKit
import Carbon
import IOKit.ps
import KumikoCore
import SwiftUI

/// What the bar's items do not say on their own, shown right above the bar while the pointer is on
/// one, the way the Dock labels its icons. The system tooltip waits a second, and in a panel of an
/// app in the background it may not come at all.
struct Tooltip: Equatable {
	/// The item's key in `BarModel.tooltipTexts`.
	var key: String
	var display: UInt32
	/// The item it is for, in its bar's coordinates.
	var frame: CGRect
}

/// Without `@Entry`, whose macro comes only with Xcode.
private struct BarDisplayKey: EnvironmentKey {
	static let defaultValue: UInt32 = 0
}

extension EnvironmentValues {
	/// The display of the bar a view is drawn in.
	var barDisplay: UInt32 {
		get { self[BarDisplayKey.self] }
		set { self[BarDisplayKey.self] = newValue }
	}
}

/// Shows `text` over the bar while the pointer is on the view. The text is made again each time
/// the label is drawn, so a click on caffeinate changes what it says at once.
struct BarTooltip: ViewModifier {
	let model: BarModel
	let key: String
	/// How far above the bar the label goes besides its own gap.
	let raise: @MainActor () -> Double
	let text: @MainActor () -> String?
	@Environment(\.barDisplay) private var display

	func body(content: Content) -> some View {
		content
			.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.itemFrames[key] = $0 }
			.onHover { over in
				if over, let frame = model.itemFrames[key] {
					model.tooltipTexts[key] = text
					model.tooltipRaises[key] = raise
					model.tooltip = Tooltip(key: key, display: display, frame: frame)
				} else if model.tooltip?.key == key {
					model.tooltip = nil
				}
			}
	}
}

extension View {
	func barTooltip(
		_ model: BarModel, _ key: String, raise: @escaping @MainActor () -> Double = { 0 },
		_ text: @escaping @MainActor () -> String?
	) -> some View {
		modifier(BarTooltip(model: model, key: key, raise: raise, text: text))
	}
}

/// The label itself, drawn by the magnifier's panel, which reaches over the windows above the bar.
struct TooltipBubble: View {
	let model: BarModel
	let tooltip: Tooltip
	/// Where the bar starts in the panel, from its top.
	let lift: Double
	let width: Double

	var body: some View {
		let scale = model.config.scale
		let height = 22 * scale
		let half = model.tooltipWidth / 2
		// Over the item, but kept a few points inside the screen.
		let x = min(max(tooltip.frame.midX, half + 6), width - half - 6)

		if let text = model.tooltipTexts[tooltip.key]?() {
			label(text, x: x, height: height, scale: scale, raise: model.tooltipRaises[tooltip.key]?() ?? 0)
		}
	}

	private func label(_ text: String, x: Double, height: Double, scale: Double, raise: Double) -> some View {
		Text(text)
			.font(.system(size: 12 * scale))
			.lineLimit(1)
			.fixedSize()
			.padding(.horizontal, 9 * scale)
			.frame(height: height)
			.background(.regularMaterial, in: Capsule())
			.overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
			.shadow(color: .black.opacity(0.15), radius: 4, y: 1)
			.onGeometryChange(for: Double.self) { $0.size.width } action: { model.tooltipWidth = $0 }
			.position(x: x, y: lift + tooltip.frame.minY - raise - 6 * scale - height / 2)
			.animation(.easeOut(duration: Magnifier.settle), value: raise)
			.transition(.opacity)
	}
}

/// The texts, one per item.
@MainActor
enum TooltipText {
	static func workspace(_ workspace: BarModel.Workspace) -> String {
		let apps = workspace.apps.map(\.name)
		return ([workspace.name] + (apps.isEmpty ? ["Empty"] : [apps.joined(separator: ", ")])).joined(separator: " · ")
	}

	static func mode(_ mode: String) -> String? {
		mode == "default" ? nil : "Hotkey mode: \(mode)"
	}

	static func window(_ state: BarModel.WindowState) -> String? {
		switch state {
		case .none: nil
		case .floating: "Floating: not in the layout"
		case .fullscreenZoom: "Zoomed to fill the screen"
		case .parentZoom: "Zoomed to its parent"
		case let .stacked(index, count): "Window \(index) of \(count) in the stack"
		}
	}

	private static let date: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "EEEE, d MMMM yyyy · 'week' w"
		return formatter
	}()

	static func dateTime(_ now: Date) -> String {
		date.string(from: now)
	}

	static func caffeinate(isOn: Bool) -> String {
		isOn ? "Keeping the Mac awake · Click to stop" : "Click to keep the Mac awake"
	}

	static func battery(_ battery: Battery.State) -> String {
		var parts = ["\(battery.percent)%"]
		if battery.isLowPowerMode { parts.append("Low Power Mode") }

		let minutes = IOPSGetTimeRemainingEstimate()
		if battery.isCharging, let toFull = Self.minutesToFull() {
			parts.append("Charging, full in \(clock(toFull))")
		} else if battery.isCharging {
			parts.append("Charging")
		} else if battery.isPluggedIn {
			parts.append("Plugged in, charging on hold")
		} else if minutes > 0 {
			parts.append("\(clock(Int(minutes / 60))) left")
		}
		return parts.joined(separator: " · ")
	}

	/// What the battery itself reckons, in minutes; nil while it is still working it out.
	private static func minutesToFull() -> Int? {
		guard
			let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
			let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
		else { return nil }
		for source in list {
			let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
			if let minutes = description?[kIOPSTimeToFullChargeKey] as? Int, minutes > 0 { return minutes }
		}
		return nil
	}

	private static func clock(_ minutes: Int) -> String {
		String(format: "%d:%02d", minutes / 60, minutes % 60)
	}

	static func input(vimMode: String?) -> String? {
		let name = InputSource.localizedName()
		let vim: String? = switch vimMode {
		case "N", "_": "Vim: normal mode"
		case "V": "Vim: visual mode"
		case "C": "Vim: command line"
		default: nil
		}
		let parts = [name, vim].compactMap(\.self)
		return parts.isEmpty ? nil : parts.joined(separator: " · ")
	}

	static func shell(_ name: String, config: Config.Bar) -> String? {
		guard let item = config.shell.first(where: { $0.name == name }) else { return nil }
		return "\(name) · \(item.command)"
	}
}

extension InputSource {
	/// The selected source as the input menu lists it: "Russian – PC", "ABC".
	static func localizedName() -> String? {
		guard
			let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
			let pointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName)
		else { return nil }

		return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
	}
}
