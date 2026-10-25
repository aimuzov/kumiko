import Foundation

extension Config.WM {
	/// Whether the window manager tiles a standard window of `app`, as far as the app alone
	/// decides: the last rule that matches it wins, as in the window manager. A rule with a title
	/// speaks about some of the app's windows, not the app, and is left out. With the rules off,
	/// `manage` alone decides.
	public func tiles(_ app: String) -> Bool {
		guard useRules else { return manage }
		let range = NSRange(app.startIndex..., in: app)
		return rules.reduce(manage) { manage, rule in
			guard rule.title == nil else { return manage }
			// Anchored the way `apps` patterns and the window manager anchor it: "Code" is not "Xcode".
			let matches = rule.app.map {
				Config.Workspace.matcher(for: $0)?.firstMatch(in: app, range: range) != nil
			} ?? true
			return matches ? rule.manage : manage
		}
	}
}
