import Foundation
import KumikoCore

/// Which workspace a new window goes to, from the `apps` patterns and the `default` flag of the
/// workspaces.
struct Placement {
	private let entries: [(name: String, pattern: NSRegularExpression)]
	private let fallback: String?

	init(_ workspaces: [Config.Workspace]) {
		entries = workspaces.flatMap { workspace in
			workspace.apps.compactMap { pattern in
				Config.Workspace.matcher(for: pattern).map { (workspace.name, $0) }
			}
		}
		fallback = workspaces.first(where: \.isDefault)?.name
	}

	/// The first workspace whose pattern matches, else the default one; nil leaves the choice to
	/// where the window appears.
	func workspace(for app: String) -> String? {
		let range = NSRange(app.startIndex..., in: app)
		return entries.first { $0.pattern.firstMatch(in: app, range: range) != nil }?.name ?? fallback
	}
}
