import AppKit
import KumikoCore
import SwiftUI

/// What the Window Rules page shows the settings of: an app, or a rule that is more than one.
enum RuleSelection: Hashable {
	case app(String)
	case pattern(Int)
}

extension SettingsModel {
	var appRules: AppRules { AppRules(config.wm.rules) }

	/// The picked app or pattern while the file has it, else the first of the list.
	var shownRule: RuleSelection? {
		let rules = appRules
		switch selectedRule {
		case let .app(name)? where rules.app(named: name) != nil: return selectedRule
		case let .pattern(index)? where rules.patterns.contains(where: { $0.index == index }): return selectedRule
		default: return rules.apps.first.map { .app($0.name) } ?? rules.patterns.first.map { .pattern($0.index) }
		}
	}

	func pickRule(_ selection: RuleSelection) {
		endTyping()
		newExceptionTitle = ""
		selectedRule = selection
	}

	func setTiles(_ tiles: Bool, of app: String) {
		change(appRules.setTiles(app, tiles))
	}

	/// The other way than the apps no rule names: going their way, the rule would change nothing.
	func addRuleApp(_ name: String) {
		change(appRules.addApp(name, tiles: !config.wm.manage))
		if writeError == nil { pickRule(.app(name)) }
	}

	func removeRule(_ selection: RuleSelection) {
		switch selection {
		case let .app(name): change(appRules.removeApp(name))
		case let .pattern(index): change(appRules.removePattern(index))
		}
		if writeError == nil, selectedRule == selection { selectedRule = nil }
	}

	func setExceptions(_ titles: [String], of app: String) {
		change(appRules.setExceptions(app, titles))
	}

	/// The typed title, or one picked from the app's open windows.
	func addException(_ title: String? = nil, to app: String) {
		let title = (title ?? newExceptionTitle).trimmingCharacters(in: .whitespaces)
		guard !title.isEmpty, let current = appRules.app(named: app)?.exceptions else { return }
		setExceptions(current + [title], of: app)
		if writeError == nil { newExceptionTitle = "" }
	}

	func setIDExceptions(_ ids: [String], of app: String) {
		change(appRules.setIDExceptions(app, ids))
	}

	/// A window picked from the app's open windows by what the app calls it.
	func addIDException(_ id: String, to app: String) {
		guard let current = appRules.app(named: app)?.idExceptions else { return }
		setIDExceptions(current + [id], of: app)
	}

	/// An empty field takes the key out: no app pattern matches every app.
	func setPattern(_ index: Int, app: String?, title: String?, id: String?, tiles: Bool) {
		func clean(_ text: String?) -> String? {
			text.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
		}
		change(appRules.setPattern(index, app: clean(app), title: clean(title), id: clean(id), tiles: tiles))
	}

	/// The workspaces that keep the app's windows in one stack, by name.
	func stackingWorkspaces(of app: String) -> [String] {
		config.workspaces.filter { $0.stack.contains(app) }.map(\.name)
	}

	func setStacks(_ on: Bool, app: String, in name: String) {
		guard let index = config.workspaces.firstIndex(where: { $0.name == name }) else { return }
		var stack = config.workspaces[index].stack.filter { $0 != app }
		if on { stack.append(app) }
		change([ConfigEdit(
			target: .entry("workspace", index), key: "stack", value: stack.isEmpty ? nil : .array(stack.map(TOMLValue.string))
		)])
	}
}

/// The words the page uses for a rule's choice.
private extension Bool {
	var tileTitle: String { self ? "Tile" : "Float" }
}

struct RulesPage: View {
	@ObservedObject var model: SettingsModel

	var body: some View {
		let rules = model.appRules

		VStack(alignment: .leading, spacing: 20) {
			Card {
				Row(
					title: "Other apps",
					detail: "Windows of the apps the list does not name.",
					reset: model.reset(\.wm.manage, "wm", "manage")
				) {
					TilePicker(tiles: Binding(get: { model.config.wm.manage }, set: { model.set("wm", "manage", .bool($0)) }))
				}
				Row(
					title: "Float settings windows",
					detail: "Windows that call themselves settings or preferences, whatever the rules below say.",
					reset: model.reset(\.wm.floatSettings, "wm", "float_settings")
				) {
					Toggle("", isOn: model.binding(\.wm.floatSettings, "wm", "float_settings"))
						.toggleStyle(.switch)
						.labelsHidden()
				}
				Row(
					title: "Float windows that cannot be resized",
					detail: "A window of one size fits no layout. Most settings windows are such.",
					last: true,
					reset: model.reset(\.wm.floatFixedSize, "wm", "float_fixed_size")
				) {
					Toggle("", isOn: model.binding(\.wm.floatFixedSize, "wm", "float_fixed_size"))
						.toggleStyle(.switch)
						.labelsHidden()
				}
			}

			// System Settings' list and detail, as on the Workspaces page.
			HStack(alignment: .top, spacing: 16) {
				RuleList(model: model, rules: rules, shown: model.shownRule)
					.frame(width: RuleList.width)

				switch model.shownRule {
				case let .app(name)?:
					if let app = rules.app(named: name) {
						AppRuleDetail(model: model, app: app).id(name)
					}
				case let .pattern(index)?:
					if let pattern = rules.patterns.first(where: { $0.index == index }) {
						PatternDetail(model: model, pattern: pattern).id(index)
					}
				case nil:
					EmptyView()
				}
			}
		}
		.onDisappear { AppIcon.forgetMissing() }
		.confirmationDialog(
			removalTitle,
			isPresented: Binding(
				get: { model.rulePendingRemoval != nil },
				set: { if !$0 { model.rulePendingRemoval = nil } }
			),
			presenting: model.rulePendingRemoval
		) { selection in
			Button("Remove", role: .destructive) { model.removeRule(selection) }
		} message: { selection in
			switch selection {
			case .app: Text("Its windows go the way of the other apps again, and its title exceptions go with it.")
			case .pattern: Text("Windows it matched go by the other rules again.")
			}
		}
	}

	private var removalTitle: String {
		switch model.rulePendingRemoval {
		case let .app(name)?: "Remove \(name)?"
		case .pattern?: "Remove this rule?"
		case nil: ""
		}
	}
}

/// `Tile | Float`, the one choice every rule makes.
private struct TilePicker: View {
	let tiles: Binding<Bool>

	var body: some View {
		Picker("", selection: tiles) {
			Text(true.tileTitle).tag(true)
			Text(false.tileTitle).tag(false)
		}
		.pickerStyle(.segmented)
		.labelsHidden()
		.fixedSize()
	}
}

/// The apps by name, then the rules that are about more than one app, in an island each, and the
/// buttons that add and take away under them.
private struct RuleList: View {
	static let width = 210.0

	@ObservedObject var model: SettingsModel
	let rules: AppRules
	let shown: RuleSelection?

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			island {
				if rules.apps.isEmpty {
					Text("No apps yet")
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, minHeight: RuleRow.height, alignment: .leading)
						.padding(.horizontal, 8)
				}
				ForEach(rules.apps, id: \.name) { app in
					RuleRow(
						title: app.name, icon: .app(AppIcon.image(for: app.name, size: 16)), value: app.tiles.tileTitle,
						selected: shown == .app(app.name)
					) { model.pickRule(.app(app.name)) }
				}
			}

			if !rules.patterns.isEmpty {
				Text("Patterns")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
					.padding(.horizontal, 8)
					.padding(.top, 6)
				island {
					ForEach(rules.patterns, id: \.index) { pattern in
						RuleRow(
							title: PatternDetail.summary(pattern.rule), icon: .none, value: pattern.rule.manage.tileTitle,
							selected: shown == .pattern(pattern.index)
						) { model.pickRule(.pattern(pattern.index)) }
					}
				}
			}

			HStack(spacing: 2) {
				AddRuleAppMenu(model: model, rules: rules)
				Button {
					if let shown { model.rulePendingRemoval = shown }
				} label: {
					Image(systemName: "minus").frame(width: 20, height: 18)
				}
				.buttonStyle(.borderless)
				.disabled(shown == nil)
				.help("Remove the selected app or rule")
			}
			.padding(.horizontal, 4)
		}
	}

	private func island(@ViewBuilder _ rows: () -> some View) -> some View {
		VStack(spacing: 0) { rows() }
			.padding(6)
			.background(RoundedRectangle(cornerRadius: CardMetrics.radius, style: .continuous).fill(.primary.opacity(0.02)))
	}
}

private struct RuleRow: View {
	static let height = 28.0

	/// An app's row always has room for an icon, a stand-in while none is found, so the names line up.
	enum Icon {
		case none
		case app(NSImage?)
	}

	let title: String
	let icon: Icon
	let value: String
	let selected: Bool
	let pick: () -> Void
	@Environment(\.controlActiveState) private var activeState

	var body: some View {
		Button(action: pick) {
			HStack(spacing: 6) {
				switch icon {
				case .none:
					EmptyView()
				case let .app(image?):
					Image(nsImage: image)
				case .app(nil):
					Image(systemName: "app.dashed")
						.font(.system(size: 12))
						.foregroundStyle(.secondary)
						.frame(width: 16, height: 16)
				}
				Text(title)
					.lineLimit(1)
					.truncationMode(.tail)
				Spacer(minLength: 4)
				Text(value)
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
			}
			.padding(.horizontal, 8)
			.frame(height: Self.height)
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

/// The list's plus: the running apps and the workspaces' apps no rule names yet, and a way to
/// pick one in /Applications.
private struct AddRuleAppMenu: View {
	@ObservedObject var model: SettingsModel
	let rules: AppRules

	var body: some View {
		Menu {
			let named = rules.apps.map(\.name)
			ForEach(candidates(excluding: named), id: \.self) { app in
				Button { model.addRuleApp(app) } label: {
					if let icon = AppIcon.image(for: app, size: 16) {
						Label { Text(app) } icon: { Image(nsImage: icon) }
					} else {
						Text(app)
					}
				}
			}
			Divider()
			Button("Choose…") {
				if let app = AddAppButton.chooseApp(), !named.contains(app) { model.addRuleApp(app) }
			}
		} label: {
			Image(systemName: "plus").frame(width: 20, height: 18)
		}
		.menuStyle(.button)
		.buttonStyle(.borderless)
		.menuIndicator(.hidden)
		.fixedSize()
		.help("Add an app")
	}

	private func candidates(excluding named: [String]) -> [String] {
		let listed = model.config.workspaces.flatMap(\.apps).compactMap { Config.Workspace.name(of: $0) }
		let all = Set(AddAppButton.running(excluding: named) + listed.filter { !named.contains($0) })
		return all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
	}
}

/// The picked app: which way its windows go, the titles that go the other way, and where they
/// are kept in one stack.
private struct AppRuleDetail: View {
	@ObservedObject var model: SettingsModel
	let app: AppRules.App

	var body: some View {
		VStack(alignment: .leading, spacing: 20) {
			Card {
				Row(title: "Windows", detail: app.tiles ? "Laid out with the others." : "Left where they open.", last: !stackable) {
					TilePicker(tiles: Binding(get: { app.tiles }, set: { model.setTiles($0, of: app.name) }))
				}
				if stackable {
					StackRow(model: model, app: app.name)
				}
			}

			Card(title: "Except these windows") {
				ForEach(app.exceptions, id: \.self) { title in
					Row(title: title) {
						removeButton(title) { model.setExceptions(app.exceptions.filter { $0 != title }, of: app.name) }
					}
				}
				// A window with no title is known by what the app calls it.
				ForEach(app.idExceptions, id: \.self) { id in
					Row(title: id, detail: "Window ID") {
						removeButton(id) { model.setIDExceptions(app.idExceptions.filter { $0 != id }, of: app.name) }
					}
					.font(.system(.body, design: .monospaced))
				}
				HStack(spacing: 8) {
					TextField("Add title", text: $model.newExceptionTitle)
						.textFieldStyle(.roundedBorder)
						.onSubmit { model.addException(to: app.name) }
					Button("Add") { model.addException(to: app.name) }
						.disabled(model.newExceptionTitle.trimmingCharacters(in: .whitespaces).isEmpty)
					OpenWindowsMenu(app: app) { window in
						switch window {
						case let .title(title): model.addException(title, to: app.name)
						case let .id(id): model.addIDException(id, to: app.name)
						}
					}
				}
				.padding(.vertical, 10)
			}

			Text(
				"Windows whose title or window ID has one of these in it \(app.tiles ? "float" : "are tiled"), "
					+ "like settings windows of an app that is otherwise tiled. Pick a window you have open to see its ID."
			)
			.font(.system(size: 11))
			.foregroundStyle(.secondary)
			.padding(.horizontal, 12)
			.padding(.top, -14)

			HStack {
				Spacer()
				Button("Remove App…", role: .destructive) { model.rulePendingRemoval = .app(app.name) }
					.buttonStyle(.bordered)
					.foregroundStyle(.red)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	/// Only with workspaces to keep a stack on.
	private var stackable: Bool { !model.config.workspaces.isEmpty }

	private func removeButton(_ name: String, remove: @escaping () -> Void) -> some View {
		Button(action: remove) {
			Image(systemName: "minus.circle.fill")
				.symbolRenderingMode(.palette)
				.foregroundStyle(.white, .red)
				.accessibilityLabel("Remove \(name)")
		}
		.buttonStyle(.borderless)
		.help("These windows go \(app.tiles ? "tiled" : "floating") again")
	}
}

/// The workspaces on which the app's windows are kept in one stack, picked in a menu.
private struct StackRow: View {
	@ObservedObject var model: SettingsModel
	let app: String

	var body: some View {
		let on = model.stackingWorkspaces(of: app)
		Row(title: "Keep windows in one stack", detail: on.isEmpty ? "Nowhere" : "On \(on.joined(separator: ", "))", last: true) {
			Menu {
				ForEach(model.config.workspaces, id: \.name) { workspace in
					Toggle(
						workspace.name,
						isOn: Binding(
							get: { on.contains(workspace.name) },
							set: { model.setStacks($0, app: app, in: workspace.name) }
						)
					)
				}
			} label: {
				Text(on.isEmpty ? "Choose" : "\(on.count) workspace\(on.count == 1 ? "" : "s")")
			}
			.menuStyle(.button)
			.buttonStyle(.bordered)
			.controlSize(.small)
			.fixedSize()
		}
	}
}

/// A rule that is not about one app, edited as it is written: regular expressions.
private struct PatternDetail: View {
	@ObservedObject var model: SettingsModel
	let pattern: AppRules.Pattern

	/// How the list names a pattern: its app pattern, or "Any app", its title pattern and its ID pattern.
	static func summary(_ rule: WindowRule) -> String {
		[rule.app ?? "Any app", rule.title.map { "“\($0)”" }, rule.id.map { "ID \($0)" }]
			.compactMap(\.self).joined(separator: " · ")
	}

	var body: some View {
		let rule = pattern.rule
		VStack(alignment: .leading, spacing: 20) {
			Card {
				Row(title: "App", detail: "A regular expression for the whole app name. Empty is any app.") {
					field(rule.app) { model.setPattern(pattern.index, app: $0, title: rule.title, id: rule.id, tiles: rule.manage) }
				}
				Row(title: "Title", detail: "A regular expression found anywhere in the window title. Empty is any title.") {
					field(rule.title) { model.setPattern(pattern.index, app: rule.app, title: $0, id: rule.id, tiles: rule.manage) }
				}
				Row(title: "Window ID", detail: "The same, for what the app calls the window. Empty is any window.") {
					field(rule.id) { model.setPattern(pattern.index, app: rule.app, title: rule.title, id: $0, tiles: rule.manage) }
				}
				Row(title: "Windows", last: true) {
					TilePicker(tiles: Binding(
						get: { rule.manage },
						set: { model.setPattern(pattern.index, app: rule.app, title: rule.title, id: rule.id, tiles: $0) }
					))
				}
			}

			HStack {
				Spacer()
				Button("Remove Rule…", role: .destructive) { model.rulePendingRemoval = .pattern(pattern.index) }
					.buttonStyle(.bordered)
					.foregroundStyle(.red)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	/// Written when Return is pressed or the field is left, like the workspace's name.
	private func field(_ value: String?, set: @escaping (String) -> Void) -> some View {
		TextField("", value: Binding(get: { value ?? "" }, set: set), format: Verbatim())
			.textFieldStyle(.roundedBorder)
			.font(.system(.body, design: .monospaced))
			.frame(maxWidth: 200)
	}
}
