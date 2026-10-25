import AppKit
import KumikoCore
import SwiftUI

extension SettingsModel {
	/// Read with the file each time: only the file keeps the order of the bindings.
	var hotkeyBindings: HotkeyBindings {
		HotkeyBindings(config.hotkeys, text: (try? String(contentsOf: configFile, encoding: .utf8)) ?? "")
	}

	var shownHotkeyMode: HotkeyBindings.ModeID {
		if let selectedHotkeyMode, hotkeyBindings.mode(selectedHotkeyMode) != nil { return selectedHotkeyMode }
		return .default
	}

	/// What the recorder pressed: a new shortcut of the mode when `key` is "", else the binding's new one.
	func record(_ combo: KeyCombo, for key: String, in mode: HotkeyBindings.ModeID) {
		let bindings = hotkeyBindings
		if key.isEmpty {
			// Doing nothing until an action is picked, in the popover that opens for it.
			change(bindings.add(combo, HotkeyAction(block: true), in: mode))
			if writeError == nil { editingHotkeyAction = combo.description }
		} else {
			change(bindings.setShortcut(combo, of: key, in: mode))
		}
		recordedHotkey = nil
		recordingHotkey = nil
	}

	func setHotkeyAction(_ action: HotkeyAction, of key: String, in mode: HotkeyBindings.ModeID) {
		change(hotkeyBindings.setAction(action, of: key, in: mode))
	}

	func addHotkeyMode(_ name: String) {
		let name = name.trimmingCharacters(in: .whitespaces).lowercased()
		change(hotkeyBindings.addMode(name))
		if writeError == nil { selectedHotkeyMode = .named(name) }
	}

	func removeHotkeyMode(_ name: String) {
		change(hotkeyBindings.removeMode(name))
		if writeError == nil, selectedHotkeyMode == .named(name) { selectedHotkeyMode = nil }
	}
}

/// System Settings' list and detail, as on the Workspaces and Window Rules pages: the modes, and
/// the shortcuts of the one picked.
struct HotkeysPage: View {
	@ObservedObject var model: SettingsModel

	var body: some View {
		let bindings = model.hotkeyBindings
		let shown = model.shownHotkeyMode

		VStack(alignment: .leading, spacing: 20) {
			HStack(alignment: .top, spacing: 16) {
				ModeList(model: model, bindings: bindings, shown: shown)
					.frame(width: ModeList.width)
				if let mode = bindings.mode(shown) {
					ModeDetail(model: model, bindings: bindings, mode: mode).id(shown)
				}
			}

			Card(title: "Shortcuts are off in") {
				ForEach(model.config.hotkeys.blacklist, id: \.self) { app in
					Row(title: app) {
						RemoveButton(help: "Shortcuts work in \(app) again") {
							model.change(bindings.setBlacklist(model.config.hotkeys.blacklist.filter { $0 != app }))
						}
					}
				}
				BlacklistMenu(model: model, bindings: bindings)
					.padding(.vertical, 9)
			}

			Card(title: "When the mode changes") {
				Row(title: "Run", detail: "A shell command, with the new mode in $KUMIKO_MODE.", last: true) {
					TextField(
						"Nothing", value: Binding(
							get: { model.config.hotkeys.onModeChange ?? "" },
							set: { model.change(bindings.setOnModeChange($0)) }
						), format: Verbatim()
					)
					.textFieldStyle(.roundedBorder)
					.font(.system(.body, design: .monospaced))
					.frame(maxWidth: 260)
				}
			}
		}
		.onDisappear {
			model.recordingHotkey = nil
			model.editingHotkeyAction = nil
		}
		.alert(
			"New Mode",
			isPresented: Binding(get: { model.newHotkeyMode != nil }, set: { if !$0 { model.newHotkeyMode = nil } })
		) {
			TextField("Name", text: Binding(get: { model.newHotkeyMode ?? "" }, set: { model.newHotkeyMode = $0 }))
			Button("Add") { model.addHotkeyMode(model.newHotkeyMode ?? "") }
				.disabled(!bindings.canAddMode((model.newHotkeyMode ?? "").lowercased()))
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("Letters, digits, - and _. It starts with Esc back to the default mode.")
		}
		.confirmationDialog(
			"Remove \(model.hotkeyModePendingRemoval.map(HotkeyCatalog.modeTitle) ?? "")?",
			isPresented: Binding(
				get: { model.hotkeyModePendingRemoval != nil },
				set: { if !$0 { model.hotkeyModePendingRemoval = nil } }
			),
			presenting: model.hotkeyModePendingRemoval
		) { name in
			Button("Remove", role: .destructive) { model.removeHotkeyMode(name) }
		} message: { _ in
			Text("Its shortcuts go with it, and shortcuts elsewhere stop switching to it.")
		}
	}
}

private struct ModeList: View {
	static let width = 190.0

	@ObservedObject var model: SettingsModel
	let bindings: HotkeyBindings
	let shown: HotkeyBindings.ModeID

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			VStack(spacing: 0) {
				ForEach(Array(bindings.modes.enumerated()), id: \.element.id) { index, mode in
					if index == 2 {
						Divider().padding(.vertical, 4).padding(.horizontal, 8)
					}
					ModeRow(mode: mode, selected: mode.id == shown) {
						model.recordingHotkey = nil
						model.selectedHotkeyMode = mode.id
					}
				}
			}
			.padding(6)
			.background(RoundedRectangle(cornerRadius: CardMetrics.radius, style: .continuous).fill(.primary.opacity(0.02)))

			HStack(spacing: 2) {
				Button { model.newHotkeyMode = "" } label: { Image(systemName: "plus").frame(width: 20, height: 18) }
					.help("Add a mode")
				Button {
					if case let .named(name) = shown { model.hotkeyModePendingRemoval = name }
				} label: { Image(systemName: "minus").frame(width: 20, height: 18) }
					.disabled(!isNamed(shown))
					.help("Remove the selected mode and its shortcuts")
			}
			.buttonStyle(.borderless)
			.padding(.horizontal, 4)
		}
	}

	private func isNamed(_ id: HotkeyBindings.ModeID) -> Bool {
		if case .named = id { return true }
		return false
	}
}

private struct ModeRow: View {
	let mode: HotkeyBindings.Mode
	let selected: Bool
	let pick: () -> Void
	@Environment(\.controlActiveState) private var activeState

	var body: some View {
		Button(action: pick) {
			HStack(spacing: 6) {
				Text(mode.title).lineLimit(1)
				Spacer(minLength: 4)
				Text("\(mode.bindings.count)")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
					.monospacedDigit()
			}
			.padding(.horizontal, 8)
			.frame(height: 28)
			.background(
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.fill(SwiftUI.Color.primary.opacity(selected ? (activeState == .inactive ? 0.03 : 0.085) : 0))
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(selected ? .isSelected : [])
	}
}

/// The picked mode: how it is entered and left, then its shortcuts.
private struct ModeDetail: View {
	@ObservedObject var model: SettingsModel
	let bindings: HotkeyBindings
	let mode: HotkeyBindings.Mode

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			if case let .named(name) = mode.id {
				Card {
					Row(title: "Enter with", detail: entry(name)) { EmptyView() }
					Row(
						title: "Leave with",
						detail: leaves ? "A shortcut below that switches to another mode." : "Esc, since no shortcut here leaves.",
						last: true
					) { EmptyView() }
				}
			}

			Card {
				HStack {
					Text("Shortcut").frame(width: ShortcutColumn.width, alignment: .leading)
					Text("Action")
					Spacer()
				}
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
				.padding(.top, 10)
				.padding(.bottom, 6)

				ForEach(mode.bindings, id: \.key) { binding in
					Divider()
					BindingRow(model: model, bindings: bindings, mode: mode, binding: binding)
				}

				Divider()
				if model.recordingHotkey == "" {
					ShortcutRecorder(model: model, mode: mode, editing: nil)
						.padding(.vertical, 8)
				} else {
					Button { model.recordingHotkey = "" } label: {
						Label("Add Shortcut", systemImage: "plus")
							.frame(maxWidth: .infinity, alignment: .leading)
							.padding(.vertical, 9)
							.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	/// The shortcuts of the default mode and of every mode that switch to this one.
	private func entry(_ name: String) -> String {
		let ways = bindings.modes.filter { $0.id == .default || $0.id == .every }.flatMap { source in
			source.bindings.filter { $0.action.mode == name }.map {
				"\(HotkeyCatalog.symbols($0.combo))\(source.id == .every ? " in every mode" : "")"
			}
		}
		return ways.isEmpty ? "No shortcut switches to it yet: add one to Default or Every mode." : ways.joined(separator: ", ")
	}

	private var leaves: Bool {
		mode.bindings.contains { $0.action.mode != nil }
	}
}

private enum ShortcutColumn {
	static let width = 170.0
}

private struct BindingRow: View {
	@ObservedObject var model: SettingsModel
	let bindings: HotkeyBindings
	let mode: HotkeyBindings.Mode
	let binding: HotkeyBindings.Binding

	var body: some View {
		HStack(spacing: 12) {
			Group {
				if model.recordingHotkey == binding.key {
					ShortcutRecorder(model: model, mode: mode, editing: binding)
				} else {
					Button { model.recordingHotkey = binding.key } label: {
						KeyCaps(text: HotkeyCatalog.symbols(binding.combo))
					}
					.buttonStyle(.plain)
					.help("Click, then press the new shortcut")
				}
			}
			.frame(width: ShortcutColumn.width, alignment: .leading)

			ActionButton(model: model, mode: mode, binding: binding)

			Spacer(minLength: 8)

			RemoveButton(help: "Remove this shortcut") { model.change(bindings.remove(binding.key, from: mode.id)) }
		}
		.padding(.vertical, 6)
	}
}

private struct RemoveButton: View {
	let help: String
	let remove: () -> Void

	var body: some View {
		Button(action: remove) {
			Image(systemName: "minus.circle.fill")
				.symbolRenderingMode(.palette)
				.foregroundStyle(.white, .red)
		}
		.buttonStyle(.borderless)
		.help(help)
	}
}

/// A shortcut drawn the way macOS menus draw theirs.
private struct KeyCaps: View {
	let text: String

	var body: some View {
		Text(text)
			.font(.system(.body, design: .rounded).weight(.medium))
			.padding(.horizontal, 8)
			.padding(.vertical, 3)
			.background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.07)))
	}
}

/// Waits for a press, while kumiko's own hotkeys are paused. Esc is a key like any other, as
/// modes are left with it; the cross gives up instead.
private struct ShortcutRecorder: View {
	@ObservedObject var model: SettingsModel
	let mode: HotkeyBindings.Mode
	let editing: HotkeyBindings.Binding?

	var body: some View {
		HStack(spacing: 8) {
			if let pressed = model.recordedHotkey,
			   let taken = mode.bindings.first(where: { $0.combo == pressed && $0.key != editing?.key })
			{
				KeyCaps(text: HotkeyCatalog.symbols(pressed))
				Text("Already: \(HotkeyCatalog.title(of: taken.action))")
					.font(.system(size: 11))
					.foregroundStyle(.orange)
					.lineLimit(1)
				Button("Replace") { model.record(pressed, for: editing?.key ?? "", in: mode.id) }
					.controlSize(.small)
			} else {
				Text("Press shortcut…")
					.foregroundStyle(.secondary)
					.padding(.horizontal, 8)
					.padding(.vertical, 3)
					.background(
						RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(SwiftUI.Color.accentColor, lineWidth: 1.5)
					)
				Toggle("Only this side", isOn: $model.recordsHotkeySide)
					.toggleStyle(.checkbox)
					.controlSize(.small)
					.help("Right ⌘ apart from left ⌘, and so on: written as rcmd instead of cmd")
			}
			Button {
				model.recordedHotkey = nil
				model.recordingHotkey = nil
			} label: {
				Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
			}
			.buttonStyle(.borderless)
			.help("Keep the shortcut as it was")
		}
		.background(KeyMonitor(sided: model.recordsHotkeySide) { combo in
			let taken = mode.bindings.contains { $0.combo == combo && $0.key != editing?.key }
			if taken {
				model.recordedHotkey = combo
			} else {
				model.record(combo, for: editing?.key ?? "", in: mode.id)
			}
		})
		.onDisappear { model.recordedHotkey = nil }
	}
}

/// Catches the key presses of the settings window while it is there, before any field does.
private struct KeyMonitor: NSViewRepresentable {
	let sided: Bool
	let pressed: (KeyCombo) -> Void

	init(sided: Bool, _ pressed: @escaping (KeyCombo) -> Void) {
		self.sided = sided
		self.pressed = pressed
	}

	func makeNSView(context: Context) -> NSView {
		let view = NSView()
		let coordinator = context.coordinator
		coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
			coordinator.pressed(Self.combo(event, sided: coordinator.sided))
			return nil
		}
		return view
	}

	func updateNSView(_ view: NSView, context: Context) {
		context.coordinator.pressed = pressed
		context.coordinator.sided = sided
	}

	static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
		if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
	}

	func makeCoordinator() -> Coordinator { Coordinator(pressed, sided: sided) }

	final class Coordinator {
		var pressed: (KeyCombo) -> Void
		var sided: Bool
		var monitor: Any?

		init(_ pressed: @escaping (KeyCombo) -> Void, sided: Bool) {
			self.pressed = pressed
			self.sided = sided
		}
	}

	/// The device bits of NSEvent's flags tell left from right; without `sided`, either side.
	static func combo(_ event: NSEvent, sided: Bool) -> KeyCombo {
		let flags = event.modifierFlags
		let device = flags.rawValue
		var modifiers = Set<KeyCombo.Modifier>()

		func add(_ flag: NSEvent.ModifierFlags, either: KeyCombo.Modifier, left: KeyCombo.Modifier, right: KeyCombo.Modifier,
		         rightBit: UInt) {
			guard flags.contains(flag) else { return }
			modifiers.insert(sided ? (device & rightBit != 0 ? right : left) : either)
		}
		add(.command, either: .cmd, left: .lcmd, right: .rcmd, rightBit: 0x10)
		add(.option, either: .alt, left: .lalt, right: .ralt, rightBit: 0x40)
		add(.control, either: .ctrl, left: .lctrl, right: .rctrl, rightBit: 0x2000)
		add(.shift, either: .shift, left: .lshift, right: .rshift, rightBit: 0x04)
		return KeyCombo(keyCode: event.keyCode, modifiers: modifiers)
	}
}

/// The apps that keep every key, and a menu of the running ones to add.
private struct BlacklistMenu: View {
	@ObservedObject var model: SettingsModel
	let bindings: HotkeyBindings

	var body: some View {
		let listed = model.config.hotkeys.blacklist
		Menu {
			ForEach(AddAppButton.running(excluding: listed), id: \.self) { app in
				Button(app) { model.change(bindings.setBlacklist(listed + [app])) }
			}
			Divider()
			Button("Choose…") {
				if let app = AddAppButton.chooseApp(), !listed.contains(app) { model.change(bindings.setBlacklist(listed + [app])) }
			}
		} label: {
			Label("Add App", systemImage: "plus")
		}
		.menuStyle(.button)
		.buttonStyle(.bordered)
		.controlSize(.small)
		.fixedSize()
	}
}

/// The action in words, and a popover to pick another.
private struct ActionButton: View {
	@ObservedObject var model: SettingsModel
	let mode: HotkeyBindings.Mode
	let binding: HotkeyBindings.Binding

	var body: some View {
		let open = Binding(
			get: { model.editingHotkeyAction == binding.key },
			set: {
				model.editingHotkeyAction = $0 ? binding.key : nil
				model.recordingSentKey = false
			}
		)
		Button { open.wrappedValue = true } label: {
			Text(HotkeyCatalog.title(of: binding.action))
				.font(isCustom ? .system(.body, design: .monospaced) : .body)
				.lineLimit(1)
				.truncationMode(.tail)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help("Click to change what it does")
		.popover(isPresented: open, arrowEdge: .bottom) {
			ActionEditor(model: model, mode: mode, binding: binding)
				.padding(16)
				.frame(width: 360)
		}
	}

	private var isCustom: Bool {
		binding.action.run.map { !HotkeyCatalog.knows($0) } ?? false
	}
}

/// Do and Then: what the shortcut does, and the mode it goes to after.
private struct ActionEditor: View {
	@ObservedObject var model: SettingsModel
	let mode: HotkeyBindings.Mode
	let binding: HotkeyBindings.Binding

	private enum Kind { case command, send, block, shell, custom, onlyMode }

	private var action: HotkeyAction { binding.action }

	private var kind: Kind {
		if let run = action.run { return HotkeyCatalog.knows(run) ? .command : .custom }
		if action.shell != nil { return .shell }
		if action.send != nil { return .send }
		if action.block { return .block }
		return .onlyMode
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			line("Do") {
				Menu(doTitle) {
					ForEach(["Windows", "Workspaces", "kumiko"], id: \.self) { group in
						Section(group) {
							ForEach(HotkeyCatalog.commands.filter { $0.group == group }, id: \.title) { command in
								Button(command.title) {
									set(run: command.run(command.options(workspaces: model.config.workspaces.count).first))
								}
							}
						}
					}
					Section("Keys") {
						Button("Press another key") { model.recordingSentKey = true }
						Button("Do nothing") { set(HotkeyAction(mode: action.mode, block: true)) }
					}
					Divider()
					Button("Shell command") { set(HotkeyAction(shell: action.shell ?? "", mode: action.mode)) }
					Button("Custom command") { set(run: action.run ?? "") }
					Button("Only switch mode") { set(HotkeyAction(mode: action.mode ?? "default")) }
				}
				.fixedSize()
			}

			switch kind {
			case .command:
				if let run = action.run, let (command, option) = HotkeyCatalog.command(for: run) {
					let options = command.options(workspaces: model.config.workspaces.count)
					if !options.isEmpty {
						line("") {
							Menu(option?.title ?? "Choose") {
								ForEach(options, id: \.word) { option in
									Button(option.title) { set(run: command.run(option)) }
								}
							}
							.fixedSize()
						}
					}
				}
			case .send:
				line("") { sentKey }
			case .shell:
				line("") { field(action.shell) { set(HotkeyAction(shell: $0, mode: action.mode)) } }
			case .custom:
				line("") { field(action.run) { set(run: $0) } }
			case .block, .onlyMode:
				EmptyView()
			}
			if model.recordingSentKey, kind != .send {
				line("") { sentKey }
			}

			line("Then") {
				Menu(action.mode.map { "Switch to \(HotkeyCatalog.modeTitle($0))" } ?? "Stay in this mode") {
					Button("Stay in this mode") {
						var changed = action
						changed.mode = nil
						if kind == .onlyMode { changed.block = true }
						set(changed)
					}
					Divider()
					ForEach(switchable, id: \.self) { name in
						Button("Switch to \(HotkeyCatalog.modeTitle(name))") {
							var changed = action
							changed.mode = name
							set(changed)
						}
					}
				}
				.fixedSize()
			}
		}
	}

	/// The key the shortcut presses instead, recorded like a shortcut.
	@ViewBuilder private var sentKey: some View {
		if model.recordingSentKey {
			Text("Press the key…")
				.foregroundStyle(.secondary)
				.padding(.horizontal, 8)
				.padding(.vertical, 3)
				.background(
					RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(SwiftUI.Color.accentColor, lineWidth: 1.5)
				)
				.background(KeyMonitor(sided: false) { combo in
					model.recordingSentKey = false
					set(HotkeyAction(mode: action.mode, send: combo))
				})
				.onAppear { model.pauseHotkeys(true) }
				.onDisappear { model.pauseHotkeys(model.recordingHotkey != nil) }
		} else if let send = action.send {
			Button { model.recordingSentKey = true } label: { KeyCaps(text: HotkeyCatalog.symbols(send)) }
				.buttonStyle(.plain)
				.help("Click, then press the key")
		}
	}

	private var doTitle: String {
		switch kind {
		case .command: action.run.flatMap { HotkeyCatalog.command(for: $0)?.command.title } ?? "Command"
		case .send: "Press another key"
		case .block: "Do nothing"
		case .shell: "Shell command"
		case .custom: "Custom command"
		case .onlyMode: "Only switch mode"
		}
	}

	/// The default mode and the named ones, but not the one the shortcut is in.
	private var switchable: [String] {
		(["default"] + model.hotkeyBindings.modes.compactMap { mode in
			if case let .named(name) = mode.id { return name }
			return nil
		}).filter { name in
			switch mode.id {
			case .default: name != "default"
			case let .named(own): name != own
			case .every: true
			}
		}
	}

	private func line(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
		HStack(alignment: .firstTextBaseline) {
			Text(title).frame(width: 44, alignment: .leading)
			content()
			Spacer(minLength: 0)
		}
	}

	/// Written when Return is pressed or the field is left.
	private func field(_ value: String?, set: @escaping (String) -> Void) -> some View {
		TextField("", value: Binding(get: { value ?? "" }, set: set), format: Verbatim())
			.textFieldStyle(.roundedBorder)
			.font(.system(.body, design: .monospaced))
	}

	private func set(run: String) {
		set(HotkeyAction(run: run, mode: action.mode))
	}

	private func set(_ action: HotkeyAction) {
		model.setHotkeyAction(action, of: binding.key, in: mode.id)
	}
}
