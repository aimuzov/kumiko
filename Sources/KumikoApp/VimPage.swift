import AppKit
import KumikoCore
import SwiftUI

extension SettingsModel {
	/// An empty list takes the key out, which is its default too.
	private func setVimCommands(_ commands: [String]) {
		set("vim", "commands", commands.isEmpty ? nil : .array(commands.map(TOMLValue.string)))
	}

	func setRussianLayout(_ on: Bool) {
		setVimCommands(VimCommands.setRussianLayout(on, in: config.vim.commands))
	}

	func setOtherVimCommands(_ others: [String]) {
		setVimCommands(VimCommands.setOthers(others, in: config.vim.commands))
	}

	func addVimCommand() {
		let command = newVimCommand.trimmingCharacters(in: .whitespaces)
		guard !command.isEmpty else { return }
		setOtherVimCommands(VimCommands.others(config.vim.commands) + [command])
		if writeError == nil { newVimCommand = "" }
	}

	func setVimBlacklist(_ apps: [String]) {
		set("vim", "blacklist", apps.isEmpty ? nil : .array(apps.map(TOMLValue.string)))
	}
}

struct VimPage: View {
	@ObservedObject var model: SettingsModel

	private var vim: Config.Vim { model.config.vim }

	var body: some View {
		VStack(alignment: .leading, spacing: 20) {
			Card {
				Row(
					title: "Russian layout in Normal mode",
					detail: "Normal-mode keys work on the Russian layout too.",
					last: true
				) {
					Toggle("", isOn: Binding(
						get: { VimCommands.hasRussianLayout(vim.commands) },
						set: { model.setRussianLayout($0) }
					))
					.toggleStyle(.switch)
					.labelsHidden()
				}
			}

			blacklist
			commands
		}
	}

	private var blacklist: some View {
		AppListCard(
			title: "Off in", empty: "Vim works in every app", apps: vim.blacklist,
			removeHelp: { "Vim works in \($0) again" }, set: model.setVimBlacklist
		)
	}

	private var commands: some View {
		let others = VimCommands.others(vim.commands)
		return VStack(alignment: .leading, spacing: 6) {
			Card(title: "Commands at start") {
				ForEach(Array(others.enumerated()), id: \.offset) { index, command in
					VimCommandRow(
						command: command,
						edit: { model.setOtherVimCommands(others.replacing(index, with: $0)) },
						remove: { model.setOtherVimCommands(others.removing(index)) },
						move: { offset in model.setOtherVimCommands(others.moving(index, by: offset)) },
						canMove: { offset in others.indices.contains(index + offset) }
					)
				}
				HStack(spacing: 8) {
					TextField("Add command, like set ignorecase", text: $model.newVimCommand)
						.textFieldStyle(.roundedBorder)
						.font(.system(.body, design: .monospaced))
						.onSubmit { model.addVimCommand() }
					Button("Add") { model.addVimCommand() }
						.disabled(model.newVimCommand.trimmingCharacters(in: .whitespaces).isEmpty)
				}
				.padding(.vertical, 10)
			}

			Text("Vim commands run in this order when kumiko starts, as in svimrc.")
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
				.padding(.horizontal, 12)
		}
	}
}

/// A command as written, edited in place and written when Return is pressed or the field is left.
private struct VimCommandRow: View {
	let command: String
	let edit: (String) -> Void
	let remove: () -> Void
	let move: (Int) -> Void
	let canMove: (Int) -> Bool

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				TextField("", value: Binding(get: { command }, set: edit), format: Verbatim())
					.textFieldStyle(.plain)
					.font(.system(.body, design: .monospaced))
					.help(command)
				RemoveButton(name: command, help: "Take this command out", remove: remove)
			}
			.padding(.vertical, 8)
			Divider()
		}
		.contextMenu {
			Button("Move Up") { move(-1) }.disabled(!canMove(-1))
			Button("Move Down") { move(1) }.disabled(!canMove(1))
			Divider()
			Button("Remove", action: remove)
		}
	}
}

private extension Array where Element == String {
	func replacing(_ index: Int, with value: String) -> [String] {
		var copy = self
		copy[index] = value
		return copy
	}

	func removing(_ index: Int) -> [String] {
		var copy = self
		copy.remove(at: index)
		return copy
	}

	func moving(_ index: Int, by offset: Int) -> [String] {
		var copy = self
		copy.swapAt(index, index + offset)
		return copy
	}
}
