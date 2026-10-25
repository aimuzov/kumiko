import ApplicationServices
import Foundation
import KumikoCore

/// Decides whether kumiko arranges a window, from the `[wm]` section of the config.
struct Rules {
	private struct Compiled {
		let app: NSRegularExpression?
		let title: NSRegularExpression?
		let id: NSRegularExpression?
		let manage: Bool
	}

	private let fallback: Bool
	private let floatSettings: Bool
	private let floatFixedSize: Bool
	private let rules: [Compiled]

	/// Patterns were already validated when the config was parsed, so a failure here cannot happen
	/// with a config that loaded; such a rule is dropped rather than crashing.
	init(_ config: Config.WM) {
		fallback = config.manage
		floatSettings = config.floatSettings
		floatFixedSize = config.floatFixedSize
		rules = (config.useRules ? config.rules : []).compactMap { rule in
			do {
				// The app pattern is anchored so that "Code" does not also catch "Xcode".
				let app = try rule.app.map { try NSRegularExpression(pattern: "^(?:\($0))$") }
				let title = try rule.title.map { try NSRegularExpression(pattern: $0) }
				let id = try rule.id.map { try NSRegularExpression(pattern: $0) }
				return Compiled(app: app, title: title, id: id, manage: rule.manage)
			} catch {
				return nil
			}
		}
	}

	/// Only standard windows are ever managed: dialogs, sheets, panels and popovers float no matter
	/// what the rules say, otherwise a "Save as…" sheet would be tiled like a document.
	///
	/// `fallback` stands in for `[wm] manage` when given: kumiko's own settings float until a rule
	/// tiles them, whatever other apps do.
	func isManaged(
		app: String, title: String, identifier: String? = nil, isResizable: Bool = true, subrole: String?,
		fallback: Bool? = nil
	) -> Bool {
		guard subrole == kAXStandardWindowSubrole as String else { return false }
		guard !floatFixedSize || isResizable else { return false }
		guard !floatSettings || !Self.isSettings(title: title, identifier: identifier) else { return false }

		var manage = fallback ?? self.fallback

		for rule in rules
		where matches(rule.app, app) && matches(rule.title, title) && matches(rule.id, identifier ?? "") {
			manage = rule.manage
		}

		return manage
	}

	/// A settings window by what the app calls it, or by a title that says nothing else. A title
	/// like "Project Settings" names a document as often as a settings window, so it is not enough.
	/// Most settings windows say neither, Calendar's is titled by its tab; they are found by their
	/// one size instead, `floatFixedSize`.
	static func isSettings(title: String, identifier: String?) -> Bool {
		let words = ["settings", "preferences"]
		if let identifier = identifier?.lowercased(), words.contains(where: identifier.contains) { return true }
		return words.contains(title.lowercased())
	}

	private func matches(_ pattern: NSRegularExpression?, _ text: String) -> Bool {
		guard let pattern else { return true }
		return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
	}
}
