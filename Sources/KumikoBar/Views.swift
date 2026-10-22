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
				HStack(spacing: 5) {
					Text("\(workspace.index)").monospacedDigit()

					if workspace.apps.isEmpty {
						Text(workspace.name).foregroundStyle(.secondary)
					} else {
						AppIcons(apps: workspace.apps)
					}
				}
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
				.foregroundStyle(Color(tints[model.mode] ?? colors.grey))
		}
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

private struct CaffeinateItem: View {
	let model: BarModel

	var body: some View {
		Image(systemName: model.isCaffeinated ? "cup.and.heat.waves.fill" : "cup.and.saucer")
			.foregroundStyle(model.isCaffeinated ? Color(model.config.colors.yellow) : .primary)
			.contentShape(Rectangle())
			.onTapGesture { model.toggleCaffeine() }
	}
}

/// The battery symbol macOS uses for the charge, and the percentage.
private struct BatteryItem: View {
	let model: BarModel

	private static func symbol(for battery: Battery.State) -> String {
		if battery.isCharging { return "battery.100percent.bolt" }
		switch battery.percent {
		case 88...: return "battery.100percent"
		case 63...: return "battery.75percent"
		case 38...: return "battery.50percent"
		case 13...: return "battery.25percent"
		default: return "battery.0percent"
		}
	}

	var body: some View {
		if let battery = model.battery {
			let colors = model.config.colors
			let symbol = Self.symbol(for: battery)
			let low = !battery.isCharging && battery.percent <= 20

			HStack(spacing: 5) {
				Text("\(battery.percent)%").monospacedDigit()
				Image(systemName: symbol).foregroundStyle(low ? Color(colors.red) : .primary)
			}
		}
	}
}

/// The input source the way macOS shows it in its input menu: the language code in a rounded
/// box. In a text field with Vim on, the Vim mode comes first as a letter in its colour, followed
/// by the command being typed after ":".
private struct InputItem: View {
	let model: BarModel

	var body: some View {
		let colors = model.config.colors
		let tints = ["N": colors.blue, "I": colors.green, "V": colors.magenta, "C": colors.orange, "_": colors.magenta]
		let layout = model.inputSource.flatMap { model.config.input[$0] } ?? model.inputLanguage ?? "?"

		HStack(spacing: 6) {
			if let mode = model.vimMode {
				Text(mode == "_" ? "…" : mode)
					.font(Font(BarFont.text(model.config)).weight(.semibold))
					.foregroundStyle(Color(colors.black))
					.frame(minWidth: 18, minHeight: 17)
					.background(RoundedRectangle(cornerRadius: 4).fill(Color(tints[mode] ?? colors.grey)))

				if let command = model.vimCommandLine {
					Text(":" + command)
				}
			}

			Text(layout)
				.font(Font(BarFont.text(model.config, scale: 11 / 13)).weight(.medium))
				.padding(.horizontal, 4)
				.frame(minHeight: 17)
				.overlay(RoundedRectangle(cornerRadius: 4).stroke(.primary, lineWidth: 1.2))
		}
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
