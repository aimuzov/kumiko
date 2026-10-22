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
		case let command?:
			return .failure("unknown command: \(command)")
		case nil:
			return .failure("no command given")
		}
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
		lines += ["", "permissions:"]
		lines += Permission.allCases.map { "  \($0.title): \($0.isGranted ? "granted" : "missing")" }
		lines += ["", "config: \(app.paths.configFile.path(percentEncoded: false))"]

		if let error = app.configError {
			lines.append("  error: \(error.description) (previous config in use)")
		}

		return lines.joined(separator: "\n")
	}
}
