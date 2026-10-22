import AppKit
import KumikoCore
import SwiftUI

/// One bar, drawn the way the macOS menu bar draws its extras: text and SF Symbols straight on the
/// desktop picture, no boxes and no shadows, in the menu bar's font. The only shape is the glass
/// capsule around the workspace on screen, the way the menu bar marks an open menu.
///
/// Items from `left` run from the left edge inward, items from `right` from the right edge inward.
struct BarView: View {
	let model: BarModel
	/// The display this bar sits on; it shows that display's workspaces.
	let display: UInt32

	var body: some View {
		let config = model.config

		HStack(spacing: 14) {
			ForEach(config.left, id: \.self) { item(named: $0) }
			Spacer(minLength: 0)
			ForEach(config.right.reversed(), id: \.self) { item(named: $0) }
		}
		.padding(.horizontal, config.padding + 6)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color(config.colors.background))
		.font(Font(BarFont.text(config)))
		.foregroundStyle(config.colors.text.map(Color.init) ?? Color(nsColor: .labelColor))
		.symbolRenderingMode(.monochrome)
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

/// The capsule of a selected menu bar item: Liquid Glass on macOS 26, a translucent fill before.
private struct Highlight: ViewModifier {
	let isOn: Bool
	let tint: KumikoCore.Color

	func body(content: Content) -> some View {
		let padded = content.padding(.horizontal, 8).frame(height: 24)

		if !isOn {
			padded
		} else if #available(macOS 26, *) {
			padded.glassEffect(.regular, in: .capsule)
		} else {
			padded.background(Capsule().fill(Color(tint)))
		}
	}
}

private struct WorkspacesItem: View {
	let model: BarModel
	let display: UInt32

	var body: some View {
		let colors = model.config.colors
		// Empty workspaces only take room when they are the one on screen.
		let shown = model.workspaces.filter { $0.display == display && ($0.isVisible || !$0.apps.isEmpty) }

		HStack(spacing: 2) {
			ForEach(shown) { workspace in
				// The workspace on screen in the text colour with its icons in colour; the others grey,
				// their icons in greyscale.
				HStack(spacing: 5) {
					Text("\(workspace.index)").monospacedDigit()

					if workspace.apps.isEmpty {
						Text(workspace.name)
					} else {
						AppIcons(apps: workspace.apps)
							.grayscale(workspace.isVisible ? 0 : 1)
							.opacity(workspace.isVisible ? 1 : 0.7)
					}
				}
				.foregroundStyle(workspace.isVisible ? .primary : .secondary)
				.modifier(Highlight(isOn: workspace.isVisible, tint: colors.active))
				.contentShape(Capsule())
				.onTapGesture { model.focusWorkspace(workspace.name) }
			}
		}
	}
}

/// The apps' own icons, small, the way the menu bar shows app icons.
private struct AppIcons: View {
	let apps: [BarModel.App]

	var body: some View {
		HStack(spacing: 3) {
			ForEach(apps) { app in
				if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
					Image(nsImage: icon)
						.resizable()
						.aspectRatio(contentMode: .fit)
						.frame(width: 15, height: 15)
				}
			}
		}
	}
}

/// The hotkey mode, as its symbol and name in the mode's colour; nothing in the default mode.
private struct ModeItem: View {
	let model: BarModel

	private static let symbols = [
		"window": "macwindow", "resize": "arrow.up.left.and.arrow.down.right",
		"move": "arrow.up.and.down.and.arrow.left.and.right", "stack": "square.stack", "command": "command",
	]

	var body: some View {
		let colors = model.config.colors
		let tints = [
			"window": colors.yellow, "resize": colors.orange, "move": colors.green, "stack": colors.magenta,
			"command": colors.red,
		]

		if model.mode != "default" {
			Label(model.mode, systemImage: Self.symbols[model.mode] ?? "keyboard")
				.modifier(Tint(color: tints[model.mode] ?? colors.grey))
		}
	}
}

/// A palette colour that reads on the bar's tone. The palette is pastel, made for a dark bar; on
/// a light one each colour goes darker and stronger.
private struct Tint: ViewModifier {
	let color: KumikoCore.Color
	@Environment(\.colorScheme) private var scheme

	func body(content: Content) -> some View {
		content.foregroundStyle(scheme == .dark ? Color(color) : Self.onLight(color))
	}

	private static func onLight(_ color: KumikoCore.Color) -> SwiftUI.Color {
		let base = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
		var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
		base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

		return Color(hue: hue, saturation: min(1, saturation + 0.35), brightness: brightness * 0.6, opacity: alpha)
	}
}

/// How the focused window sits in the layout, when it is anything but a plain tile.
private struct WindowItem: View {
	let model: BarModel

	var body: some View {
		let colors = model.config.colors

		switch model.window {
		case .none:
			EmptyView()
		case .floating:
			Image(systemName: "macwindow.on.rectangle").foregroundStyle(Color(colors.red))
		case .fullscreenZoom:
			Image(systemName: "arrow.up.left.and.arrow.down.right").foregroundStyle(Color(colors.green))
		case .parentZoom:
			Image(systemName: "rectangle.inset.filled").foregroundStyle(Color(colors.blue))
		case let .stacked(index, count):
			Label("\(index)/\(count)", systemImage: "square.stack").foregroundStyle(Color(colors.magenta))
		}
	}
}

/// The date and the time, the way the menu bar clock shows them.
private struct DateTimeItem: View {
	let model: BarModel

	private static let formatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "EEE d MMM  HH:mm"
		return formatter
	}()

	var body: some View {
		Text(Self.formatter.string(from: model.now)).monospacedDigit()
	}
}

/// A mug, filled while the Mac is kept awake: on and off the way menu bar extras show them, by fill
/// rather than by colour.
private struct CaffeinateItem: View {
	let model: BarModel

	var body: some View {
		Image(systemName: model.isCaffeinated ? "mug.fill" : "mug")
			.contentShape(Rectangle())
			.onTapGesture { model.toggleCaffeine() }
	}
}

/// The battery the way the menu bar's own battery item shows it, without the percentage.
private struct BatteryItem: View {
	let model: BarModel

	var body: some View {
		if let battery = model.battery {
			BatteryGlyph(battery: battery)
		}
	}
}

/// The battery as Control Center draws it, from its own images: the outline and its cap, a fill
/// as wide as the charge, and a bolt on the charger or a plug when charging is on hold, cut into
/// the battery under it. The fill is yellow in Low Power Mode and red when the charge runs low.
private struct BatteryGlyph: View {
	let battery: Battery.State

	// Points, after the images: a 23 by 12 outline, the fill inset 2 from its edges.
	private static let body = CGSize(width: 23, height: 12)
	private static let fill = CGRect(x: 2, y: 2, width: 19, height: 8)

	var body: some View {
		ZStack(alignment: .topLeading) {
			BatteryImages.piece(BatteryImages.outline, size: Self.body) {
				RoundedRectangle(cornerRadius: 3.5).strokeBorder(lineWidth: 1)
			}
			BatteryImages.piece(BatteryImages.cap, size: CGSize(width: 2, height: 12)) {
				Capsule().frame(width: 1.5, height: 4).frame(maxWidth: .infinity, alignment: .trailing)
			}
			.offset(x: Self.body.width)

			RoundedRectangle(cornerRadius: 1.5, style: .continuous)
				.fill(fillColor)
				.frame(width: fillWidth, height: Self.fill.height)
				.offset(x: Self.fill.minX, y: Self.fill.minY)

			if let mark {
				// The mask is a little larger than the mark, so a gap is left around it.
				BatteryImages.piece(mark.mask, size: markSize) { EmptyView() }
					.offset(markOffset)
					.blendMode(.destinationOut)
			}
		}
		.compositingGroup()
		.overlay(alignment: .topLeading) {
			if let mark {
				BatteryImages.piece(mark.glyph, size: markSize) {
					Image(systemName: battery.isCharging ? "bolt.fill" : "powerplug.fill").font(.system(size: 9))
				}
				.offset(markOffset)
			}
		}
		.frame(width: Self.body.width + 2, height: Self.body.height, alignment: .topLeading)
	}

	/// As wide as the charge in whole points, the way Control Center rounds it: 51% and 54% both
	/// fill 10 of 19.
	private var fillWidth: CGFloat {
		guard battery.percent > 0 else { return 0 }
		return max((Self.fill.width * CGFloat(battery.percent) / 100).rounded(), 2)
	}

	private var fillColor: AnyShapeStyle {
		if battery.isLowPowerMode { return AnyShapeStyle(SwiftUI.Color(nsColor: .systemYellow)) }
		if !battery.isPluggedIn, battery.percent <= 20 { return AnyShapeStyle(SwiftUI.Color(nsColor: .systemRed)) }
		return AnyShapeStyle(.foreground)
	}

	private var mark: (glyph: NSImage?, mask: NSImage?)? {
		if battery.isCharging { return (BatteryImages.bolt, BatteryImages.boltMask) }
		if battery.isPluggedIn { return (BatteryImages.plug, BatteryImages.plugMask) }
		return nil
	}

	// The bolt and the plug are 11 by 14, centred on the outline and a point over its top and bottom.
	private let markSize = CGSize(width: 11, height: 14)
	private var markOffset: CGSize {
		CGSize(width: (Self.body.width - markSize.width) / 2, height: (Self.body.height - markSize.height) / 2)
	}
}

/// Control Center's battery images, from its asset catalog. Each has a drawn stand-in, should a
/// macOS update rename or drop it.
@MainActor
private enum BatteryImages {
	private static let bundle = Bundle(path: "/System/Library/CoreServices/ControlCenter.app")

	static let outline = image("battery-outline")
	static let cap = image("battery-cap")
	static let bolt = image("battery-bolt")
	static let boltMask = image("battery-bolt-mask")
	static let plug = image("battery-plug")
	static let plugMask = image("battery-plug-mask")

	private static func image(_ name: String) -> NSImage? {
		bundle?.image(forResource: name)
	}

	/// The image at its size, tinted like a symbol when it is a template, or the stand-in.
	@ViewBuilder
	static func piece(_ image: NSImage?, size: CGSize, @ViewBuilder standIn: () -> some View) -> some View {
		Group {
			if let image {
				Image(nsImage: image).renderingMode(image.isTemplate ? .template : .original).resizable()
			} else {
				standIn()
			}
		}
		.frame(width: size.width, height: size.height)
	}
}

/// The input source the way the menu bar's own input menu shows it, and before it, in a text
/// field with Vim on, the Vim mode the way the hotkey modes show: symbol and name in the mode's
/// colour. Insert mode is plain typing and shows nothing, like the default hotkey mode.
private struct InputItem: View {
	let model: BarModel

	var body: some View {
		HStack(spacing: 14) {
			vimMode
			layout
		}
	}

	@ViewBuilder
	private var vimMode: some View {
		let colors = model.config.colors

		switch model.vimMode {
		case "N", "_":
			Label("normal", systemImage: "character.cursor.ibeam").modifier(Tint(color: colors.blue))
		case "V":
			Label("visual", systemImage: "selection.pin.in.out").modifier(Tint(color: colors.magenta))
		case "C":
			Label(":" + (model.vimCommandLine ?? ""), systemImage: "chevron.right").modifier(Tint(color: colors.orange))
		default:
			EmptyView()
		}
	}

	/// The system's badge, unless the config gives the source a text of its own; then that text,
	/// drawn in a frame like the badge.
	@ViewBuilder
	private var layout: some View {
		if let text = model.inputSource.flatMap({ model.config.input[$0] }) {
			framed(text)
		} else if model.inputSource != nil, let badge = InputSource.badge() {
			Image(nsImage: badge).renderingMode(.template)
		} else if let language = model.inputLanguage {
			framed(language)
		}
	}

	private func framed(_ text: String) -> some View {
		Text(text)
			.font(Font(BarFont.text(model.config, scale: 11 / 13)).weight(.medium))
			.padding(.horizontal, 4)
			.frame(minHeight: 16)
			.overlay(RoundedRectangle(cornerRadius: 4).stroke(.primary, lineWidth: 1.2))
	}
}

private struct ShellItemView: View {
	let model: BarModel
	let name: String

	var body: some View {
		if let text = model.shell[name], !text.isEmpty {
			Text(text)
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
	/// `scale` sizes a smaller label (the input source code) against the bar's text.
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
