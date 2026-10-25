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

		HStack(spacing: 14 * config.scale) {
			ForEach(model.items(config.left), id: \.self) { item(named: $0) }
			Spacer(minLength: 0)
			ForEach(model.items(config.right).reversed(), id: \.self) { item(named: $0) }
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
/// Under the pointer an item gets a capsule of the system accent colour, faint over one that is
/// not selected and fainter over the selected one, as the frame of the focused window is drawn.
private struct Highlight: ViewModifier {
	let isOn: Bool
	var isHovered = false
	let tint: KumikoCore.Color
	let scale: Double

	func body(content: Content) -> some View {
		let padded = content.padding(.horizontal, 8 * scale).frame(height: 24 * scale)

		Group {
			if !isOn {
				padded.background(accent(0.3))
			} else if #available(macOS 26, *) {
				padded.glassEffect(.regular, in: .capsule).overlay(accent(0.2))
			} else {
				padded.background(Capsule().fill(Color(tint))).overlay(accent(0.2))
			}
		}
		.animation(.easeOut(duration: 0.15), value: isHovered)
	}

	/// The colour System Settings has, picked again whenever it changes there.
	private func accent(_ opacity: Double) -> some View {
		Capsule().fill(Color(nsColor: .controlAccentColor).opacity(isHovered ? opacity : 0)).allowsHitTesting(false)
	}
}

private struct WorkspacesItem: View {
	let model: BarModel
	let display: UInt32

	var body: some View {
		let colors = model.config.colors
		// Empty workspaces only take room when they are the one on screen, and without a number
		// not even then: there would be nothing to draw.
		let shown = model.workspaces.filter {
			$0.display == display && ($0.isVisible || !$0.apps.isEmpty) && (model.showsNumbers || !$0.apps.isEmpty)
		}

		// No view rather than an empty one: the bar's spacing would leave a gap for it.
		if !shown.isEmpty {
			workspaces(shown, colors: colors)
		}
	}

	private func workspaces(_ shown: [BarModel.Workspace], colors: Config.Bar.Palette) -> some View {
		let scale = model.config.scale

		return HStack(spacing: 2 * scale) {
			ForEach(shown) { workspace in
				// The workspace on screen in the text colour with its icons in colour; the others grey,
				// their icons in greyscale.
				HStack(spacing: 5 * scale) {
					if model.showsNumbers {
						Text("\(workspace.index)").monospacedDigit()
					}

					if workspace.apps.isEmpty {
						Text(workspace.name)
					} else {
						AppIcons(model: model, workspace: workspace)
					}
				}
				.foregroundStyle(workspace.isVisible ? .primary : .secondary)
				.modifier(Highlight(
					isOn: workspace.isVisible, isHovered: model.hoveredWorkspace == workspace.name, tint: colors.active,
					scale: scale
				))
				.contentShape(Capsule())
				// The icons follow the pointer on their own too: both hovers see it, neither takes it.
				.onHover { over in
					if over {
						model.hoveredWorkspace = workspace.name
					} else if model.hoveredWorkspace == workspace.name {
						model.hoveredWorkspace = nil
					}
				}
				.onTapGesture { model.focusWorkspace(workspace.name) }
			}
		}
	}
}

/// A workspace's row of app icons as both the bar and the magnifier draw it: the icons, their size,
/// and where each one is and how large it grows for the pointer.
@MainActor
private struct IconRow {
	let workspace: BarModel.Workspace
	let size: Double
	let spacing: Double
	let icons: [(app: BarModel.App, icon: NSImage)]
	let pointer: BarModel.Pointer?
	/// Scale and shift of each icon; nil unless the row magnifies. All at their own size and place
	/// while the pointer is coming in or has just left, so they grow from there and settle back to it.
	let placement: [(scale: Double, offset: Double)]?

	init(model: BarModel, workspace: BarModel.Workspace) {
		self.workspace = workspace
		size = 15 * model.config.scale
		spacing = 3 * model.config.scale
		icons = workspace.apps.compactMap { app in Self.icon(of: app.pid).map { (app: app, icon: $0) } }
		pointer = model.pointer.flatMap { $0.workspace == workspace.name ? $0 : nil }

		let count = icons.count
		placement = pointer.flatMap { [size, spacing] pointer in
			pointer.largest.map { largest in
				pointer.isOver
					? Magnifier(size: size, spacing: spacing, largest: largest).layout(count: count, pointer: pointer.x)
					: Array(repeating: (scale: 1.0, offset: 0.0), count: count)
			}
		}
	}

	/// The icon under the pointer.
	var hovered: Int? {
		pointer.flatMap { $0.isOver ? index(at: $0.x) : nil }
	}

	/// Whether the magnifier draws the icons instead of the bar.
	var isMagnified: Bool { placement != nil }

	func scale(_ index: Int) -> Double { placement?[index].scale ?? 1 }

	/// The centre of an icon from the row's leading edge, where it is drawn now.
	func center(_ index: Int) -> Double {
		Double(index) * (size + spacing) + size / 2 + (placement?[index].offset ?? 0)
	}

	func isMuted(_ index: Int) -> Bool { !workspace.isVisible && hovered != index }

	/// The icon drawn at `x` along the row, with the gap between two split down the middle.
	func index(at x: Double) -> Int? {
		icons.indices.first { abs(x - center($0)) <= (size * scale($0) + spacing) / 2 }
	}

	/// One image per app for as long as it runs. `NSRunningApplication.icon` makes a new one each
	/// time, and a new image is drawn afresh: with the row redrawn on every move of the pointer, the
	/// icons would flicker.
	private static var iconCache: [pid_t: NSImage] = [:]

	private static func icon(of pid: pid_t) -> NSImage? {
		if let icon = iconCache[pid] { return icon }
		let icon = NSRunningApplication(processIdentifier: pid)?.icon
		iconCache[pid] = icon
		return icon
	}
}

/// One app icon at its own size, grey when muted.
private struct AppIcon: View {
	let image: NSImage
	let size: Double
	let muted: Bool

	var body: some View {
		Image(nsImage: image)
			.resizable()
			.aspectRatio(contentMode: .fit)
			.frame(width: size, height: size)
			.grayscale(muted ? 1 : 0)
			.opacity(muted ? 0.7 : 1)
			.animation(.easeOut(duration: 0.12), value: muted)
	}
}

/// The apps' own icons, small, the way the menu bar shows app icons. A click on one goes to that
/// app rather than to the workspace as a whole. On a hidden workspace they are grey, except the
/// one under the pointer. With magnification on they grow under the pointer, the way the Dock's do:
/// the magnifier draws them then, over the windows, and the bar keeps only their place.
private struct AppIcons: View {
	let model: BarModel
	let workspace: BarModel.Workspace

	var body: some View {
		let row = IconRow(model: model, workspace: workspace)
		let size = row.size

		HStack(spacing: row.spacing) {
			ForEach(Array(row.icons.enumerated()), id: \.element.app.id) { index, item in
				AppIcon(image: item.icon, size: size, muted: row.isMuted(index))
			}
		}
		.opacity(row.isMagnified ? 0 : 1)
		.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.iconRows[workspace.name] = $0 }
		// The icons take no events of their own: the row alone follows the pointer, and finds the icon
		// under it from the same layout the magnifier draws them by.
		.allowsHitTesting(false)
		// The pointer is followed a little past the icons, over the whole height of the bar.
		.padding(.horizontal, size / 2)
		.padding(.vertical, (model.config.height - size) / 2)
		.contentShape(Rectangle())
		.onContinuousHover { phase in
			hover(phase, size: size)
		}
		// Between the icons a click still goes to the workspace, as it does on its number.
		.onTapGesture(coordinateSpace: .local) { location in
			if let index = row.index(at: location.x - size / 2) {
				model.focusApp(row.icons[index].app.pid, workspace.name)
			} else {
				model.focusWorkspace(workspace.name)
			}
		}
		.help(row.hovered.map { row.icons[$0].app.name } ?? "")
		.padding(.horizontal, -size / 2)
		.padding(.vertical, -(model.config.height - size) / 2)
	}

	/// The model's pointer, not the one this body was drawn with: hover events come faster than the
	/// bar redraws, and a stale one would leave the icons magnified after the pointer left.
	private func hover(_ phase: HoverPhase, size: Double) {
		let name = workspace.name

		switch phase {
		case let .active(point):
			let x = point.x - size / 2
			if var current = model.pointer, current.workspace == name {
				current.x = x
				current.isOver = true
				model.pointer = current
				return
			}
			// The Dock's settings are read once per visit, not on every move.
			let largest = Magnifier.largest(for: model.config, size: size)
			model.pointer = BarModel.Pointer(workspace: name, x: x, largest: largest, isOver: largest == nil)
			// The magnifier first takes the icons over at their own size, then grows them.
			if largest != nil {
				DispatchQueue.main.async {
					MainActor.assumeIsolated {
						if model.pointer?.workspace == name { model.pointer?.isOver = true }
					}
				}
			}
		case .ended:
			guard model.pointer?.workspace == name else { return }
			guard model.pointer?.largest != nil else {
				model.pointer = nil
				return
			}
			// Back to their own size first; the bar takes them back once they are there.
			model.pointer?.isOver = false
			DispatchQueue.main.asyncAfter(deadline: .now() + Magnifier.settle) {
				MainActor.assumeIsolated {
					if let pointer = model.pointer, pointer.workspace == name, !pointer.isOver { model.pointer = nil }
				}
			}
		}
	}
}

/// The magnified icons of the bar on one display, drawn over the windows from where the bar keeps
/// their place. It takes no events: the bar under it follows the pointer and takes the clicks.
struct MagnifierView: View {
	let model: BarModel
	let display: UInt32
	/// How far the magnifier reaches above the bar.
	let lift: Double

	var body: some View {
		ZStack(alignment: .topLeading) {
			if let pointer = model.pointer, pointer.largest != nil,
			   let workspace = model.workspaces.first(where: { $0.name == pointer.workspace && $0.display == display }),
			   let frame = model.iconRows[workspace.name]
			{
				let row = IconRow(model: model, workspace: workspace)
				// Drawn at the largest size and scaled down from it: scaled up from the bar's size, an
				// icon is the bar's few pixels blown up.
				let largest = max(pointer.largest ?? row.size, row.size)

				ForEach(Array(row.icons.enumerated()), id: \.element.app.id) { index, item in
					AppIcon(image: item.icon, size: largest, muted: row.isMuted(index))
						.scaleEffect(row.scale(index) * row.size / largest, anchor: .bottom)
						.position(x: frame.minX + row.center(index), y: lift + frame.midY + (row.size - largest) / 2)
				}
				.animation(.easeOut(duration: Magnifier.settle), value: pointer)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.allowsHitTesting(false)
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
			let scale = model.config.scale
			// Drawn at Control Center's size and scaled as a whole, so its pieces stay in register.
			BatteryGlyph(battery: battery)
				.scaleEffect(scale, anchor: .topLeading)
				.frame(width: BatteryGlyph.size.width * scale, height: BatteryGlyph.size.height * scale, alignment: .topLeading)
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
	/// The outline with its cap.
	static let size = CGSize(width: body.width + 2, height: body.height)

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
		.frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
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
			let scale = model.config.scale
			Image(nsImage: badge)
				.renderingMode(.template)
				.resizable()
				.frame(width: badge.size.width * scale, height: badge.size.height * scale)
		} else if let language = model.inputLanguage {
			framed(language)
		}
	}

	private func framed(_ text: String) -> some View {
		let scale = model.config.scale

		return Text(text)
			.font(Font(BarFont.text(model.config, scale: 11 / 13)).weight(.medium))
			.padding(.horizontal, 4 * scale)
			.frame(minHeight: 16 * scale)
			.overlay(RoundedRectangle(cornerRadius: 4 * scale).stroke(.primary, lineWidth: 1.2 * scale))
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
	/// `scale` sizes a smaller label (the input source code) against the bar's text; the bar's own
	/// scale applies on top of it.
	@MainActor
	static func text(_ config: Config.Bar, scale: Double = 1) -> NSFont {
		let base = NSFont.menuBarFont(ofSize: config.fontSize)
		let size = base.pointSize * scale * config.scale

		if !config.font.isEmpty, let font = NSFont(name: config.font, size: size) {
			return font
		}

		return NSFont.menuBarFont(ofSize: size)
	}
}
