import AppKit
import KumikoCore
import SwiftUI

/// The settings window, laid out like System Settings: a sidebar of panes, each a grouped form.
/// kumiko.toml stays the source of every value. For now the window shows what the file says and
/// opens it for editing; changing values from here waits for a writer that keeps the file as the
/// user wrote it.
@MainActor
final class SettingsWindow {
	private let model: SettingsModel
	private var window: NSWindow?
	private var closeObserver: (any NSObjectProtocol)?

	init(app: AppDelegate) {
		model = SettingsModel(configFile: app.paths.configFile, config: app.config, error: app.configError?.description)

		app.bus.subscribe { [weak self, unowned app] event in
			guard case .configReloaded = event else { return }
			self?.model.update(app.config, error: app.configError?.description)
		}
	}

	/// Shows the window, on the pane named (case does not matter) when one is.
	@discardableResult
	func show(pane name: String? = nil) -> Bool {
		if let name {
			guard let pane = Pane.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else {
				return false
			}
			model.pane = pane
		}

		if window == nil {
			let window = NSWindow(
				contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
				styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
				backing: .buffered,
				defer: false
			)
			window.title = "kumiko Settings"
			window.titlebarAppearsTransparent = true
			window.toolbarStyle = .unified
			window.isReleasedWhenClosed = false
			window.contentView = NSHostingView(rootView: SettingsView(model: model))
			window.center()
			window.setFrameAutosaveName("kumiko.settings")
			self.window = window

			closeObserver = NotificationCenter.default.addObserver(
				forName: NSWindow.willCloseNotification, object: window, queue: .main
			) { _ in
				MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
			}
		}

		// kumiko has no Dock icon, and an app without one gets no menu bar and no place in cmd-tab;
		// it has one while the window is in front, as on an empty workspace.
		NSApp.setActivationPolicy(.regular)
		NSApp.activate()
		window?.makeKeyAndOrderFront(nil)
		return true
	}
}

@MainActor
final class SettingsModel: ObservableObject {
	let configFile: URL
	@Published private(set) var config: Config
	@Published private(set) var error: String?
	// In the model rather than in @State: the State macro needs a plugin only Xcode ships.
	@Published var pane: Pane? = .general

	init(configFile: URL, config: Config, error: String?) {
		self.configFile = configFile
		self.config = config
		self.error = error
	}

	func update(_ config: Config, error: String?) {
		self.config = config
		self.error = error
	}

	func openInEditor() {
		NSWorkspace.shared.open(configFile)
	}

	func revealInFinder() {
		NSWorkspace.shared.activateFileViewerSelecting([configFile])
	}
}

enum Pane: String, CaseIterable, Identifiable {
	case general = "General"
	case windows = "Windows"
	case borders = "Borders"
	case bar = "Bar"
	case advanced = "Advanced"

	var id: Self { self }

	var symbol: String {
		switch self {
		case .general: "gearshape"
		case .windows: "rectangle.split.2x1"
		case .borders: "square.dashed"
		case .bar: "menubar.rectangle"
		case .advanced: "slider.horizontal.3"
		}
	}
}

private struct SettingsView: View {
	@ObservedObject var model: SettingsModel

	var body: some View {
		NavigationSplitView {
			List(Pane.allCases, selection: $model.pane) { pane in
				Label(pane.rawValue, systemImage: pane.symbol)
			}
			.navigationSplitViewColumnWidth(180)
		} detail: {
			Form {
				FileSection(model: model)

				switch model.pane ?? .general {
				case .general: GeneralPane(config: model.config)
				case .windows: WindowsPane(wm: model.config.wm)
				case .borders: BordersPane(borders: model.config.borders)
				case .bar: BarPane(bar: model.config.bar)
				case .advanced: AdvancedPane(config: model.config)
				}
			}
			.formStyle(.grouped)
			.navigationTitle((model.pane ?? .general).rawValue)
		}
	}
}

/// Where the values come from, and the way to change them for now.
private struct FileSection: View {
	@ObservedObject var model: SettingsModel

	var body: some View {
		Section {
			LabeledContent("Config file") {
				Text(model.configFile.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
					.textSelection(.enabled)
					.foregroundStyle(.secondary)
			}

			if let error = model.error {
				Label(error, systemImage: "exclamationmark.triangle.fill")
					.foregroundStyle(.red)
			}

			HStack {
				Text("Settings are read from the file and change when it is saved.")
					.foregroundStyle(.secondary)
				Spacer()
				Button("Reveal in Finder") { model.revealInFinder() }
				Button("Open in Editor") { model.openInEditor() }
					.keyboardShortcut("e")
			}
		}
	}
}

private struct GeneralPane: View {
	let config: Config

	var body: some View {
		Section("Modules") {
			ValueRow("Window manager", on: config.wm.enabled)
			ValueRow("Hotkeys", on: config.hotkeys.enabled)
			ValueRow("Bar", on: config.bar.enabled)
			ValueRow("Borders", on: config.borders.enabled)
			ValueRow("Vim modes in text fields", on: config.vim.enabled)
		}
	}
}

private struct WindowsPane: View {
	let wm: Config.WM

	var body: some View {
		Section("Layout") {
			ValueRow("Manage windows by default", on: wm.manage)
			LabeledContent("Gap", value: "\(wm.gap) pt")
			LabeledContent("Padding", value: Self.describe(wm.padding))
		}

		Section {
			ValueRow("Hide apps with no window on screen", on: wm.hideApps)
		} footer: {
			Text("An app whose windows are all on hidden workspaces is hidden, like cmd-h.")
				.foregroundStyle(.secondary)
		}
	}

	private static func describe(_ padding: Insets) -> String {
		let sides = [padding.top, padding.bottom, padding.left, padding.right]
		if Set(sides).count == 1 { return "\(padding.top) pt" }
		return "top \(padding.top), bottom \(padding.bottom), left \(padding.left), right \(padding.right) pt"
	}
}

private struct BordersPane: View {
	let borders: Config.Borders

	var body: some View {
		Section("Frame around the focused window") {
			ValueRow("Show border", on: borders.enabled)
			LabeledContent("Width", value: "\(Self.points(borders.width)) pt")
			LabeledContent("Corner radius", value: "\(Self.points(borders.radius)) pt")
			LabeledContent("Color") {
				RoundedRectangle(cornerRadius: 4)
					.fill(SwiftUI.Color(
						.sRGB, red: borders.color.red, green: borders.color.green, blue: borders.color.blue,
						opacity: borders.color.alpha
					))
					.frame(width: 44, height: 20)
					.overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
			}
		}

		if !borders.blacklist.isEmpty {
			Section("No border for") {
				Text(borders.blacklist.joined(separator: ", "))
					.foregroundStyle(.secondary)
			}
		}
	}

	static func points(_ value: Double) -> String {
		value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
	}
}

private struct BarPane: View {
	let bar: Config.Bar

	var body: some View {
		Section("Bar") {
			ValueRow("Show bar", on: bar.enabled)
			LabeledContent("Position", value: bar.position.rawValue.capitalized)
			LabeledContent("Height", value: "\(BordersPane.points(bar.height)) pt")
		}

		Section("Items") {
			LabeledContent("Left", value: bar.left.joined(separator: ", "))
			LabeledContent("Right", value: bar.right.joined(separator: ", "))
		}
	}
}

/// What the window does not edit even later: shown so it can be checked at a glance, changed in
/// the file.
private struct AdvancedPane: View {
	let config: Config

	var body: some View {
		Section("Workspaces") {
			if config.workspaces.isEmpty {
				Text("1…9 on the main display").foregroundStyle(.secondary)
			}
			ForEach(Array(config.workspaces.enumerated()), id: \.offset) { _, workspace in
				LabeledContent(workspace.name) {
					Text(workspace.apps.isEmpty ? workspace.display : workspace.apps.joined(separator: ", "))
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}
		}

		Section("Window rules") {
			if config.wm.rules.isEmpty {
				Text("None").foregroundStyle(.secondary)
			}
			ForEach(Array(config.wm.rules.enumerated()), id: \.offset) { _, rule in
				LabeledContent([rule.app, rule.title.map { "title ~ \($0)" }].compactMap(\.self).joined(separator: ", ")) {
					Text(rule.manage ? "managed" : "left alone").foregroundStyle(.secondary)
				}
			}
		}

		Section("Hotkeys") {
			LabeledContent("Bindings", value: String(config.hotkeys.bindings.count))
			LabeledContent("Global bindings", value: String(config.hotkeys.global.count))
			LabeledContent("Modes", value: config.hotkeys.modes.keys.sorted().joined(separator: ", "))
		}
	}
}

/// A setting that is on or off, shown as the switch it will become once the window can write.
private struct ValueRow: View {
	let title: String
	let on: Bool

	init(_ title: String, on: Bool) {
		self.title = title
		self.on = on
	}

	var body: some View {
		Toggle(title, isOn: .constant(on))
			.disabled(true)
	}
}
