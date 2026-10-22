import AppKit
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
		case "quit":
			// After the reply is on its way: terminating right here would cut the CLI off mid-answer.
			DispatchQueue.main.async { NSApp.terminate(nil) }
			return .success()
		case "reload":
			switch app.reloadConfig() {
			case .success: return .success()
			case let .failure(error): return .failure(error.description)
			}
		case "status":
			return .success(status())
		case "query":
			return query(Array(args.dropFirst()))
		case "window", "workspace":
			guard let manager = app.manager else { return .failure("window management is not running") }
			return manager.handle(args)
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
			return json(tracker.sortedWindows.map(describe))
		case "workspaces":
			return json(app.manager?.workspaceStates ?? [])
		case "displays":
			return json(app.manager?.displayStates ?? [])
		case "focused":
			guard let id = tracker.focusedWindowID, let window = tracker.windows[id] else {
				return .failure("no focused window")
			}
			return json(describe(window))
		default:
			return .failure("usage: kumiko query windows|focused|workspaces|displays")
		}
	}

	private func describe(_ window: WindowInfo) -> QueriedWindow {
		let state = app.manager?.state(of: window.id) ?? (isFloating: true, stackIndex: 0, zoom: nil, workspace: nil)
		return QueriedWindow(
			window: window, isFloating: state.isFloating, stackIndex: state.stackIndex, zoom: state.zoom,
			workspace: state.workspace
		)
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

			if let extra = app.manager?.extraNativeSpaces {
				lines.append("  warning: \(extra) extra native Space(s); kumiko expects one per display,")
				lines.append("           remove the rest in Mission Control or their windows cannot be shown")
			}
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

/// A window as `query` prints it: what the tracker knows plus where the layout put it.
private struct QueriedWindow: Encodable {
	let window: WindowInfo
	let isFloating: Bool
	/// 1-based position in a stack, 0 when the window is not stacked.
	let stackIndex: Int
	let zoom: String?
	let workspace: String?

	func encode(to encoder: any Encoder) throws {
		// Both write into the same JSON object, so the layout fields sit next to the window's own.
		try window.encode(to: encoder)

		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(isFloating, forKey: .isFloating)
		try container.encode(stackIndex, forKey: .stackIndex)
		try container.encode(zoom, forKey: .zoom)
		try container.encode(workspace, forKey: .workspace)
	}

	private enum CodingKeys: String, CodingKey {
		case isFloating, stackIndex, zoom, workspace
	}
}
