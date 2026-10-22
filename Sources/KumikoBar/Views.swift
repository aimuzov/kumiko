import AppKit
import KumikoCore
import SwiftUI

/// One bar: items from `left` from the left edge inward, items from `right` from the right edge
/// inward, sized and styled like the sketchybar setup it replaces.
struct BarView: View {
	@Environment(\.colorScheme) private var scheme
	let model: BarModel
	/// The display this bar sits on; it shows that display's workspaces.
	let display: UInt32

	var body: some View {
		let config = model.config

		HStack(spacing: 6) {
			ForEach(config.left, id: \.self) { item(named: $0) }
			Spacer(minLength: 0)
			ForEach(config.right.reversed(), id: \.self) { item(named: $0) }
		}
		// A soft shadow of the opposite tone keeps text readable on a busy or mid-tone picture,
		// the way the menu bar's text is.
		.shadow(color: (scheme == .dark ? Color.black : Color.white).opacity(0.5), radius: 3)
		.padding(.horizontal, config.padding)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color(config.colors.background))
		.font(Font(BarFont.text(config)))
		.foregroundStyle(config.colors.text.map(Color.init) ?? Color(nsColor: .labelColor))
	}

	@ViewBuilder
	private func item(named name: String) -> some View {
		switch name {
		case "workspaces": WorkspacesItem(model: model, display: display)
		case "mode": ModeItem(model: model)
		case "window": WindowItem(model: model)
		case "datetime": DateTimeItem(model: model)
		case "caffeinate": CaffeinateItem(model: model)
		case "battery": BatteryItem(model: model)
		case "input": InputItem(model: model)
		default: ShellItemView(model: model, name: name)
		}
	}
}

/// The rounded box every item sits in: 26 points high, fully rounded.
private struct Pill<Content: View>: View {
	var color: KumikoCore.Color?
	@ViewBuilder var content: Content

	var body: some View {
		content
			.padding(.horizontal, 3)
			.frame(height: 26)
			.background(
				RoundedRectangle(cornerRadius: 16)
					.fill(color.map(SwiftUI.Color.init) ?? .clear)
			)
	}
}

/// Number glyphs of SF Pro for workspace 1 to 16, as the sketchybar item drew them.
private let numberGlyphs = [
	"􀀻", "􀀽", "􀀿", "􀁁", "􀁃", "􀁅", "􀁇", "􀁉", "􀁋", "􀔔", "􀔕", "􀔖", "􀔗", "􀔘", "􀔙", "􀔚",
]

private struct WorkspacesItem: View {
	let model: BarModel
	let display: UInt32

	var body: some View {
		let config = model.config

		ForEach(model.workspaces.filter { $0.display == display }) { workspace in
			Pill(color: workspace.isVisible ? config.colors.active : nil) {
				HStack(spacing: 3) {
					Text(workspace.index <= numberGlyphs.count ? numberGlyphs[workspace.index - 1] : "\(workspace.index)")

					if workspace.apps.isEmpty {
						// An empty workspace says what it is for instead of showing nothing.
						Text(workspace.name)
					} else {
						AppIcons(apps: workspace.apps)
					}
				}
				.padding(.horizontal, 3)
			}
			.contentShape(Rectangle())
			.onTapGesture { model.focusWorkspace(workspace.name) }
		}
	}
}

/// The apps' own icons, in colour.
private struct AppIcons: View {
	let apps: [BarModel.App]

	var body: some View {
		HStack(spacing: 4) {
			ForEach(apps) { app in
				if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
					Image(nsImage: icon)
						.resizable()
						.aspectRatio(contentMode: .fit)
						.frame(width: 16, height: 16)
				}
			}
		}
	}
}

private struct ModeItem: View {
	let model: BarModel

	private static let glyphs = ["window": "􀏜", "resize": "􀄭", "move": "􀭱", "stack": "􃑷", "command": "􀆔"]

	var body: some View {
		let colors = model.config.colors
		let tints = [
			"window": colors.yellow, "resize": colors.orange, "move": colors.green, "stack": colors.magenta,
			"command": colors.red,
		]

		if let glyph = Self.glyphs[model.mode] {
			Pill(color: tints[model.mode] ?? colors.grey) {
				Text(glyph).foregroundStyle(Color(colors.black)).frame(width: 38)
			}
		}
	}
}

private struct WindowItem: View {
	let model: BarModel

	var body: some View {
		let colors = model.config.colors

		switch model.window {
		case .none:
			EmptyView()
		case .floating:
			Pill { Text("􀢌").foregroundStyle(Color(colors.red)).frame(width: 24) }
		case .fullscreenZoom:
			Pill { Text("􀏜").foregroundStyle(Color(colors.green)).frame(width: 24) }
		case .parentZoom:
			Pill { Text("􀥃").foregroundStyle(Color(colors.blue)).frame(width: 24) }
		case let .stacked(index, count):
			Pill {
				HStack(spacing: 3) {
					Text("􃑷").foregroundStyle(Color(colors.magenta))
					Text("\(index) / \(count)")
				}
			}
		}
	}
}

private struct DateTimeItem: View {
	let model: BarModel

	private static let date = formatter("EEE dd MMM")
	private static let time = formatter("HH:mm")

	private static func formatter(_ format: String) -> DateFormatter {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = format
		return formatter
	}

	var body: some View {
		Pill {
			HStack(spacing: 6) {
				Text(Self.date.string(from: model.now))
				Text(Self.time.string(from: model.now))
			}
			.padding(.horizontal, 3)
		}
	}
}

private struct CaffeinateItem: View {
	let model: BarModel

	var body: some View {
		let colors = model.config.colors

		Pill {
			Text(model.isCaffeinated ? "􀆼" : "􀆻")
				.font(Font(BarFont.text(model.config, scale: 16 / 14)))
				.foregroundStyle(Color(model.isCaffeinated ? colors.yellow : colors.white))
				.padding(.horizontal, 3)
		}
		.contentShape(Rectangle())
		.onTapGesture { model.toggleCaffeine() }
	}
}

private struct BatteryItem: View {
	let model: BarModel

	var body: some View {
		let colors = model.config.colors

		if let battery = model.battery {
			let (glyph, tint): (String, KumikoCore.Color) = switch battery.percent {
			case _ where battery.isCharging: ("􀢋", colors.white)
			case 81...: ("􀛨", colors.white)
			case 61...: ("􀺸", colors.white)
			case 41...: ("􀺶", colors.yellow)
			case 21...: ("􀛩", colors.orange)
			default: ("􀛪", colors.red)
			}

			Pill {
				HStack(spacing: 6) {
					Text(glyph).foregroundStyle(Color(tint))
					Text("\(battery.percent)%")
				}
				.padding(.horizontal, 3)
			}
		}
	}
}

/// The keyboard layout, and in a text field with Vim on, the Vim mode as a coloured badge with the
/// command being typed after it, as the sketchybar input item showed SketchyVim's.
private struct InputItem: View {
	let model: BarModel

	private static let vimGlyphs = ["N": "􀀞", "I": "􀀔", "V": "􀀮", "C": "􀀈", "_": "􀍷"]

	var body: some View {
		let colors = model.config.colors
		let layout = model.inputSource.flatMap { model.config.input[$0] } ?? "􀁝"
		let tints = ["N": colors.blue, "I": colors.green, "V": colors.magenta, "C": colors.orange, "_": colors.magenta]
		let font = Font(BarFont.text(model.config, scale: 17 / 14))

		if let mode = model.vimMode, let glyph = Self.vimGlyphs[mode] {
			Pill(color: tints[mode] ?? colors.grey) {
				HStack(spacing: 3) {
					Text(glyph)
					Text(layout)
					if mode == "C", let command = model.vimCommandLine {
						Text(Self.vimGlyphs["C"]!)
						Text(command).font(Font(BarFont.text(model.config)))
					}
				}
				.font(font)
				.foregroundStyle(Color(colors.black))
				.shadow(radius: 0)
				.padding(.horizontal, 3)
			}
		} else {
			Pill {
				Text(layout).font(font).padding(.horizontal, 3)
			}
		}
	}
}

private struct ShellItemView: View {
	let model: BarModel
	let name: String

	var body: some View {
		if let text = model.shell[name], !text.isEmpty {
			Pill { Text(text).padding(.horizontal, 3) }
		}
	}
}

extension SwiftUI.Color {
	init(_ color: KumikoCore.Color) {
		self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
	}
}

/// The bar's font: the menu bar's own unless the config names another.
enum BarFont {
	/// `scale` sizes the few glyph-only items (caffeinate, input) the way the sketchybar items
	/// sized them against a 14-point label.
	@MainActor
	static func text(_ config: Config.Bar, scale: Double = 1) -> NSFont {
		let base = NSFont.menuBarFont(ofSize: config.fontSize)
		let size = base.pointSize * scale

		if !config.font.isEmpty, let font = NSFont(name: config.font, size: size) {
			return font
		}

		return NSFont.menuBarFont(ofSize: size)
	}
}
