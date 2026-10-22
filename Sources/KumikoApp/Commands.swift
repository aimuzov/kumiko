import Foundation
import KumikoCore

/// Answers the CLI. Each command is a word followed by its arguments, the way it was typed.
@MainActor
struct Commands {
	unowned let app: AppDelegate

	func handle(_ args: [String]) -> Response {
		switch args.first {
		case "ping":
			return .success("pong")
		case "version":
			return .success(Kumiko.version)
		case "reload":
			switch app.reloadConfig() {
			case .success: return .success()
			case let .failure(error): return .failure(error.description)
			}
		case "status":
			return .success(status())
		case "query":
			return query(Array(args.dropFirst()))
		case let command?:
			return .failure("unknown command: \(command)")
		case nil:
			return .failure("no command given")
		}
	}

	private func query(_ args: [String]) -> Response {
		guard let tracker = app.tracker else { return .failure("window tracking is not running") }

		switch args.first {
		case "windows":
			return json(tracker.sortedWindows)
		case "focused":
			guard let id = tracker.focusedWindowID, let window = tracker.windows[id] else {
				return .failure("no focused window")
			}
			return json(window)
		default:
			return .failure("usage: kumiko query windows|focused")
		}
	}

	/// snake_case keys, so scripts write `.is_managed` instead of quoting a key in jq.
	private func json(_ value: some Encodable) -> Response {
		let encoder = JSONEncoder()
		encoder.keyEncodingStrategy = .convertToSnakeCase
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

		guard let data = try? encoder.encode(value) else { return .failure("cannot encode the answer") }
		return .success(String(decoding: data, as: UTF8.self))
	}

	private func status() -> String {
		let config = app.config
		let modules: [(String, Bool)] = [
			("wm", config.wm.enabled),
			("hotkeys", config.hotkeys.enabled),
			("bar", config.bar.enabled),
			("borders", config.borders.enabled),
		]

		var lines = ["kumiko \(Kumiko.version)", "", "modules:"]
		lines += modules.map { "  \($0.0): \($0.1 ? "on" : "off")" }
		if let tracker = app.tracker {
			let managed = tracker.windows.values.filter(\.isManaged).count
			let state = tracker.isRunning
				? "\(tracker.windows.count) windows, \(managed) managed"
				: config.wm.enabled ? "waiting for Accessibility" : "off"
			lines.append("  windows: \(state)")
		}

		lines += ["", "permissions:"]
		lines += Permission.allCases.map { "  \($0.title): \($0.isGranted ? "granted" : "missing")" }
		lines += ["", "config: \(app.paths.configFile.path(percentEncoded: false))"]

		if let error = app.configError {
			lines.append("  error: \(error.description) (previous config in use)")
		}

		return lines.joined(separator: "\n")
	}
}
