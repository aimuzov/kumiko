import ApplicationServices
import Foundation
import KumikoCore

/// Decides whether kumiko arranges a window, from the `[wm]` section of the config.
struct Rules {
	private struct Compiled {
		let app: NSRegularExpression?
		let title: NSRegularExpression?
		let manage: Bool
	}

	private let fallback: Bool
	private let rules: [Compiled]

	/// Patterns were already validated when the config was parsed, so a failure here cannot happen
	/// with a config that loaded; such a rule is dropped rather than crashing.
	init(_ config: Config.WM) {
		fallback = config.manage
		rules = config.rules.compactMap { rule in
			do {
				// The app pattern is anchored so that "Code" does not also catch "Xcode".
				let app = try rule.app.map { try NSRegularExpression(pattern: "^(?:\($0))$") }
				let title = try rule.title.map { try NSRegularExpression(pattern: $0) }
				return Compiled(app: app, title: title, manage: rule.manage)
			} catch {
				return nil
			}
		}
	}

	/// Only standard windows are ever managed: dialogs, sheets, panels and popovers float no matter
	/// what the rules say, otherwise a "Save as…" sheet would be tiled like a document.
	func isManaged(app: String, title: String, subrole: String?) -> Bool {
		guard subrole == kAXStandardWindowSubrole as String else { return false }

		var manage = fallback

		for rule in rules where matches(rule.app, app) && matches(rule.title, title) {
			manage = rule.manage
		}

		return manage
	}

	private func matches(_ pattern: NSRegularExpression?, _ text: String) -> Bool {
		guard let pattern else { return true }
		return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
	}
}
